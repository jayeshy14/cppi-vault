// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeLegManager} from "../src/SafeLegManager.sol";
import {IPTAdapter} from "../src/interfaces/IPTAdapter.sol";
import {MockUSDC} from "./mocks/Mocks.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @dev PT mock: buys at par, sells at par minus a settable haircut. Holds
///      real USDC so value is conserved end to end.
contract MockPTAdapter is IPTAdapter {
    using SafeTransferLib for address;

    address public immutable usdc;
    uint256 public valueWad;
    uint256 public haircutBps;
    uint256 public impliedRateWad = 0.045e18;
    uint256 public maturity;

    constructor(address usdc_) {
        usdc = usdc_;
        maturity = block.timestamp + 365 days;
    }

    function setHaircut(uint256 bps) external {
        haircutBps = bps;
    }

    function value() external view returns (uint256) {
        return valueWad;
    }

    function deposit(uint256 assets) external {
        valueWad += assets * 1e12;
    }

    function withdraw(uint256 amountWad, address to) external returns (uint256 assetsOut) {
        valueWad -= amountWad;
        assetsOut = (amountWad * (10_000 - haircutBps) / 10_000) / 1e12;
        usdc.safeTransfer(to, assetsOut);
    }
}

/// @dev NAV stub: manager reads totalNav() for band sizing. Tests fix it so
///      band math is deterministic and independent of leg state.
contract MockNavVault {
    uint256 public totalNav;

    function set(uint256 nav) external {
        totalNav = nav;
    }
}

contract SafeLegManagerTest is Test {
    SafeLegManager manager;
    MockPTAdapter pt;
    MockNavVault navVault;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address executor = makeAddr("executor");
    address stranger = makeAddr("stranger");

    // vault totalNav fixed at 1000: buffer bands are min 10 / target 30 / max 50
    uint256 constant NAV = 1000e18;

    function setUp() public {
        usdc = new MockUSDC();
        navVault = new MockNavVault();
        navVault.set(NAV);
        manager = new SafeLegManager(address(navVault), address(usdc), 6, owner);
        pt = new MockPTAdapter(address(usdc));
        vm.prank(owner);
        manager.setPeriphery(IPTAdapter(address(pt)), executor, keeper);
    }

    function _inflow(uint256 assets) internal {
        usdc.mint(address(manager), assets);
        vm.prank(keeper);
        manager.onInflow();
    }

    function test_inflow_fillsBufferToTarget_thenBuysPT() public {
        _inflow(100e6);
        // target buffer = 3% of 1000 = 30; rest (70) buys PT
        assertEq(manager.bufferWad(), 30e18);
        assertEq(pt.valueWad(), 70e18);
        assertEq(manager.value(), 100e18);
    }

    function test_inflow_belowTarget_staysInBuffer() public {
        _inflow(20e6);
        assertEq(manager.bufferWad(), 20e18);
        assertEq(pt.valueWad(), 0);
    }

    function test_provide_drainsBufferToMinFirst() public {
        _inflow(100e6); // buffer 30, pt 70
        vm.prank(executor);
        uint256 out = manager.provide(15e18, executor);
        // buffer can give down to min band (10): 20 available, 15 requested
        assertEq(out, 15e6);
        assertEq(manager.bufferWad(), 15e18);
        assertEq(pt.valueWad(), 70e18); // PT untouched
    }

    function test_provide_beyondBuffer_sellsPT() public {
        _inflow(100e6); // buffer 30, pt 70
        vm.prank(executor);
        uint256 out = manager.provide(50e18, executor);
        // 20 from buffer (down to min), 30 from PT
        assertEq(out, 50e6);
        assertEq(manager.bufferWad(), 10e18);
        assertEq(pt.valueWad(), 40e18);
        assertEq(manager.value(), 50e18);
    }

    function test_provide_ptShortfall_digsIntoProtectedBand() public {
        _inflow(100e6); // buffer 30, pt 70
        // drain PT almost entirely first
        vm.prank(executor);
        manager.provide(85e18, executor); // 20 buffer + 65 pt -> buffer 10, pt 5
        // ask for more than PT holds: remainder comes from the protected band
        vm.prank(executor);
        uint256 out = manager.provide(12e18, executor);
        assertEq(out, 12e6);
        assertEq(pt.valueWad(), 0);
        assertEq(manager.bufferWad(), 3e18);
    }

    function test_provide_haircut_reducesDeliveredNotReverts() public {
        _inflow(100e6);
        pt.setHaircut(100); // PT sells 1% under par
        vm.prank(executor);
        uint256 out = manager.provide(50e18, executor);
        // 20 par from buffer + 30 at 99% from PT = 49.7
        assertEq(out, 49.7e6);
    }

    function test_provide_revertsBeyondValue() public {
        _inflow(100e6);
        vm.prank(executor);
        vm.expectRevert(SafeLegManager.InsufficientValue.selector);
        manager.provide(101e18, executor);
    }

    function test_bufferRebalance_spillsAboveMax() public {
        _inflow(100e6); // buffer 30, pt 70
        usdc.mint(address(manager), 30e6); // buffer now 60 > max 50
        vm.prank(keeper);
        manager.rebalanceBuffer();
        assertEq(manager.bufferWad(), 30e18); // back to target
        assertEq(pt.valueWad(), 100e18);
    }

    function test_bufferRebalance_topsUpBelowMin() public {
        _inflow(100e6); // buffer 30, pt 70
        vm.prank(executor);
        manager.provide(25e18, executor); // buffer 10 (min), pt 65
        vm.prank(executor);
        manager.provide(5e18, executor); // digs to buffer 10 -> pt 60... buffer at min
        // push buffer below min via a direct provide of the band itself
        navVault.set(2000e18); // bands double: min now 20 > buffer 10
        vm.prank(keeper);
        manager.rebalanceBuffer();
        // topped up to new target (60)
        assertEq(manager.bufferWad(), 60e18);
        assertEq(manager.value(), 70e18); // conservation: 100 in, 30 provided out
    }

    function test_accessControl() public {
        _inflow(50e6);
        vm.prank(stranger);
        vm.expectRevert(SafeLegManager.NotAuthorized.selector);
        manager.provide(1e18, stranger);
        vm.prank(stranger);
        vm.expectRevert(SafeLegManager.NotAuthorized.selector);
        manager.onInflow();
    }

    function test_setBands_validation() public {
        vm.prank(owner);
        vm.expectRevert(SafeLegManager.BadBands.selector);
        manager.setBands(400, 300, 500); // min > target
        vm.prank(owner);
        manager.setBands(50, 200, 400);
        assertEq(manager.bufferTargetBps(), 200);
    }

    // ---------- H4 regression: keeper least-privilege ----------

    function test_h4_keeperCannotRouteFundsToArbitraryAddress() public {
        _inflow(100e6); // buffer 30, pt 70
        // the keeper is a hot automation key: it must NOT be able to send the
        // safe leg to an attacker address via provide()
        vm.prank(keeper);
        vm.expectRevert(SafeLegManager.NotAuthorized.selector);
        manager.provide(100e18, keeper);
    }

    function test_h4_keeperRetainsRecipientlessMaintenance() public {
        // keeper may still run maintenance (funds only move buffer<->PT)
        usdc.mint(address(manager), 100e6);
        vm.prank(keeper);
        manager.onInflow();
        assertEq(manager.bufferWad(), 30e18);

        usdc.mint(address(manager), 30e6); // buffer 60 > max 50
        vm.prank(keeper);
        manager.rebalanceBuffer();
        assertEq(manager.bufferWad(), 30e18);
    }

    function test_h4_executorStillRoutes() public {
        _inflow(100e6);
        vm.prank(executor);
        uint256 out = manager.provide(50e18, executor);
        assertEq(out, 50e6);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_valueConservation_noHaircut(uint96 inflowAssets, uint96 provideWad) public {
        uint256 assets = bound(uint256(inflowAssets), 1e6, 500e6);
        _inflow(assets);
        uint256 before = manager.value();
        uint256 amount = bound(uint256(provideWad), 1e12, before);
        vm.prank(executor);
        uint256 out = manager.provide(amount, executor);
        // delivered + remaining == starting value, up to USDC-precision dust
        assertApproxEqAbs(out * 1e12 + manager.value(), before, 2e12);
    }
}
