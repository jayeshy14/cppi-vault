// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ExecutionModule} from "../../src/ExecutionModule.sol";
import {RiskyLegManager} from "../../src/RiskyLegManager.sol";
import {SafeLegManager} from "../../src/SafeLegManager.sol";
import {IPTAdapter} from "../../src/interfaces/IPTAdapter.sol";
import {IPriceSource, ISwapRouter02} from "../../src/interfaces/IExecutionPeriphery.sol";
import {MockPTAdapter} from "../SafeLegManager.t.sol";
import {VaultStub} from "../mocks/ExecutionMocks.sol";

interface IChainlinkFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IWstETH {
    function stEthPerToken() external view returns (uint256);
}

/// @dev Thin Chainlink-backed price source for fork tests only; the real
///      OracleHub (staleness, wstETH basis checks) is a separate deliverable.
contract ChainlinkPriceSource is IPriceSource {
    IChainlinkFeed constant ETH_USD = IChainlinkFeed(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    IWstETH constant WSTETH = IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    function ethUsdWad() public view returns (uint256) {
        (, int256 answer,,,) = ETH_USD.latestRoundData();
        return uint256(answer) * 1e10; // 8 -> 18 decimals
    }

    function wstethUsdWad() external view returns (uint256) {
        return ethUsdWad() * WSTETH.stEthPerToken() / 1e18;
    }
}

contract ExecutionModuleForkTest is Test {
    address constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    ExecutionModule exec;
    RiskyLegManager riskyLeg;
    SafeLegManager safeLeg;
    MockPTAdapter pt;
    VaultStub vaultStub;
    ChainlinkPriceSource prices;
    bool internal runFork;

    address keeper = makeAddr("keeper");

    function setUp() public {
        runFork = vm.envOr("RUN_FORK_TESTS", false);
        if (!runFork) return;
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        vaultStub = new VaultStub();
        vaultStub.set(0, 0, 100_000e18);
        prices = new ChainlinkPriceSource();
        pt = new MockPTAdapter(USDC);
        safeLeg = new SafeLegManager(address(vaultStub), USDC, 6, address(this));
        riskyLeg = new RiskyLegManager(WETH, WSTETH, address(this));
        exec = new ExecutionModule(address(vaultStub), USDC, WETH, WSTETH, address(this));

        safeLeg.setPeriphery(IPTAdapter(address(pt)), address(exec), keeper);
        riskyLeg.setPeriphery(IPriceSource(address(prices)), address(exec), keeper);
        exec.setPeriphery(safeLeg, riskyLeg, IPriceSource(address(prices)), ISwapRouter02(SWAP_ROUTER_02), keeper);
        vaultStub.approveToken(USDC, address(exec));

        deal(USDC, address(vaultStub), 100_000e6);
    }

    function _totalValue() internal view returns (uint256) {
        return riskyLeg.value() + safeLeg.value() + IERC20Like(USDC).balanceOf(address(vaultStub)) * 1e12;
    }

    function test_fork_buyThenSell_roundTrip_conservesValue() public {
        if (!runFork) return;
        uint256 before = _totalValue();

        // buy 50k of ETH exposure from vault idle, Chainlink-anchored minOut
        vm.prank(address(vaultStub));
        exec.executeRebalance(int256(50_000e18), 50);
        assertApproxEqRel(riskyLeg.value(), 50_000e18, 0.01e18);

        // sell half back: proceeds land in safe leg and allocate to buffer+PT
        vm.prank(address(vaultStub));
        exec.executeRebalance(-int256(25_000e18), 50);
        assertApproxEqRel(riskyLeg.value(), 25_000e18, 0.015e18);
        assertApproxEqRel(safeLeg.value(), 25_000e18, 0.015e18);
        assertGt(pt.valueWad(), 0); // inflow allocated beyond the buffer

        // full round trip through two real 5bps pools: < 40bps total cost
        assertGt(_totalValue(), before * 9960 / 10_000);
    }

    function test_fork_chainlinkAnchor_blocksBadFill() public {
        if (!runFork) return;
        // demand an impossible bound (0bps slippage on a real pool): both
        // tiers must miss minOut and the whole rebalance reverts atomically
        vm.prank(address(vaultStub));
        vm.expectRevert();
        exec.executeRebalance(int256(50_000e18), 0);
        assertEq(riskyLeg.value(), 0);
        assertEq(IERC20Like(USDC).balanceOf(address(vaultStub)), 100_000e6);
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}
