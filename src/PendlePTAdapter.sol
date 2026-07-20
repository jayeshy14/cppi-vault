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
interface IERC20DecimalsLike {
    function decimals() external view returns (uint8);
}

interface IERC4626Like {
    function asset() external view returns (address);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

contract PendlePTAdapter is IPTAdapter, Ownable {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    IPendleRouter public immutable router;
    IPendlePYLpOracle public immutable oracle;
    address public immutable asset;
    /// @dev token the SY redeems to; if not the asset itself, it must be an
    ///      ERC-4626 vault on the asset and exits unwrap through it
    address public immutable redeemToken;
    uint256 internal immutable assetScale; // 10^(18 - assetDecimals)
    uint32 public immutable twapDuration;

    address public market;
    address public pt;
    address public yt;
    uint256 public maturity;
    uint256 public ptScale; // 10^(18 - ptDecimals), re-read on every market bind

    address public manager; // SafeLegManager, set once
    uint256 public maxSlippageBps = 50;
    uint256 public approxWindowBps = 1000; // PT-buy search window above expected

    uint256 internal constant YEAR = 365 days;

    event Deposited(uint256 assets, uint256 ptOut);
    event Withdrawn(uint256 amountWad, uint256 ptIn, uint256 assetsOut, bool viaRedemption);
    event Rolled(address indexed fromMarket, address indexed toMarket, uint256 assetsMoved, uint256 ptOut);
    event SlippageSet(uint256 bps);
    event MarketPrepared(address indexed market, uint16 cardinality);

    error NotAuthorized();
    error AlreadySet();
    error OracleNotReady();
    error IncompatibleMarket();
    error BadSlippage();
    error SlippageExceeded();

    modifier onlyManager() {
        if (msg.sender != manager && msg.sender != owner()) revert NotAuthorized();
        _;
    }

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

    function setManager(address manager_) external onlyOwner {
        if (manager != address(0)) revert AlreadySet();
        manager = manager_;
    }

    function setMaxSlippage(uint256 bps) external onlyOwner {
        if (bps > 500) revert BadSlippage();
        maxSlippageBps = bps;
        emit SlippageSet(bps);
    }

    /// @notice Width of the PT-buy binary-search window above the expected fill
    ///         (bps). Wider tolerates larger spot-vs-TWAP divergence before the
    ///         router search range reverts (audit M2). Bounded to keep the
    ///         search from overflowing router math.
    function setApproxWindowBps(uint256 bps) external onlyOwner {
        if (bps < 100 || bps > 5000) revert BadSlippage();
        approxWindowBps = bps;
    }

    /// @notice Return un-deposited deposit asset to the manager (audit M2).
    function reclaim(uint256 amount, address to) external onlyManager {
        asset.safeTransfer(to, amount);
    }

    // ---------- IPTAdapter ----------

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

    function deposit(uint256 assets) external onlyManager {
        _buyPt(assets);
    }

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

    // ---------- maturity roll ----------

    /// @notice Move the entire position into a new market in one transaction.
    ///         The old position exits at the oracle-bounded price (redemption
    ///         at par if matured); the new market must accept the deposit
    ///         asset directly and have a ready oracle.
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
    function prepareMarket(address market_) external onlyOwner {
        (bool increaseRequired, uint16 cardinalityRequired,) = oracle.getOracleState(market_, twapDuration);
        if (increaseRequired) IPendleMarket(market_).increaseObservationsCardinalityNext(cardinalityRequired);
        emit MarketPrepared(market_, cardinalityRequired);
    }

    // ---------- internal ----------

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

    function _minAssetsOut(uint256 ptIn, uint256 rate) internal view returns (uint256) {
        uint256 fairWad = (ptIn * ptScale).mulWad(rate);
        return (fairWad * (10_000 - maxSlippageBps) / 10_000) / assetScale;
    }

    function _rate() internal view returns (uint256) {
        return oracle.getPtToAssetRate(market, twapDuration);
    }

    /// @dev Exit ptIn to the deposit asset held by this contract. When the
    ///      SY redeems to a 4626 wrapper instead of the asset, unwrap it and
    ///      enforce the slippage bound on the FINAL asset amount, since the
    ///      router leg is denominated in wrapper shares.
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

    function _tokenOutput(uint256 minOut) internal view returns (TokenOutput memory) {
        return TokenOutput({
            tokenOut: redeemToken,
            minTokenOut: minOut,
            tokenRedeemSy: redeemToken,
            pendleSwap: address(0),
            swapData: SwapData(SwapType.NONE, address(0), "", false)
        });
    }

    function _emptyLimit() internal pure returns (LimitOrderData memory limit) {}
}
