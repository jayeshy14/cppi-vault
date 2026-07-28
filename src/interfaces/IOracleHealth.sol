// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IOracleHealth
/// @notice Optional oracle-health signal the vault reads to gate user flows and
///         to widen the emergency de-risk bound while a feed is unreliable.
interface IOracleHealth {
    /// @notice True when every feed the vault depends on is fresh and within its
    ///         sanity bounds. When false, new deposits/redeems and settlement are
    ///         gated and the emergency de-risk uses the wider degraded bound.
    /// @return healthy_ Whether the oracle stack is currently healthy.
    function healthy() external view returns (bool healthy_);

    /// @notice True when the ETH feed has been stale beyond its prolonged-staleness
    ///         window, i.e. the risky-leg mark is frozen and the normal CPPI trigger
    ///         is blind to a real decline (audit M4). Enables the permissionless
    ///         prolonged-staleness circuit breaker.
    /// @return stale Whether the feed has been stale beyond the prolonged window.
    function prolongedStale() external view returns (bool stale);
}
