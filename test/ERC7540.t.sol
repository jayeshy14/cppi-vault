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
