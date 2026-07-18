// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {CPPIMath} from "./CPPIMath.sol";

/// @title FloorPolicy
/// @notice The floor-policy family for a CPPI vault: Fixed, Step ratchet, and
///         TIPP continuous ratchet, expressed as one floor function.
/// @dev The floor is stored and computed PER SHARE, not as a whole-vault
///      aggregate (audit H3). Capital protection is a per-share promise, and
///      the vault's share supply changes mid-term via epoch settlement; a
///      per-share floor is invariant to those mint/burn flows, so a mid-term
///      deposit or redemption can no longer dilute existing holders' floor or
///      manufacture a phantom shortfall. Callers reconstruct the aggregate
///      floor as floorPerShare * totalSupply. All values WAD.
///      floorPerShare = max(PV(protectedPerShare, liveRate, timeLeft), policy),
///      clamped monotone non-decreasing within a term.
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
        uint256 protectionWad; // P: fraction of term-start navPerShare promised at maturity
        uint256 triggerWad; // T (Step only): step fires when navPerShare >= T x floorPerShare
        uint256 stepWad; // k (Step only): protectedPerShare multiplier per step
        uint256 ratchetWad; // TIPP only: floorPerShare >= ratchet x high-water navPerShare
    }

    struct State {
        uint256 protectedPerShareWad; // per-share protected amount; Step raises this
        uint256 hwmNavPerShareWad; // TIPP high-water navPerShare
        uint256 lastFloorPerShareWad; // monotonicity clamp (per share)
        uint32 stepCount;
    }

    /// @dev Bounds one update's step loop; with k >= MIN_STEP a gap large
    ///      enough to exhaust this cap cannot occur without navPerShare growing
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

    function initialize(State storage s, Config memory c, uint256 termStartNavPerShare) internal {
        s.protectedPerShareWad = termStartNavPerShare.mulWad(c.protectionWad);
        s.hwmNavPerShareWad = termStartNavPerShare;
        s.lastFloorPerShareWad = 0;
        s.stepCount = 0;
    }

    /// @notice Compute the current per-share floor and apply ratchet transitions.
    /// @param navPerShare current vault NAV per share, WAD
    /// @param rateWad live PT-implied yield (caller clamps per spec section 5)
    /// @param nowTs current timestamp
    function currentFloor(State storage s, Config memory c, uint256 navPerShare, uint256 rateWad, uint256 nowTs)
        internal
        returns (uint256 floor)
    {
        uint256 timeLeft = c.termEnd > nowTs ? c.termEnd - nowTs : 0;
        floor = CPPIMath.floorValue(s.protectedPerShareWad, rateWad, timeLeft);

        if (c.kind == Kind.Tipp) {
            if (navPerShare > s.hwmNavPerShareWad) s.hwmNavPerShareWad = navPerShare;
            uint256 ratchetFloor = s.hwmNavPerShareWad.mulWad(c.ratchetWad);
            if (ratchetFloor > floor) floor = ratchetFloor;
        } else if (c.kind == Kind.Step) {
            uint256 steps;
            while (steps < MAX_STEPS_PER_UPDATE && floor != 0 && navPerShare >= floor.mulWad(c.triggerWad)) {
                s.protectedPerShareWad = s.protectedPerShareWad.mulWad(c.stepWad);
                floor = CPPIMath.floorValue(s.protectedPerShareWad, rateWad, timeLeft);
                unchecked {
                    ++steps;
                }
            }
            if (steps != 0) s.stepCount += uint32(steps);
        }

        // Monotone within the term: rate moves and policy math may only raise it.
        if (floor < s.lastFloorPerShareWad) {
            floor = s.lastFloorPerShareWad;
        } else {
            s.lastFloorPerShareWad = floor;
        }
    }

    /// @notice View variant: the per-share floor without state transitions.
    function previewFloor(State memory s, Config memory c, uint256 navPerShare, uint256 rateWad, uint256 nowTs)
        internal
        pure
        returns (uint256 floor)
    {
        uint256 timeLeft = c.termEnd > nowTs ? c.termEnd - nowTs : 0;
        floor = CPPIMath.floorValue(s.protectedPerShareWad, rateWad, timeLeft);
        if (c.kind == Kind.Tipp) {
            uint256 hwm = navPerShare > s.hwmNavPerShareWad ? navPerShare : s.hwmNavPerShareWad;
            uint256 ratchetFloor = hwm.mulWad(c.ratchetWad);
            if (ratchetFloor > floor) floor = ratchetFloor;
        } else if (c.kind == Kind.Step) {
            uint256 protectedPerShare = s.protectedPerShareWad;
            uint256 steps;
            while (steps < MAX_STEPS_PER_UPDATE && floor != 0 && navPerShare >= floor.mulWad(c.triggerWad)) {
                protectedPerShare = protectedPerShare.mulWad(c.stepWad);
                floor = CPPIMath.floorValue(protectedPerShare, rateWad, timeLeft);
                unchecked {
                    ++steps;
                }
            }
        }
        if (floor < s.lastFloorPerShareWad) floor = s.lastFloorPerShareWad;
    }
}
