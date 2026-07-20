// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {CPPIController} from "./CPPIController.sol";
import {RebalancePolicy} from "./libraries/RebalancePolicy.sol";
import {ILeg, IExecutionModule, IRateOracle} from "./interfaces/IVaultPeriphery.sol";

interface IOracleHealth {
    function healthy() external view returns (bool);
    function prolongedStale() external view returns (bool);
}

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

    // ---------- config ----------

    address public immutable asset; // deposit asset (e.g. USDC)
    uint256 internal immutable assetScale; // 10^(18 - assetDecimals)

    CPPIController public controller;
    ILeg public safeLeg;
    ILeg public riskyLeg;
    IExecutionModule public executor;
    IRateOracle public rateOracle;

    address public keeper;
    address public guardian;
    bool public paused;
    IOracleHealth public healthSource; // optional: gates NEW user flows only

    // fees: caps enforced in code, zero by default (curator loss-leader norm)
    uint16 public managementFeeBps; // per year, on shareholder NAV
    uint16 public performanceFeeBps; // on gains in navPerShare above the high-water mark
    /// @dev Per-share high-water mark: the highest navPerShare a performance
    ///      fee has been charged at. The fee applies only to gains above it,
    ///      so flat/losing terms and re-struck short terms pay nothing (audit
    ///      H1/H2). Initialized at the first startTerm.
    uint256 public highWaterPerShareWad;
    address public feeRecipient;
    uint64 public lastMgmtAccrualAt;
    uint16 public constant MAX_MANAGEMENT_FEE_BPS = 200;
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 2000;

    uint256 internal constant SCHEDULED_SLIPPAGE_BPS = 50;
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

    // ---------- async accounting ----------

    struct Request {
        uint64 epoch;
        uint192 amountWad; // deposits: asset WAD; redeems: share WAD
    }

    /// @dev ERC-7540 operator model: operator may act for a controller.
    mapping(address => mapping(address => bool)) public isOperator;

    uint64 public currentEpoch = 1;
    mapping(uint64 => uint256) public epochNavPerShare; // 0 = unsettled
    mapping(address => Request) public depositRequests;
    mapping(address => Request) public redeemRequests;
    uint256 public totalPendingDepositsWad;
    uint256 public totalPendingRedeemShares;
    uint256 public totalReservedPayoutsWad;
    // per-epoch redemption bookkeeping so the last claimant of an epoch drains
    // the aggregate-vs-per-user rounding residue (audit I1)
    mapping(uint64 => uint256) public epochReservedWad;
    mapping(uint64 => uint256) public epochRedeemRemaining;

    // ---------- events / errors ----------

    event DepositRequested(address indexed user, uint64 indexed epoch, uint256 assetsWad);
    event RedeemRequested(address indexed user, uint64 indexed epoch, uint256 shares);
    event EpochSettled(uint64 indexed epoch, uint256 navPerShare, uint256 depositsWad, uint256 redeemShares);
    event SharesClaimed(address indexed user, uint64 indexed epoch, uint256 shares);
    event AssetsClaimed(address indexed user, uint64 indexed epoch, uint256 assetsWad);
    event Rebalanced(RebalancePolicy.Trigger trigger, int256 deltaWad, uint256 floor, uint256 target);
    event PausedSet(bool paused);
    event FeesSet(uint16 managementBps, uint16 performanceBps, address recipient);
    event ManagementFeeAccrued(uint256 feeShares);
    event PerformanceFeeCharged(uint256 feeShares, uint256 gainWad);
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    event EmergencySlippageSet(uint256 bps);

    error ZeroAmount();
    error Paused();
    error NotKeeper();
    error NotGuardian();
    error NoTrigger();
    error EpochNotSettled();
    error PendingRequestFromEarlierEpoch();
    error NothingToClaim();
    error NothingToSettle();
    error InsufficientIdle();
    error AlreadySet();
    error OracleUnhealthy();
    error FeeAboveCap();
    error NotOperator();
    error ClaimMismatch();
    error SlippageOutOfRange();

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        _;
    }

    constructor(address asset_, uint8 assetDecimals, address owner_) {
        require(assetDecimals <= 18);
        asset = asset_;
        assetScale = 10 ** (18 - assetDecimals);
        _initializeOwner(owner_);
    }

    function name() public pure override returns (string memory) {
        return "CPPI Protected Vault";
    }

    function symbol() public pure override returns (string memory) {
        return "cppiVLT";
    }

    // ---------- wiring (owner, one-time for controller) ----------

    function setController(CPPIController c) external onlyOwner {
        if (address(controller) != address(0)) revert AlreadySet();
        controller = c;
    }

    function setPeriphery(ILeg safe_, ILeg risky_, IExecutionModule exec_, IRateOracle rate_) external onlyOwner {
        safeLeg = safe_;
        riskyLeg = risky_;
        executor = exec_;
        rateOracle = rate_;
        asset.safeApprove(address(exec_), type(uint256).max);
    }

    function setRoles(address keeper_, address guardian_) external onlyOwner {
        keeper = keeper_;
        guardian = guardian_;
    }

    function setHealthSource(IOracleHealth healthSource_) external onlyOwner {
        healthSource = healthSource_;
    }

    function setFees(uint16 managementBps, uint16 performanceBps, address recipient) external onlyOwner {
        if (managementBps > MAX_MANAGEMENT_FEE_BPS || performanceBps > MAX_PERFORMANCE_FEE_BPS) revert FeeAboveCap();
        _accrueManagementFee();
        managementFeeBps = managementBps;
        performanceFeeBps = performanceBps;
        feeRecipient = recipient;
        emit FeesSet(managementBps, performanceBps, recipient);
    }

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
    function setEmergencySlippageBps(uint256 bps) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        if (bps != 0 && (bps < EMERGENCY_SLIPPAGE_BPS || bps > EMERGENCY_DEGRADED_SLIPPAGE_BPS)) {
            revert SlippageOutOfRange();
        }
        emergencySlippageBps = bps;
        emit EmergencySlippageSet(bps);
    }

    // ---------- NAV ----------

    /// @notice Total value in the system, WAD asset terms.
    function totalNav() public view returns (uint256) {
        return _idleWad() + safeLeg.value() + riskyLeg.value();
    }

    /// @notice Value belonging to current shareholders: excludes unsettled
    ///         deposit cash and reserved (settled, unclaimed) redemptions.
    function shareholderNav() public view returns (uint256) {
        return totalNav() - totalPendingDepositsWad - totalReservedPayoutsWad;
    }

    function navPerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? 1e18 : shareholderNav().divWad(supply);
    }

    // ---------- requests ----------

    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function requestDeposit(uint256 assets) external returns (uint256) {
        return _requestDeposit(assets, msg.sender, msg.sender);
    }

    /// @notice ERC-7540 request form. requestId is the epoch the request
    ///         settles in; requests are fungible within an epoch.
    function requestDeposit(uint256 assets, address controller, address owner_) external returns (uint256) {
        // caller must be able to move owner_'s assets AND to write the
        // controller's request slot (audit L1): the latter blocks seeding a
        // dust request into an arbitrary controller's slot to grief it
        _authControllerOrOperator(owner_);
        _authControllerOrOperator(controller);
        return _requestDeposit(assets, controller, owner_);
    }

    function requestRedeem(uint256 shares) external returns (uint256) {
        return _requestRedeem(shares, msg.sender, msg.sender);
    }

    function requestRedeem(uint256 shares, address controller, address owner_) external returns (uint256) {
        _authControllerOrOperator(owner_);
        _authControllerOrOperator(controller); // audit L1: can't grief a foreign slot
        return _requestRedeem(shares, controller, owner_);
    }

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

    // ---------- settlement ----------

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

    function claimShares() external {
        _claimDeposit(msg.sender, msg.sender);
    }

    function claimAssets() external {
        _claimRedeem(msg.sender, msg.sender);
    }

    /// @notice ERC-7540 claim entrypoints. Deviation from the standard,
    ///         documented: claims are full-only; `assets`/`shares` must match
    ///         the whole claimable amount.
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares) {
        _authControllerOrOperator(controller);
        if (assets != claimableDepositRequest(depositRequests[controller].epoch, controller)) revert ClaimMismatch();
        return _claimDeposit(controller, receiver);
    }

    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        _authControllerOrOperator(controller);
        Request storage r = depositRequests[controller];
        uint256 price = epochNavPerShare[r.epoch];
        if (price == 0 || shares != uint256(r.amountWad).divWad(price)) revert ClaimMismatch();
        assets = uint256(r.amountWad) / assetScale;
        _claimDeposit(controller, receiver);
    }

    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        _authControllerOrOperator(controller);
        if (shares != uint256(redeemRequests[controller].amountWad)) revert ClaimMismatch();
        if (epochNavPerShare[redeemRequests[controller].epoch] == 0) revert EpochNotSettled();
        return _claimRedeem(controller, receiver);
    }

    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares) {
        _authControllerOrOperator(controller);
        Request storage r = redeemRequests[controller];
        uint256 price = epochNavPerShare[r.epoch];
        if (price == 0) revert EpochNotSettled();
        if (assets != uint256(r.amountWad).mulWad(price) / assetScale) revert ClaimMismatch();
        shares = uint256(r.amountWad);
        _claimRedeem(controller, receiver);
    }

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

    // ---------- ERC-7540 views ----------

    function pendingDepositRequest(uint256 requestId, address controller) public view returns (uint256 assets) {
        Request storage r = depositRequests[controller];
        if (r.epoch == requestId && epochNavPerShare[r.epoch] == 0) return uint256(r.amountWad) / assetScale;
    }

    function claimableDepositRequest(uint256 requestId, address controller) public view returns (uint256 assets) {
        Request storage r = depositRequests[controller];
        if (r.epoch == requestId && epochNavPerShare[r.epoch] != 0) return uint256(r.amountWad) / assetScale;
    }

    function pendingRedeemRequest(uint256 requestId, address controller) public view returns (uint256 shares) {
        Request storage r = redeemRequests[controller];
        if (r.epoch == requestId && epochNavPerShare[r.epoch] == 0) return uint256(r.amountWad);
    }

    function claimableRedeemRequest(uint256 requestId, address controller) public view returns (uint256 shares) {
        Request storage r = redeemRequests[controller];
        if (r.epoch == requestId && epochNavPerShare[r.epoch] != 0) return uint256(r.amountWad);
    }

    function totalAssets() external view returns (uint256) {
        return shareholderNav() / assetScale;
    }

    /// @notice ERC-7575 single-share-token vault: the share IS this contract.
    function share() external view returns (address) {
        return address(this);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC-165
            || interfaceId == 0xe3bc4e65 // ERC-7540 operator
            || interfaceId == 0xce3bbe50 // ERC-7540 async deposit
            || interfaceId == 0x620ee8e4; // ERC-7540 async redeem
    }

    // ---------- term lifecycle ----------

    function startTerm(uint64 duration) external onlyKeeper {
        // seed the high-water mark at the first term's entry navPerShare so the
        // performance fee is measured from real principal, not from zero
        if (highWaterPerShareWad == 0) highWaterPerShareWad = navPerShare();
        controller.startTerm(
            uint64(block.timestamp), uint64(block.timestamp) + duration, shareholderNav(), totalSupply()
        );
    }

    /// @dev Performance fee is charged only on the rise in navPerShare above
    ///      the per-share high-water mark, then the mark ratchets up. Flat or
    ///      losing terms, and re-struck short terms where navPerShare has not
    ///      advanced, pay nothing (audit H1/H2). Deposits never move
    ///      navPerShare (they mint at price), so the per-share basis is clean.
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

    // ---------- rebalancing ----------

    /// @notice Execute a rebalance if a trigger fires. Scheduled path is
    ///         keeper-gated; Emergency is permissionless and works while
    ///         paused (spec invariant 5).
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
    function freeAssets(uint256 amountWad) external onlyKeeper {
        executor.freeAssets(amountWad);
    }

    // ---------- internal ----------

    /// @dev Mint management-fee shares pro-rata to elapsed time. Dilutes all
    ///      holders equally; called before any settlement pricing so epochs
    ///      never straddle an unaccrued period.
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

    function _authControllerOrOperator(address controller) internal view {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) revert NotOperator();
    }

    function _requireOracleHealthy() internal view {
        if (address(healthSource) != address(0) && !healthSource.healthy()) revert OracleUnhealthy();
    }

    function _oracleDegraded() internal view returns (bool) {
        return address(healthSource) != address(0) && !healthSource.healthy();
    }

    function _idleWad() internal view returns (uint256) {
        return SafeTransferLib.balanceOf(asset, address(this)) * assetScale;
    }
}
