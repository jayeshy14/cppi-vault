// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {CPPIMath} from "./CPPIMath.sol";

/// @title FloorPolicy
/// @notice The floor-policy family for a CPPI vault: Fixed, Step ratchet, and
///         TIPP continuous ratchet, expressed as one floor function.
/// @dev floor = max(PV(protectedAmount, liveRate, timeLeft), policy term),
///      clamped monotone non-decreasing within a term. The Step policy raises
///      protectedAmount itself by k whenever NAV reaches T x floor, so the
///      ratchet survives rate changes and accretion consistently. All values
///      WAD unless noted.
library FloorPolicy {
    using FixedPointMathLib for uint256;

    enum Kind {
        Fixed,
        Step,
        Tipp
    }

    struct Config {
        Kind kind;
        uint64 termStart;
        uint64 termEnd;
        uint256 protectionWad; // P: fraction of term-start NAV promised at maturity
        uint256 triggerWad; // T (Step only): step fires when nav >= T x floor
        uint256 stepWad; // k (Step only): protectedAmount multiplier per step
        uint256 ratchetWad; // TIPP only: floor >= ratchet x high-water NAV
    }

    struct State {
        uint256 protectedAmount; // absolute asset terms; Step raises this
        uint256 hwmNav; // TIPP high-water NAV
        uint256 lastFloor; // monotonicity clamp
        uint32 stepCount;
    }

    /// @dev Bounds one update's step loop; with k >= MIN_STEP a gap large
    ///      enough to exhaust this cap cannot occur without NAV growing
    ///      >= MIN_STEP^MAX_STEPS x floor in a single update.
    uint256 internal constant MAX_STEPS_PER_UPDATE = 10;
    uint256 internal constant MIN_STEP = 1.05e18;
    uint256 internal constant WAD = 1e18;

    error InvalidConfig();

    function validate(Config memory c) internal pure {
        if (c.protectionWad == 0 || c.protectionWad >= WAD) revert InvalidConfig();
        if (c.termEnd <= c.termStart) revert InvalidConfig();
        if (c.kind == Kind.Step) {
            // k < T keeps a positive cushion after every step; T <= 2 (with
            // m = 2) guarantees the safe leg never fully empties.
            if (c.stepWad < MIN_STEP || c.stepWad >= c.triggerWad) revert InvalidConfig();
            if (c.triggerWad > 2e18) revert InvalidConfig();
        } else if (c.kind == Kind.Tipp) {
            if (c.ratchetWad == 0 || c.ratchetWad >= WAD) revert InvalidConfig();
        }
    }

    function initialize(State storage s, Config memory c, uint256 termStartNav) internal {
        s.protectedAmount = termStartNav.mulWad(c.protectionWad);
        s.hwmNav = termStartNav;
        s.lastFloor = 0;
        s.stepCount = 0;
    }

    /// @notice Compute the current floor and apply ratchet state transitions.
    /// @param nav current vault NAV in asset terms
    /// @param rateWad live PT-implied yield (caller clamps per spec section 5)
    /// @param nowTs current timestamp
    function currentFloor(State storage s, Config memory c, uint256 nav, uint256 rateWad, uint256 nowTs)
        internal
        returns (uint256 floor)
    {
        uint256 timeLeft = c.termEnd > nowTs ? c.termEnd - nowTs : 0;
        floor = CPPIMath.floorValue(s.protectedAmount, rateWad, timeLeft);

        if (c.kind == Kind.Tipp) {
            if (nav > s.hwmNav) s.hwmNav = nav;
            uint256 ratchetFloor = s.hwmNav.mulWad(c.ratchetWad);
            if (ratchetFloor > floor) floor = ratchetFloor;
        } else if (c.kind == Kind.Step) {
            uint256 steps;
            while (steps < MAX_STEPS_PER_UPDATE && floor != 0 && nav >= floor.mulWad(c.triggerWad)) {
                s.protectedAmount = s.protectedAmount.mulWad(c.stepWad);
                floor = CPPIMath.floorValue(s.protectedAmount, rateWad, timeLeft);
                unchecked {
                    ++steps;
                }
            }
            if (steps != 0) s.stepCount += uint32(steps);
        }

        // Monotone within the term: rate moves and policy math may only raise it.
        if (floor < s.lastFloor) {
            floor = s.lastFloor;
        } else {
            s.lastFloor = floor;
        }
    }

    /// @notice View variant: what the floor would be without state transitions.
    function previewFloor(State memory s, Config memory c, uint256 nav, uint256 rateWad, uint256 nowTs)
        internal
        pure
        returns (uint256 floor)
    {
        uint256 timeLeft = c.termEnd > nowTs ? c.termEnd - nowTs : 0;
        floor = CPPIMath.floorValue(s.protectedAmount, rateWad, timeLeft);
        if (c.kind == Kind.Tipp) {
            uint256 hwm = nav > s.hwmNav ? nav : s.hwmNav;
            uint256 ratchetFloor = hwm.mulWad(c.ratchetWad);
            if (ratchetFloor > floor) floor = ratchetFloor;
        } else if (c.kind == Kind.Step) {
            uint256 protectedAmount = s.protectedAmount;
            uint256 steps;
            while (steps < MAX_STEPS_PER_UPDATE && floor != 0 && nav >= floor.mulWad(c.triggerWad)) {
                protectedAmount = protectedAmount.mulWad(c.stepWad);
                floor = CPPIMath.floorValue(protectedAmount, rateWad, timeLeft);
                unchecked {
                    ++steps;
                }
            }
        }
        if (floor < s.lastFloor) floor = s.lastFloor;
    }
}
