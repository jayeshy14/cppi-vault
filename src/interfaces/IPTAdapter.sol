// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPTAdapter
/// @notice Fixed-yield tranche of the safe leg. v1 implementation is a Pendle
///         PT position; the mock stands in until the fork-tested adapter lands.
/// @dev All values WAD asset terms. Implementations own their PT tokens and
///      price them via the PT oracle; selling before maturity realizes
///      whatever the market pays (duration risk is the holder's).
interface IPTAdapter {
    /// @notice Current value of the PT position, WAD asset terms. The safe leg
    ///         reads it to mark the capital-protection side into vault NAV.
    /// @return valueWad The PT position's current value, in WAD asset terms.
    function value() external view returns (uint256 valueWad);

    /// @notice Live PT-implied yield. The controller reads it to discount the
    ///         protected amount when marking the floor.
    /// @return rateWad The PT-implied yield, in WAD.
    function impliedRateWad() external view returns (uint256 rateWad);

    /// @notice Buy PT with `assets` deposit-asset units held by the caller.
    ///         Caller must have transferred the assets to the adapter first.
    ///         The vault uses it to deploy idle asset into the fixed-yield leg.
    /// @param assets The deposit-asset units to spend on PT, in native decimals.
    function deposit(uint256 assets) external;

    /// @notice Return up to `amount` of un-deposited deposit asset held by the
    ///         adapter to `to` (the manager). Used to recover funds when a PT
    ///         buy is skipped/failed so nothing strands (audit M2).
    /// @param amount The maximum deposit-asset units to return, in native decimals.
    /// @param to The recipient that receives the returned asset (the manager).
    function reclaim(uint256 amount, address to) external;

    /// @notice Sell/redeem PT worth `amountWad` and send proceeds to `to`. The
    ///         vault calls it to free asset for redemption settlement or to
    ///         shift value out of the safe leg on a rebalance.
    /// @param amountWad The PT value to sell/redeem, in WAD asset terms.
    /// @param to The recipient that receives the sale proceeds.
    /// @return assetsOut The deposit-asset units actually delivered, in native decimals.
    function withdraw(uint256 amountWad, address to) external returns (uint256 assetsOut);

    /// @notice Maturity timestamp of the currently held PT series. The vault
    ///         reads it to align the term with the PT's zero-coupon maturity.
    /// @return maturityTs The PT series maturity, as a Unix timestamp.
    function maturity() external view returns (uint256 maturityTs);
}
