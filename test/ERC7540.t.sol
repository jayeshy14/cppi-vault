// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CPPIVault} from "../src/CPPIVault.sol";
import {CPPIController} from "../src/CPPIController.sol";
import {FloorPolicy} from "../src/libraries/FloorPolicy.sol";
import {RebalancePolicy} from "../src/libraries/RebalancePolicy.sol";
import {ILeg, IExecutionModule, IRateOracle} from "../src/interfaces/IVaultPeriphery.sol";
import {MockUSDC, MockLeg, MockExecutor, MockRateOracle} from "./mocks/Mocks.sol";

contract ERC7540Test is Test {
    CPPIVault vault;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob"); // alice's operator
    address recv = makeAddr("recv");

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
        CPPIController controller = new CPPIController(address(vault), 2e18, fc, rc);
        MockLeg safe = new MockLeg();
        MockLeg risky = new MockLeg();
        MockExecutor exec = new MockExecutor(address(vault), address(usdc), safe, risky);

        vm.startPrank(owner);
        vault.setController(controller);
        vault.setPeriphery(
            ILeg(address(safe)),
            ILeg(address(risky)),
            IExecutionModule(address(exec)),
            IRateOracle(address(new MockRateOracle()))
        );
        vault.setRoles(keeper, keeper);
        vm.stopPrank();

        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_requestId_isEpoch_andViewsTransition() public {
        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(100e6, alice, alice);
        assertEq(requestId, 1);
        assertEq(vault.pendingDepositRequest(requestId, alice), 100e6);
        assertEq(vault.claimableDepositRequest(requestId, alice), 0);

        vm.prank(keeper);
        vault.settleEpoch();
        assertEq(vault.pendingDepositRequest(requestId, alice), 0);
        assertEq(vault.claimableDepositRequest(requestId, alice), 100e6);
    }

    function test_operator_canRequestAndClaimForController() public {
        vm.prank(alice);
        vault.setOperator(bob, true);
        assertTrue(vault.isOperator(alice, bob));

        // operator requests: assets pulled from alice, request owned by alice
        vm.prank(bob);
        vault.requestDeposit(100e6, alice, alice);
        vm.prank(keeper);
        vault.settleEpoch();

        // operator claims to a receiver of choice via the standard entrypoint
        vm.prank(bob);
        uint256 shares = vault.deposit(100e6, recv, alice);
        assertEq(vault.balanceOf(recv), shares);
        assertEq(shares, 100e18);
    }

    function test_nonOperator_reverts() public {
        vm.prank(bob);
        vm.expectRevert(CPPIVault.NotOperator.selector);
        vault.requestDeposit(100e6, alice, alice);
    }

    // L1: an attacker cannot seed a request into a foreign controller's slot
    function test_l1_cannotGriefForeignControllerSlot() public {
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 1e6);
        vm.prank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        // attacker funds from self (owner_=attacker) but targets alice's slot
        vm.prank(attacker);
        vm.expectRevert(CPPIVault.NotOperator.selector);
        vault.requestDeposit(1, alice, attacker);
        // alice's slot is untouched: she can request normally
        vm.prank(alice);
        vault.requestDeposit(100e6, alice, alice);
        assertEq(vault.pendingDepositRequest(1, alice), 100e6);
    }

    function test_l1_operatorCanStillWriteControllerSlot() public {
        vm.prank(alice);
        vault.setOperator(bob, true);
        // bob (alice's operator) targets alice's slot funding from alice: ok
        vm.prank(bob);
        vault.requestDeposit(100e6, alice, alice);
        assertEq(vault.pendingDepositRequest(1, alice), 100e6);
    }

    // I1: the aggregate payout reserved at settlement is floor(sumShares * price),
    // but each claimant is paid floor(userShares * price). With more than one
    // fractional (non-1e18-multiple) claimant the per-user floors sum to strictly
    // less than the aggregate, leaving a few wei of reserved dust. The last
    // claimant of the epoch must drain that residue so it does not stay frozen
    // in totalReservedPayoutsWad.
    function test_i1_reservedDustDrainedOnLastClaim() public {
        address carol = makeAddr("carol");
        address[3] memory holders = [alice, bob, carol];
        for (uint256 i = 0; i < holders.length; i++) {
            usdc.mint(holders[i], 1_000e6);
            vm.prank(holders[i]);
            usdc.approve(address(vault), type(uint256).max);
        }

        // seed holder enters at price 1e18 so the later donation has an existing
        // shareholder to accrue to, moving navPerShare off 1e18.
        address seed = makeAddr("seed");
        usdc.mint(seed, 1_000e6);
        vm.prank(seed);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(seed);
        vault.requestDeposit(300e6);
        vm.prank(keeper);
        vault.settleEpoch();
        vm.prank(seed);
        vault.claimShares();

        // donate yield -> navPerShare = 400/300 = 1.3333...e18 (non-terminating
        // wad fraction, so shares * price leaves nonzero sub-wei remainders)
        usdc.mint(address(vault), 100e6);

        // three holders each mint the same fractional share amount at 1.5e18
        for (uint256 i = 0; i < holders.length; i++) {
            vm.prank(holders[i]);
            vault.requestDeposit(100e6);
        }
        vm.prank(keeper);
        vault.settleEpoch();
        for (uint256 i = 0; i < holders.length; i++) {
            vm.prank(holders[i]);
            vault.claimShares();
        }
        assertTrue(vault.balanceOf(alice) % 1e18 != 0, "holders should be fractional");

        // all three redeem their full balance in the same epoch
        for (uint256 i = 0; i < holders.length; i++) {
            uint256 shares = vault.balanceOf(holders[i]);
            vm.prank(holders[i]);
            vault.requestRedeem(shares);
        }
        vm.prank(keeper);
        vault.settleEpoch();

        // claims one by one; the aggregate-vs-per-user rounding residue (here
        // 2 wei) sits reserved until the last claimant of the epoch drains it.
        for (uint256 i = 0; i < holders.length; i++) {
            vm.prank(holders[i]);
            vault.claimAssets();
        }

        assertEq(vault.totalReservedPayoutsWad(), 0, "reserved dust must be fully drained");
    }

    // G2: settling an epoch when NAV has collapsed to 0 (navPerShare == 0 while
    // shares are outstanding) must revert instead of writing the 0 that doubles
    // as the "unsettled" sentinel for epochNavPerShare, which would brick every
    // claim/view for that epoch forever and permanently lock the requests.
    function test_g2_settleRevertsWhenNavCollapsedToZero() public {
        vm.prank(alice);
        vault.requestDeposit(100e6);
        vm.prank(keeper);
        vault.settleEpoch();
        vm.prank(alice);
        vault.claimShares();
        assertEq(vault.balanceOf(alice), 100e18);

        // queue a full redeem: shares lock in custody, totalSupply stays 100e18
        vm.prank(alice);
        vault.requestRedeem(100e18);

        // simulate total loss: drain the vault's idle USDC so totalNav -> 0 and
        // navPerShare -> 0 with shares still outstanding
        uint256 bal = usdc.balanceOf(address(vault));
        vm.prank(address(vault));
        usdc.transfer(address(0xdead), bal);
        assertEq(vault.totalNav(), 0);
        assertEq(vault.navPerShare(), 0);

        vm.prank(keeper);
        vm.expectRevert(CPPIVault.NavCollapsed.selector);
        vault.settleEpoch();
    }

    function test_deposit_fullClaimOnly() public {
        vm.prank(alice);
        vault.requestDeposit(100e6, alice, alice);
        vm.prank(keeper);
        vault.settleEpoch();
        vm.prank(alice);
        vm.expectRevert(CPPIVault.ClaimMismatch.selector);
        vault.deposit(50e6, alice, alice); // partial claims not supported
        vm.prank(alice);
        vault.deposit(100e6, alice, alice);
        assertEq(vault.balanceOf(alice), 100e18);
    }

    function test_redeemFlow_standardEntrypoints() public {
        // enter via legacy path
        vm.startPrank(alice);
        vault.requestDeposit(100e6);
        vm.stopPrank();
        vm.prank(keeper);
        vault.settleEpoch();
        vm.prank(alice);
        vault.claimShares();

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(40e18, alice, alice);
        assertEq(vault.pendingRedeemRequest(requestId, alice), 40e18);

        vm.prank(keeper);
        vault.settleEpoch();
        assertEq(vault.claimableRedeemRequest(requestId, alice), 40e18);

        vm.prank(alice);
        uint256 assets = vault.redeem(40e18, recv, alice);
        assertEq(assets, 40e6);
        assertEq(usdc.balanceOf(recv), 40e6);
    }

    function test_supportsInterface_and4626Views() public {
        assertTrue(vault.supportsInterface(0x01ffc9a7));
        assertTrue(vault.supportsInterface(0xe3bc4e65));
        assertTrue(vault.supportsInterface(0xce3bbe50));
        assertTrue(vault.supportsInterface(0x620ee8e4));
        assertFalse(vault.supportsInterface(0xdeadbeef));
        assertEq(vault.share(), address(vault));

        vm.prank(alice);
        vault.requestDeposit(100e6);
        vm.prank(keeper);
        vault.settleEpoch();
        assertEq(vault.totalAssets(), 100e6);
    }
}
