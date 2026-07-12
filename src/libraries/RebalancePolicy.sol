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
    enum Trigger {
        None,
        Scheduled,
        Emergency
    }

    struct Config {
        uint64 minInterval; // hard anti-thrash floor for every path
        uint64 cadence; // scheduled path spacing
        uint16 driftSmallBps; // scheduled path fires at drift >= this
        uint16 driftLargeBps; // emergency path fires at drift >= this
        uint16 cushionFloorBps; // emergency path fires at cushion/nav <= this
    }

    error InvalidConfig();

    function validate(Config memory c) internal pure {
        if (c.driftSmallBps > c.driftLargeBps) revert InvalidConfig();
        if (c.cadence < c.minInterval) revert InvalidConfig();
        if (c.driftLargeBps == 0) revert InvalidConfig();
    }

    /// @notice Classify what may fire now. Callers enforce keeper gating for
    ///         Scheduled; Emergency is permissionless by design so anyone can
    ///         save the vault if the keeper is down during a crash.
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
