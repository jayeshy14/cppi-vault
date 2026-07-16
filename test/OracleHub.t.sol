// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {OracleHub} from "../src/OracleHub.sol";
import {IPTAdapter} from "../src/interfaces/IPTAdapter.sol";

contract MockFeed {
    int256 public answer = 2000e8;
    uint256 public updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, 0, updatedAt, 0);
    }
}

contract MockWstRate {
    uint256 public stEthPerToken = 1.2e18;

    function set(uint256 r) external {
        stEthPerToken = r;
    }
}

contract MockPool {
    uint160 public sqrtPriceX96;

    /// @dev token1-per-token0 ratio in WAD -> sqrtPriceX96
    function setRatioWad(uint256 ratioWad) external {
        sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(ratioWad, 1 << 192, 1e18)));
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }
}

contract MockRateAdapter {
    uint256 public impliedRateWad = 0.045e18;
}

contract OracleHubTest is Test {
    OracleHub hub;
    MockFeed feed;
    MockWstRate wstRate;
    MockPool pool;

    function setUp() public {
        vm.warp(1_000_000);
        feed = new MockFeed();
        wstRate = new MockWstRate();
        pool = new MockPool();
        pool.setRatioWad(1.2e18); // pool agrees with the exchange rate
        hub = new OracleHub(address(feed), address(wstRate), address(pool), true, address(this));
        hub.setPtAdapter(IPTAdapter(address(new MockRateAdapter())));
    }

    function test_freshPrices() public view {
        assertEq(hub.ethUsdWad(), 2000e18);
        assertApproxEqRel(hub.wstethUsdWad(), 2400e18, 1e9); // 1.2 x 2000
        assertTrue(hub.healthy());
        assertTrue(hub.wstethBuyAllowed());
    }

    function test_staleness_servesSnapshot_flagsUnhealthy() public {
        hub.refresh(); // snapshot 2000
        // feed goes stale beyond maxFeedAge
        vm.warp(block.timestamp + 2 hours);
        assertFalse(hub.healthy());
        assertEq(hub.ethUsdWad(), 2000e18); // last-good: rebalancing continues
        assertFalse(hub.wstethBuyAllowed()); // but no new wstETH
    }

    function test_staleness_withoutSnapshot_reverts() public {
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(OracleHub.NoPrice.selector);
        hub.ethUsdWad();
    }

    function test_refresh_revertsWhenStale() public {
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(OracleHub.NoPrice.selector);
        hub.refresh();
    }

    function test_basisBreach_marksLower_blocksBuys() public {
        // pool prints wstETH 5% below the exchange rate (depeg scenario)
        pool.setRatioWad(1.14e18);
        assertApproxEqRel(hub.wstethUsdWad(), 2280e18, 1e6); // marked at pool (lower)
        assertFalse(hub.wstethBuyAllowed());

        // exchange rate lower than pool: still marks the lower one
        pool.setRatioWad(1.32e18);
        assertApproxEqRel(hub.wstethUsdWad(), 2400e18, 1e6); // rate-based is lower
        assertFalse(hub.wstethBuyAllowed());
    }

    function test_smallBasis_usesExchangeRate() public {
        pool.setRatioWad(1.21e18); // ~0.8% basis, inside 2% limit
        assertApproxEqRel(hub.wstethUsdWad(), 2400e18, 1e6);
        assertTrue(hub.wstethBuyAllowed());
    }

    function test_negativeAnswer_treatedUnhealthy() public {
        hub.refresh();
        feed.set(-1, block.timestamp);
        assertFalse(hub.healthy());
        assertEq(hub.ethUsdWad(), 2000e18); // snapshot fallback
    }

    function test_rateWad_passthrough() public view {
        assertEq(hub.rateWad(), 0.045e18);
    }

    function test_paramValidation() public {
        vm.expectRevert(OracleHub.BadParams.selector);
        hub.setParams(100, 200); // maxFeedAge too small
        vm.expectRevert(OracleHub.BadParams.selector);
        hub.setParams(3900, 1500); // basis limit too wide
    }
}
