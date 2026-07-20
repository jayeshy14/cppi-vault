// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RiskyLegManager} from "../src/RiskyLegManager.sol";
import {ExecutionModule} from "../src/ExecutionModule.sol";
import {SafeLegManager} from "../src/SafeLegManager.sol";
import {IPTAdapter} from "../src/interfaces/IPTAdapter.sol";
import {IPriceSource, ISwapRouter02} from "../src/interfaces/IExecutionPeriphery.sol";
import {MockUSDC} from "./mocks/Mocks.sol";
import {Mock18, MockPriceSource, MockSwapRouter, VaultStub} from "./mocks/ExecutionMocks.sol";
import {MockPTAdapter} from "./SafeLegManager.t.sol";

contract ExecutionLayerTest is Test {
    MockUSDC usdc;
    Mock18 weth;
    Mock18 wsteth;
    MockPriceSource prices;
    MockSwapRouter router;
    VaultStub vault;
    SafeLegManager safeLeg;
    RiskyLegManager riskyLeg;
    ExecutionModule exec;
    MockPTAdapter pt;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");

    function setUp() public {
        usdc = new MockUSDC();
        weth = new Mock18("WETH");
        wsteth = new Mock18("wstETH");
        prices = new MockPriceSource(); // ETH 2000, wstETH 2400
        router = new MockSwapRouter(prices, address(usdc), address(weth), address(wsteth));
        vault = new VaultStub();
        vault.set(0, 0, 1000e18);

        safeLeg = new SafeLegManager(address(vault), address(usdc), 6, owner);
        pt = new MockPTAdapter(address(usdc));
        riskyLeg = new RiskyLegManager(address(weth), address(wsteth), owner);
        exec = new ExecutionModule(address(vault), address(usdc), address(weth), address(wsteth), owner);

        vm.startPrank(owner);
        safeLeg.setPeriphery(IPTAdapter(address(pt)), address(exec), keeper);
        riskyLeg.setPeriphery(IPriceSource(address(prices)), address(exec), keeper);
        exec.setPeriphery(safeLeg, riskyLeg, IPriceSource(address(prices)), ISwapRouter02(address(router)), keeper);
        vm.stopPrank();

        vault.approveToken(address(usdc), address(exec));

        // float liquidity for the mock router's output side
        usdc.mint(address(router), 10_000_000e6);
        weth.mint(address(router), 10_000e18);
        wsteth.mint(address(router), 10_000e18);
    }

    // ---------- RiskyLegManager ----------

    function test_riskyValue_pricesBothTokens() public {
        weth.mint(address(riskyLeg), 10e18); // 20,000
        wsteth.mint(address(riskyLeg), 5e18); // 12,000
        assertEq(riskyLeg.value(), 32_000e18);
    }

    function test_riskyProvide_wethFirst_wstethReserve() public {
        weth.mint(address(riskyLeg), 10e18); // 20,000
        wsteth.mint(address(riskyLeg), 5e18); // 12,000
        vm.prank(address(exec));
        (uint256 w, uint256 ws) = riskyLeg.provide(26_000e18, address(exec));
        assertEq(w, 10e18); // all WETH first (20,000)
        assertEq(ws, 2.5e18); // 6,000 of wstETH at 2400
    }

    function test_riskyProvide_revertsBeyondValue() public {
        weth.mint(address(riskyLeg), 1e18);
        vm.prank(address(exec));
        vm.expectRevert(RiskyLegManager.InsufficientValue.selector);
        riskyLeg.provide(3000e18, address(exec));
    }

    function test_wstethTarget_capEnforced() public {
        vm.prank(owner);
        vm.expectRevert(RiskyLegManager.AboveCap.selector);
        riskyLeg.setWstethTarget(5001);
    }

    // ---------- ExecutionModule: buys ----------

    function test_buy_usesFreeIdleFirst_respectsOwedCash() public {
        // vault holds 100 USDC but 60 is pending deposits + 10 reserved: free = 30
        usdc.mint(address(vault), 100e6);
        vault.set(60e18, 10e18, 1000e18);
        // safe leg holds 50 in buffer for the remainder
        usdc.mint(address(safeLeg), 50e6);

        vm.prank(address(vault));
        exec.executeRebalance(int256(70e18), 50);

        // 30 from free idle + 40 from safe leg = 70 USDC swapped to 0.035 WETH
        assertEq(usdc.balanceOf(address(vault)), 70e6); // owed cash untouched
        assertApproxEqAbs(weth.balanceOf(address(riskyLeg)), 0.035e18, 1e12);
        assertApproxEqAbs(safeLeg.value(), 10e18, 1e12);
    }

    function test_buy_minOutEnforced_bubblesWhenBothTiersFail() public {
        usdc.mint(address(vault), 100e6);
        // router charges 2% on both tiers: outside the 50bps bound
        router.setTier(500, 200, false);
        router.setTier(3000, 200, false);
        vm.prank(address(vault));
        vm.expectRevert(MockSwapRouter.MinOut.selector);
        exec.executeRebalance(int256(50e18), 50);
    }

    function test_buy_fallbackTierUsed_whenPrimaryDisabled() public {
        usdc.mint(address(vault), 100e6);
        router.setTier(500, 0, true); // primary reverts outright
        vm.prank(address(vault));
        exec.executeRebalance(int256(50e18), 50);
        assertApproxEqAbs(weth.balanceOf(address(riskyLeg)), 0.025e18, 1e12);
    }

    // ---------- ExecutionModule: sells ----------

    function test_sell_routesProceedsToSafeLeg_andAllocates() public {
        weth.mint(address(riskyLeg), 10e18); // 20,000
        vm.prank(address(vault));
        exec.executeRebalance(-int256(6_000e18), 50);

        // 3 WETH sold for 6,000 USDC: buffer fills to target (3% of 1000 nav
        // = 30), rest buys PT
        assertEq(weth.balanceOf(address(riskyLeg)), 7e18);
        assertApproxEqAbs(safeLeg.value(), 6_000e18, 1e12);
        assertApproxEqAbs(safeLeg.bufferWad(), 30e18, 1e12);
        assertApproxEqAbs(pt.valueWad(), 5_970e18, 1e12);
    }

    function test_sell_wstethTwoHop() public {
        weth.mint(address(riskyLeg), 1e18); // 2,000
        wsteth.mint(address(riskyLeg), 5e18); // 12,000
        vm.prank(address(vault));
        exec.executeRebalance(-int256(8_000e18), 50);
        // 2,000 from WETH, 6,000 via wstETH->WETH->USDC
        assertEq(weth.balanceOf(address(riskyLeg)), 0);
        assertApproxEqAbs(wsteth.balanceOf(address(riskyLeg)), 2.5e18, 1e12);
        assertApproxEqAbs(safeLeg.value(), 8_000e18, 1e12);
    }

    // ---------- freeAssets + composition ----------

    function test_freeAssets_deliversToVault() public {
        usdc.mint(address(safeLeg), 100e6);
        vm.prank(address(vault));
        exec.freeAssets(40e18);
        assertEq(usdc.balanceOf(address(vault)), 40e6);
    }

    function test_l4_freeAssets_deliversSafePortionWhenRiskySaleReverts() public {
        // safe leg holds 40 (buffer), risky leg holds WETH; ask for 60 so a
        // risky shortfall sale is needed
        usdc.mint(address(safeLeg), 40e6);
        weth.mint(address(riskyLeg), 5e18); // 10,000 of ETH exposure
        // both swap tiers disabled: the risky sale cannot clear
        router.setTier(500, 0, true);
        router.setTier(3000, 0, true);

        vm.prank(address(vault));
        exec.freeAssets(60e18); // must NOT revert

        // the safe-leg portion was still delivered
        assertEq(usdc.balanceOf(address(vault)), 40e6);
    }

    // ---------- L3 regression: composition slippage cap + freshness gate ----

    function test_l3_slippageClampedToCeiling() public {
        vm.prank(owner);
        riskyLeg.setWstethTarget(2500);
        weth.mint(address(riskyLeg), 10e18);
        // 6% execution cost on BOTH tiers: exceeds the 5% composition clamp,
        // so even asking for 100% slippage cannot drive minOut low enough
        router.setTier(100, 600, false);
        router.setTier(3000, 600, false);
        vm.prank(keeper);
        vm.expectRevert(); // clamped to 500bps; 6% cost misses minOut on both tiers
        exec.rebalanceComposition(5_000e18, 10_000);
    }

    function test_l3_sellBranchGatedOnDepeg() public {
        vm.prank(owner);
        riskyLeg.setWstethTarget(1000); // 10%
        weth.mint(address(riskyLeg), 5e18); // 10,000
        wsteth.mint(address(riskyLeg), 5e18); // 12,000 -> ~54% wstETH, above target
        uint256 shareBefore = riskyLeg.wstethShareBps();

        prices.setBuyAllowed(false); // depeg/staleness
        vm.prank(keeper);
        exec.rebalanceComposition(100_000e18, 50); // sell branch must now no-op
        assertEq(riskyLeg.wstethShareBps(), shareBefore); // unchanged
    }

    function test_composition_movesTowardTarget() public {
        vm.prank(owner);
        riskyLeg.setWstethTarget(2500); // 25%
        weth.mint(address(riskyLeg), 10e18); // 20,000, 0% wstETH

        vm.prank(keeper);
        exec.rebalanceComposition(5_000e18, 50);
        // moved 5,000 toward the 25% target
        assertApproxEqAbs(riskyLeg.value(), 20_000e18, 1e15);
        assertApproxEqRel(riskyLeg.wstethShareBps(), 2500, 0.01e18);
    }

    function test_composition_trimsAboveTarget() public {
        vm.prank(owner);
        riskyLeg.setWstethTarget(1000); // 10%
        weth.mint(address(riskyLeg), 5e18); // 10,000
        wsteth.mint(address(riskyLeg), 5e18); // 12,000 -> 54% share

        vm.prank(keeper);
        exec.rebalanceComposition(100_000e18, 50);
        assertApproxEqRel(riskyLeg.wstethShareBps(), 1000, 0.02e18);
    }

    // ---------- H4 regression: risky leg keeper least-privilege ----------

    function test_h4_keeperCannotDrainRiskyLeg() public {
        weth.mint(address(riskyLeg), 10e18);
        vm.prank(keeper);
        vm.expectRevert(RiskyLegManager.NotAuthorized.selector);
        riskyLeg.provide(1000e18, keeper);
        vm.prank(keeper);
        vm.expectRevert(RiskyLegManager.NotAuthorized.selector);
        riskyLeg.provideToken(address(weth), 1e18, keeper);
    }

    // ---------- access control ----------

    function test_accessControl() public {
        vm.expectRevert(ExecutionModule.NotVault.selector);
        exec.executeRebalance(int256(1e18), 50);
        vm.expectRevert(ExecutionModule.NotKeeper.selector);
        exec.rebalanceComposition(1e18, 50);
    }
}
