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

    uint256 public immutable multiplierWad;
    address public immutable vault;

    FloorPolicy.Config internal floorConfig;
    RebalancePolicy.Config internal rebalConfig;
    FloorPolicy.State internal floorState;

    uint64 public lastRebalanceAt;
    uint64 public termNumber;
    bool public termActive;

    /// @dev Last aggregate floor (floorPerShare * supply) computed by assess();
    ///      a convenience for the vault, dashboards, and invariant checks. The
    ///      authoritative floor is per-share, in floorState (audit H3).
    uint256 public lastFloorAggregate;

    uint256 internal constant MAX_RATE_WAD = 0.2e18;
    uint256 internal constant MAX_RATE_STEP_WAD = 0.02e18;
    uint256 internal lastRateWad;

    event TermStarted(
        uint64 indexed termNumber, uint64 termStart, uint64 termEnd, uint256 nav, uint256 protectedAmount
    );
    event TermSettled(uint64 indexed termNumber, uint256 nav, uint256 protectedAmount, uint256 shortfall);
    event RebalanceRecorded(uint64 indexed termNumber, RebalancePolicy.Trigger trigger, uint256 floor, uint256 target);

    error NotVault();
    error TermNotActive();
    error TermStillActive();
    error TermNotMatured();
    error ZeroSupply();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

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

    // ---------- term lifecycle ----------

    /// @param nav aggregate shareholder NAV at term start
    /// @param supply total share supply at term start (protection is per-share)
    function startTerm(uint64 termStart, uint64 termEnd, uint256 nav, uint256 supply) external onlyVault {
        if (termActive) revert TermStillActive();
        if (supply == 0) revert ZeroSupply();
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
    function settleTerm(uint256 nav, uint256 supply) external onlyVault returns (uint256 shortfall) {
        if (!termActive) revert TermNotActive();
        if (block.timestamp < floorConfig.termEnd) revert TermNotMatured();
        uint256 protectedAmount = floorState.protectedPerShareWad.mulWad(supply);
        shortfall = nav < protectedAmount ? protectedAmount - nav : 0;
        termActive = false;
        emit TermSettled(termNumber, nav, protectedAmount, shortfall);
    }

    // ---------- assessment ----------

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
    function recordRebalance(RebalancePolicy.Trigger trigger, uint256 floor, uint256 target) external onlyVault {
        lastRebalanceAt = uint64(block.timestamp);
        emit RebalanceRecorded(termNumber, trigger, floor, target);
    }

    // ---------- views ----------

    /// @notice Per-share protected amount (the authoritative floor state).
    function protectedPerShareWad() external view returns (uint256) {
        return floorState.protectedPerShareWad;
    }

    /// @notice Aggregate protected amount at a given supply (per-share * supply).
    function protectedAmount(uint256 supply) external view returns (uint256) {
        return floorState.protectedPerShareWad.mulWad(supply);
    }

    /// @notice Last aggregate floor from assess() (monotone within a term
    ///         at fixed supply); convenience for dashboards / invariant hooks.
    function lastFloor() external view returns (uint256) {
        return lastFloorAggregate;
    }

    function maxSurvivableGapBps() external view returns (uint256) {
        return CPPIMath.maxSurvivableGapBps(multiplierWad);
    }

    function floorConfigView() external view returns (FloorPolicy.Config memory) {
        return floorConfig;
    }

    // ---------- internal ----------

    /// @dev Clamp the oracle rate to [0, MAX_RATE] and bound per-update change,
    ///      limiting floor manipulation via the PT-implied-yield input.
    function _clampRate(uint256 raw) internal returns (uint256 rate) {
        rate = raw > MAX_RATE_WAD ? MAX_RATE_WAD : raw;
        uint256 last = lastRateWad;
        if (rate > last + MAX_RATE_STEP_WAD) rate = last + MAX_RATE_STEP_WAD;
        else if (rate + MAX_RATE_STEP_WAD < last) rate = last - MAX_RATE_STEP_WAD;
        lastRateWad = rate;
    }
}
