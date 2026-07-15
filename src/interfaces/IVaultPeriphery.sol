// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A vault leg (safe or risky) reporting its value in WAD asset terms.
interface ILeg {
    function value() external view returns (uint256);
}

/// @notice Execution module: routes rebalance flows between legs and frees
///         idle assets for redemption settlement. Implementations must be
///         atomic; the emergency path depends on it (spec invariant 5).
interface IExecutionModule {
    /// @param deltaWad positive: buy risky with safe-side value; negative: sell risky
    /// @param maxSlippageBps execution bound, oracle-anchored
    function executeRebalance(int256 deltaWad, uint256 maxSlippageBps) external;

    /// @notice Unwind safe-side value into idle deposit asset held by the vault.
    function freeAssets(uint256 amountWad) external;
}

/// @notice Live PT-implied yield source (clamped downstream by the controller).
interface IRateOracle {
    function rateWad() external view returns (uint256);
}
