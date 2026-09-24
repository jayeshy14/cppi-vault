// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CPPIVault} from "../src/CPPIVault.sol";
import {CPPIController} from "../src/CPPIController.sol";
import {FloorPolicy} from "../src/libraries/FloorPolicy.sol";
import {RebalancePolicy} from "../src/libraries/RebalancePolicy.sol";
import {ILeg, IExecutionModule, IRateOracle} from "../src/interfaces/IVaultPeriphery.sol";
import {MockUSDC, MockLeg, MockExecutor, MockRateOracle} from "./mocks/Mocks.sol";

/// @notice Fee accrual against the per-share protection promise. Each test
///         drives the vault to a state where NAV meets the protected amount
///         before fees, then shows the fee mint leaves held shares below it.
///         These tests pass while the behaviour exists and are expected to
///         fail once fees are capped at the cushion above the floor.
contract FeeFloorBreachTest is Test {
    CPPIVault vault;
    CPPIController controller;
    MockUSDC usdc;
    MockLeg safe;
    MockLeg risky;
    MockExecutor exec;
    MockRateOracle rate;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address recipient = makeAddr("recipient");

    function _deploy(FloorPolicy.Config memory fc) internal {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        vault = new CPPIVault(address(usdc), 6, owner);

        fc.termStart = uint64(block.timestamp);
        fc.termEnd = uint64(block.timestamp + 365 days);
        RebalancePolicy.Config memory rc = RebalancePolicy.Config({
            minInterval: 1 hours, cadence: 1 days, driftSmallBps: 200, driftLargeBps: 500, cushionFloorBps: 300
        });
        controller = new CPPIController(address(vault), 2e18, fc, rc);

        safe = new MockLeg();
        risky = new MockLeg();
        exec = new MockExecutor(address(vault), address(usdc), safe, risky);
        rate = new MockRateOracle();

        vm.startPrank(owner);
        vault.setController(controller);
        vault.setPeriphery(
            ILeg(address(safe)), ILeg(address(risky)), IExecutionModule(address(exec)), IRateOracle(address(rate))
        );
        vault.setRoles(keeper, guardian);
        vm.stopPrank();

        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _fixed90() internal pure returns (FloorPolicy.Config memory fc) {
        fc.kind = FloorPolicy.Kind.Fixed;
        fc.protectionWad = 0.9e18;
    }

    function _step90() internal pure returns (FloorPolicy.Config memory fc) {
        fc.kind = FloorPolicy.Kind.Step;
        fc.protectionWad = 0.9e18;
        fc.triggerWad = 1.8e18;
        fc.stepWad = 1.25e18;
    }

    function _locked80() internal pure returns (FloorPolicy.Config memory fc) {
        fc.kind = FloorPolicy.Kind.Tipp;
        fc.protectionWad = 0.9e18;
        fc.ratchetWad = 0.8e18;
    }

    function _depositAndClaim(uint256 assets) internal {
        vm.prank(alice);
        vault.requestDeposit(assets);
        vm.prank(keeper);
        vault.settleEpoch();
        vm.prank(alice);
        vault.claimShares();
    }

    /// @dev Mark total NAV to `navWad` by moving the leg values; idle stays put.
    function _setNav(uint256 navWad) internal {
        uint256 idleWad = usdc.balanceOf(address(vault)) * 1e12;
        risky.set(0);
        safe.set(navWad - idleWad);
    }

    function _startTermAndAllocate() internal {
        vm.prank(keeper);
        vault.startTerm(365 days);
        vault.rebalance();
    }

    function _toMaturity() internal {
        vm.warp(block.timestamp + 365 days + 1);
    }

    // ---------- performance fee after the shortfall check ----------

    /// Step class: a rally steps protection to 1.125 per share, the vault then
    /// de-risks into maturity at 1.13. settleTerm reports no shortfall, and the
    /// fee on (1.13 - 1.00) takes held shares to ~1.1046, below 1.125.
    function test_performanceFee_stepRatchet_endsBelowProtected() public {
        _deploy(_step90());
        vm.prank(owner);
        vault.setFees(0, 2000, recipient);
        _depositAndClaim(100e6);
        _startTermAndAllocate();
        assertEq(vault.highWaterPerShareWad(), 1e18);

        // rally to navPS 1.60 >= 1.8 x floor fires one step: 0.9 x 1.25
        vm.warp(block.timestamp + 1 hours + 1);
        _setNav(160e18);
        vault.rebalance();
        assertEq(controller.protectedPerShareWad(), 1.125e18);

        _toMaturity();
        _setNav(113e18);
        assertGe(vault.navPerShare(), controller.protectedPerShareWad());

        vm.prank(keeper);
        uint256 shortfall = vault.settleTerm();

        assertEq(shortfall, 0);
        assertGt(vault.balanceOf(recipient), 0);
        assertLt(vault.navPerShare(), controller.protectedPerShareWad());
        assertApproxEqRel(vault.navPerShare(), 1.1046e18, 1e14);
    }

    /// TIPP class: navPS peaks at 1.5 so the lock is 1.2 per share. Maturity at
    /// 1.21 clears the lock, then the fee on (1.21 - 1.00) takes held shares to
    /// ~1.1694. settleTerm checks only the base 0.9 and reports no shortfall.
    function test_performanceFee_tippLock_endsBelowLock() public {
        _deploy(_locked80());
        vm.prank(owner);
        vault.setFees(0, 2000, recipient);
        _depositAndClaim(100e6);
        _startTermAndAllocate();

        vm.warp(block.timestamp + 1 hours + 1);
        _setNav(150e18);
        vault.rebalance();
        uint256 lockPerShare = uint256(1.5e18) * 0.8e18 / 1e18;
        assertGe(controller.lastFloor(), lockPerShare * 100); // aggregate over 100 shares

        _toMaturity();
        _setNav(121e18);
        assertGe(vault.navPerShare(), lockPerShare);

        vm.prank(keeper);
        uint256 shortfall = vault.settleTerm();

        assertEq(shortfall, 0);
        assertLt(vault.navPerShare(), lockPerShare);
        assertApproxEqRel(vault.navPerShare(), 1.1694e18, 1e14);
    }

    /// Fixed class over two terms with the fee on: term 2 starts after a rally
    /// at navPS 1.50 (protected 1.35) while the mark is 1.20, and ends at 1.30.
    /// settleTerm reports a 0.05 per-share shortfall and still mints a fee, so
    /// the real shortfall is larger than the one reported.
    function test_performanceFee_chargedWhileShortfallReported() public {
        _deploy(_fixed90());
        vm.prank(owner);
        vault.setFees(0, 2000, recipient);
        _depositAndClaim(100e6);
        _startTermAndAllocate();

        _toMaturity();
        _setNav(120e18);
        vm.prank(keeper);
        vault.settleTerm();
        assertEq(vault.highWaterPerShareWad(), 1.2e18);

        uint256 supply = vault.totalSupply();
        _setNav(supply * 15 / 10); // navPS 1.50 between terms
        vm.prank(keeper);
        vault.startTerm(365 days);
        assertApproxEqRel(controller.protectedPerShareWad(), 1.35e18, 1e12);

        _toMaturity();
        _setNav(supply * 13 / 10); // navPS 1.30
        uint256 recipientBefore = vault.balanceOf(recipient);

        vm.prank(keeper);
        uint256 shortfall = vault.settleTerm();

        assertApproxEqRel(shortfall, supply * 5 / 100, 1e12); // 0.05 per share, reported
        assertGt(vault.balanceOf(recipient), recipientBefore); // fee minted anyway
        uint256 realShortfall = (controller.protectedPerShareWad() - vault.navPerShare()) * vault.totalSupply() / 1e18;
        assertGt(realShortfall, shortfall);
        assertApproxEqRel(vault.navPerShare(), 1.2803e18, 1e14);
    }

    // ---------- high-water mark left behind while the fee is off ----------

    /// Term 1 ends at 1.50 with the fee off, so the mark stays at 1.00. The
    /// owner then turns the fee on; term 2 starts at 1.50 (protected 1.35) and
    /// ends at 1.36. The fee is charged on the 0.36 gain from 1.00, which takes
    /// held shares to ~1.2916, below 1.35, with a reported shortfall of 0.
    function test_performanceFee_staleMarkChargesEarlierTermGains() public {
        _deploy(_fixed90());
        _depositAndClaim(100e6);
        _startTermAndAllocate();

        _toMaturity();
        _setNav(150e18);
        vm.prank(keeper);
        vault.settleTerm();
        assertEq(vault.highWaterPerShareWad(), 1e18); // no ratchet while the fee is off

        vm.prank(owner);
        vault.setFees(0, 2000, recipient);
        vm.prank(keeper);
        vault.startTerm(365 days);
        assertApproxEqRel(controller.protectedPerShareWad(), 1.35e18, 1e12);

        _toMaturity();
        _setNav(136e18);
        assertGe(vault.navPerShare(), controller.protectedPerShareWad());

        vm.prank(keeper);
        uint256 shortfall = vault.settleTerm();

        assertEq(shortfall, 0);
        assertLt(vault.navPerShare(), controller.protectedPerShareWad());
        assertApproxEqRel(vault.navPerShare(), 1.2916e18, 1e14);
    }

    // ---------- management fee at the floor ----------

    /// A fully de-risked Fixed90 vault reaches maturity holding exactly the
    /// protected 0.90 per share. settleTerm accrues a year of the 200 bps
    /// management fee first, which takes held shares to ~0.882 and turns a
    /// zero shortfall into one the fee alone created.
    function test_managementFee_pushesFlooredVaultBelowProtected() public {
        _deploy(_fixed90());
        vm.prank(owner);
        vault.setFees(200, 0, recipient);
        _depositAndClaim(100e6);
        _startTermAndAllocate();

        _toMaturity();
        _setNav(90e18);
        assertEq(vault.navPerShare(), controller.protectedPerShareWad()); // exactly at the promise

        vm.prank(keeper);
        uint256 shortfall = vault.settleTerm();

        assertGt(vault.balanceOf(recipient), 0);
        assertGt(shortfall, 0);
        assertLt(vault.navPerShare(), controller.protectedPerShareWad());
        assertApproxEqRel(vault.navPerShare(), 0.8824e18, 1e14);
    }
}
