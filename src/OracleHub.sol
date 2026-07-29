// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPriceSource} from "./interfaces/IExecutionPeriphery.sol";
import {IRateOracle} from "./interfaces/IVaultPeriphery.sol";
import {IPTAdapter} from "./interfaces/IPTAdapter.sol";

/// @notice Minimal Chainlink aggregator surface (price feed plus decimals).
interface IChainlinkFeed {
    /// @notice Latest round data from the aggregator.
    /// @return roundId The round the answer was computed in.
    /// @return answer The reported price, in feed decimals.
    /// @return startedAt When the round started.
    /// @return updatedAt When the answer was last updated (used for staleness).
    /// @return answeredInRound The round the answer was carried over from.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice The feed's answer decimals, used to scale the price to WAD.
    /// @return The number of decimals the feed reports.
    function decimals() external view returns (uint8);
}

/// @notice Minimal wstETH surface: the Lido stETH-per-wstETH exchange rate.
interface IWstETHRate {
    /// @notice stETH per wstETH, the fundamental (non-manipulable) redemption rate.
    /// @return The exchange rate, in WAD.
    function stEthPerToken() external view returns (uint256);
}

/// @notice Minimal Uniswap V3 pool surface: the current spot (slot0).
interface IUniV3PoolSlot0 {
    /// @notice Current pool slot0 state.
    /// @return sqrtPriceX96 The current sqrt price as a Q64.96.
    /// @return tick The current tick.
    /// @return obsIndex The most recent observation index.
    /// @return obsCard The current observation cardinality.
    /// @return obsCardNext The next observation cardinality.
    /// @return feeProtocol The protocol fee setting.
    /// @return unlocked Whether the pool is unlocked.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 obsIndex,
            uint16 obsCard,
            uint16 obsCardNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

/// @title OracleHub
/// @notice The vault's single price and rate authority. Chainlink ETH/USD
///         with staleness handling, wstETH marked at the LOWER of its
///         exchange-rate value and the pool spot when they disagree beyond
///         the basis limit, and the live PT-implied yield for the floor.
/// @dev Degradation semantics per spec section 8: when the feed goes stale,
///      getters serve the last refreshed snapshot so REBALANCING NEVER HALTS,
///      while healthy() flips false so the vault pauses new deposits. Anyone
///      may call refresh() to update snapshots while the feed is fresh.
contract OracleHub is IPriceSource, IRateOracle, Ownable {
    using FixedPointMathLib for uint256;

    // ============================================================================
    // Configuration and state
    // ============================================================================

    /// @notice The Chainlink ETH/USD price feed.
    IChainlinkFeed public immutable ethUsdFeed;

    /// @notice The wstETH exchange-rate source (Lido stEthPerToken).
    IWstETHRate public immutable wsteth;

    /// @notice The wstETH/WETH Uniswap V3 pool, read as a depeg gate only.
    IUniV3PoolSlot0 public immutable wstethWethPool;

    /// @notice The PT adapter that supplies the live implied floor rate.
    IPTAdapter public ptAdapter;

    /// @notice Whether wstETH is token0 in wstethWethPool, fixing the ratio orientation.
    bool public immutable wstethIsToken0;

    /// @notice Max age (seconds) before the ETH/USD feed is considered stale.
    uint256 public maxFeedAge = 3900; // Chainlink ETH/USD heartbeat 3600 + margin

    /// @notice Max tolerated basis (bps) between the wstETH exchange rate and pool spot before buys are blocked.
    uint256 public maxBasisBps = 200;

    /// @dev Optional USDC/USD feed (audit L8). The vault denominates in USDC
    ///      but marks the risky leg in USD; if unset, USDC is assumed at par.
    ///      When set and USDC depegs beyond maxUsdcDepegBps, healthy() flips
    ///      false so deposits/settlement pause until the peg returns.
    IChainlinkFeed public usdcUsdFeed;

    /// @notice Max tolerated USDC depeg (bps) before healthy() flips false (audit L8).
    uint256 public maxUsdcDepegBps = 200;

    /// @dev Prolonged-staleness window (audit M4). Once the ETH feed has been
    ///      stale longer than this since the last good snapshot, the CPPI
    ///      trigger is blind, so a permissionless circuit-breaker de-risk is
    ///      allowed (see CPPIVault.deRiskUnderProlongedStaleness).
    uint256 public prolongedStalenessWindow = 3 hours;

    /// @notice Last refreshed ETH/USD price, served while the feed is stale (WAD).
    uint256 public snapshotEthUsdWad;

    /// @notice Timestamp of the last snapshot, the anchor for prolonged staleness.
    uint64 public snapshotAt;

    // ============================================================================
    // Events and errors
    // ============================================================================

    /// @notice Emitted when the price snapshot is refreshed.
    /// @param ethUsdWad The freshly snapshotted ETH/USD price, in WAD.
    event Refreshed(uint256 ethUsdWad);

    /// @notice Emitted when the staleness/basis params are updated.
    /// @param maxFeedAge The new max feed age, in seconds.
    /// @param maxBasisBps The new max wstETH basis, in basis points.
    event ParamsSet(uint256 maxFeedAge, uint256 maxBasisBps);

    /// @notice Emitted when the optional USDC/USD depeg feed is set.
    /// @param feed The USDC/USD feed address (address(0) disables the check).
    /// @param maxDepegBps The new max USDC depeg tolerance, in basis points.
    event UsdcFeedSet(address feed, uint256 maxDepegBps);

    /// @notice Emitted when the prolonged-staleness window is updated.
    /// @param window The new window, in seconds.
    event ProlongedWindowSet(uint256 window);

    /// @notice No usable price is available (feed reverted/non-positive and no snapshot).
    error NoPrice();

    /// @notice A parameter update was outside its allowed range.
    error BadParams();

    // ============================================================================
    // Setup (owner)
    // ============================================================================

    /// @notice Deploy the hub over its price sources.
    /// @param ethUsdFeed_ The Chainlink ETH/USD feed.
    /// @param wsteth_ The wstETH exchange-rate source.
    /// @param pool_ The wstETH/WETH Uniswap V3 pool used as a depeg gate.
    /// @param wstethIsToken0_ Whether wstETH is token0 in that pool.
    /// @param owner_ The initial owner.
    constructor(address ethUsdFeed_, address wsteth_, address pool_, bool wstethIsToken0_, address owner_) {
        ethUsdFeed = IChainlinkFeed(ethUsdFeed_);
        wsteth = IWstETHRate(wsteth_);
        wstethWethPool = IUniV3PoolSlot0(pool_);
        wstethIsToken0 = wstethIsToken0_;
        _initializeOwner(owner_);
    }

    /// @notice Wire the PT adapter that supplies the implied floor rate.
    /// @param ptAdapter_ The PT adapter.
    function setPtAdapter(IPTAdapter ptAdapter_) external onlyOwner {
        ptAdapter = ptAdapter_;
    }

    /// @notice Update the staleness and wstETH-basis parameters.
    /// @param maxFeedAge_ The new max feed age in seconds (600 .. 1 days).
    /// @param maxBasisBps_ The new max wstETH basis in bps (<= 1000).
    function setParams(uint256 maxFeedAge_, uint256 maxBasisBps_) external onlyOwner {
        if (maxFeedAge_ < 600 || maxFeedAge_ > 1 days || maxBasisBps_ > 1000) revert BadParams();
        maxFeedAge = maxFeedAge_;
        maxBasisBps = maxBasisBps_;
        emit ParamsSet(maxFeedAge_, maxBasisBps_);
    }

    /// @notice Set the optional USDC/USD depeg feed (audit L8). address(0)
    ///         disables the check (USDC assumed at par).
    /// @param feed The USDC/USD feed address (address(0) to disable).
    /// @param maxDepegBps The new max USDC depeg tolerance in bps (<= 2000).
    function setUsdcFeed(address feed, uint256 maxDepegBps) external onlyOwner {
        if (maxDepegBps > 2000) revert BadParams();
        usdcUsdFeed = IChainlinkFeed(feed);
        maxUsdcDepegBps = maxDepegBps;
        emit UsdcFeedSet(feed, maxDepegBps);
    }

    /// @notice Update the prolonged-staleness window (audit M4).
    /// @param window The new window in seconds (>= maxFeedAge, <= 2 days).
    function setProlongedStalenessWindow(uint256 window) external onlyOwner {
        if (window < maxFeedAge || window > 2 days) revert BadParams();
        prolongedStalenessWindow = window;
        emit ProlongedWindowSet(window);
    }

    // ============================================================================
    // Maintenance
    // ============================================================================

    /// @notice Snapshot the current fresh price; permissionless. The keeper
    ///         calls this each rebalance so a later feed outage degrades to
    ///         a recent price, not an ancient one.
    function refresh() external {
        (uint256 price, bool fresh) = _freshEthUsd();
        if (!fresh) revert NoPrice();
        snapshotEthUsdWad = price;
        snapshotAt = uint64(block.timestamp);
        emit Refreshed(price);
    }

    // ============================================================================
    // IPriceSource: price reads
    // ============================================================================

    /// @notice ETH/USD price: the live feed while fresh, else the last snapshot.
    /// @dev When degraded, serves the last-good snapshot so the floor defense
    ///      keeps running (spec section 8); reverts only if no snapshot exists.
    /// @return The ETH/USD price, in WAD.
    function ethUsdWad() public view returns (uint256) {
        (uint256 price, bool fresh) = _freshEthUsd();
        if (fresh) return price;
        if (snapshotEthUsdWad == 0) revert NoPrice();
        return snapshotEthUsdWad; // degraded: last-good so floor defense continues
    }

    /// @notice wstETH marked at the Lido exchange rate (stEthPerToken x
    ///         ETH/USD), NOT the DEX spot (audit H5). The exchange rate is the
    ///         fundamental redemption value and, unlike a UniV3 slot0 read, is
    ///         not flash-loan manipulable, so it cannot be used to skew share
    ///         pricing at settlement. This is the standard wstETH-collateral
    ///         marking (Aave/Morpho). The pool spot is kept only as a depeg
    ///         gate on BUYING more wstETH (wstethBuyAllowed), where a pushed
    ///         spot is fail-safe: it can only block a buy, never inflate value.
    /// @return The wstETH price, in USD WAD.
    function wstethUsdWad() external view returns (uint256) {
        return wsteth.stEthPerToken().mulWad(ethUsdWad());
    }

    /// @notice Whether buying more wstETH is allowed: the ETH feed must be fresh
    ///         and the exchange rate must not diverge from pool spot beyond the
    ///         basis limit. A pushed spot can only block a buy, never inflate value.
    /// @return True when a wstETH buy is permitted.
    function wstethBuyAllowed() external view returns (bool) {
        (, bool fresh) = _freshEthUsd();
        if (!fresh) return false;
        uint256 rateBased = wsteth.stEthPerToken();
        uint256 poolBased = _poolWethPerWsteth();
        return _basisBps(rateBased, poolBased) <= maxBasisBps;
    }

    // ============================================================================
    // Health signals
    // ============================================================================

    /// @notice Health gate the vault uses to pause NEW user flows and epoch
    ///         settlement: the ETH feed must be fresh AND USDC on peg (L8).
    /// @return True when the oracle stack is healthy.
    function healthy() external view returns (bool) {
        (, bool fresh) = _freshEthUsd();
        return fresh && usdcHealthy();
    }

    /// @notice True when USDC is within its depeg tolerance (or no feed set).
    /// @return True when USDC is on peg (or the depeg check is disabled).
    function usdcHealthy() public view returns (bool) {
        if (address(usdcUsdFeed) == address(0)) return true;
        try usdcUsdFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || block.timestamp > updatedAt + maxFeedAge) return false;
            uint256 px = uint256(answer) * 10 ** (18 - usdcUsdFeed.decimals());
            uint256 dev = px > 1e18 ? px - 1e18 : 1e18 - px;
            return dev * 10_000 / 1e18 <= maxUsdcDepegBps;
        } catch {
            return false;
        }
    }

    /// @notice True when the ETH feed has been stale beyond the prolonged
    ///         window (audit M4): the risky-leg mark is frozen and the CPPI
    ///         trigger is blind, so a permissionless circuit-breaker de-risk
    ///         is warranted.
    /// @return True when staleness has exceeded the prolonged window.
    function prolongedStale() external view returns (bool) {
        (, bool fresh) = _freshEthUsd();
        if (fresh) return false;
        return snapshotAt != 0 && block.timestamp > uint256(snapshotAt) + prolongedStalenessWindow;
    }

    // ============================================================================
    // IRateOracle
    // ============================================================================

    /// @notice The live PT-implied yield used to discount the floor.
    /// @return The implied rate, in WAD.
    function rateWad() external view returns (uint256) {
        return ptAdapter.impliedRateWad();
    }

    // ============================================================================
    // Internal helpers
    // ============================================================================

    /// @notice Read the ETH/USD feed and report whether it is fresh.
    /// @dev Reverts are caught and reported as not-fresh so a feed outage
    ///      degrades gracefully rather than bubbling up.
    /// @return priceWad The feed price scaled to WAD (0 if unusable).
    /// @return fresh Whether the answer is positive and within maxFeedAge.
    function _freshEthUsd() internal view returns (uint256 priceWad, bool fresh) {
        try ethUsdFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0) return (0, false);
            priceWad = uint256(answer) * 10 ** (18 - ethUsdFeed.decimals());
            fresh = block.timestamp <= updatedAt + maxFeedAge;
        } catch {
            return (0, false);
        }
    }

    /// @dev Pool spot: WETH per wstETH from sqrtPriceX96. With wstETH as
    ///      token0 the raw ratio is already token1/token0.
    /// @return WETH per wstETH from the pool spot, in WAD.
    function _poolWethPerWsteth() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = wstethWethPool.slot0();
        uint256 sq = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 ratioWad = FixedPointMathLib.fullMulDiv(sq, 1e18, 1 << 192);
        return wstethIsToken0 ? ratioWad : uint256(1e36) / ratioWad;
    }

    /// @notice Relative difference between two values, in basis points.
    /// @param a The first value.
    /// @param b The second value.
    /// @return The gap between them as bps of the larger (0 if both are 0).
    function _basisBps(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 hi = FixedPointMathLib.max(a, b);
        uint256 lo = FixedPointMathLib.min(a, b);
        if (hi == 0) return 0;
        return (hi - lo) * 10_000 / hi;
    }
}
