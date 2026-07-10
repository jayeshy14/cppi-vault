// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebalancePolicy} from "../src/libraries/RebalancePolicy.sol";

contract RebalancePolicyTest is Test {
    using RebalancePolicy for RebalancePolicy.Config;

    RebalancePolicy.Config internal cfg = RebalancePolicy.Config({
        minInterval: 1 hours,
        cadence: 1 days,
        driftSmallBps: 200,
        driftLargeBps: 500,
        cushionFloorBps: 300
    });

    uint256 constant T0 = 1_000_000;

    function classify(uint256 last, uint256 nowTs, uint256 drift, uint256 cushionBps)
        internal
        view
        returns (RebalancePolicy.Trigger)
    {
        return RebalancePolicy.classify(cfg, last, nowTs, drift, cushionBps);
    }

    function test_validate_rejectsBadConfigs() public {
        RebalancePolicy.Config memory bad = cfg;
        bad.driftSmallBps = 600; // small > large
        vm.expectRevert(RebalancePolicy.InvalidConfig.selector);
        this.validateExternal(bad);

        bad = cfg;
        bad.cadence = 30 minutes; // cadence < minInterval
        vm.expectRevert(RebalancePolicy.InvalidConfig.selector);
        this.validateExternal(bad);
    }

    function validateExternal(RebalancePolicy.Config memory c) external pure {
        RebalancePolicy.validate(c);
    }

    function test_minInterval_gatesEverything() public view {
        // huge drift and dead cushion, but 30min since last: nothing fires
        assertEq(
            uint8(classify(T0, T0 + 30 minutes, 2000, 0)),
            uint8(RebalancePolicy.Trigger.None)
        );
    }

    function test_emergency_onLargeDrift_beforeCadence() public view {
        // 2h since last (past minInterval, well before cadence), drift 5%
        assertEq(
            uint8(classify(T0, T0 + 2 hours, 500, 5000)),
            uint8(RebalancePolicy.Trigger.Emergency)
        );
    }

    function test_emergency_onLowCushion() public view {
        // drift small but cushion at 2% of nav: crash de-risk path
        assertEq(
            uint8(classify(T0, T0 + 2 hours, 50, 200)),
            uint8(RebalancePolicy.Trigger.Emergency)
        );
    }

    function test_scheduled_needsCadenceAndSmallDrift() public view {
        // past cadence with 3% drift
        assertEq(
            uint8(classify(T0, T0 + 1 days, 300, 5000)),
            uint8(RebalancePolicy.Trigger.Scheduled)
        );
        // past cadence, drift below band: nothing
        assertEq(
            uint8(classify(T0, T0 + 1 days, 100, 5000)),
            uint8(RebalancePolicy.Trigger.None)
        );
        // drift fine, cadence not elapsed: nothing
        assertEq(
            uint8(classify(T0, T0 + 2 hours, 300, 5000)),
            uint8(RebalancePolicy.Trigger.None)
        );
    }

    function test_firstRebalance_ignoresTiming() public view {
        assertEq(
            uint8(classify(0, T0, 300, 5000)), uint8(RebalancePolicy.Trigger.Scheduled)
        );
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_emergencyDominatesWhenPastMinInterval(uint256 drift, uint256 cushionBps)
        public
        view
    {
        drift = bound(drift, cfg.driftLargeBps, 10_000);
        cushionBps = bound(cushionBps, 0, 10_000);
        assertEq(
            uint8(classify(T0, T0 + cfg.minInterval, drift, cushionBps)),
            uint8(RebalancePolicy.Trigger.Emergency)
        );
    }
}
