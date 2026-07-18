// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CPPIController} from "../src/CPPIController.sol";
import {FloorPolicy} from "../src/libraries/FloorPolicy.sol";
import {RebalancePolicy} from "../src/libraries/RebalancePolicy.sol";

contract CPPIControllerTest is Test {
    CPPIController controller;
    address vault = makeAddr("vault");

    uint256 constant NAV0 = 100e18;
    uint256 constant RATE = 0.04e18;

    function setUp() public {
        vm.warp(1_000_000);
        FloorPolicy.Config memory fc;
        fc.kind = FloorPolicy.Kind.Fixed;
        fc.termStart = uint64(block.timestamp);
        fc.termEnd = uint64(block.timestamp + 365 days);
        fc.protectionWad = 0.9e18;

        RebalancePolicy.Config memory rc = RebalancePolicy.Config({
            minInterval: 1 hours, cadence: 1 days, driftSmallBps: 200, driftLargeBps: 500, cushionFloorBps: 300
        });

        controller = new CPPIController(vault, 2e18, fc, rc);
        vm.prank(vault);
        controller.startTerm(uint64(block.timestamp), uint64(block.timestamp + 365 days), NAV0, 1e18);
    }

    function test_onlyVault() public {
        vm.expectRevert(CPPIController.NotVault.selector);
        controller.assess(NAV0, 1e18, 27e18, RATE);
    }

    function test_assess_matchesWorkedExample() public {
        vm.prank(vault);
        CPPIController.Assessment memory a = controller.assess(NAV0, 1e18, 0, RATE);
        assertApproxEqRel(a.floor, 86.4710495237090888e18, 1e6);
        assertApproxEqRel(a.targetRisky, 27.0579009525818224e18, 1e6);
        // zero holdings vs 27% target: drift ~27%, emergency fires (first rebalance)
        assertEq(uint8(a.trigger), uint8(RebalancePolicy.Trigger.Emergency));
    }

    function test_assess_scheduledFlow() public {
        // start at target, drift small: nothing fires
        vm.startPrank(vault);
        CPPIController.Assessment memory a = controller.assess(NAV0, 1e18, 27.06e18, RATE);
        assertEq(uint8(a.trigger), uint8(RebalancePolicy.Trigger.None));

        controller.recordRebalance(RebalancePolicy.Trigger.Scheduled, a.floor, a.targetRisky);

        // 1 day later with 3% drift: scheduled
        vm.warp(block.timestamp + 1 days);
        a = controller.assess(NAV0, 1e18, 24e18, RATE);
        assertEq(uint8(a.trigger), uint8(RebalancePolicy.Trigger.Scheduled));

        // 2h after a rebalance with 6% drift: emergency (bypasses cadence)
        controller.recordRebalance(RebalancePolicy.Trigger.Scheduled, a.floor, a.targetRisky);
        vm.warp(block.timestamp + 2 hours);
        a = controller.assess(NAV0, 1e18, 33.5e18, RATE);
        assertEq(uint8(a.trigger), uint8(RebalancePolicy.Trigger.Emergency));
        vm.stopPrank();
    }

    function test_assess_moderateGap_waitsForCadence() public {
        // a -25% one-move gap at m=2 leaves ~4.7% drift: BELOW the emergency
        // line, correctly left to the scheduled path (design record day-60 row)
        vm.startPrank(vault);
        controller.recordRebalance(RebalancePolicy.Trigger.Scheduled, 0, 0);
        vm.warp(block.timestamp + 2 hours);
        CPPIController.Assessment memory a = controller.assess(92.4e18, 1e18, 16.2e18, RATE);
        assertApproxEqRel(a.cushion, 5.9e18, 0.05e18);
        assertEq(uint8(a.trigger), uint8(RebalancePolicy.Trigger.None));
        vm.stopPrank();
    }

    function test_assess_severeGap_firesEmergency() public {
        // deeper dislocation: risky 20 vs target ~7 is >14% drift, and the
        // cushion is nearly spent: permissionless emergency path fires
        vm.startPrank(vault);
        controller.recordRebalance(RebalancePolicy.Trigger.Scheduled, 0, 0);
        vm.warp(block.timestamp + 2 hours);
        CPPIController.Assessment memory a = controller.assess(90e18, 1e18, 20e18, RATE);
        assertApproxEqRel(a.cushion, 3.53e18, 0.02e18);
        assertEq(uint8(a.trigger), uint8(RebalancePolicy.Trigger.Emergency));
        vm.stopPrank();
    }

    function test_rateClamp_boundsManipulation() public {
        vm.startPrank(vault);
        CPPIController.Assessment memory a1 = controller.assess(NAV0, 1e18, 27e18, RATE);
        // oracle reports an absurd 50% yield: clamped to last + 2% = 6%
        CPPIController.Assessment memory a2 = controller.assess(NAV0, 1e18, 27e18, 0.5e18);
        // higher rate lowers raw PV, but monotone clamp holds the floor
        assertGe(a2.floor, a1.floor);
        vm.stopPrank();
    }

    function test_settleTerm_flow() public {
        vm.startPrank(vault);
        vm.expectRevert(CPPIController.TermNotMatured.selector);
        controller.settleTerm(95e18, 1e18);

        vm.warp(block.timestamp + 365 days + 1);
        uint256 shortfall = controller.settleTerm(95e18, 1e18);
        assertEq(shortfall, 0); // 95 >= 90 protected

        // second term restarts cleanly
        controller.startTerm(uint64(block.timestamp), uint64(block.timestamp + 365 days), 95e18, 1e18);
        assertEq(controller.termNumber(), 2);
        assertApproxEqRel(controller.protectedAmount(1e18), 85.5e18, 1e6); // 90% of 95
        vm.stopPrank();
    }

    function test_settleTerm_reportsShortfall() public {
        vm.startPrank(vault);
        vm.warp(block.timestamp + 365 days + 1);
        uint256 shortfall = controller.settleTerm(88e18, 1e18);
        assertEq(shortfall, 2e18); // breached by 2 under the 90 promise
        vm.stopPrank();
    }
}
