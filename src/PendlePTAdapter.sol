// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPTAdapter} from "./interfaces/IPTAdapter.sol";
import {
    IPendleRouter,
    IPendleMarket,
    IStandardizedYield,
    IPendlePYLpOracle,
    TokenInput,
    TokenOutput,
    ApproxParams,
    LimitOrderData,
    SwapData,
    SwapType
} from "./interfaces/pendle/IPendle.sol";

/// @title PendlePTAdapter
/// @notice The fixed-yield tranche of the safe leg, held as Pendle PT.
///         Fully onchain path: the market's SY must accept the deposit asset
///         directly, so no external aggregator calldata is ever needed.
/// @dev Valuation and swap bounds are anchored to the canonical PY/LP oracle
///      (TWAP), which also supplies the live implied rate for the floor.
///      Before maturity, exits swap PT through the market; after maturity,
///      exits redeem PT at par. rollToMarket moves the whole position to the
///      next maturity in one transaction so the floor leg is never without
///      fixed yield across a roll.
/// @notice Minimal view into a token's decimals, used to derive the PT scale factor.
interface IERC20DecimalsLike {
    /// @notice The token's decimal precision.
    /// @return The number of decimals the token uses.
    function decimals() external view returns (uint8);
}

/// @notice Minimal ERC-4626 view used when the SY redeems to a vault wrapper
///         rather than the deposit asset itself.
interface IERC4626Like {
    /// @notice The underlying asset the vault wraps.
    /// @return The underlying asset address.
    function asset() external view returns (address);

    /// @notice Redeem vault shares for the underlying asset.
    /// @param shares The number of vault shares to redeem.
    /// @param receiver The address that receives the underlying asset.
    /// @param owner The address whose shares are burned.
    /// @return assets The amount of underlying asset returned.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

contract PendlePTAdapter is IPTAdapter, Ownable {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    // ============================================================================
    // Configuration and state
    // ============================================================================

    /// @notice The Pendle router used to buy PT, swap PT for tokens, and redeem PT at maturity.
    IPendleRouter public immutable router;

    /// @notice The canonical Pendle PY/LP oracle that supplies the PT/asset TWAP rate.
    IPendlePYLpOracle public immutable oracle;

    /// @notice The deposit asset (e.g. USDC) that this adapter accepts and reports value in.
    address public immutable asset;

    /// @dev Token the SY redeems to; if not the asset itself, it must be an
    ///      ERC-4626 vault on the asset and exits unwrap through it.
    address public immutable redeemToken;

    /// @dev Scale factor to convert the asset's native decimals to WAD: 10^(18 - assetDecimals).
    uint256 internal immutable assetScale;

    /// @notice The TWAP window (seconds) used for all oracle rate reads.
    uint32 public immutable twapDuration;

    /// @notice The Pendle market the position is currently bound to.
    address public market;

    /// @notice The PT (principal token) of the bound market.
    address public pt;

    /// @notice The YT (yield token) of the bound market, used to redeem PY at maturity.
    address public yt;

    /// @notice Maturity timestamp of the bound market. Exits swap through the
    ///         market before this and redeem PT at par after it.
    uint256 public maturity;

    /// @dev Scale factor to convert PT native decimals to WAD: 10^(18 - ptDecimals).
    ///      Re-read on every market bind since a new market may have a different PT.
    uint256 public ptScale;

    /// @dev The SafeLegManager authorized to drive deposits, withdrawals, and rolls. Set once.
    address public manager;

    /// @notice Maximum slippage tolerated on PT buys and exits, in basis points.
    uint256 public maxSlippageBps = 50;

    /// @dev Width of the PT-buy binary-search window above the expected fill, in
    ///      basis points. Widening tolerates larger spot-vs-TWAP divergence.
    uint256 public approxWindowBps = 1000;

    /// @dev Seconds in a year, used to annualize the implied rate.
    uint256 internal constant YEAR = 365 days;

    // ============================================================================
    // Events, errors, and modifiers
    // ============================================================================

    /// @notice Emitted when deposit asset is spent to buy PT.
    /// @param assets The deposit asset amount spent, in asset native units.
    /// @param ptOut The PT received, in PT native units.
    event Deposited(uint256 assets, uint256 ptOut);

    /// @notice Emitted when PT is exited back to the deposit asset.
    /// @param amountWad The requested withdrawal amount, in WAD asset terms.
    /// @param ptIn The PT spent on the exit, in PT native units.
    /// @param assetsOut The deposit asset delivered, in asset native units.
    /// @param viaRedemption True if PT was redeemed at par (matured), false if swapped through the market.
    event Withdrawn(uint256 amountWad, uint256 ptIn, uint256 assetsOut, bool viaRedemption);

    /// @notice Emitted when the whole position is rolled from one market to the next.
    /// @param fromMarket The market exited.
    /// @param toMarket The market entered.
    /// @param assetsMoved The deposit asset carried across the roll, in asset native units.
    /// @param ptOut The PT bought in the new market, in PT native units.
    event Rolled(address indexed fromMarket, address indexed toMarket, uint256 assetsMoved, uint256 ptOut);

    /// @notice Emitted when the maximum slippage bound is updated.
    /// @param bps The new maximum slippage, in basis points.
    event SlippageSet(uint256 bps);

    /// @notice Emitted when a market's Pendle oracle cardinality is warmed up ahead of binding.
    /// @param market The market whose oracle was prepared.
    /// @param cardinality The observation cardinality requested.
    event MarketPrepared(address indexed market, uint16 cardinality);

    /// @notice Caller is neither the manager nor the owner.
    error NotAuthorized();

    /// @notice A one-time setter was called after it was already set.
    error AlreadySet();

    /// @notice The market's oracle TWAP window is not yet satisfied.
    error OracleNotReady();

    /// @notice The market cannot accept the deposit asset or redeem to the redeem token, or has expired.
    error IncompatibleMarket();

    /// @notice A slippage parameter was outside its allowed range.
    error BadSlippage();

    /// @notice A wrapper-unwrap exit delivered fewer assets than the slippage bound allows.
    error SlippageExceeded();

    /// @notice Restricts a function to the manager or the owner.
    /// @dev Reverts NotAuthorized for any other caller. The owner is always
    ///      allowed so it can act as a fallback manager.
    modifier onlyManager() {
        if (msg.sender != manager && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    // ============================================================================
    // Setup (owner, one-time wiring)
    // ============================================================================

    /// @notice Deploy the adapter, bind its first market, and set its owner.
    /// @dev Records the WAD scale factor from the asset's decimals, validates the
    ///      redeem token (asset itself or an ERC-4626 vault on the asset), binds
    ///      the initial market, and grants the router a max asset approval.
    /// @param router_ The Pendle router.
    /// @param oracle_ The Pendle PY/LP oracle.
    /// @param market_ The initial Pendle market to bind.
    /// @param asset_ The deposit asset the adapter accepts.
    /// @param redeemToken_ The token the SY redeems to (the asset, or an ERC-4626 vault on it).
    /// @param assetDecimals The asset's token decimals, used to derive the WAD scale.
    /// @param twapDuration_ The TWAP window (seconds) for oracle rate reads.
    /// @param owner_ The initial owner address.
    constructor(
        address router_,
        address oracle_,
        address market_,
        address asset_,
        address redeemToken_,
        uint8 assetDecimals,
        uint32 twapDuration_,
        address owner_
    ) {
        router = IPendleRouter(router_);
        oracle = IPendlePYLpOracle(oracle_);
        asset = asset_;
        redeemToken = redeemToken_;
        if (redeemToken_ != asset_ && IERC4626Like(redeemToken_).asset() != asset_) revert IncompatibleMarket();
        assetScale = 10 ** (18 - assetDecimals);
        twapDuration = twapDuration_;
        _initializeOwner(owner_);
        _bindMarket(market_);
        asset.safeApprove(router_, type(uint256).max);
    }

    /// @notice Set the manager address once. Can only be assigned while unset.
    /// @param manager_ The SafeLegManager authorized to drive the position.
    function setManager(address manager_) external onlyOwner {
        if (manager != address(0)) revert AlreadySet();
        manager = manager_;
    }

    /// @notice Update the maximum slippage bound applied to PT buys and exits.
    /// @param bps The new maximum slippage, in basis points (capped at 500).
    function setMaxSlippage(uint256 bps) external onlyOwner {
        if (bps > 500) revert BadSlippage();
        maxSlippageBps = bps;
        emit SlippageSet(bps);
    }

    /// @notice Width of the PT-buy binary-search window above the expected fill
    ///         (bps). Wider tolerates larger spot-vs-TWAP divergence before the
    ///         router search range reverts (audit M2). Bounded to keep the
    ///         search from overflowing router math.
    /// @param bps The new search window above expected, in basis points (100 to 5000).
    function setApproxWindowBps(uint256 bps) external onlyOwner {
        if (bps < 100 || bps > 5000) revert BadSlippage();
        approxWindowBps = bps;
    }

    /// @notice Return un-deposited deposit asset to the manager (audit M2).
    /// @param amount The deposit asset amount to return, in asset native units.
    /// @param to The recipient of the returned asset.
    function reclaim(uint256 amount, address to) external onlyManager {
        asset.safeTransfer(to, amount);
    }

    // ============================================================================
    // IPTAdapter: valuation, deposit, and withdraw
    // ============================================================================

    /// @notice PT position marked at the oracle TWAP rate, WAD asset terms.
    function value() public view returns (uint256) {
        uint256 ptBal = SafeTransferLib.balanceOf(pt, address(this));
        if (ptBal == 0) return 0;
        return (ptBal * ptScale).mulWad(_rate());
    }

    /// @notice Continuously compounded implied yield to maturity from the
    ///         oracle PT price: r = -ln(rate) / timeLeft.
    function impliedRateWad() external view returns (uint256) {
        if (block.timestamp >= maturity) return 0;
        int256 lnRate = FixedPointMathLib.lnWad(int256(_rate()));
        if (lnRate >= 0) return 0;
        uint256 timeLeftWad = (maturity - block.timestamp) * 1e18 / YEAR;
        return uint256(-lnRate).divWad(timeLeftWad);
    }

    /// @notice Spend deposit asset held by this adapter to buy PT in the bound market.
    /// @param assets The deposit asset amount to spend, in asset native units.
    function deposit(uint256 assets) external onlyManager {
        _buyPt(assets);
    }

    /// @notice Exit enough PT to raise the requested amount and send the asset to `to`.
    /// @dev Sizes the PT to spend from the oracle rate, caps it at the held
    ///      balance, and exits at par when matured or through the market otherwise.
    /// @param amountWad The target withdrawal amount, in WAD asset terms.
    /// @param to The recipient of the withdrawn deposit asset.
    /// @return assetsOut The deposit asset delivered, in asset native units.
    function withdraw(uint256 amountWad, address to) external onlyManager returns (uint256 assetsOut) {
        uint256 rate = _rate();
        uint256 ptBal = SafeTransferLib.balanceOf(pt, address(this));
        uint256 ptIn = amountWad.divWad(rate) / ptScale;
        if (ptIn > ptBal) ptIn = ptBal;
        if (ptIn == 0) return 0;

        uint256 minOut = _minAssetsOut(ptIn, rate);
        bool matured = block.timestamp >= maturity;
        assetsOut = _exitPt(ptIn, matured, minOut);
        asset.safeTransfer(to, assetsOut);
        emit Withdrawn(amountWad, ptIn, assetsOut, matured);
    }

    // ============================================================================
    // Maturity roll
    // ============================================================================

    /// @notice Move the entire position into a new market in one transaction.
    ///         The old position exits at the oracle-bounded price (redemption
    ///         at par if matured); the new market must accept the deposit
    ///         asset directly and have a ready oracle.
    /// @param newMarket The next Pendle market to bind and re-enter.
    function rollToMarket(address newMarket) external onlyManager {
        address oldMarket = market;
        uint256 ptBal = SafeTransferLib.balanceOf(pt, address(this));

        uint256 assetsMoved;
        if (ptBal > 0) {
            assetsMoved = _exitPt(ptBal, block.timestamp >= maturity, _minAssetsOut(ptBal, _rate()));
        }

        _bindMarket(newMarket);
        uint256 ptOut;
        if (assetsMoved > 0) ptOut = _buyPt(assetsMoved);
        emit Rolled(oldMarket, newMarket, assetsMoved, ptOut);
    }

    /// @notice Warm up a market's Pendle oracle ahead of binding it (audit I2).
    ///         `_bindMarket` (via the constructor or `rollToMarket`) reverts
    ///         `OracleNotReady` when the TWAP window is not yet satisfied, which
    ///         rolls back the cardinality increase issued in the same tx, so the
    ///         bump never persists and the operator is stuck. This standalone,
    ///         non-reverting call issues the increase (a permissionless one-time
    ///         market setup) so the TWAP window can start filling before the
    ///         roll. Owner-only convenience; the underlying market call is itself
    ///         permissionless, so it can also be triggered directly on the market.
    /// @param market_ The market whose oracle cardinality to warm up ahead of binding.
    function prepareMarket(address market_) external onlyOwner {
        (bool increaseRequired, uint16 cardinalityRequired,) = oracle.getOracleState(market_, twapDuration);
        if (increaseRequired) IPendleMarket(market_).increaseObservationsCardinalityNext(cardinalityRequired);
        emit MarketPrepared(market_, cardinalityRequired);
    }

    // ============================================================================
    // Internal helpers
    // ============================================================================

    /// @dev Bind the adapter to a market: validate the SY accepts the asset and
    ///      redeems to the redeem token, warm and require a ready oracle, cache
    ///      the PT/YT/maturity/scale, and approve PT to the router. Reverts if
    ///      the market is incompatible, its oracle is not ready, or it has expired.
    /// @param market_ The Pendle market to bind.
    function _bindMarket(address market_) internal {
        (address sy, address pt_, address yt_) = IPendleMarket(market_).readTokens();
        if (!IStandardizedYield(sy).isValidTokenIn(asset) || !IStandardizedYield(sy).isValidTokenOut(redeemToken)) {
            revert IncompatibleMarket();
        }
        (bool increaseRequired, uint16 cardinalityRequired, bool oldestSatisfied) =
            oracle.getOracleState(market_, twapDuration);
        // cardinality growth is a permissionless one-time market setup; issue it
        // here too, but note it only persists when this bind succeeds. For a cold
        // oracle (oldest observation not yet satisfied) the revert below rolls it
        // back, so warm the market with prepareMarket() ahead of the roll (audit I2).
        if (increaseRequired) IPendleMarket(market_).increaseObservationsCardinalityNext(cardinalityRequired);
        if (!oldestSatisfied) revert OracleNotReady();
        uint256 expiry = IPendleMarket(market_).expiry();
        if (expiry <= block.timestamp) revert IncompatibleMarket();
        market = market_;
        pt = pt_;
        yt = yt_;
        maturity = expiry;
        ptScale = 10 ** (18 - IERC20DecimalsLike(pt_).decimals());
        pt_.safeApprove(address(router), type(uint256).max);
    }

    /// @dev Buy PT with the given deposit asset amount, bounding the fill at
    ///      maxSlippageBps below the oracle-expected PT and searching within an
    ///      oracle-anchored window above it.
    /// @param assets The deposit asset amount to spend, in asset native units.
    /// @return netPtOut The PT received, in PT native units.
    function _buyPt(uint256 assets) internal returns (uint256 netPtOut) {
        // expected PT = assets / rate; bound the fill at maxSlippageBps below
        uint256 expectedPt = (assets * assetScale).divWad(_rate()) / ptScale;
        uint256 minPtOut = expectedPt * (10_000 - maxSlippageBps) / 10_000;

        TokenInput memory input = TokenInput({
            tokenIn: asset,
            netTokenIn: assets,
            tokenMintSy: asset,
            pendleSwap: address(0),
            swapData: SwapData(SwapType.NONE, address(0), "", false)
        });
        // oracle-anchored search range: the true fill lives near expectedPt,
        // so a bounded window converges fast and cannot overflow router math
        uint256 guessMax = expectedPt * (10_000 + approxWindowBps) / 10_000;
        ApproxParams memory approx = ApproxParams(minPtOut, guessMax, 0, 30, 1e14);
        (netPtOut,,) = router.swapExactTokenForPt(address(this), market, minPtOut, approx, input, _emptyLimit());
        emit Deposited(assets, netPtOut);
    }

    /// @dev Minimum acceptable asset output for exiting ptIn, the oracle-fair
    ///      value discounted by maxSlippageBps, in asset native units.
    /// @param ptIn The PT being exited, in PT native units.
    /// @param rate The oracle PT/asset rate, in WAD.
    /// @return The slippage-bounded minimum asset output, in asset native units.
    function _minAssetsOut(uint256 ptIn, uint256 rate) internal view returns (uint256) {
        uint256 fairWad = (ptIn * ptScale).mulWad(rate);
        return (fairWad * (10_000 - maxSlippageBps) / 10_000) / assetScale;
    }

    /// @dev The current oracle PT/asset TWAP rate over twapDuration.
    /// @return The PT/asset rate, in WAD.
    function _rate() internal view returns (uint256) {
        return oracle.getPtToAssetRate(market, twapDuration);
    }

    /// @dev Exit ptIn to the deposit asset held by this contract. When the
    ///      SY redeems to a 4626 wrapper instead of the asset, unwrap it and
    ///      enforce the slippage bound on the FINAL asset amount, since the
    ///      router leg is denominated in wrapper shares.
    /// @param ptIn The PT to exit, in PT native units.
    /// @param matured True to redeem PT at par, false to swap it through the market.
    /// @param minAssetsOut The minimum acceptable asset output, in asset native units.
    /// @return assetsOut The deposit asset obtained, in asset native units.
    function _exitPt(uint256 ptIn, bool matured, uint256 minAssetsOut) internal returns (uint256 assetsOut) {
        bool direct = redeemToken == asset;
        uint256 routerMin = direct ? minAssetsOut : 1;
        uint256 received;
        if (matured) {
            (received,) = router.redeemPyToToken(address(this), yt, ptIn, _tokenOutput(routerMin));
        } else {
            (received,,) =
                router.swapExactPtForToken(address(this), market, ptIn, _tokenOutput(routerMin), _emptyLimit());
        }
        if (direct) {
            assetsOut = received;
        } else {
            assetsOut = IERC4626Like(redeemToken).redeem(received, address(this), address(this));
            if (assetsOut < minAssetsOut) revert SlippageExceeded();
        }
    }

    /// @dev Build the router TokenOutput that redeems the SY to the redeem token
    ///      with no external aggregator swap.
    /// @param minOut The minimum token output enforced by the router leg.
    /// @return The populated TokenOutput for the exit.
    function _tokenOutput(uint256 minOut) internal view returns (TokenOutput memory) {
        return TokenOutput({
            tokenOut: redeemToken,
            minTokenOut: minOut,
            tokenRedeemSy: redeemToken,
            pendleSwap: address(0),
            swapData: SwapData(SwapType.NONE, address(0), "", false)
        });
    }

    /// @dev An empty limit-order struct: this adapter never uses Pendle limit orders.
    /// @return limit A zero-initialized LimitOrderData.
    function _emptyLimit() internal pure returns (LimitOrderData memory limit) {}
}
