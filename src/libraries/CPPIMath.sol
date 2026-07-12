// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title CPPIMath
/// @notice Pure math for a CPPI capital-protected vault.
/// @dev All values are WAD (1e18) fixed point unless suffixed Bps.
///      The engine is one equation: targetRisky = m * (nav - floor),
///      clamped to [0, nav]. The floor is the present value of the
///      protected amount, discounted at the safe-leg rate, so a safe leg
///      of exactly floorValue() accretes to the protected amount at
///      maturity with no dependence on the risky asset.
library CPPIMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    /// @notice Present value of the protected amount `secondsLeft` before maturity.
    /// @param protectedAmount amount guaranteed at maturity (WAD-scaled asset units)
    /// @param rateWad continuously compounded safe-leg rate, e.g. 0.04e18
    function floorValue(uint256 protectedAmount, uint256 rateWad, uint256 secondsLeft) internal pure returns (uint256) {
        if (secondsLeft == 0) return protectedAmount;
        int256 exponent = -int256(rateWad * secondsLeft / YEAR);
        return FixedPointMathLib.mulWad(protectedAmount, uint256(FixedPointMathLib.expWad(exponent)));
    }

    function cushion(uint256 nav, uint256 floor) internal pure returns (uint256) {
        return nav > floor ? nav - floor : 0;
    }

    /// @notice Target risky exposure: m * cushion, clamped to the whole NAV.
    function targetRisky(uint256 nav, uint256 floor, uint256 multiplierWad) internal pure returns (uint256) {
        uint256 target = FixedPointMathLib.mulWad(multiplierWad, cushion(nav, floor));
        return FixedPointMathLib.min(target, nav);
    }

    /// @notice Absolute deviation of current risky exposure from target, in bps of NAV.
    function driftBps(uint256 currentRisky, uint256 target, uint256 nav) internal pure returns (uint256) {
        if (nav == 0) return 0;
        uint256 dev = FixedPointMathLib.dist(currentRisky, target);
        return dev * BPS / nav;
    }

    /// @notice Cushion as bps of NAV; the health metric the emergency path watches.
    function cushionBps(uint256 nav, uint256 floor) internal pure returns (uint256) {
        if (nav == 0) return 0;
        return cushion(nav, floor) * BPS / nav;
    }

    /// @notice Largest single-move drop the strategy survives before the floor
    ///         can break: 1/m, in bps. Independent of floor and NAV.
    function maxSurvivableGapBps(uint256 multiplierWad) internal pure returns (uint256) {
        return WAD * BPS / multiplierWad;
    }
}
