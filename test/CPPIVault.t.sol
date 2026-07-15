// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CPPIVault} from "../src/CPPIVault.sol";
import {CPPIController} from "../src/CPPIController.sol";
import {FloorPolicy} from "../src/libraries/FloorPolicy.sol";
import {RebalancePolicy} from "../src/libraries/RebalancePolicy.sol";
import {ILeg, IExecutionModule, IRateOracle} from "../src/interfaces/IVaultPeriphery.sol";
import {MockUSDC, MockLeg, MockExecutor, MockRateOracle} from "./mocks/Mocks.sol";

contract CPPIVaultTest is Test {
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
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        vault = new CPPIVault(address(usdc), 6, owner);

        FloorPolicy.Config memory fc;
        fc.kind = FloorPolicy.Kind.Fixed;
        fc.termStart = uint64(block.timestamp);
        fc.termEnd = uint64(block.timestamp + 365 days);
        fc.protectionWad = 0.9e18;
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
        usdc.mint(bob, 1_000e6);
        usdc.mint(address(exec), 1_000e6); // freeAssets float
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _depositAndClaim(address user, uint256 assets) internal {
        vm.prank(user);
        vault.requestDeposit(assets);
        vm.prank(keeper);
        vault.settleEpoch();
        vm.prank(user);
        vault.claimShares();
    }

    // ---------- async accounting ----------

    function test_depositSettleClaim_flow() public {
        vm.prank(alice);
        vault.requestDeposit(100e6);
        // pending cash is not shareholder value
        assertEq(vault.shareholderNav(), 0);
        assertEq(vault.totalNav(), 100e18);

        vm.prank(keeper);
        vault.settleEpoch();
        assertEq(vault.epochNavPerShare(1), 1e18);
        assertEq(vault.shareholderNav(), 100e18);

        vm.prank(alice);
        vault.claimShares();
        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.navPerShare(), 1e18);
    }

    function test_settlement_doesNotDiluteExistingHolders() public {
        _depositAndClaim(alice, 100e6);
        // vault appreciates: risky leg marks up 20 (nav 120)
        vm.prank(keeper);
        vault.startTerm(365 days);
        vault.rebalance(); // initial allocation, emergency, permissionless
        risky.add(20e18);
        uint256 priceBefore = vault.navPerShare();
        assertApproxEqRel(priceBefore, 1.2e18, 1e12);

        // bob's deposit settles at the appreciated price, alice unaffected
        vm.prank(bob);
        vault.requestDeposit(60e6);
        assertEq(vault.navPerShare(), priceBefore); // pending cash excluded
        vm.prank(keeper);
        vault.settleEpoch();
        vm.prank(bob);
        vault.claimShares();
        assertApproxEqRel(vault.balanceOf(bob), 50e18, 1e6); // 60 / 1.2
        assertApproxEqRel(vault.navPerShare(), priceBefore, 1e12);
    }

    function test_redeemSettleClaim_flow() public {
        _depositAndClaim(alice, 100e6);
        vm.prank(alice);
        vault.requestRedeem(40e18);
        assertEq(vault.balanceOf(alice), 60e18); // locked in custody

        vm.prank(keeper);
        vault.settleEpoch();
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.claimAssets();
        assertEq(usdc.balanceOf(alice) - balBefore, 40e6);
        assertEq(vault.totalSupply(), 60e18);
        assertEq(vault.navPerShare(), 1e18);
    }

    function test_settle_revertsWhenIdleCannotCoverPayout() public {
        _depositAndClaim(alice, 100e6);
        vm.prank(keeper);
        vault.startTerm(365 days);
        vault.rebalance();
        // move ALL idle into the safe leg so redemption cannot be paid
        uint256 idle = usdc.balanceOf(address(vault));
        vm.prank(address(vault));
        usdc.transfer(address(exec), idle);
        safe.add(idle * 1e12);

        vm.prank(alice);
        vault.requestRedeem(50e18);
        vm.prank(keeper);
        vm.expectRevert(CPPIVault.InsufficientIdle.selector);
        vault.settleEpoch();

        // keeper frees assets from the safe side, then settlement passes
        vm.prank(keeper);
        vault.freeAssets(60e18);
        vm.prank(keeper);
        vault.settleEpoch();
    }

    function test_secondRequest_afterUnclaimedEarlierEpoch_reverts() public {
        vm.prank(alice);
        vault.requestDeposit(50e6);
        vm.prank(keeper);
        vault.settleEpoch();
        // alice never claimed; next epoch request must revert
        vm.prank(alice);
        vm.expectRevert(CPPIVault.PendingRequestFromEarlierEpoch.selector);
        vault.requestDeposit(10e6);
        // after claiming, requesting works again
        vm.prank(alice);
        vault.claimShares();
        vm.prank(alice);
        vault.requestDeposit(10e6);
    }

    // ---------- rebalancing ----------

    function test_rebalance_initialAllocation_matchesWorkedExample() public {
        _depositAndClaim(alice, 100e6);
        vm.prank(keeper);
        vault.startTerm(365 days);
        vault.rebalance();
        // 27.06% initial exposure per the worked example (USDC-precision)
        assertApproxEqRel(risky.value(), 27.0579009525818224e18, 1e12);
        assertEq(vault.totalNav(), 100e18);
    }

    function test_rebalance_scheduled_isKeeperGated() public {
        _depositAndClaim(alice, 100e6);
        vm.prank(keeper);
        vault.startTerm(365 days);
        vault.rebalance();

        // drift to ~3% over a day: scheduled trigger
        vm.warp(block.timestamp + 1 days);
        risky.sub(3e18);
        vm.prank(alice);
        vm.expectRevert(CPPIVault.NotKeeper.selector);
        vault.rebalance();
        vm.prank(keeper);
        vault.rebalance();
        assertEq(uint256(exec.lastSlippageBps()), 50);
    }

    function test_rebalance_emergency_isPermissionless_evenWhenPaused() public {
        _depositAndClaim(alice, 100e6);
        vm.prank(keeper);
        vault.startTerm(365 days);

        vm.prank(guardian);
        vault.setPaused(true);

        // initial allocation drift ~27% >= 5%: emergency, callable by anyone
        vm.prank(alice);
        vault.rebalance();
        assertEq(uint256(exec.lastSlippageBps()), 150);

        // but user flows are blocked while paused
        vm.prank(bob);
        vm.expectRevert(CPPIVault.Paused.selector);
        vault.requestDeposit(10e6);
    }

    function test_rebalance_revertsWithoutTrigger() public {
        _depositAndClaim(alice, 100e6);
        vm.prank(keeper);
        vault.startTerm(365 days);
        vault.rebalance();
        // immediately after: minInterval gates everything
        vm.expectRevert(CPPIVault.NoTrigger.selector);
        vault.rebalance();
    }

    // ---------- term lifecycle ----------

    function test_term_startAndSettle() public {
        _depositAndClaim(alice, 100e6);
        vm.prank(keeper);
        vault.startTerm(365 days);
        vault.rebalance();

        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(keeper);
        uint256 shortfall = vault.settleTerm();
        assertEq(shortfall, 0);

        // roll into a new term at current NAV
        vm.prank(keeper);
        vault.startTerm(365 days);
        assertEq(controller.termNumber(), 2);
    }
}
