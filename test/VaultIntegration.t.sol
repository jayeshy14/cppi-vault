// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CPPIVault, IOracleHealth} from "../src/CPPIVault.sol";
import {CPPIController} from "../src/CPPIController.sol";
import {SafeLegManager} from "../src/SafeLegManager.sol";
import {RiskyLegManager} from "../src/RiskyLegManager.sol";
import {ExecutionModule} from "../src/ExecutionModule.sol";
import {FloorPolicy} from "../src/libraries/FloorPolicy.sol";
import {RebalancePolicy} from "../src/libraries/RebalancePolicy.sol";
import {IPTAdapter} from "../src/interfaces/IPTAdapter.sol";
import {ILeg, IExecutionModule, IRateOracle} from "../src/interfaces/IVaultPeriphery.sol";
import {IPriceSource, ISwapRouter02} from "../src/interfaces/IExecutionPeriphery.sol";
import {MockUSDC} from "./mocks/Mocks.sol";
import {Mock18, MockPriceSource, MockSwapRouter} from "./mocks/ExecutionMocks.sol";
import {MockPTAdapter} from "./SafeLegManager.t.sol";

contract MockHealth is IOracleHealth {
    bool public healthy = true;
    bool public prolongedStale;

    function set(bool h) external {
        healthy = h;
    }

    function setProlonged(bool p) external {
        prolongedStale = p;
    }
}

contract MockRate {
    uint256 public rateWad = 0.04e18;
}

/// @dev Full-stack lifecycle: real vault, controller, both leg managers and
///      the execution module wired together; mocks only at the market edges
///      (swap router, PT adapter, prices, chainlink-health).
contract VaultIntegrationTest is Test {
    CPPIVault vault;
    CPPIController controller;
    SafeLegManager safeLeg;
    RiskyLegManager riskyLeg;
    ExecutionModule exec;
    MockUSDC usdc;
    Mock18 weth;
    Mock18 wsteth;
    MockPriceSource prices;
    MockSwapRouter router;
    MockPTAdapter pt;
    MockHealth health;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address feeTo = makeAddr("feeTo");

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        weth = new Mock18("WETH");
        wsteth = new Mock18("wstETH");
        prices = new MockPriceSource(); // ETH 2000
        router = new MockSwapRouter(prices, address(usdc), address(weth), address(wsteth));
        health = new MockHealth();

        vault = new CPPIVault(address(usdc), 6, owner);

        FloorPolicy.Config memory fc;
        fc.kind = FloorPolicy.Kind.Fixed;
        fc.termStart = uint64(block.timestamp);
        fc.termEnd = uint64(block.timestamp + 365 days);
        fc.protectionWad = 0.9e18;
        RebalancePolicy.Config memory rc = RebalancePolicy.Config({
            minInterval: 1 hours, cadence: 1 days, driftSmallBps: 200, driftLargeBps: 500, cushionFloorBps: 300
        });
        controller = new CPPIController(address(vault), 2e18, fc, rc);

        safeLeg = new SafeLegManager(address(vault), address(usdc), 6, owner);
        pt = new MockPTAdapter(address(usdc));
        riskyLeg = new RiskyLegManager(address(weth), address(wsteth), owner);
        exec = new ExecutionModule(address(vault), address(usdc), address(weth), address(wsteth), 6, owner);

        vm.startPrank(owner);
        vault.setController(controller);
        vault.setPeriphery(
            ILeg(address(safeLeg)),
            ILeg(address(riskyLeg)),
            IExecutionModule(address(exec)),
            IRateOracle(address(new MockRate()))
        );
        vault.setRoles(keeper, guardian);
        vault.setHealthSource(health);
        safeLeg.setPeriphery(IPTAdapter(address(pt)), address(exec), keeper);
        riskyLeg.setPeriphery(IPriceSource(address(prices)), address(exec), keeper);
        exec.setPeriphery(safeLeg, riskyLeg, IPriceSource(address(prices)), ISwapRouter02(address(router)), keeper);
        vm.stopPrank();

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(bob, 1_000_000e6);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        // router float
        usdc.mint(address(router), 10_000_000e6);
        weth.mint(address(router), 10_000e18);
        wsteth.mint(address(router), 10_000e18);
    }

    // ---------- H3 regression: per-share floor is supply-invariant ----------

    function test_h3_midTermDeposit_preservesPerShareFloor() public {
        _enter(100_000e6);
        // per-share protection at term start
        uint256 protectedPerShare0 = controller.protectedPerShareWad();
        uint256 supply0 = vault.totalSupply();
        assertApproxEqRel(protectedPerShare0, 0.9e18, 0.001e18); // 90% of navPerShare (=1)

        // a mid-term depositor settles: mints shares while the term is live
        vm.prank(bob);
        vault.requestDeposit(100_000e6);
        vm.prank(keeper);
        vault.settleEpoch();

        // per-share protection is UNCHANGED (the H3 bug halved it)
        assertEq(controller.protectedPerShareWad(), protectedPerShare0);
        // aggregate protection scaled up with supply, not frozen
        uint256 supply1 = vault.totalSupply();
        assertGt(supply1, supply0);
        assertApproxEqRel(
            controller.protectedAmount(supply1), controller.protectedAmount(supply0) * supply1 / supply0, 0.0001e18
        );
    }

    function test_h3_midTermRedeem_noPhantomShortfall() public {
        _enter(100_000e6);
        uint256 protectedPerShare0 = controller.protectedPerShareWad();

        // half the holder redeems mid-term at fair NAV
        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.requestRedeem(half);
        uint256 needWad = half * vault.navPerShare() / 1e18;
        vm.prank(keeper);
        vault.freeAssets(needWad * 10_100 / 10_000);
        vm.prank(keeper);
        vault.settleEpoch();
        vm.prank(alice);
        vault.claimAssets();

        // per-share floor unchanged, aggregate scaled down (no phantom breach)
        assertEq(controller.protectedPerShareWad(), protectedPerShare0);

        // at maturity: zero shortfall despite the mid-term supply halving
        // (inject the PT carry the mock omits so the safe leg accretes to par)
        pt.simulateYield(3_000e18);
        vm.warp(block.timestamp + 366 days);
        vm.prank(keeper);
        assertEq(vault.settleTerm(), 0);
    }

    // ---------- M4/L5 regression: oracle robustness ----------

    function test_m4_prolongedStaleness_permissionlessFullDeRisk() public {
        _enter(100_000e6);
        assertGt(riskyLeg.value(), 20_000e18); // ~27% ETH

        // oracle stale beyond the prolonged window: normal trigger is blind
        health.setProlonged(true);

        // anyone can force a full de-risk into the safe leg
        vm.prank(makeAddr("rando"));
        vault.deRiskUnderProlongedStaleness();
        assertLt(riskyLeg.value(), 1e15); // fully de-risked
        assertGe(vault.shareholderNav() + 1e15, controller.lastFloor());
    }

    function test_m4_notAllowedWhenNotProlonged() public {
        _enter(100_000e6);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(CPPIVault.OracleUnhealthy.selector);
        vault.deRiskUnderProlongedStaleness();
    }

    function test_l5_settleEpoch_blockedWhenUnhealthy() public {
        // alice requests while healthy
        vm.prank(alice);
        vault.requestDeposit(100_000e6);
        // oracle goes unhealthy before settlement
        health.set(false);
        vm.prank(keeper);
        vm.expectRevert(CPPIVault.OracleUnhealthy.selector);
        vault.settleEpoch();
    }

    function _enter(uint256 assets) internal {
        vm.prank(alice);
        vault.requestDeposit(assets);
        vm.prank(keeper);
        vault.settleEpoch();
        vm.prank(alice);
        vault.claimShares();
        vm.prank(keeper);
        vault.startTerm(365 days);
        vault.rebalance(); // initial allocation: emergency, permissionless
    }

    function test_lifecycle_fullTerm() public {
        _enter(100_000e6);

        // after initial allocation: ~27% ETH, remaining free idle swept into
        // the safe leg (buffer + PT), NAV conserved
        assertApproxEqRel(riskyLeg.value(), 27_058e18, 0.001e18);
        assertApproxEqRel(safeLeg.value(), 72_942e18, 0.001e18);
        assertGt(pt.valueWad(), 65_000e18); // most of the safe leg in PT
        assertApproxEqRel(vault.totalNav(), 100_000e18, 1e12);

        // rally: ETH +50%, cushion compounds, scheduled buy after cadence
        prices.setEth(3000e18);
        vm.warp(block.timestamp + 1 days);
        vm.prank(keeper);
        vault.rebalance();
        uint256 navAfterRally = vault.shareholderNav();
        assertApproxEqRel(navAfterRally, 113_529e18, 0.001e18);
        // exposure ratcheted up: target = 2 x (nav - floor)
        assertGt(riskyLeg.value(), 40_000e18);

        // crash: ETH -40% in one move, permissionless emergency de-risks
        prices.setEth(1800e18);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(makeAddr("rando"));
        vault.rebalance();
        // sold into PT: floor still defended
        uint256 nav = vault.shareholderNav();
        assertGt(nav, 90_000e18);
        assertLt(riskyLeg.value() * 1e18 / nav, 0.35e18); // de-risked hard

        // maturity: floor held
        vm.warp(block.timestamp + 365 days);
        vm.prank(keeper);
        uint256 shortfall = vault.settleTerm();
        assertEq(shortfall, 0);

        // exit: redeem everything at maturity
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares);
        uint256 navToFree = vault.shareholderNav();
        vm.prank(keeper);
        vault.freeAssets(navToFree);
        vm.prank(keeper);
        vault.settleEpoch();
        vm.prank(alice);
        vault.claimAssets();
        // protected: at least 90% of the deposit came back
        assertGt(usdc.balanceOf(alice), 990_000e6); // 900k untouched + >=90k payout
    }

    function test_oracleUnhealthy_pausesFlows_notEmergency() public {
        _enter(100_000e6);
        health.set(false);

        vm.prank(alice);
        vm.expectRevert(CPPIVault.OracleUnhealthy.selector);
        vault.requestDeposit(1_000e6);

        // emergency path unaffected: crash + permissionless rebalance
        prices.setEth(1200e18);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(makeAddr("rando"));
        vault.rebalance();
    }

    function test_managementFee_accruesProRata() public {
        vm.prank(owner);
        vault.setFees(100, 0, feeTo); // 1%/yr management
        _enter(100_000e6);

        vm.warp(block.timestamp + 182.5 days);
        // trigger accrual via an epoch settlement
        vm.prank(alice);
        vault.requestDeposit(1e6);
        vm.prank(keeper);
        vault.settleEpoch();

        // ~0.5% of NAV in fee shares after half a year
        uint256 feeShares = vault.balanceOf(feeTo);
        uint256 feeValue = feeShares * vault.navPerShare() / 1e18;
        assertApproxEqRel(feeValue, 500e18, 0.02e18);
    }

    function test_performanceFee_onGainsAboveHighWater() public {
        vm.prank(owner);
        vault.setFees(0, 1000, feeTo); // 10% above the high-water mark
        _enter(100_000e6);

        prices.setEth(3000e18); // nav ~113.5k; TRUE profit vs 100k start ~13.5k
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(keeper);
        vault.settleTerm();

        // fee is 10% of REAL profit (nav - startNav), not of nav-above-floor;
        // slightly less than 1353 after self-dilution of the minted fee shares
        uint256 feeValue = vault.balanceOf(feeTo) * vault.navPerShare() / 1e18;
        assertApproxEqRel(feeValue, 1_337e18, 0.01e18); // 10% x ~13.5k, diluted
    }

    // ---------- H1/H2 regression: fee basis + anti-churn ----------

    function test_h1_noPerfFeeOnFlatTerm() public {
        vm.prank(owner);
        vault.setFees(0, 1000, feeTo);
        _enter(100_000e6);
        // no price move: navPerShare stays at the high-water mark
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(keeper);
        vault.settleTerm();
        assertEq(vault.balanceOf(feeTo), 0); // flat term pays nothing
    }

    function test_h1_noPerfFeeOnLosingTerm() public {
        vm.prank(owner);
        vault.setFees(0, 1000, feeTo);
        _enter(100_000e6);
        // ETH drifts down: NAV ends below start but above the floor
        prices.setEth(1800e18);
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(keeper);
        vault.settleTerm();
        assertEq(vault.balanceOf(feeTo), 0); // a losing vault pays no perf fee
    }

    function test_h1_highWaterHoldsAcrossTerms() public {
        vm.prank(owner);
        vault.setFees(0, 1000, feeTo);
        _enter(100_000e6);

        // term 1: rally, fee charged, HWM ratchets up
        prices.setEth(3000e18);
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(keeper);
        vault.settleTerm();
        uint256 feeAfterTerm1 = vault.balanceOf(feeTo);
        assertGt(feeAfterTerm1, 0);

        // term 2 at the elevated NAV, then a flat close: no new gain above HWM
        vm.prank(keeper);
        vault.startTerm(365 days);
        vault.rebalance();
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(keeper);
        vault.settleTerm();
        assertEq(vault.balanceOf(feeTo), feeAfterTerm1); // no double-charge
    }

    function test_h2_minTermDuration_blocksChurn() public {
        _enter(100_000e6);
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(keeper);
        vault.settleTerm();
        // a one-second churn term is rejected
        vm.prank(keeper);
        vm.expectRevert(CPPIController.TermTooShort.selector);
        vault.startTerm(1);
    }

    function test_feeCaps_enforced() public {
        vm.startPrank(owner);
        vm.expectRevert(CPPIVault.FeeAboveCap.selector);
        vault.setFees(201, 0, feeTo);
        vm.expectRevert(CPPIVault.FeeAboveCap.selector);
        vault.setFees(0, 2001, feeTo);
        vm.stopPrank();
    }
}
