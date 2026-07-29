// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {CPPIMath} from "./libraries/CPPIMath.sol";
import {FloorPolicy} from "./libraries/FloorPolicy.sol";
import {RebalancePolicy} from "./libraries/RebalancePolicy.sol";

/// @title CPPIController
/// @notice Per-share-class CPPI state machine: term lifecycle, floor state,
///         and rebalance assessment. Holds no funds and executes no trades;
///         the vault reads assessments and routes execution.
/// @dev The multiplier is immutable and shared by every class (it alone
///      controls breach risk). Floor policy parameters are fixed at
///      construction. Rate input is the live PT-implied yield, clamped here
///      per spec section 5.
contract CPPIController {
    using FloorPolicy for FloorPolicy.State;
    using FixedPointMathLib for uint256;

    // ============================================================================
    // Configuration and state
    // ============================================================================

    /// @notice The CPPI multiplier, in WAD. Immutable and shared by every class;
    ///         it alone controls breach risk (target risky = multiplier * cushion).
    uint256 public immutable multiplierWad;

    /// @notice The vault contract authorized to drive this controller's state machine.
    address public immutable vault;

    /// @dev Floor policy parameters (glide path, protected ratio, term bounds),
    ///      fixed at construction and re-stamped with each term's start/end.
    FloorPolicy.Config internal floorConfig;

    /// @dev Rebalance policy parameters (drift/cushion thresholds, min interval)
    ///      used to classify which trigger, if any, may fire.
    RebalancePolicy.Config internal rebalConfig;

    /// @dev Live floor state (per-share protected amount and ratchet state) for
    ///      the active term. The authoritative floor is stored per-share here.
    FloorPolicy.State internal floorState;

    /// @notice Timestamp of the last recorded rebalance, gating the next one via minInterval.
    uint64 public lastRebalanceAt;

    /// @notice The current term counter, incremented on each startTerm.
    uint64 public termNumber;

    /// @notice Whether a term is currently active (between startTerm and settleTerm).
    bool public termActive;

    /// @dev Last aggregate floor (floorPerShare * supply) computed by assess();
    ///      a convenience for the vault, dashboards, and invariant checks. The
    ///      authoritative floor is per-share, in floorState (audit H3).
    uint256 public lastFloorAggregate;

    /// @dev Hard ceiling on the accepted PT-implied yield, in WAD, clamping the
    ///      rate input before it feeds the floor computation.
    uint256 internal constant MAX_RATE_WAD = 0.2e18;

    /// @dev Maximum accepted upward change in the rate per update, in WAD; bounds
    ///      floor manipulation via a spiked PT-implied-yield input (audit M3).
    uint256 internal constant MAX_RATE_STEP_WAD = 0.02e18;

    /// @dev Last clamped rate applied, in WAD; the anchor the per-update step is
    ///      measured against. Seeded at construction.
    uint256 internal lastRateWad;

    /// @dev Anti-churn floor on term length (audit H2). Well below the 12-month
    ///      product term; exists so a compromised keeper cannot loop tiny terms.
    uint64 public constant MIN_TERM_DURATION = 7 days;

    // ============================================================================
    // Events and errors
    // ============================================================================

    /// @notice Emitted when a new term is started.
    /// @param termNumber The term counter after incrementing.
    /// @param termStart The term's start timestamp.
    /// @param termEnd The term's maturity timestamp.
    /// @param nav Aggregate shareholder NAV at term start, in WAD.
    /// @param protectedWad Aggregate protected amount at term start (per-share * supply), in WAD.
    event TermStarted(uint64 indexed termNumber, uint64 termStart, uint64 termEnd, uint256 nav, uint256 protectedWad);

    /// @notice Emitted when a matured term is settled.
    /// @param termNumber The term counter of the settled term.
    /// @param nav Aggregate shareholder NAV at settlement, in WAD.
    /// @param protectedWad Aggregate protected amount reconstructed at settlement, in WAD.
    /// @param shortfall Realized shortfall below the protected amount (target: zero), in WAD.
    event TermSettled(uint64 indexed termNumber, uint256 nav, uint256 protectedWad, uint256 shortfall);

    /// @notice Emitted when an executed rebalance is recorded.
    /// @param termNumber The term counter the rebalance belongs to.
    /// @param trigger Which trigger fired (Scheduled or Emergency).
    /// @param floor The aggregate floor the assessment was taken against, in WAD.
    /// @param target The target risky exposure, in WAD.
    event RebalanceRecorded(uint64 indexed termNumber, RebalancePolicy.Trigger trigger, uint256 floor, uint256 target);

    /// @notice Caller is not the wired vault.
    error NotVault();

    /// @notice An operation requiring an active term was attempted while none is active.
    error TermNotActive();

    /// @notice startTerm was called while a term is still active.
    error TermStillActive();

    /// @notice settleTerm was called before the term reached maturity.
    error TermNotMatured();

    /// @notice An operation was attempted at zero share supply (protection is per-share).
    error ZeroSupply();

    /// @notice A term shorter than MIN_TERM_DURATION was requested (audit H2).
    error TermTooShort();

    /// @notice Restricts a function to the wired vault.
    /// @dev Reverts NotVault for any other caller.
    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    /// @notice Deploy the controller, wiring it to a vault and fixing the CPPI
    ///         multiplier and floor/rebalance policy parameters.
    /// @param vault_ The vault authorized to drive this controller.
    /// @param multiplierWad_ The CPPI multiplier, in WAD (bounded to [1e18, 4e18]).
    /// @param floorConfig_ The floor policy parameters, validated at construction.
    /// @param rebalConfig_ The rebalance policy parameters, validated at construction.
    constructor(
        address vault_,
        uint256 multiplierWad_,
        FloorPolicy.Config memory floorConfig_,
        RebalancePolicy.Config memory rebalConfig_
    ) {
        require(vault_ != address(0) && multiplierWad_ >= 1e18 && multiplierWad_ <= 4e18);
        FloorPolicy.validate(floorConfig_);
        RebalancePolicy.validate(rebalConfig_);
        vault = vault_;
        multiplierWad = multiplierWad_;
        floorConfig = floorConfig_;
        rebalConfig = rebalConfig_;
        lastRateWad = 0.04e18;
    }

    // ============================================================================
    // Term lifecycle
    // ============================================================================

    /// @notice Start a new term: stamp the term window, initialize the per-share
    ///         floor from entry navPerShare, and activate the state machine.
    /// @param termStart The term's start timestamp.
    /// @param termEnd The term's maturity timestamp (must be at least MIN_TERM_DURATION out).
    /// @param nav aggregate shareholder NAV at term start
    /// @param supply total share supply at term start (protection is per-share)
    function startTerm(uint64 termStart, uint64 termEnd, uint256 nav, uint256 supply) external onlyVault {
        if (termActive) revert TermStillActive();
        if (supply == 0) revert ZeroSupply();
        if (termEnd < termStart + MIN_TERM_DURATION) revert TermTooShort();
        floorConfig.termStart = termStart;
        floorConfig.termEnd = termEnd;
        FloorPolicy.validate(floorConfig);
        FloorPolicy.initialize(floorState, floorConfig, nav.divWad(supply));
        termActive = true;
        lastRebalanceAt = 0;
        unchecked {
            ++termNumber;
        }
        emit TermStarted(termNumber, termStart, termEnd, nav, floorState.protectedPerShareWad.mulWad(supply));
    }

    /// @notice Settle a matured term. Emits realized shortfall (target: zero).
    /// @dev Protection is per-share: the aggregate protected amount is
    ///      reconstructed from the current supply, so mid-term mint/burn can
    ///      no longer desync it from the promise (audit H3).
    /// @param nav aggregate shareholder NAV at settlement
    /// @param supply total share supply at settlement (the per-share floor scales to it)
    /// @return shortfall The amount NAV falls below the protected amount, or 0 if fully funded.
    function settleTerm(uint256 nav, uint256 supply) external onlyVault returns (uint256 shortfall) {
        if (!termActive) revert TermNotActive();
        if (block.timestamp < floorConfig.termEnd) revert TermNotMatured();
        uint256 protectedWad = floorState.protectedPerShareWad.mulWad(supply);
        shortfall = nav < protectedWad ? protectedWad - nav : 0;
        termActive = false;
        emit TermSettled(termNumber, nav, protectedWad, shortfall);
    }

    // ============================================================================
    // Assessment
    // ============================================================================

    /// @notice Snapshot of the CPPI assessment the vault acts on.
    /// @param floor The aggregate floor (per-share floor * supply), in WAD.
    /// @param cushion The buffer of NAV above the floor, in WAD.
    /// @param targetRisky The target risky-leg exposure (multiplier * cushion), in WAD.
    /// @param driftBps The current risky exposure's drift from target, in basis points.
    /// @param cushionBps The cushion expressed as a fraction of NAV, in basis points.
    /// @param trigger Which rebalance trigger (if any) may fire now.
    struct Assessment {
        uint256 floor;
        uint256 cushion;
        uint256 targetRisky;
        uint256 driftBps;
        uint256 cushionBps;
        RebalancePolicy.Trigger trigger;
    }

    /// @notice Compute floor, target exposure, and which trigger (if any) may
    ///         fire now. State-mutating: applies ratchet transitions and the
    ///         monotone clamp.
    /// @param nav aggregate shareholder NAV
    /// @param supply total share supply (the per-share floor scales to it)
    /// @param riskyValue the current risky-leg value, in WAD, measured for drift
    /// @param rawRateWad the live PT-implied yield, in WAD, before clamping
    /// @return a The assessment snapshot (floor, cushion, target, drift, cushion bps, trigger).
    function assess(uint256 nav, uint256 supply, uint256 riskyValue, uint256 rawRateWad)
        external
        onlyVault
        returns (Assessment memory a)
    {
        if (!termActive) revert TermNotActive();
        if (supply == 0) revert ZeroSupply();
        uint256 rate = _clampRate(rawRateWad);
        uint256 navPerShare = nav.divWad(supply);
        // per-share floor is supply-invariant; reconstruct the aggregate for
        // the cushion/target/drift math the vault operates on
        uint256 floorPerShare = floorState.currentFloor(floorConfig, navPerShare, rate, block.timestamp);
        a.floor = floorPerShare.mulWad(supply);
        lastFloorAggregate = a.floor;
        a.cushion = CPPIMath.cushion(nav, a.floor);
        a.targetRisky = CPPIMath.targetRisky(nav, a.floor, multiplierWad);
        a.driftBps = CPPIMath.driftBps(riskyValue, a.targetRisky, nav);
        a.cushionBps = CPPIMath.cushionBps(nav, a.floor);
        a.trigger = RebalancePolicy.classify(rebalConfig, lastRebalanceAt, block.timestamp, a.driftBps, a.cushionBps);
    }

    /// @notice Record an executed rebalance (gates the next one via minInterval).
    /// @param trigger Which trigger fired (Scheduled or Emergency).
    /// @param floor The aggregate floor the assessment was taken against, in WAD.
    /// @param target The target risky exposure that was executed toward, in WAD.
    function recordRebalance(RebalancePolicy.Trigger trigger, uint256 floor, uint256 target) external onlyVault {
        lastRebalanceAt = uint64(block.timestamp);
        emit RebalanceRecorded(termNumber, trigger, floor, target);
    }

    // ---------- views ----------

    /// @notice Per-share protected amount (the authoritative floor state).
    /// @return The per-share protected amount, in WAD.
    function protectedPerShareWad() external view returns (uint256) {
        return floorState.protectedPerShareWad;
    }

    /// @notice Aggregate protected amount at a given supply (per-share * supply).
    /// @param supply The share supply the per-share floor scales to.
    /// @return The aggregate protected amount at that supply, in WAD.
    function protectedAmount(uint256 supply) external view returns (uint256) {
        return floorState.protectedPerShareWad.mulWad(supply);
    }

    /// @notice Last aggregate floor from assess() (monotone within a term
    ///         at fixed supply); convenience for dashboards / invariant hooks.
    /// @return The last aggregate floor computed by assess(), in WAD.
    function lastFloor() external view returns (uint256) {
        return lastFloorAggregate;
    }

    /// @notice The largest single-step risky-leg drawdown the strategy can
    ///         absorb before NAV would breach the floor, a function of the
    ///         multiplier alone.
    /// @return The maximum survivable gap, in basis points.
    function maxSurvivableGapBps() external view returns (uint256) {
        return CPPIMath.maxSurvivableGapBps(multiplierWad);
    }

    /// @notice The active floor policy configuration (glide path, protected
    ///         ratio, term window).
    /// @return The floor policy config struct currently in effect.
    function floorConfigView() external view returns (FloorPolicy.Config memory) {
        return floorConfig;
    }

    // ---------- internal ----------

    /// @notice Clamp the raw oracle rate to the accepted band and rate-limit
    ///         upward moves before it feeds the floor computation.
    /// @dev Clamp the oracle rate to [0, MAX_RATE] and bound per-update change,
    ///      limiting floor manipulation via the PT-implied-yield input.
    /// @param raw The live PT-implied yield, in WAD, before clamping.
    /// @return rate The clamped rate applied, in WAD.
    function _clampRate(uint256 raw) internal returns (uint256 rate) {
        rate = raw > MAX_RATE_WAD ? MAX_RATE_WAD : raw;
        uint256 last = lastRateWad;
        // Asymmetric clamp (audit M3): only bound UPWARD moves. A spiked rate
        // deepens the discount and lowers the floor, the manipulation
        // direction, so it is rate-limited. A falling rate raises the floor
        // (conservative, better-funded), so it is applied immediately rather
        // than lagging behind a fast PT-yield collapse.
        if (rate > last + MAX_RATE_STEP_WAD) rate = last + MAX_RATE_STEP_WAD;
        lastRateWad = rate;
    }
}
