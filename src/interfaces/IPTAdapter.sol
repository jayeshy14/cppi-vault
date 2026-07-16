// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Fixed-yield tranche of the safe leg. v1 implementation is a Pendle
///         PT position; the mock stands in until the fork-tested adapter lands.
/// @dev All values WAD asset terms. Implementations own their PT tokens and
///      price them via the PT oracle; selling before maturity realizes
///      whatever the market pays (duration risk is the holder's).
interface IPTAdapter {
    /// @notice Current value of the PT position, WAD asset terms.
    function value() external view returns (uint256);

    /// @notice Live PT-implied yield (feeds the controller's floor marking).
    function impliedRateWad() external view returns (uint256);

    /// @notice Buy PT with `assets` deposit-asset units held by the caller.
    ///         Caller must have transferred the assets to the adapter first.
    function deposit(uint256 assets) external;

    /// @notice Sell/redeem PT worth `amountWad` and send proceeds to `to`.
    /// @return assetsOut deposit-asset units actually delivered
    function withdraw(uint256 amountWad, address to) external returns (uint256 assetsOut);

    /// @notice Maturity timestamp of the currently held PT series.
    function maturity() external view returns (uint256);
}
