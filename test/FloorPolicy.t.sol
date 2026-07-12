// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FloorPolicy} from "../src/libraries/FloorPolicy.sol";
import {CPPIMath} from "../src/libraries/CPPIMath.sol";

contract FloorPolicyHarness {
    using FloorPolicy for FloorPolicy.State;

    FloorPolicy.State public state;
    FloorPolicy.Config public config;

    constructor(FloorPolicy.Config memory c, uint256 termStartNav) {
        FloorPolicy.validate(c);
        config = c;
        FloorPolicy.initialize(state, c, termStartNav);
    }

    function update(uint256 nav, uint256 rateWad, uint256 nowTs) external returns (uint256) {
        return FloorPolicy.currentFloor(state, config, nav, rateWad, nowTs);
    }

    function protectedAmount() external view returns (uint256) {
        return state.protectedAmount;
    }

    function stepCount() external view returns (uint32) {
        return state.stepCount;
    }

    function hwmNav() external view returns (uint256) {
        return state.hwmNav;
    }
}

contract FloorPolicyTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant RATE = 0.04e18;
    uint64 constant T0 = 1_000_000;
    uint64 constant T1 = T0 + 365 days;
    uint256 constant NAV0 = 100e18;

    function cfg(FloorPolicy.Kind kind) internal pure returns (FloorPolicy.Config memory c) {
        c.kind = kind;
        c.termStart = T0;
        c.termEnd = T1;
        c.protectionWad = 0.9e18;
        if (kind == FloorPolicy.Kind.Step) {
            c.triggerWad = 1.8e18;
            c.stepWad = 1.25e18;
        }
        if (kind == FloorPolicy.Kind.Tipp) {
            c.ratchetWad = 0.8e18;
        }
    }

    // ---------- fixed ----------

    function test_fixed_startAndMaturity() public {
        FloorPolicyHarness h = new FloorPolicyHarness(cfg(FloorPolicy.Kind.Fixed), NAV0);
        // matches CPPIMath PV at term start: 90 x e^-0.04
        assertApproxEqRel(h.update(NAV0, RATE, T0), 86.4710495237090888e18, 1e6);
        // equals the protected amount at maturity
        assertEq(h.update(NAV0, RATE, T1), 90e18);
    }

    function test_fixed_rateDropRaisesFloor() public {
        FloorPolicyHarness h = new FloorPolicyHarness(cfg(FloorPolicy.Kind.Fixed), NAV0);
        uint256 f4 = h.update(NAV0, RATE, T0);
        uint256 f1 = h.update(NAV0, 0.01e18, T0);
        assertGt(f1, f4); // falling live rate raises the floor
    }

    function test_fixed_monotoneClampBlocksRateRise() public {
        FloorPolicyHarness h = new FloorPolicyHarness(cfg(FloorPolicy.Kind.Fixed), NAV0);
        uint256 f1 = h.update(NAV0, 0.01e18, T0);
        // rate jumps back up: raw PV would fall, clamp must hold the floor
        uint256 f2 = h.update(NAV0, 0.1e18, T0 + 1);
        assertGe(f2, f1);
    }

    // ---------- step ----------

    function test_step_firesAtTrigger() public {
        FloorPolicyHarness h = new FloorPolicyHarness(cfg(FloorPolicy.Kind.Step), NAV0);
        uint256 f0 = h.update(NAV0, RATE, T0);
        // below trigger: nothing
        h.update(f0 * 179 / 100, RATE, T0 + 1);
        assertEq(h.stepCount(), 0);
        // just past trigger (floor accretes slightly between updates)
        uint256 f1 = h.update(f0 * 181 / 100, RATE, T0 + 2);
        assertEq(h.stepCount(), 1);
        assertApproxEqRel(h.protectedAmount(), 90e18 * 125 / 100, 1e6);
        assertGt(f1, f0);
    }

    function test_step_multipleStepsInOneGap_capped() public {
        FloorPolicyHarness h = new FloorPolicyHarness(cfg(FloorPolicy.Kind.Step), NAV0);
        uint256 f0 = h.update(NAV0, RATE, T0);
        // NAV 100x the floor in one update: loop must terminate at the cap
        h.update(f0 * 100, RATE, T0 + 1);
        assertLe(h.stepCount(), 10);
        assertGt(h.stepCount(), 1);
    }

    function test_step_neverStepsToCashLock() public {
        FloorPolicyHarness h = new FloorPolicyHarness(cfg(FloorPolicy.Kind.Step), NAV0);
        uint256 f0 = h.update(NAV0, RATE, T0);
        uint256 nav = f0 * 18 / 10;
        uint256 f1 = h.update(nav, RATE, T0 + 1);
        // post-step floor stays strictly below NAV (k < T)
        assertLt(f1, nav);
    }

    // ---------- tipp ----------

    function test_tipp_tracksHighWater() public {
        FloorPolicyHarness h = new FloorPolicyHarness(cfg(FloorPolicy.Kind.Tipp), NAV0);
        h.update(NAV0, RATE, T0);
        h.update(200e18, RATE, T0 + 1);
        assertEq(h.hwmNav(), 200e18);
        // floor binds at 80% of HWM even after NAV falls back
        uint256 f = h.update(120e18, RATE, T0 + 2);
        assertEq(f, 160e18);
    }

    function test_tipp_pvDominatesUntilRatchetBinds() public {
        FloorPolicyHarness h = new FloorPolicyHarness(cfg(FloorPolicy.Kind.Tipp), NAV0);
        // at start, 80% of HWM (80) < PV floor (~86.5): PV wins
        uint256 f = h.update(NAV0, RATE, T0);
        assertApproxEqRel(f, 86.4710495237090888e18, 1e6);
    }

    // ---------- config validation ----------

    function test_validate_rejects() public {
        FloorPolicy.Config memory c = cfg(FloorPolicy.Kind.Step);
        c.stepWad = 1.9e18; // k >= T
        vm.expectRevert(FloorPolicy.InvalidConfig.selector);
        new FloorPolicyHarness(c, NAV0);

        c = cfg(FloorPolicy.Kind.Step);
        c.triggerWad = 2.5e18; // T > 2 would let the safe leg empty at m = 2
        vm.expectRevert(FloorPolicy.InvalidConfig.selector);
        new FloorPolicyHarness(c, NAV0);

        c = cfg(FloorPolicy.Kind.Fixed);
        c.protectionWad = 1.1e18;
        vm.expectRevert(FloorPolicy.InvalidConfig.selector);
        new FloorPolicyHarness(c, NAV0);
    }

    // ---------- the core invariant: monotone floor ----------

    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_floorMonotone_acrossArbitraryPaths(uint256 seed) public {
        FloorPolicy.Kind kind = FloorPolicy.Kind(seed % 3);
        FloorPolicyHarness h = new FloorPolicyHarness(cfg(kind), NAV0);
        uint256 nav = NAV0;
        uint256 lastFloor;
        uint256 ts = T0;
        for (uint256 i; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            // nav moves in [-50%, +100%] per step, rate in [0, 20%]
            nav = nav * (50 + (seed % 151)) / 100;
            if (nav == 0) nav = 1;
            uint256 rate = (seed >> 128) % 0.2e18;
            ts += uint64((seed >> 200) % 30 days);
            if (ts > T1) ts = T1;
            uint256 f = h.update(nav, rate, ts);
            assertGe(f, lastFloor, "floor decreased");
            lastFloor = f;
        }
    }
}
