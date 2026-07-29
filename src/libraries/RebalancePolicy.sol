// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RebalancePolicy
/// @notice Two-tier rebalance trigger classification for a CPPI vault.
/// @dev Same shape as the index-protocol Rebalancer: a keeper-gated
///      scheduled path (cadence elapsed AND drift above a small band) and a
///      permissionless emergency path (drift above a large band OR cushion
///      below a health threshold). A global minimum interval anti-thrashes
///      both paths. Spike triggers kill latency risk; they cannot help with
///      a true gap, which only the multiplier survives.
library RebalancePolicy {
    // ============================================================================
    // Types and config
    // ============================================================================

    /// @notice Which rebalance path may fire.
    enum Trigger {
        /// @notice No rebalance is due.
        None,
        /// @notice The keeper-gated scheduled path (cadence elapsed and drift above the small band).
        Scheduled,
        /// @notice The permissionless emergency path (drift above the large band or cushion below its floor).
        Emergency
    }

    /// @notice Trigger thresholds for the two-tier rebalance policy.
    /// @param minInterval Hard anti-thrash floor, in seconds, applied to every path.
    /// @param cadence Scheduled path spacing, in seconds.
    /// @param driftSmallBps Scheduled path fires at drift >= this, in basis points.
    /// @param driftLargeBps Emergency path fires at drift >= this, in basis points.
    /// @param cushionFloorBps Emergency path fires at cushion/nav <= this, in basis points.
    struct Config {
        uint64 minInterval;
        uint64 cadence;
        uint16 driftSmallBps;
        uint16 driftLargeBps;
        uint16 cushionFloorBps;
    }

    /// @notice A config field was outside its permitted range or ordering.
    error InvalidConfig();

    // ============================================================================
    // Policy
    // ============================================================================

    /// @notice Revert unless the config is internally consistent: the small
    ///         drift band must not exceed the large one, cadence must be at
    ///         least the minimum interval, and the large drift band must be
    ///         non-zero.
    /// @param c The rebalance policy config to check.
    function validate(Config memory c) internal pure {
        if (c.driftSmallBps > c.driftLargeBps) revert InvalidConfig();
        if (c.cadence < c.minInterval) revert InvalidConfig();
        if (c.driftLargeBps == 0) revert InvalidConfig();
    }

    /// @notice Classify what may fire now. Within minInterval of the last
    ///         rebalance nothing fires; otherwise Emergency wins when drift is
    ///         at or above the large band or cushion is at or below its floor,
    ///         then Scheduled fires when the cadence has elapsed and drift is at
    ///         or above the small band. Callers enforce keeper gating for
    ///         Scheduled; Emergency is permissionless by design so anyone can
    ///         save the vault if the keeper is down during a crash.
    /// @param c The rebalance policy config.
    /// @param lastRebalanceAt Timestamp of the last rebalance (0 if none yet).
    /// @param nowTs The current timestamp.
    /// @param driftBps_ Current drift of risky exposure from target, in basis points of NAV.
    /// @param cushionBps_ Current cushion as basis points of NAV.
    /// @return The trigger that may fire now.
    function classify(Config memory c, uint256 lastRebalanceAt, uint256 nowTs, uint256 driftBps_, uint256 cushionBps_)
        internal
        pure
        returns (Trigger)
    {
        if (lastRebalanceAt != 0 && nowTs < lastRebalanceAt + c.minInterval) {
            return Trigger.None;
        }
        if (driftBps_ >= c.driftLargeBps || cushionBps_ <= c.cushionFloorBps) {
            return Trigger.Emergency;
        }
        bool cadenceElapsed = lastRebalanceAt == 0 || nowTs >= lastRebalanceAt + c.cadence;
        if (cadenceElapsed && driftBps_ >= c.driftSmallBps) {
            return Trigger.Scheduled;
        }
        return Trigger.None;
    }
}
