// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {CPPIController} from "./CPPIController.sol";
import {RebalancePolicy} from "./libraries/RebalancePolicy.sol";
import {ILeg, IExecutionModule, IRateOracle} from "./interfaces/IVaultPeriphery.sol";
import {IOracleHealth} from "./interfaces/IOracleHealth.sol";

/// @title CPPIVault
/// @notice Term-based capital-protected vault share token with asynchronous,
///         epoch-settled deposits and redemptions. Holds idle deposit asset;
///         leg values and trade execution live behind ILeg/IExecutionModule.
/// @dev Async model: requests accrue during an epoch and settle at a single
///      NAV-per-share when the keeper settles the epoch, then claims pull
///      from vault custody at that fixed price. Pending deposit cash and
///      reserved redemption payouts are excluded from shareholder NAV, so
///      request timing cannot dilute existing holders (spec invariant 6).
///      The protection promise applies to shares held to term maturity;
///      early redemptions settle at NAV with no floor claim.
contract CPPIVault is ERC20, Ownable {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    // ============================================================================
    // Configuration and state
    // ============================================================================

    /// @notice The deposit asset (e.g. USDC) that the vault accepts.
    address public immutable asset;

    /// @notice Scale factor to convert the asset's native decimals to WAD (18 decimals).
    uint256 internal immutable assetScale;

    /// @notice The controller that manages the CPPI strategy and term lifecycle.
    CPPIController public controller;

    /// @notice The safe leg: the capital-protection side, held in a Pendle PT (a
    ///         zero-coupon-bond-like instrument) plus a liquid asset buffer.
    ILeg public safeLeg;

    /// @notice The risky leg: the growth side, held as ETH exposure (WETH plus a
    ///         capped wstETH fraction).
    ILeg public riskyLeg;

    /// @notice The execution module that handles rebalancing trades.
    IExecutionModule public executor;

    /// @notice The rate oracle that provides the current interest rate for the CPPI strategy.
    IRateOracle public rateOracle;

    /// @notice The keeper address that is authorized to perform certain actions on the vault.
    address public keeper;

    /// @notice The guardian address that can pause the vault and set emergency parameters.
    address public guardian;

    /// @notice Indicates whether the vault is paused, preventing new deposits and redemptions.
    bool public paused;

    /// @notice The health source that provides oracle health information, gating new user flows.
    IOracleHealth public healthSource;

    /// @notice Management fee in basis points (bps) per year, charged on shareholder NAV.
    uint16 public managementFeeBps;

    /// @notice Performance fee in basis points (bps) on gains in NAV per share above the high-water mark.
    uint16 public performanceFeeBps;

    /// @notice The per-share high-water mark for the performance fee: the highest
    ///         navPerShare a fee has been charged at. The fee applies only to gains
    ///         above it, so flat/losing terms and re-struck short terms pay nothing
    ///         (audit H1/H2). Initialized at the first startTerm.
    uint256 public highWaterPerShareWad;

    /// @notice The recipient address for management and performance fees.
    address public feeRecipient;

    /// @notice Timestamp of the last management fee accrual, used to calculate the fee over time.
    uint64 public lastMgmtAccrualAt;

    /// @notice Maximum allowed management fee in basis points (bps) per year.
    uint16 public constant MAX_MANAGEMENT_FEE_BPS = 200;

    /// @notice Maximum allowed performance fee in basis points (bps) on gains.
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 2000;

    /// @dev Tight bound for a keeper-gated scheduled rebalance, in basis points.
    uint256 internal constant SCHEDULED_SLIPPAGE_BPS = 50;

    /// @dev Tight bound used for a permissionless emergency de-risk while the oracle is healthy (audit H6).
    uint256 internal constant EMERGENCY_SLIPPAGE_BPS = 150;

    /// @dev Wider bound used for an emergency de-risk while the oracle is
    ///      unhealthy (audit H6). A stale feed serves a last-good price that
    ///      lags a fast fall; the tight 150bps bound would then make the swap
    ///      unfillable and brick the very defense it must run. Executing at a
    ///      wider bound during a genuine feed outage beats not de-risking.
    uint256 internal constant EMERGENCY_DEGRADED_SLIPPAGE_BPS = 1000;

    /// @dev Guardian-settable widening of the *healthy-oracle* emergency bound
    ///      (audit L6). 0 (default) uses EMERGENCY_SLIPPAGE_BPS. During a genuine
    ///      thin- or attacker-thinned-liquidity dislocation the permissionless
    ///      de-risk can miss the tight 150bps bound and revert; the guardian may
    ///      widen it, up to the already-sanctioned degraded ceiling, so the
    ///      defense still clears. Widening trades more single-swap sandwich
    ///      exposure (audit L7) for guaranteed execution, so it is a deliberate,
    ///      resettable knob that never loosens the scheduled or degraded bounds.
    uint256 public emergencySlippageBps;

    // ============================================================================
    // Async deposit/redeem state and operator model
    // ============================================================================

    /// @notice Async deposit/redeem request data structure, tracking the epoch and amount in WAD.
    /// @param epoch The epoch in which the request was made.
    /// @param amountWad The amount of assets (for deposits) or shares (for redemptions) in WAD.
    struct Request {
        uint64 epoch;
        uint192 amountWad;
    }

    /// @notice Mapping of controller addresses to operator approvals, allowing operators to act on behalf of controllers.
    mapping(address => mapping(address => bool)) public isOperator;

    /// @notice The current epoch number, incremented with each settlement.
    uint64 public currentEpoch = 1;

    /// @notice Mapping of epoch numbers to NAV per share at settlement, with 0 indicating unsettled epochs.
    mapping(uint64 => uint256) public epochNavPerShare;

    /// @notice Mapping of controller addresses to their pending deposit requests.
    mapping(address => Request) public depositRequests;

    /// @notice Mapping of controller addresses to their pending redeem requests.
    mapping(address => Request) public redeemRequests;

    /// @notice Total pending deposits in WAD, representing the sum of all deposit requests not yet settled.
    uint256 public totalPendingDepositsWad;

    /// @notice Total pending redeem shares, representing the sum of all redeem requests not yet settled.
    uint256 public totalPendingRedeemShares;

    /// @notice Total reserved payouts in WAD, representing the sum of all settled but unclaimed redemptions.
    uint256 public totalReservedPayoutsWad;

    /// @notice Per-epoch reserved payout in WAD. Together with epochRedeemRemaining
    ///         this lets the last claimant of an epoch drain the aggregate-vs-per-user
    ///         rounding residue instead of leaving it frozen in shareholderNav (audit I1).
    mapping(uint64 => uint256) public epochReservedWad;

    /// @notice Per-epoch redeem shares still unclaimed. Reaching 0 marks the last
    ///         claimant, who then drains the epoch's rounding residue (audit I1).
    mapping(uint64 => uint256) public epochRedeemRemaining;

    // ============================================================================
    // Events, errors, and modifiers
    // ============================================================================

    /// @notice Emitted when a deposit request is queued into an epoch.
    /// @param user The controller whose request slot was credited.
    /// @param epoch The epoch the request settles in.
    /// @param assetsWad The requested deposit amount, in WAD.
    event DepositRequested(address indexed user, uint64 indexed epoch, uint256 assetsWad);

    /// @notice Emitted when a redeem request is queued into an epoch.
    /// @param user The controller whose request slot was credited.
    /// @param epoch The epoch the request settles in.
    /// @param shares The share amount locked for redemption, in WAD.
    event RedeemRequested(address indexed user, uint64 indexed epoch, uint256 shares);

    /// @notice Emitted when an epoch is settled at a single navPerShare.
    /// @param epoch The epoch that was settled.
    /// @param navPerShare The price struck for the epoch, in WAD.
    /// @param depositsWad Aggregate deposits minted at settlement, in WAD.
    /// @param redeemShares Aggregate shares burned at settlement, in WAD.
    event EpochSettled(uint64 indexed epoch, uint256 navPerShare, uint256 depositsWad, uint256 redeemShares);

    /// @notice Emitted when a settled deposit is claimed for its shares.
    /// @param user The controller whose deposit was claimed.
    /// @param epoch The epoch the deposit settled in.
    /// @param shares The shares delivered, in WAD.
    event SharesClaimed(address indexed user, uint64 indexed epoch, uint256 shares);

    /// @notice Emitted when a settled redemption is claimed for its assets.
    /// @param user The controller whose redemption was claimed.
    /// @param epoch The epoch the redemption settled in.
    /// @param assetsWad The payout, in WAD.
    event AssetsClaimed(address indexed user, uint64 indexed epoch, uint256 assetsWad);

    /// @notice Emitted after a rebalance moves the risky leg toward its target.
    /// @param trigger Which trigger fired (Scheduled or Emergency).
    /// @param deltaWad Signed change in risky exposure applied, in WAD.
    /// @param floor The floor the assessment was taken against, in WAD.
    /// @param target The target risky exposure, in WAD.
    event Rebalanced(RebalancePolicy.Trigger trigger, int256 deltaWad, uint256 floor, uint256 target);

    /// @notice Emitted when the guardian/owner pauses or unpauses user flows.
    /// @param paused The new paused state.
    event PausedSet(bool paused);

    /// @notice Emitted when fee parameters are updated.
    /// @param managementBps The new management fee, in basis points per year.
    /// @param performanceBps The new performance fee, in basis points.
    /// @param recipient The new fee recipient.
    event FeesSet(uint16 managementBps, uint16 performanceBps, address recipient);

    /// @notice Emitted when management-fee shares are accrued and minted.
    /// @param feeShares The shares minted to the fee recipient.
    event ManagementFeeAccrued(uint256 feeShares);

    /// @notice Emitted when a performance fee is charged at term settlement.
    /// @param feeShares The shares minted to the fee recipient.
    /// @param gainWad The gain the fee was charged on, in WAD.
    event PerformanceFeeCharged(uint256 feeShares, uint256 gainWad);

    /// @notice Emitted when a controller sets or revokes an operator.
    /// @param controller The controller granting/revoking authority.
    /// @param operator The operator being set.
    /// @param approved The new approval state.
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /// @notice Emitted when the guardian/owner widens or resets the healthy-oracle
    ///         emergency slippage bound.
    /// @param bps The new override, in basis points (0 resets to the tight default).
    event EmergencySlippageSet(uint256 bps);

    /// @notice A user-supplied amount was zero.
    error ZeroAmount();

    /// @notice User flow attempted while the vault is paused.
    error Paused();

    /// @notice Caller is neither the keeper nor the owner.
    error NotKeeper();

    /// @notice Caller is neither the guardian nor the owner.
    error NotGuardian();

    /// @notice A rebalance was requested with no active trigger.
    error NoTrigger();

    /// @notice Claim/redeem attempted before the request's epoch was settled.
    error EpochNotSettled();

    /// @notice A controller already has a pending request from an earlier epoch.
    error PendingRequestFromEarlierEpoch();

    /// @notice Claim attempted with no claimable request.
    error NothingToClaim();

    /// @notice settleEpoch called with no pending deposits or redemptions.
    error NothingToSettle();

    /// @notice Not enough idle asset to reserve the settled redemption payouts.
    error InsufficientIdle();

    /// @notice A one-time setter was called after it was already set.
    error AlreadySet();

    /// @notice Oracle health gate failed (unhealthy, or the wrong health state).
    error OracleUnhealthy();

    /// @notice A fee parameter exceeds its hard cap.
    error FeeAboveCap();

    /// @notice Caller is neither the controller nor its operator.
    error NotOperator();

    /// @notice A full-only claim amount did not match the whole claimable amount.
    error ClaimMismatch();

    /// @notice An emergency slippage override was outside [tight, degraded].
    error SlippageOutOfRange();

    /// @notice Refused to settle an epoch at a zero navPerShare (audit: G2 guard).
    error NavCollapsed();

    /// @notice Restricts a function to the keeper or the owner.
    /// @dev Reverts NotKeeper for any other caller. The owner is always allowed
    ///      so it can act as a fallback keeper.
    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        _;
    }

    /// @notice Deploy the vault for a given deposit asset and set its owner.
    /// @dev Records the WAD scale factor from the asset's decimals so all
    ///      internal accounting can run in 18-decimal fixed point regardless of
    ///      the asset's native precision. Rejects assets with more than 18
    ///      decimals, which the scale factor cannot represent.
    /// @param asset_ The deposit asset the vault accepts.
    /// @param assetDecimals The asset's token decimals (must be <= 18).
    /// @param owner_ The initial owner address.
    constructor(address asset_, uint8 assetDecimals, address owner_) {
        require(assetDecimals <= 18);
        asset = asset_;
        assetScale = 10 ** (18 - assetDecimals);
        _initializeOwner(owner_);
    }

    /// @notice The ERC-20 name of the share token.
    /// @return The human-readable token name.
    function name() public pure override returns (string memory) {
        return "CPPI Protected Vault";
    }

    /// @notice The ERC-20 symbol of the share token.
    /// @return The token symbol.
    function symbol() public pure override returns (string memory) {
        return "cppiVLT";
    }

    // ============================================================================
    // Wiring (owner, one-time setup)
    // ============================================================================

    /// @notice Wire the CPPI controller once, at setup.
    /// @dev One-time setter: reverts AlreadySet if the controller is already
    ///      configured, so the strategy brain cannot be swapped after launch.
    /// @param c The controller that manages the CPPI strategy and term lifecycle.
    function setController(CPPIController c) external onlyOwner {
        if (address(controller) != address(0)) revert AlreadySet();
        controller = c;
    }

    /// @notice Wire the periphery modules and grant the executor spend approval.
    /// @dev Approves the executor to pull the deposit asset up to the max so it
    ///      can fund rebalancing trades without per-trade approvals.
    /// @param safe_ The safe (capital-protection) leg.
    /// @param risky_ The risky (growth) leg.
    /// @param exec_ The execution module that runs rebalancing trades.
    /// @param rate_ The rate oracle feeding the CPPI strategy.
    function setPeriphery(ILeg safe_, ILeg risky_, IExecutionModule exec_, IRateOracle rate_) external onlyOwner {
        safeLeg = safe_;
        riskyLeg = risky_;
        executor = exec_;
        rateOracle = rate_;
        asset.safeApprove(address(exec_), type(uint256).max);
    }

    /// @notice Set the keeper and guardian role addresses.
    /// @param keeper_ The keeper authorized for scheduled operational actions.
    /// @param guardian_ The guardian authorized to pause and set emergency params.
    function setRoles(address keeper_, address guardian_) external onlyOwner {
        keeper = keeper_;
        guardian = guardian_;
    }

    /// @notice Set the oracle health source that gates new user flows.
    /// @param healthSource_ The health source; the zero address disables the gate.
    function setHealthSource(IOracleHealth healthSource_) external onlyOwner {
        healthSource = healthSource_;
    }

    /// @notice Update fee parameters and the fee recipient.
    /// @dev Enforces the hard caps and accrues the outstanding management fee at
    ///      the old rate before switching, so the rate change never applies
    ///      retroactively to elapsed time.
    /// @param managementBps The new management fee, in basis points per year.
    /// @param performanceBps The new performance fee, in basis points.
    /// @param recipient The new fee recipient.
    function setFees(uint16 managementBps, uint16 performanceBps, address recipient) external onlyOwner {
        if (managementBps > MAX_MANAGEMENT_FEE_BPS || performanceBps > MAX_PERFORMANCE_FEE_BPS) revert FeeAboveCap();
        _accrueManagementFee();
        managementFeeBps = managementBps;
        performanceFeeBps = performanceBps;
        feeRecipient = recipient;
        emit FeesSet(managementBps, performanceBps, recipient);
    }

    /// @notice Pause or unpause user deposit and redeem flows.
    /// @dev Guardian- or owner-gated. Pausing halts new requests but leaves the
    ///      permissionless emergency de-risk operational (spec invariant 5).
    /// @param paused_ The new paused state.
    function setPaused(bool paused_) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Widen (or reset) the healthy-oracle emergency de-risk bound so a
    ///         thin/attacker-thinned pool cannot indefinitely revert the
    ///         permissionless defense (audit L6). 0 resets to the tight default;
    ///         any override stays within [EMERGENCY_SLIPPAGE_BPS,
    ///         EMERGENCY_DEGRADED_SLIPPAGE_BPS] so it can only ever widen the
    ///         tight bound toward the already-sanctioned degraded ceiling.
    /// @dev Guardian- or owner-gated. Reverts SlippageOutOfRange for any nonzero
    ///      value outside [EMERGENCY_SLIPPAGE_BPS, EMERGENCY_DEGRADED_SLIPPAGE_BPS].
    /// @param bps The new override, in basis points; 0 resets to the tight default.
    function setEmergencySlippageBps(uint256 bps) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        if (bps != 0 && (bps < EMERGENCY_SLIPPAGE_BPS || bps > EMERGENCY_DEGRADED_SLIPPAGE_BPS)) {
            revert SlippageOutOfRange();
        }
        emergencySlippageBps = bps;
        emit EmergencySlippageSet(bps);
    }

    // ============================================================================
    // NAV accounting
    // ============================================================================

    /// @notice Total value in the system, WAD asset terms.
    /// @return The sum of idle asset plus both leg values, in WAD.
    function totalNav() public view returns (uint256) {
        return _idleWad() + safeLeg.value() + riskyLeg.value();
    }

    /// @notice Value belonging to current shareholders: excludes unsettled
    ///         deposit cash and reserved (settled, unclaimed) redemptions.
    /// @return The shareholder-owned NAV, in WAD.
    function shareholderNav() public view returns (uint256) {
        return totalNav() - totalPendingDepositsWad - totalReservedPayoutsWad;
    }

    /// @notice The current NAV per share.
    /// @dev Returns 1e18 when no shares are outstanding, seeding the price at par.
    /// @return The price per share, in WAD.
    function navPerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? 1e18 : shareholderNav().divWad(supply);
    }

    // ============================================================================
    // Deposit and redeem requests
    // ============================================================================

    /// @notice Grant or revoke an operator that may act on the caller's behalf.
    /// @param operator The operator being set for msg.sender as controller.
    /// @param approved The new approval state.
    /// @return Always true, per the ERC-7540 operator interface.
    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @notice Queue a deposit request for the caller, as both controller and owner.
    /// @param assets The deposit amount, in the asset's native decimals.
    /// @return The epoch the request settles in (its ERC-7540 requestId).
    function requestDeposit(uint256 assets) external returns (uint256) {
        return _requestDeposit(assets, msg.sender, msg.sender);
    }

    /// @notice ERC-7540 request form. requestId is the epoch the request
    ///         settles in; requests are fungible within an epoch.
    /// @dev The caller must be authorized over both owner_ (to move its assets)
    ///      and controller (to write its request slot). Gating the controller
    ///      too blocks seeding a dust request into an arbitrary controller's slot
    ///      to grief it (audit L1).
    /// @param assets The deposit amount, in the asset's native decimals.
    /// @param controller The controller whose request slot is credited.
    /// @param owner_ The address whose assets are pulled in.
    /// @return The epoch the request settles in (its ERC-7540 requestId).
    function requestDeposit(uint256 assets, address controller, address owner_) external returns (uint256) {
        // caller must be able to move owner_'s assets AND to write the
        // controller's request slot (audit L1): the latter blocks seeding a
        // dust request into an arbitrary controller's slot to grief it
        _authControllerOrOperator(owner_);
        _authControllerOrOperator(controller);
        return _requestDeposit(assets, controller, owner_);
    }

    /// @notice Queue a redeem request for the caller, as both controller and owner.
    /// @param shares The share amount to lock for redemption, in WAD.
    /// @return The epoch the request settles in (its ERC-7540 requestId).
    function requestRedeem(uint256 shares) external returns (uint256) {
        return _requestRedeem(shares, msg.sender, msg.sender);
    }

    /// @notice ERC-7540 redeem request form on behalf of a controller and owner.
    /// @dev The caller must be authorized over both owner_ (to move its shares)
    ///      and controller (to write its request slot); gating the controller
    ///      blocks griefing a foreign slot (audit L1).
    /// @param shares The share amount to lock for redemption, in WAD.
    /// @param controller The controller whose request slot is credited.
    /// @param owner_ The address whose shares are locked in custody.
    /// @return The epoch the request settles in (its ERC-7540 requestId).
    function requestRedeem(uint256 shares, address controller, address owner_) external returns (uint256) {
        _authControllerOrOperator(owner_);
        _authControllerOrOperator(controller); // audit L1: can't grief a foreign slot
        return _requestRedeem(shares, controller, owner_);
    }

    /// @notice Shared deposit-request logic: pull assets and accrue into the
    ///         controller's slot for the current epoch.
    /// @dev Reverts while paused or when the oracle is unhealthy, and blocks a
    ///      new request if the controller still has an unsettled request from an
    ///      earlier epoch. Amounts are scaled to WAD for internal accounting.
    /// @param assets The deposit amount, in the asset's native decimals.
    /// @param controller The controller whose request slot is credited.
    /// @param owner_ The address whose assets are pulled in.
    /// @return The current epoch, in which the request settles.
    function _requestDeposit(uint256 assets, address controller, address owner_) internal returns (uint256) {
        if (paused) revert Paused();
        _requireOracleHealthy();
        if (assets == 0) revert ZeroAmount();
        Request storage r = depositRequests[controller];
        if (r.amountWad != 0 && r.epoch != currentEpoch) revert PendingRequestFromEarlierEpoch();
        asset.safeTransferFrom(owner_, address(this), assets);
        uint256 wad = assets * assetScale;
        r.epoch = currentEpoch;
        r.amountWad += uint192(wad);
        totalPendingDepositsWad += wad;
        emit DepositRequested(controller, currentEpoch, wad);
        return currentEpoch;
    }

    /// @notice Shared redeem-request logic: lock shares in custody and accrue
    ///         into the controller's slot for the current epoch.
    /// @dev Reverts while paused or when the oracle is unhealthy, and blocks a
    ///      new request if the controller still has an unsettled request from an
    ///      earlier epoch. Shares are transferred to the vault to lock them.
    /// @param shares The share amount to lock for redemption, in WAD.
    /// @param controller The controller whose request slot is credited.
    /// @param owner_ The address whose shares are locked in custody.
    /// @return The current epoch, in which the request settles.
    function _requestRedeem(uint256 shares, address controller, address owner_) internal returns (uint256) {
        if (paused) revert Paused();
        _requireOracleHealthy();
        if (shares == 0) revert ZeroAmount();
        Request storage r = redeemRequests[controller];
        if (r.amountWad != 0 && r.epoch != currentEpoch) revert PendingRequestFromEarlierEpoch();
        _transfer(owner_, address(this), shares); // lock shares in custody
        r.epoch = currentEpoch;
        r.amountWad += uint192(shares);
        totalPendingRedeemShares += shares;
        emit RedeemRequested(controller, currentEpoch, shares);
        return currentEpoch;
    }

    // ============================================================================
    // Epoch settlement
    // ============================================================================

    /// @notice Settle the current epoch at one NAV per share: mint aggregate
    ///         shares for pending deposits into custody, burn locked redeem
    ///         shares, and reserve their payout. Requires enough idle asset
    ///         to cover reserved payouts (keeper frees assets beforehand).
    function settleEpoch() external onlyKeeper {
        _requireOracleHealthy(); // L5: don't crystallize value at a stale/depegged price
        _accrueManagementFee();
        uint256 depositsWad = totalPendingDepositsWad;
        uint256 redeemShares = totalPendingRedeemShares;
        if (depositsWad == 0 && redeemShares == 0) revert NothingToSettle();

        uint256 price = navPerShare();
        // A collapsed NAV (shareholderNav == 0 while shares are outstanding)
        // makes navPerShare 0, which is the "unsettled" sentinel for
        // epochNavPerShare (and a divide-by-zero for the deposit-share mint).
        // Settling here would poison the epoch: every claim/view then reads it
        // as unsettled and reverts EpochNotSettled forever, permanently locking
        // the requests. Refuse to settle a 0-price epoch; it becomes settleable
        // again if NAV recovers above 0, and holders keep their shares/requests
        // meanwhile (fairer than crystallizing a 0 payout).
        if (price == 0) revert NavCollapsed();
        uint64 epoch = currentEpoch;
        epochNavPerShare[epoch] = price;

        if (depositsWad != 0) {
            _mint(address(this), depositsWad.divWad(price));
            totalPendingDepositsWad = 0;
        }
        if (redeemShares != 0) {
            uint256 payoutWad = redeemShares.mulWad(price);
            if (_idleWad() < totalReservedPayoutsWad + payoutWad) revert InsufficientIdle();
            _burn(address(this), redeemShares);
            totalReservedPayoutsWad += payoutWad;
            epochReservedWad[epoch] = payoutWad;
            epochRedeemRemaining[epoch] = redeemShares;
            totalPendingRedeemShares = 0;
        }

        currentEpoch = epoch + 1;
        emit EpochSettled(epoch, price, depositsWad, redeemShares);
    }

    /// @notice Claim the shares from the caller's settled deposit request.
    function claimShares() external {
        _claimDeposit(msg.sender, msg.sender);
    }

    /// @notice Claim the assets from the caller's settled redeem request.
    function claimAssets() external {
        _claimRedeem(msg.sender, msg.sender);
    }

    /// @notice ERC-7540 claim entrypoints. Deviation from the standard,
    ///         documented: claims are full-only; `assets`/`shares` must match
    ///         the whole claimable amount.
    /// @dev Claim the settled deposit for a controller. `assets` must equal the
    ///      whole claimable amount or it reverts ClaimMismatch.
    /// @param assets The full claimable deposit amount, in native decimals.
    /// @param receiver The address that receives the minted shares.
    /// @param controller The controller whose settled deposit is claimed.
    /// @return shares The shares delivered to the receiver, in WAD.
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares) {
        _authControllerOrOperator(controller);
        if (assets != claimableDepositRequest(depositRequests[controller].epoch, controller)) revert ClaimMismatch();
        return _claimDeposit(controller, receiver);
    }

    /// @notice ERC-7540 full-only mint claim: deliver the settled deposit shares.
    /// @dev `shares` must equal the whole claimable share amount at the settled
    ///      price or it reverts ClaimMismatch.
    /// @param shares The full claimable share amount, in WAD.
    /// @param receiver The address that receives the shares.
    /// @param controller The controller whose settled deposit is claimed.
    /// @return assets The assets that funded the claim, in native decimals.
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        _authControllerOrOperator(controller);
        Request storage r = depositRequests[controller];
        uint256 price = epochNavPerShare[r.epoch];
        if (price == 0 || shares != uint256(r.amountWad).divWad(price)) revert ClaimMismatch();
        assets = uint256(r.amountWad) / assetScale;
        _claimDeposit(controller, receiver);
    }

    /// @notice ERC-7540 full-only redeem claim: pay out the settled redemption.
    /// @dev `shares` must equal the whole locked redeem amount, and the epoch
    ///      must be settled, or it reverts.
    /// @param shares The full locked redeem share amount, in WAD.
    /// @param receiver The address that receives the assets.
    /// @param controller The controller whose settled redemption is claimed.
    /// @return assets The payout delivered, in native decimals.
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        _authControllerOrOperator(controller);
        if (shares != uint256(redeemRequests[controller].amountWad)) revert ClaimMismatch();
        if (epochNavPerShare[redeemRequests[controller].epoch] == 0) revert EpochNotSettled();
        return _claimRedeem(controller, receiver);
    }

    /// @notice ERC-7540 full-only withdraw claim: pay out the settled redemption
    ///         expressed as an asset amount.
    /// @dev The epoch must be settled and `assets` must equal the whole payout at
    ///      the settled price or it reverts.
    /// @param assets The full claimable payout, in native decimals.
    /// @param receiver The address that receives the assets.
    /// @param controller The controller whose settled redemption is claimed.
    /// @return shares The locked shares burned for the payout, in WAD.
    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares) {
        _authControllerOrOperator(controller);
        Request storage r = redeemRequests[controller];
        uint256 price = epochNavPerShare[r.epoch];
        if (price == 0) revert EpochNotSettled();
        if (assets != uint256(r.amountWad).mulWad(price) / assetScale) revert ClaimMismatch();
        shares = uint256(r.amountWad);
        _claimRedeem(controller, receiver);
    }

    /// @notice Shared deposit-claim logic: deliver settled shares and clear the slot.
    /// @dev Reverts NothingToClaim if the slot is empty or EpochNotSettled if its
    ///      epoch has no struck price. Deletes the request before transferring the
    ///      shares out of custody.
    /// @param controller The controller whose settled deposit is claimed.
    /// @param receiver The address that receives the shares.
    /// @return shares The shares delivered, in WAD.
    function _claimDeposit(address controller, address receiver) internal returns (uint256 shares) {
        Request storage r = depositRequests[controller];
        uint256 price = epochNavPerShare[r.epoch];
        if (r.amountWad == 0) revert NothingToClaim();
        if (price == 0) revert EpochNotSettled();
        shares = uint256(r.amountWad).divWad(price);
        uint64 epoch = r.epoch;
        delete depositRequests[controller];
        _transfer(address(this), receiver, shares);
        emit SharesClaimed(controller, epoch, shares);
    }

    /// @notice Shared redeem-claim logic: pay out the settled redemption and
    ///         clear the slot.
    /// @dev Reverts NothingToClaim if the slot is empty or EpochNotSettled if its
    ///      epoch has no struck price. The last redeemer of the epoch drains the
    ///      aggregate-vs-per-user rounding residue so it does not stay frozen in
    ///      shareholderNav (audit I1).
    /// @param controller The controller whose settled redemption is claimed.
    /// @param receiver The address that receives the assets.
    /// @return assets The payout delivered, in native decimals.
    function _claimRedeem(address controller, address receiver) internal returns (uint256 assets) {
        Request storage r = redeemRequests[controller];
        uint256 price = epochNavPerShare[r.epoch];
        if (r.amountWad == 0) revert NothingToClaim();
        if (price == 0) revert EpochNotSettled();
        uint256 shares = uint256(r.amountWad);
        uint256 payoutWad = shares.mulWad(price);
        uint64 epoch = r.epoch;
        delete redeemRequests[controller];
        totalReservedPayoutsWad -= payoutWad;
        epochReservedWad[epoch] -= payoutWad;
        epochRedeemRemaining[epoch] -= shares;
        // last redeemer of the epoch: drain the aggregate-vs-per-user rounding
        // residue so it doesn't stay frozen in shareholderNav (audit I1)
        if (epochRedeemRemaining[epoch] == 0 && epochReservedWad[epoch] != 0) {
            totalReservedPayoutsWad -= epochReservedWad[epoch];
            epochReservedWad[epoch] = 0;
        }
        assets = payoutWad / assetScale;
        asset.safeTransfer(receiver, assets);
        emit AssetsClaimed(controller, epoch, payoutWad);
    }

    // ============================================================================
    // Claims and ERC-7540 views
    // ============================================================================

    /// @notice ERC-7540 pending (not-yet-settled) deposit amount for a request.
    /// @param requestId The epoch the request was made in.
    /// @param controller The controller whose request is queried.
    /// @return assets The pending deposit amount in native decimals, or 0 if the
    ///         request is absent, from another epoch, or already settled.
    function pendingDepositRequest(uint256 requestId, address controller) public view returns (uint256 assets) {
        Request storage r = depositRequests[controller];
        if (r.epoch == requestId && epochNavPerShare[r.epoch] == 0) return uint256(r.amountWad) / assetScale;
    }

    /// @notice ERC-7540 claimable (settled) deposit amount for a request.
    /// @param requestId The epoch the request was made in.
    /// @param controller The controller whose request is queried.
    /// @return assets The claimable deposit amount in native decimals, or 0 if
    ///         the request is absent, from another epoch, or not yet settled.
    function claimableDepositRequest(uint256 requestId, address controller) public view returns (uint256 assets) {
        Request storage r = depositRequests[controller];
        if (r.epoch == requestId && epochNavPerShare[r.epoch] != 0) return uint256(r.amountWad) / assetScale;
    }

    /// @notice ERC-7540 pending (not-yet-settled) redeem shares for a request.
    /// @param requestId The epoch the request was made in.
    /// @param controller The controller whose request is queried.
    /// @return shares The pending redeem shares in WAD, or 0 if the request is
    ///         absent, from another epoch, or already settled.
    function pendingRedeemRequest(uint256 requestId, address controller) public view returns (uint256 shares) {
        Request storage r = redeemRequests[controller];
        if (r.epoch == requestId && epochNavPerShare[r.epoch] == 0) return uint256(r.amountWad);
    }

    /// @notice ERC-7540 claimable (settled) redeem shares for a request.
    /// @param requestId The epoch the request was made in.
    /// @param controller The controller whose request is queried.
    /// @return shares The claimable redeem shares in WAD, or 0 if the request is
    ///         absent, from another epoch, or not yet settled.
    function claimableRedeemRequest(uint256 requestId, address controller) public view returns (uint256 shares) {
        Request storage r = redeemRequests[controller];
        if (r.epoch == requestId && epochNavPerShare[r.epoch] != 0) return uint256(r.amountWad);
    }

    /// @notice Shareholder-owned assets, in the asset's native decimals.
    /// @return The shareholder NAV converted from WAD to native decimals.
    function totalAssets() external view returns (uint256) {
        return shareholderNav() / assetScale;
    }

    /// @notice ERC-7575 single-share-token vault: the share IS this contract.
    /// @return The share token address (this contract).
    function share() external view returns (address) {
        return address(this);
    }

    /// @notice ERC-165 interface detection.
    /// @param interfaceId The interface identifier to check.
    /// @return True for ERC-165 and the ERC-7540 operator, async-deposit, and
    ///         async-redeem interfaces; false otherwise.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC-165
            || interfaceId == 0xe3bc4e65 // ERC-7540 operator
            || interfaceId == 0xce3bbe50 // ERC-7540 async deposit
            || interfaceId == 0x620ee8e4; // ERC-7540 async redeem
    }

    // ============================================================================
    // Term lifecycle and fees
    // ============================================================================

    /// @notice Start a new capital-protection term of the given duration.
    /// @dev Keeper-gated. Seeds the performance-fee high-water mark at the first
    ///      term's entry navPerShare so the fee is measured from real principal,
    ///      not from zero, then hands the term parameters to the controller.
    /// @param duration The term length in seconds, added to the current timestamp
    ///        to set the maturity.
    function startTerm(uint64 duration) external onlyKeeper {
        // seed the high-water mark at the first term's entry navPerShare so the
        // performance fee is measured from real principal, not from zero
        if (highWaterPerShareWad == 0) highWaterPerShareWad = navPerShare();
        controller.startTerm(
            uint64(block.timestamp), uint64(block.timestamp) + duration, shareholderNav(), totalSupply()
        );
    }

    /// @notice Settle the active term, accrue fees, and report any shortfall.
    /// @dev Performance fee is charged only on the rise in navPerShare above
    ///      the per-share high-water mark, then the mark ratchets up. Flat or
    ///      losing terms, and re-struck short terms where navPerShare has not
    ///      advanced, pay nothing (audit H1/H2). Deposits never move
    ///      navPerShare (they mint at price), so the per-share basis is clean.
    /// @return shortfall The term shortfall reported by the controller, in WAD.
    function settleTerm() external onlyKeeper returns (uint256 shortfall) {
        _accrueManagementFee();
        uint256 supply = totalSupply();
        uint256 nav = shareholderNav();
        shortfall = controller.settleTerm(nav, supply);
        if (performanceFeeBps == 0 || feeRecipient == address(0) || supply == 0) return shortfall;

        uint256 navPS = navPerShare();
        uint256 hwm = highWaterPerShareWad;
        if (navPS > hwm) {
            uint256 gainWad = (navPS - hwm).mulWad(supply);
            uint256 feeWad = gainWad * performanceFeeBps / 10_000;
            uint256 feeShares = feeWad.divWad(navPS);
            highWaterPerShareWad = navPS; // ratchet the mark up
            _mint(feeRecipient, feeShares);
            emit PerformanceFeeCharged(feeShares, gainWad);
        }
    }

    // ============================================================================
    // Rebalancing and emergency de-risk
    // ============================================================================

    /// @notice Execute a rebalance if a trigger fires. Scheduled path is
    ///         keeper-gated; Emergency is permissionless and works while
    ///         paused (spec invariant 5).
    /// @dev Reverts NoTrigger when neither trigger is active, and NotKeeper when
    ///      a Scheduled trigger is invoked by a non-keeper. The slippage bound is
    ///      chosen per trigger and, for Emergency, per oracle health.
    /// @return trigger The trigger that fired and was executed.
    function rebalance() external returns (RebalancePolicy.Trigger trigger) {
        CPPIController.Assessment memory a =
            controller.assess(shareholderNav(), totalSupply(), riskyLeg.value(), rateOracle.rateWad());
        trigger = a.trigger;
        if (trigger == RebalancePolicy.Trigger.None) revert NoTrigger();
        if (trigger == RebalancePolicy.Trigger.Scheduled && msg.sender != keeper && msg.sender != owner()) {
            revert NotKeeper();
        }

        int256 deltaWad = int256(a.targetRisky) - int256(riskyLeg.value());
        uint256 bound;
        if (trigger == RebalancePolicy.Trigger.Emergency) {
            // relax the bound while the oracle is degraded so a lagging feed
            // cannot brick the permissionless de-risk (audit H6); when the feed
            // is healthy use the guardian-configurable bound, which widens the
            // tight default only during a declared thin-liquidity dislocation
            // (audit L6) and defaults to EMERGENCY_SLIPPAGE_BPS
            if (_oracleDegraded()) {
                bound = EMERGENCY_DEGRADED_SLIPPAGE_BPS;
            } else {
                bound = emergencySlippageBps == 0 ? EMERGENCY_SLIPPAGE_BPS : emergencySlippageBps;
            }
        } else {
            bound = SCHEDULED_SLIPPAGE_BPS;
        }
        executor.executeRebalance(deltaWad, bound);
        controller.recordRebalance(trigger, a.floor, a.targetRisky);
        emit Rebalanced(trigger, deltaWad, a.floor, a.targetRisky);
    }

    /// @notice Permissionless circuit breaker (audit M4). When the oracle has
    ///         been stale beyond its prolonged window, the risky-leg mark is
    ///         frozen and the normal CPPI trigger is blind to a real decline,
    ///         so anyone may fully de-risk the vault into the safe leg at the
    ///         degraded bound. Over-conservative but floor-safe: a later
    ///         rebalance re-risks once the feed recovers.
    function deRiskUnderProlongedStaleness() external {
        if (address(healthSource) == address(0) || !healthSource.prolongedStale()) revert OracleUnhealthy();
        uint256 risky = riskyLeg.value();
        if (risky == 0) revert NoTrigger();
        executor.executeRebalance(-int256(risky), EMERGENCY_DEGRADED_SLIPPAGE_BPS);
        emit Rebalanced(RebalancePolicy.Trigger.Emergency, -int256(risky), 0, 0);
    }

    /// @notice Keeper pre-funds redemption settlement from the safe side.
    /// @param amountWad The asset amount to free into idle custody, in WAD.
    function freeAssets(uint256 amountWad) external onlyKeeper {
        executor.freeAssets(amountWad);
    }

    // ============================================================================
    // Internal helpers
    // ============================================================================

    /// @notice Accrue and mint the management fee owed since the last accrual.
    /// @dev Mint management-fee shares pro-rata to elapsed time. Dilutes all
    ///      holders equally; called before any settlement pricing so epochs
    ///      never straddle an unaccrued period. No-ops when the fee is off, there
    ///      is no recipient, no prior accrual timestamp, or no supply.
    function _accrueManagementFee() internal {
        uint64 last = lastMgmtAccrualAt;
        lastMgmtAccrualAt = uint64(block.timestamp);
        if (managementFeeBps == 0 || feeRecipient == address(0) || last == 0 || totalSupply() == 0) return;
        uint256 elapsed = block.timestamp - last;
        if (elapsed == 0) return;
        uint256 feeWad = shareholderNav() * managementFeeBps * elapsed / (10_000 * 365 days);
        if (feeWad == 0) return;
        uint256 feeShares = feeWad.divWad(navPerShare());
        _mint(feeRecipient, feeShares);
        emit ManagementFeeAccrued(feeShares);
    }

    /// @notice Require that the caller is the controller itself or its operator.
    /// @dev Reverts NotOperator otherwise.
    /// @param controller The controller whose authority is being checked.
    function _authControllerOrOperator(address controller) internal view {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) revert NotOperator();
    }

    /// @notice Require the oracle be healthy (or unconfigured) to proceed.
    /// @dev Reverts OracleUnhealthy when a health source is set and reports
    ///      unhealthy; a zero health source disables the gate.
    function _requireOracleHealthy() internal view {
        if (address(healthSource) != address(0) && !healthSource.healthy()) revert OracleUnhealthy();
    }

    /// @notice Whether the oracle is configured and currently unhealthy.
    /// @return True if a health source is set and reports unhealthy.
    function _oracleDegraded() internal view returns (bool) {
        return address(healthSource) != address(0) && !healthSource.healthy();
    }

    /// @notice The idle deposit asset held directly by the vault, in WAD.
    /// @return The vault's asset balance scaled to WAD.
    function _idleWad() internal view returns (uint256) {
        return SafeTransferLib.balanceOf(asset, address(this)) * assetScale;
    }
}
