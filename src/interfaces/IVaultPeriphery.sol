// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILeg
/// @notice A vault leg (safe or risky) that reports the current value of the
///         assets it holds, so the vault can mark NAV without knowing the leg's
///         internal composition.
interface ILeg {
    /// @notice Current mark of everything the leg holds, in WAD asset terms.
    /// @return valueWad The leg's value in WAD asset terms.
    function value() external view returns (uint256);
}

/// @title IExecutionModule
/// @notice Execution module that routes rebalance flows between the safe and
///         risky legs and frees idle assets for redemption settlement. The
///         vault relies on this surface for both scheduled rebalances and the
///         permissionless emergency de-risk.
/// @dev Implementations must be atomic; the emergency path depends on it
///      (spec invariant 5).
interface IExecutionModule {
    /// @notice Move exposure between legs to apply a signed rebalance delta,
    ///         subject to an oracle-anchored slippage bound. The vault calls
    ///         this to reach the controller's target risky exposure.
    /// @param deltaWad Signed change in risky exposure, in WAD: positive buys
    ///        risky with safe-side value, negative sells risky.
    /// @param maxSlippageBps Execution slippage bound in basis points,
    ///        oracle-anchored.
    function executeRebalance(int256 deltaWad, uint256 maxSlippageBps) external;

    /// @notice Unwind safe-side value into idle deposit asset held by the vault,
    ///         so the keeper can pre-fund a redemption settlement.
    /// @param amountWad The amount of safe-side value to free, in WAD asset terms.
    function freeAssets(uint256 amountWad) external;
}

/// @title IRateOracle
/// @notice Live PT-implied yield source the CPPI strategy reads to mark its
///         floor and size the risky allocation.
/// @dev The rate is clamped downstream by the controller.
interface IRateOracle {
    /// @notice Current PT-implied yield used by the controller.
    /// @return rate The implied rate, in WAD (1e18 == 100%).
    function rateWad() external view returns (uint256);
}
