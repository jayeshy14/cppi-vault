// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CPPIMath} from "../src/libraries/CPPIMath.sol";

contract CPPIMathTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant RATE = 0.04e18;
    uint256 constant PROTECTED = 0.9e18;
    uint256 constant M2 = 2e18;

    // 0.90 * e^(-0.04) for a full year out, cross-checked against the
    // python calibration repo: 0.8647105...e18
    function test_floorValue_oneYearOut() public pure {
        uint256 f = CPPIMath.floorValue(PROTECTED, RATE, 365 days);
        assertApproxEqRel(f, 0.864710495237090888e18, 1e6);
    }

    function test_floorValue_atMaturityIsProtected() public pure {
        assertEq(CPPIMath.floorValue(PROTECTED, RATE, 0), PROTECTED);
    }

    function test_floorValue_zeroRateIsFlat() public pure {
        assertEq(CPPIMath.floorValue(PROTECTED, 0, 365 days), PROTECTED);
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_floorValue_neverExceedsProtected(uint256 rate, uint256 secondsLeft) public pure {
        rate = bound(rate, 0, 1e18);
        secondsLeft = bound(secondsLeft, 0, 10 * 365 days);
        assertLe(CPPIMath.floorValue(PROTECTED, rate, secondsLeft), PROTECTED);
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_floorValue_accretesMonotonically(uint256 rate, uint256 t1, uint256 t2) public pure {
        rate = bound(rate, 0, 1e18);
        t1 = bound(t1, 0, 10 * 365 days);
        t2 = bound(t2, 0, t1);
        // less time left => floor is closer to the protected amount
        assertGe(CPPIMath.floorValue(PROTECTED, rate, t2), CPPIMath.floorValue(PROTECTED, rate, t1));
    }

    function test_targetRisky_matchesWorkedExample() public pure {
        // deposit 1, floor 0.865, cushion 0.135, m=2 => 27% exposure
        uint256 floor = CPPIMath.floorValue(PROTECTED, RATE, 365 days);
        uint256 target = CPPIMath.targetRisky(WAD, floor, M2);
        assertApproxEqRel(target, 0.270579009525818224e18, 1e6);
    }

    function test_targetRisky_clampsAtNav() public pure {
        // cushion 0.6 of nav 1 at m=2 wants 1.2, must clamp to nav
        assertEq(CPPIMath.targetRisky(WAD, 0.4e18, M2), WAD);
    }

    function test_targetRisky_zeroAtOrBelowFloor() public pure {
        assertEq(CPPIMath.targetRisky(0.8e18, 0.8e18, M2), 0);
        assertEq(CPPIMath.targetRisky(0.7e18, 0.8e18, M2), 0);
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_targetRisky_invariants(uint256 nav, uint256 floor, uint256 m) public pure {
        nav = bound(nav, 0, 1e30);
        floor = bound(floor, 0, 1e30);
        m = bound(m, 1e18, 20e18);
        uint256 target = CPPIMath.targetRisky(nav, floor, m);
        assertLe(target, nav);
        if (floor >= nav) assertEq(target, 0);
    }

    function test_driftBps() public pure {
        assertEq(CPPIMath.driftBps(0.27e18, 0.32e18, WAD), 500);
        assertEq(CPPIMath.driftBps(0.32e18, 0.27e18, WAD), 500);
        assertEq(CPPIMath.driftBps(0.27e18, 0.27e18, WAD), 0);
        assertEq(CPPIMath.driftBps(1, 0, 0), 0);
    }

    function test_maxSurvivableGap() public pure {
        assertEq(CPPIMath.maxSurvivableGapBps(2e18), 5000);
        assertEq(CPPIMath.maxSurvivableGapBps(4e18), 2500);
        assertEq(CPPIMath.maxSurvivableGapBps(2.5e18), 4000);
    }

    function test_cushionBps() public pure {
        assertEq(CPPIMath.cushionBps(WAD, 0.865e18), 1350);
        assertEq(CPPIMath.cushionBps(WAD, WAD), 0);
        assertEq(CPPIMath.cushionBps(0, 0), 0);
    }
}
