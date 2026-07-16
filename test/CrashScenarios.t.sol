// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CPPIVault, IOracleHealth} from "../src/CPPIVault.sol";
import {CPPIController} from "../src/CPPIController.sol";
import {SafeLegManager} from "../src/SafeLegManager.sol";
import {RiskyLegManager} from "../src/RiskyLegManager.sol";
import {ExecutionModule} from "../src/ExecutionModule.sol";
import {OracleHub} from "../src/OracleHub.sol";
import {FloorPolicy} from "../src/libraries/FloorPolicy.sol";
import {RebalancePolicy} from "../src/libraries/RebalancePolicy.sol";
import {IPTAdapter} from "../src/interfaces/IPTAdapter.sol";
import {ILeg, IExecutionModule, IRateOracle} from "../src/interfaces/IVaultPeriphery.sol";
import {IPriceSource, ISwapRouter02} from "../src/interfaces/IExecutionPeriphery.sol";
import {MockUSDC} from "./mocks/Mocks.sol";
import {Mock18, MockPriceSource, MockSwapRouter} from "./mocks/ExecutionMocks.sol";
import {MockPTAdapter} from "./SafeLegManager.t.sol";
import {MockFeed, MockWstRate, MockPool, MockRateAdapter} from "./OracleHub.t.sol";

contract MockRateCS {
    uint256 public rateWad = 0.04e18;
}

/// @dev Crash replays against the fully integrated system. The Oct 10 2025
///      path is the real hourly ETH series from the research harness
///      (cppi-backtest/data/eth_5m_oct10_2025.csv, resampled), embedded as
///      ppm factors of the window open.
contract CrashScenariosTest is Test {
    CPPIVault vault;
    CPPIController controller;
    SafeLegManager safeLeg;
    RiskyLegManager riskyLeg;
    ExecutionModule exec;
    MockPriceSource prices;
    MockSwapRouter router;
    MockUSDC usdc;
    Mock18 weth;
    Mock18 wsteth;
    MockPTAdapter pt;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");

    uint256 constant DEPOSIT = 100_000e6;
    uint256 constant ETH0 = 2000e18;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        weth = new Mock18("WETH");
        wsteth = new Mock18("wstETH");
        prices = new MockPriceSource();
        prices.setEth(ETH0);
        router = new MockSwapRouter(prices, address(usdc), address(weth), address(wsteth));
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
        safeLeg = new SafeLegManager(address(vault), address(usdc), 6, owner);
        pt = new MockPTAdapter(address(usdc));
        riskyLeg = new RiskyLegManager(address(weth), address(wsteth), owner);
        exec = new ExecutionModule(address(vault), address(usdc), address(weth), address(wsteth), owner);

        vm.startPrank(owner);
        vault.setController(controller);
        vault.setPeriphery(
            ILeg(address(safeLeg)),
            ILeg(address(riskyLeg)),
            IExecutionModule(address(exec)),
            IRateOracle(address(new MockRateCS()))
        );
        vault.setRoles(keeper, keeper);
        safeLeg.setPeriphery(IPTAdapter(address(pt)), address(exec), keeper);
        riskyLeg.setPeriphery(IPriceSource(address(prices)), address(exec), keeper);
        exec.setPeriphery(safeLeg, riskyLeg, IPriceSource(address(prices)), ISwapRouter02(address(router)), keeper);
        vm.stopPrank();

        usdc.mint(address(router), 100_000_000e6);
        weth.mint(address(router), 100_000e18);
        wsteth.mint(address(router), 100_000e18);

        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.requestDeposit(DEPOSIT);
        vm.stopPrank();
        vm.prank(keeper);
        vault.settleEpoch();
        vm.prank(alice);
        vault.claimShares();
        vm.prank(keeper);
        vault.startTerm(365 days);
        vault.rebalance();
    }

    function _try(address caller) internal {
        vm.prank(caller);
        try vault.rebalance() {} catch {}
    }

    /// @notice The real Oct 10-11 2025 hourly ETH path (ppm of window open).
    function _oct10Path() internal pure returns (uint32[37] memory f) {
        f = [
            uint32(1000000),
            998329,
            995090,
            992337,
            991734,
            997179,
            987970,
            986918,
            992106,
            986628,
            991369,
            991399,
            992659,
            994384,
            977093,
            936633,
            937976,
            934547,
            925386,
            912539,
            883717,
            901680,
            880017,
            874226,
            876225,
            852227,
            876839,
            865674,
            872130,
            865038,
            863282,
            858039,
            870948,
            874146,
            875177,
            876570,
            872810
        ];
    }

    function test_oct10_2025_hourlyReplay_floorHolds() public {
        uint32[37] memory path = _oct10Path();
        uint256 minGap = type(uint256).max;
        for (uint256 i = 1; i < path.length; ++i) {
            prices.setEth(ETH0 * path[i] / 1e6);
            vm.warp(block.timestamp + 1 hours);
            _try(keeper);
            uint256 nav = vault.shareholderNav();
            uint256 floor = controller.lastFloor();
            assertGe(nav + 1e15, floor, "floor pierced during Oct 10 replay");
            if (nav > floor && nav - floor < minGap) minGap = nav - floor;
        }
        // survived the worst crypto liquidation day with margin to spare
        assertGt(minGap, 3_000e18);
    }

    function test_march2020_gap44_floorHolds_thenRecovers() public {
        // one-move -44% (March 12 2020 magnitude): below the 50% wipe at m=2
        vm.warp(block.timestamp + 2 hours);
        prices.setEth(ETH0 * 56 / 100);
        _try(makeAddr("rando")); // permissionless emergency
        uint256 nav = vault.shareholderNav();
        assertGe(nav + 1e15, controller.lastFloor(), "floor pierced on 44% gap");
        // deep de-risk: cushion collapsed, exposure follows
        assertLt(riskyLeg.value() * 1e18 / nav, 0.12e18);

        // recovery: +30% off the bottom, vault re-risks on the way up
        vm.warp(block.timestamp + 1 days);
        prices.setEth(ETH0 * 56 * 130 / 10_000);
        _try(keeper);
        assertGt(riskyLeg.value() * 1e18 / vault.shareholderNav(), 0.05e18);

        // inject the ~4% PT carry the mock omits (the real adapter accretes
        // to par by construction; the backtest models this as SAFE_APY)
        pt.simulateYield(2_950e18);
        vm.warp(block.timestamp + 366 days);
        vm.prank(keeper);
        assertEq(vault.settleTerm(), 0);
    }

    function test_gap55_breachIsBounded_notCatastrophic() public {
        // beyond the 1/m = 50% survivable gap: the floor breaks, but the
        // damage is m x (gap - 1/m) of the cushion, not the whole cushion
        vm.warp(block.timestamp + 2 hours);
        prices.setEth(ETH0 * 45 / 100);
        _try(makeAddr("rando"));

        uint256 nav = vault.shareholderNav();
        uint256 floor = controller.lastFloor();
        assertLt(nav, floor, "55% gap should breach");
        // fully de-risked at cash-lock
        assertLt(riskyLeg.value() * 1e18 / nav, 0.02e18);

        vm.warp(block.timestamp + 366 days);
        vm.prank(keeper);
        uint256 shortfall = vault.settleTerm();
        // breached, but bounded: well under the naive full-cushion loss
        // (mock PT carries no yield, so the accretion that would narrow the
        //  gap in production is absent here; bound accounts for that)
        assertGt(shortfall, 1_000e18);
        assertLt(shortfall, 6_000e18);
    }

    function test_wstethDepeg_buysBlocked_sellsUnaffected() public {
        vm.prank(owner);
        riskyLeg.setWstethTarget(3000);
        vm.prank(keeper);
        exec.rebalanceComposition(100_000e18, 50);
        assertGt(riskyLeg.wstethShareBps(), 2500);

        // depeg: wstETH marked down 6%, oracle blocks further buys
        prices.setWsteth(prices.wstethUsdWad() * 94 / 100);
        prices.setBuyAllowed(false);
        uint256 shareBefore = riskyLeg.wstethShareBps();
        vm.prank(keeper);
        exec.rebalanceComposition(100_000e18, 50); // must be a no-op on buys
        assertLe(riskyLeg.wstethShareBps(), shareBefore + 10);

        // de-risking still works and sells the discounted asset last
        vm.warp(block.timestamp + 2 hours);
        prices.setEth(ETH0 * 60 / 100);
        _try(makeAddr("rando"));
        assertGe(vault.shareholderNav() + 1e15, controller.lastFloor());
    }

    function test_oracleStaleness_gatesDeposits_defenseContinues() public {
        // wire a real OracleHub (mock feed) as the vault's health source
        MockFeed feed = new MockFeed();
        MockWstRate wr = new MockWstRate();
        MockPool pool = new MockPool();
        pool.setRatioWad(1.2e18);
        OracleHub hub = new OracleHub(address(feed), address(wr), address(pool), true, owner);
        hub.refresh();
        vm.prank(owner);
        vault.setHealthSource(IOracleHealth(address(hub)));

        // feed goes stale: new user flows pause
        vm.warp(block.timestamp + 3 hours);
        vm.prank(alice);
        vm.expectRevert(CPPIVault.OracleUnhealthy.selector);
        vault.requestDeposit(1e6);

        // but the floor defense is untouched: crash + permissionless rebalance
        prices.setEth(ETH0 * 55 / 100);
        _try(makeAddr("rando"));
        assertGe(vault.shareholderNav() + 1e15, controller.lastFloor());
    }
}
