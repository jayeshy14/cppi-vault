// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {CPPIController} from "./CPPIController.sol";
import {RebalancePolicy} from "./libraries/RebalancePolicy.sol";
import {ILeg, IExecutionModule, IRateOracle} from "./interfaces/IVaultPeriphery.sol";

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

    uint256 internal constant SCHEDULED_SLIPPAGE_BPS = 50;
    uint256 internal constant EMERGENCY_SLIPPAGE_BPS = 150;

    // ---------- async accounting ----------

    struct Request {
        uint64 epoch;
        uint192 amountWad; // deposits: asset WAD; redeems: share WAD
    }

    uint64 public currentEpoch = 1;
    mapping(uint64 => uint256) public epochNavPerShare; // 0 = unsettled
    mapping(address => Request) public depositRequests;
    mapping(address => Request) public redeemRequests;
    uint256 public totalPendingDepositsWad;
    uint256 public totalPendingRedeemShares;
    uint256 public totalReservedPayoutsWad;

    // ---------- events / errors ----------

    event DepositRequested(address indexed user, uint64 indexed epoch, uint256 assetsWad);
    event RedeemRequested(address indexed user, uint64 indexed epoch, uint256 shares);
    event EpochSettled(uint64 indexed epoch, uint256 navPerShare, uint256 depositsWad, uint256 redeemShares);
    event SharesClaimed(address indexed user, uint64 indexed epoch, uint256 shares);
    event AssetsClaimed(address indexed user, uint64 indexed epoch, uint256 assetsWad);
    event Rebalanced(RebalancePolicy.Trigger trigger, int256 deltaWad, uint256 floor, uint256 target);
    event PausedSet(bool paused);

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

    function setPaused(bool paused_) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        paused = paused_;
        emit PausedSet(paused_);
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

    function requestDeposit(uint256 assets) external {
        if (paused) revert Paused();
        if (assets == 0) revert ZeroAmount();
        Request storage r = depositRequests[msg.sender];
        if (r.amountWad != 0 && r.epoch != currentEpoch) revert PendingRequestFromEarlierEpoch();
        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 wad = assets * assetScale;
        r.epoch = currentEpoch;
        r.amountWad += uint192(wad);
        totalPendingDepositsWad += wad;
        emit DepositRequested(msg.sender, currentEpoch, wad);
    }

    function requestRedeem(uint256 shares) external {
        if (paused) revert Paused();
        if (shares == 0) revert ZeroAmount();
        Request storage r = redeemRequests[msg.sender];
        if (r.amountWad != 0 && r.epoch != currentEpoch) revert PendingRequestFromEarlierEpoch();
        _transfer(msg.sender, address(this), shares); // lock shares in custody
        r.epoch = currentEpoch;
        r.amountWad += uint192(shares);
        totalPendingRedeemShares += shares;
        emit RedeemRequested(msg.sender, currentEpoch, shares);
    }

    // ---------- settlement ----------

    /// @notice Settle the current epoch at one NAV per share: mint aggregate
    ///         shares for pending deposits into custody, burn locked redeem
    ///         shares, and reserve their payout. Requires enough idle asset
    ///         to cover reserved payouts (keeper frees assets beforehand).
    function settleEpoch() external onlyKeeper {
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
            totalPendingRedeemShares = 0;
        }

        currentEpoch = epoch + 1;
        emit EpochSettled(epoch, price, depositsWad, redeemShares);
    }

    function claimShares() external {
        Request storage r = depositRequests[msg.sender];
        uint256 price = epochNavPerShare[r.epoch];
        if (r.amountWad == 0) revert NothingToClaim();
        if (price == 0) revert EpochNotSettled();
        uint256 shares = uint256(r.amountWad).divWad(price);
        uint64 epoch = r.epoch;
        delete depositRequests[msg.sender];
        _transfer(address(this), msg.sender, shares);
        emit SharesClaimed(msg.sender, epoch, shares);
    }

    function claimAssets() external {
        Request storage r = redeemRequests[msg.sender];
        uint256 price = epochNavPerShare[r.epoch];
        if (r.amountWad == 0) revert NothingToClaim();
        if (price == 0) revert EpochNotSettled();
        uint256 payoutWad = uint256(r.amountWad).mulWad(price);
        uint64 epoch = r.epoch;
        delete redeemRequests[msg.sender];
        totalReservedPayoutsWad -= payoutWad;
        asset.safeTransfer(msg.sender, payoutWad / assetScale);
        emit AssetsClaimed(msg.sender, epoch, payoutWad);
    }

    // ---------- term lifecycle ----------

    function startTerm(uint64 duration) external onlyKeeper {
        controller.startTerm(uint64(block.timestamp), uint64(block.timestamp) + duration, shareholderNav());
    }

    function settleTerm() external onlyKeeper returns (uint256 shortfall) {
        return controller.settleTerm(shareholderNav());
    }

    // ---------- rebalancing ----------

    /// @notice Execute a rebalance if a trigger fires. Scheduled path is
    ///         keeper-gated; Emergency is permissionless and works while
    ///         paused (spec invariant 5).
    function rebalance() external returns (RebalancePolicy.Trigger trigger) {
        CPPIController.Assessment memory a = controller.assess(shareholderNav(), riskyLeg.value(), rateOracle.rateWad());
        trigger = a.trigger;
        if (trigger == RebalancePolicy.Trigger.None) revert NoTrigger();
        if (trigger == RebalancePolicy.Trigger.Scheduled && msg.sender != keeper && msg.sender != owner()) {
            revert NotKeeper();
        }

        int256 deltaWad = int256(a.targetRisky) - int256(riskyLeg.value());
        uint256 bound = trigger == RebalancePolicy.Trigger.Emergency ? EMERGENCY_SLIPPAGE_BPS : SCHEDULED_SLIPPAGE_BPS;
        executor.executeRebalance(deltaWad, bound);
        controller.recordRebalance(trigger, a.floor, a.targetRisky);
        emit Rebalanced(trigger, deltaWad, a.floor, a.targetRisky);
    }

    /// @notice Keeper pre-funds redemption settlement from the safe side.
    function freeAssets(uint256 amountWad) external onlyKeeper {
        executor.freeAssets(amountWad);
    }

    // ---------- internal ----------

    function _idleWad() internal view returns (uint256) {
        return SafeTransferLib.balanceOf(asset, address(this)) * assetScale;
    }
}
