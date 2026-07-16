// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CPPIVault, IOracleHealth} from "../src/CPPIVault.sol";
import {CPPIController} from "../src/CPPIController.sol";
import {SafeLegManager} from "../src/SafeLegManager.sol";
import {RiskyLegManager} from "../src/RiskyLegManager.sol";
import {ExecutionModule} from "../src/ExecutionModule.sol";
import {FloorPolicy} from "../src/libraries/FloorPolicy.sol";
import {RebalancePolicy} from "../src/libraries/RebalancePolicy.sol";
import {IPTAdapter} from "../src/interfaces/IPTAdapter.sol";
import {ILeg, IExecutionModule, IRateOracle} from "../src/interfaces/IVaultPeriphery.sol";
import {IPriceSource, ISwapRouter02} from "../src/interfaces/IExecutionPeriphery.sol";
import {MockUSDC} from "./mocks/Mocks.sol";
import {Mock18, MockPriceSource, MockSwapRouter} from "./mocks/ExecutionMocks.sol";
import {MockPTAdapter} from "./SafeLegManager.t.sol";

contract MockRateInv {
    uint256 public rateWad = 0.04e18;
}

/// @dev Stateful-fuzz handler over the fully integrated system. Every action
///      keeps its own preconditions so runs stay meaningful, and post-action
///      assertions enforce the properties that only hold at action boundaries
///      (post-rebalance drift, cash-lock de-risking).
contract VaultHandler is Test {
    CPPIVault public vault;
    CPPIController public controller;
    SafeLegManager public safeLeg;
    RiskyLegManager public riskyLeg;
    MockPriceSource public prices;
    MockUSDC public usdc;
    MockPTAdapter public pt;

    address public keeper;
    address public alice = address(0xA11CE);
    uint256 public ghostLastFloor;
    uint256 public rebalances;

    uint256 constant MIN_ETH = 50e18;
    uint256 constant MAX_ETH = 100_000e18;

    constructor(
        CPPIVault vault_,
        CPPIController controller_,
        SafeLegManager safeLeg_,
        RiskyLegManager riskyLeg_,
        MockPriceSource prices_,
        MockUSDC usdc_,
        MockPTAdapter pt_,
        address keeper_
    ) {
        vault = vault_;
        controller = controller_;
        safeLeg = safeLeg_;
        riskyLeg = riskyLeg_;
        prices = prices_;
        usdc = usdc_;
        pt = pt_;
        keeper = keeper_;
    }

    function movePrice(int256 pctBps) external {
        // single-step move in [-60%, +60%]: beyond the 1/m survivable gap
        pctBps = bound(pctBps, -6000, 6000);
        uint256 eth = prices.ethUsdWad();
        uint256 next = eth * uint256(int256(10_000) + pctBps) / 10_000;
        if (next < MIN_ETH) next = MIN_ETH;
        if (next > MAX_ETH) next = MAX_ETH;
        prices.setEth(next);
        prices.setWsteth(next * 12 / 10);
    }

    function warp(uint256 hrs) external {
        hrs = bound(hrs, 1, 72);
        vm.warp(block.timestamp + hrs * 1 hours);
    }

    function deposit(uint256 assets) external {
        assets = bound(assets, 1e6, 100_000e6);
        if (vault.pendingDepositRequest(uint256(vault.currentEpoch()), alice) == 0) {
            (uint64 epoch, uint192 amt) = vault.depositRequests(alice);
            if (amt != 0 && epoch != vault.currentEpoch()) return; // unclaimed earlier epoch
        }
        usdc.mint(alice, assets);
        vm.startPrank(alice);
        usdc.approve(address(vault), assets);
        vault.requestDeposit(assets);
        vm.stopPrank();
    }

    function redeem(uint256 shares) external {
        uint256 bal = vault.balanceOf(alice);
        if (bal == 0) return;
        (uint64 epoch, uint192 amt) = vault.redeemRequests(alice);
        if (amt != 0 && epoch != vault.currentEpoch()) return;
        shares = bound(shares, 1, bal);
        vm.prank(alice);
        vault.requestRedeem(shares);
    }

    function settleAndClaim() external {
        uint256 pendingDeposits = vault.totalPendingDepositsWad();
        uint256 pendingRedeems = vault.totalPendingRedeemShares();
        if (pendingDeposits == 0 && pendingRedeems == 0) return;

        if (pendingRedeems > 0) {
            uint256 needWad = pendingRedeems * vault.navPerShare() / 1e18;
            vm.prank(keeper);
            try vault.freeAssets(needWad * 10_100 / 10_000) {} catch {}
        }
        vm.prank(keeper);
        try vault.settleEpoch() {}
        catch {
            return;
        }
        vm.startPrank(alice);
        try vault.claimShares() {} catch {}
        try vault.claimAssets() {} catch {}
        vm.stopPrank();
    }

    function rebalance() external {
        vm.prank(keeper);
        try vault.rebalance() {}
        catch {
            return;
        }
        rebalances++;
        // floor monotonicity checkpoint (floor state only moves in assess)
        uint256 f = controller.lastFloor();
        assertGe(f, ghostLastFloor, "floor decreased across rebalance");
        ghostLastFloor = f;
        // post-rebalance: exposure sits on target (within band + trade dust)
        uint256 nav = vault.shareholderNav();
        if (nav == 0) return;
        uint256 floor = controller.lastFloor();
        uint256 target = nav > floor ? 2 * (nav - floor) : 0;
        if (target > nav) target = nav;
        uint256 risky = riskyLeg.value();
        uint256 drift = risky > target ? risky - target : target - risky;
        assertLe(drift * 10_000 / nav, 250, "post-rebalance drift beyond band");
        // cash-lock: when the cushion is spent, the vault must be de-risked
        if (nav <= floor) {
            assertLe(risky * 10_000 / nav, 100, "cash-locked but still exposed");
        }
    }
}

contract InvariantsTest is Test {
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
    VaultHandler handler;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        weth = new Mock18("WETH");
        wsteth = new Mock18("wstETH");
        prices = new MockPriceSource();
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
            IRateOracle(address(new MockRateInv()))
        );
        vault.setRoles(keeper, keeper);
        safeLeg.setPeriphery(IPTAdapter(address(pt)), address(exec), keeper);
        riskyLeg.setPeriphery(IPriceSource(address(prices)), address(exec), keeper);
        exec.setPeriphery(safeLeg, riskyLeg, IPriceSource(address(prices)), ISwapRouter02(address(router)), keeper);
        vm.stopPrank();

        // router float
        usdc.mint(address(router), 100_000_000e6);
        weth.mint(address(router), 100_000e18);
        wsteth.mint(address(router), 100_000e18);

        // seed the vault and start a term so rebalances are live
        handler = new VaultHandler(vault, controller, safeLeg, riskyLeg, prices, usdc, pt, keeper);
        handler.deposit(100_000e6);
        handler.settleAndClaim();
        vm.prank(keeper);
        vault.startTerm(365 days);
        handler.rebalance();

        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = false

    /// @dev Spec invariant 2: the floor never decreases within a term.
    function invariant_floorMonotone() public view {
        uint256 floor = controller.lastFloor();
        assertGe(floor, handler.ghostLastFloor());
    }

    /// @dev Reserved payouts and pending deposit cash must physically sit in
    ///      the vault at all times (spec invariant 6 discipline).
    function invariant_owedCashCovered() public view {
        uint256 idleWad = usdc.balanceOf(address(vault)) * 1e12;
        assertGe(
            idleWad + 1e13, vault.totalReservedPayoutsWad() + vault.totalPendingDepositsWad(), "owed cash not covered"
        );
    }

    /// @dev Accounting identity: shareholder NAV + owed = total system value.
    function invariant_navAccountingIdentity() public view {
        uint256 total = vault.totalNav();
        uint256 parts = vault.shareholderNav() + vault.totalPendingDepositsWad() + vault.totalReservedPayoutsWad();
        assertApproxEqAbs(total, parts, 1e13);
    }

    /// @dev Shares are always backed: positive supply implies positive NAV.
    function invariant_sharesBacked() public view {
        if (vault.totalSupply() > 0) {
            assertGt(vault.navPerShare(), 0);
        }
    }
}
