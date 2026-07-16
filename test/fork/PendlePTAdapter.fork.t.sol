// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PendlePTAdapter} from "../../src/PendlePTAdapter.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @dev Mainnet-fork tests against the live superUSDC Pendle market. Run:
///        RUN_FORK_TESTS=true forge test --match-contract Fork
///      Skipped by default so CI stays green without an RPC secret; pass
///      MAINNET_RPC_URL to use a private endpoint instead of publicnode.
contract PendlePTAdapterForkTest is Test {
    using SafeTransferLib for address;

    // pinned mainnet addresses (verified live 2026-07-16)
    address constant ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant ORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    // TermMax vault USDC market: SY accepts and redeems USDC directly (two-way)
    address constant MARKET_TMVUSDC = 0x9Dbb0D00F965e22F51434C0Ea2c2e09DfBCfFB62; // expiry 2026-10-29
    address constant MARKET_CUSD = 0x9EaAedA23177B7168c55a3A0F937f67919733449; // USDC two-way, expiry 2026-07-23
    address constant MARKET_APYUSD = 0xC5f938A8ef5F3BF9E72F5aA094baF5E03f4727D3; // no USDC-in: incompatible
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    PendlePTAdapter adapter;
    address managerEoa = makeAddr("manager");
    bool internal runFork;

    function setUp() public {
        runFork = vm.envOr("RUN_FORK_TESTS", false);
        if (!runFork) return;
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        adapter = new PendlePTAdapter(ROUTER, ORACLE, MARKET_TMVUSDC, USDC, USDC, 6, 900, address(this));
        adapter.setManager(managerEoa);
        adapter.setMaxSlippage(100); // modest-liquidity market, oracle-anchored bounds
        deal(USDC, managerEoa, 1_000_000e6);
    }

    function _deposit(uint256 assets) internal {
        vm.startPrank(managerEoa);
        USDC.safeTransfer(address(adapter), assets);
        adapter.deposit(assets);
        vm.stopPrank();
    }

    function test_fork_depositBuysPtNearOracleFairValue() public {
        if (!runFork) return;
        _deposit(20_000e6);
        // PT valued at the oracle rate: within the 100bps slippage bound
        assertApproxEqRel(adapter.value(), 20_000e18, 0.01e18);
    }

    function test_fork_impliedRate_isSane() public {
        if (!runFork) return;
        uint256 r = adapter.impliedRateWad();
        // tmvUSDC implied yield: sanity window 1% - 20%
        assertGt(r, 0.01e18);
        assertLt(r, 0.2e18);
    }

    function test_fork_withdraw_deliversAssetsWithinBound() public {
        if (!runFork) return;
        _deposit(20_000e6);
        uint256 before = IERC20Like(USDC).balanceOf(managerEoa);
        vm.prank(managerEoa);
        uint256 out = adapter.withdraw(8_000e18, managerEoa);
        assertEq(IERC20Like(USDC).balanceOf(managerEoa) - before, out);
        // round trip through the AMM: fees + impact inside 1.5%
        assertApproxEqRel(out, 8_000e6, 0.015e18);
        assertApproxEqRel(adapter.value(), 12_000e18, 0.015e18);
    }

    function test_fork_withdraw_afterMaturity_redeemsAtPar() public {
        if (!runFork) return;
        _deposit(10_000e6);
        uint256 valueBefore = adapter.value();
        vm.warp(adapter.maturity() + 1);
        vm.prank(managerEoa);
        uint256 out = adapter.withdraw(type(uint128).max, managerEoa);
        // PT redeems at par post-expiry: proceeds >= pre-warp marked value
        assertGe(out * 1e12, valueBefore.mulDivDown(99, 100));
        assertEq(adapter.value(), 0);
    }

    function test_fork_roll_movesPositionToNewMarket() public {
        if (!runFork) return;
        _deposit(2_000e6);
        uint256 valueBefore = adapter.value();
        uint256 oldMaturity = adapter.maturity();

        vm.prank(managerEoa);
        adapter.rollToMarket(MARKET_CUSD);

        assertEq(adapter.market(), MARKET_CUSD);
        assertLt(adapter.maturity(), oldMaturity); // cUSD expires sooner; roll legality only needs a live market
        // exit + re-entry through two AMMs: value preserved within ~2x bound
        assertApproxEqRel(adapter.value(), valueBefore, 0.02e18);
    }

    function test_fork_roll_rejectsIncompatibleMarket() public {
        if (!runFork) return;
        // apyUSD's SY does not accept USDC: adapter must refuse to bind it
        vm.prank(managerEoa);
        vm.expectRevert(PendlePTAdapter.IncompatibleMarket.selector);
        adapter.rollToMarket(MARKET_APYUSD);
    }

    function test_fork_managerGating() public {
        if (!runFork) return;
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(PendlePTAdapter.NotAuthorized.selector);
        adapter.deposit(1e6);
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

library mulDivLib {
    function mulDivDown(uint256 x, uint256 y, uint256 z) internal pure returns (uint256) {
        return x * y / z;
    }
}

using mulDivLib for uint256;
