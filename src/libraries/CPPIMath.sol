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
    // ============================================================================
    // Constants
    // ============================================================================

    /// @dev Fixed-point scale: 1e18 represents 1.0.
    uint256 internal constant WAD = 1e18;

    /// @dev Basis-point scale: 10_000 bps represents 100%.
    uint256 internal constant BPS = 10_000;

    /// @dev Seconds in a year, the denominator for annualized-rate discounting.
    uint256 internal constant YEAR = 365 days;

    // ============================================================================
    // CPPI math
    // ============================================================================

    /// @notice Present value of the protected amount `secondsLeft` before
    ///         maturity, discounting continuously at the safe-leg rate:
    ///         protectedAmount * e^(-rateWad * secondsLeft / YEAR). At maturity
    ///         (secondsLeft == 0) the present value equals the protected amount.
    /// @param protectedAmount Amount guaranteed at maturity, in WAD-scaled asset units.
    /// @param rateWad Continuously compounded safe-leg rate, WAD (e.g. 0.04e18).
    /// @param secondsLeft Seconds remaining until maturity.
    /// @return The discounted present value of the protected amount, WAD.
    function floorValue(uint256 protectedAmount, uint256 rateWad, uint256 secondsLeft) internal pure returns (uint256) {
        if (secondsLeft == 0) return protectedAmount;
        int256 exponent = -int256(rateWad * secondsLeft / YEAR);
        return FixedPointMathLib.mulWad(protectedAmount, uint256(FixedPointMathLib.expWad(exponent)));
    }

    /// @notice The cushion, nav - floor, floored at zero when NAV is below the floor.
    /// @param nav Total value in the system, WAD.
    /// @param floor The protected floor value, WAD.
    /// @return The non-negative cushion, WAD.
    function cushion(uint256 nav, uint256 floor) internal pure returns (uint256) {
        return nav > floor ? nav - floor : 0;
    }

    /// @notice Target risky exposure: m * cushion, clamped to the whole NAV.
    /// @param nav Total value in the system, WAD.
    /// @param floor The protected floor value, WAD.
    /// @param multiplierWad The CPPI multiplier m, WAD.
    /// @return The target risky exposure, WAD, never exceeding nav.
    function targetRisky(uint256 nav, uint256 floor, uint256 multiplierWad) internal pure returns (uint256) {
        uint256 target = FixedPointMathLib.mulWad(multiplierWad, cushion(nav, floor));
        return FixedPointMathLib.min(target, nav);
    }

    /// @notice Absolute deviation of current risky exposure from target, in bps
    ///         of NAV: |currentRisky - target| * BPS / nav. Returns 0 when nav is 0.
    /// @param currentRisky The current risky-leg exposure, WAD.
    /// @param target The target risky exposure, WAD.
    /// @param nav Total value in the system, WAD.
    /// @return The drift, in basis points of NAV.
    function driftBps(uint256 currentRisky, uint256 target, uint256 nav) internal pure returns (uint256) {
        if (nav == 0) return 0;
        uint256 dev = FixedPointMathLib.dist(currentRisky, target);
        return dev * BPS / nav;
    }

    /// @notice Cushion as bps of NAV; the health metric the emergency path
    ///         watches: cushion(nav, floor) * BPS / nav. Returns 0 when nav is 0.
    /// @param nav Total value in the system, WAD.
    /// @param floor The protected floor value, WAD.
    /// @return The cushion, in basis points of NAV.
    function cushionBps(uint256 nav, uint256 floor) internal pure returns (uint256) {
        if (nav == 0) return 0;
        return cushion(nav, floor) * BPS / nav;
    }

    /// @notice Largest single-move drop the strategy survives before the floor
    ///         can break: 1/m, in bps. Independent of floor and NAV.
    /// @param multiplierWad The CPPI multiplier m, WAD.
    /// @return The maximum survivable single-move gap, in basis points.
    function maxSurvivableGapBps(uint256 multiplierWad) internal pure returns (uint256) {
        return WAD * BPS / multiplierWad;
    }
}
