// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPriceSource} from "./interfaces/IExecutionPeriphery.sol";
import {IRateOracle} from "./interfaces/IVaultPeriphery.sol";
import {IPTAdapter} from "./interfaces/IPTAdapter.sol";

interface IChainlinkFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

interface IWstETHRate {
    function stEthPerToken() external view returns (uint256);
}

interface IUniV3PoolSlot0 {
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

    IChainlinkFeed public immutable ethUsdFeed;
    IWstETHRate public immutable wsteth;
    IUniV3PoolSlot0 public immutable wstethWethPool;
    IPTAdapter public ptAdapter;
    bool public immutable wstethIsToken0;

    uint256 public maxFeedAge = 3900; // Chainlink ETH/USD heartbeat 3600 + margin
    uint256 public maxBasisBps = 200;

    /// @dev Optional USDC/USD feed (audit L8). The vault denominates in USDC
    ///      but marks the risky leg in USD; if unset, USDC is assumed at par.
    ///      When set and USDC depegs beyond maxUsdcDepegBps, healthy() flips
    ///      false so deposits/settlement pause until the peg returns.
    IChainlinkFeed public usdcUsdFeed;
    uint256 public maxUsdcDepegBps = 200;

    /// @dev Prolonged-staleness window (audit M4). Once the ETH feed has been
    ///      stale longer than this since the last good snapshot, the CPPI
    ///      trigger is blind, so a permissionless circuit-breaker de-risk is
    ///      allowed (see CPPIVault.deRiskUnderProlongedStaleness).
    uint256 public prolongedStalenessWindow = 3 hours;

    uint256 public snapshotEthUsdWad;
    uint64 public snapshotAt;

    event Refreshed(uint256 ethUsdWad);
    event ParamsSet(uint256 maxFeedAge, uint256 maxBasisBps);
    event UsdcFeedSet(address feed, uint256 maxDepegBps);
    event ProlongedWindowSet(uint256 window);

    error NoPrice();
    error BadParams();

    constructor(address ethUsdFeed_, address wsteth_, address pool_, bool wstethIsToken0_, address owner_) {
        ethUsdFeed = IChainlinkFeed(ethUsdFeed_);
        wsteth = IWstETHRate(wsteth_);
        wstethWethPool = IUniV3PoolSlot0(pool_);
        wstethIsToken0 = wstethIsToken0_;
        _initializeOwner(owner_);
    }

    function setPtAdapter(IPTAdapter ptAdapter_) external onlyOwner {
        ptAdapter = ptAdapter_;
    }

    function setParams(uint256 maxFeedAge_, uint256 maxBasisBps_) external onlyOwner {
        if (maxFeedAge_ < 600 || maxFeedAge_ > 1 days || maxBasisBps_ > 1000) revert BadParams();
        maxFeedAge = maxFeedAge_;
        maxBasisBps = maxBasisBps_;
        emit ParamsSet(maxFeedAge_, maxBasisBps_);
    }

    /// @notice Set the optional USDC/USD depeg feed (audit L8). address(0)
    ///         disables the check (USDC assumed at par).
    function setUsdcFeed(address feed, uint256 maxDepegBps) external onlyOwner {
        if (maxDepegBps > 2000) revert BadParams();
        usdcUsdFeed = IChainlinkFeed(feed);
        maxUsdcDepegBps = maxDepegBps;
        emit UsdcFeedSet(feed, maxDepegBps);
    }

    function setProlongedStalenessWindow(uint256 window) external onlyOwner {
        if (window < maxFeedAge || window > 2 days) revert BadParams();
        prolongedStalenessWindow = window;
        emit ProlongedWindowSet(window);
    }

    // ---------- maintenance ----------

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

    // ---------- IPriceSource ----------

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
    function wstethUsdWad() external view returns (uint256) {
        return wsteth.stEthPerToken().mulWad(ethUsdWad());
    }

    function wstethBuyAllowed() external view returns (bool) {
        (, bool fresh) = _freshEthUsd();
        if (!fresh) return false;
        uint256 rateBased = wsteth.stEthPerToken();
        uint256 poolBased = _poolWethPerWsteth();
        return _basisBps(rateBased, poolBased) <= maxBasisBps;
    }

    /// @notice Health gate the vault uses to pause NEW user flows and epoch
    ///         settlement: the ETH feed must be fresh AND USDC on peg (L8).
    function healthy() external view returns (bool) {
        (, bool fresh) = _freshEthUsd();
        return fresh && usdcHealthy();
    }

    /// @notice True when USDC is within its depeg tolerance (or no feed set).
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
    function prolongedStale() external view returns (bool) {
        (, bool fresh) = _freshEthUsd();
        if (fresh) return false;
        return snapshotAt != 0 && block.timestamp > uint256(snapshotAt) + prolongedStalenessWindow;
    }

    // ---------- IRateOracle ----------

    function rateWad() external view returns (uint256) {
        return ptAdapter.impliedRateWad();
    }

    // ---------- internal ----------

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
    function _poolWethPerWsteth() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = wstethWethPool.slot0();
        uint256 sq = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 ratioWad = FixedPointMathLib.fullMulDiv(sq, 1e18, 1 << 192);
        return wstethIsToken0 ? ratioWad : uint256(1e36) / ratioWad;
    }

    function _basisBps(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 hi = FixedPointMathLib.max(a, b);
        uint256 lo = FixedPointMathLib.min(a, b);
        if (hi == 0) return 0;
        return (hi - lo) * 10_000 / hi;
    }
}
