// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CPPIVault, IOracleHealth} from "../src/CPPIVault.sol";
import {CPPIController} from "../src/CPPIController.sol";
import {SafeLegManager} from "../src/SafeLegManager.sol";
import {RiskyLegManager} from "../src/RiskyLegManager.sol";
import {ExecutionModule} from "../src/ExecutionModule.sol";
import {PendlePTAdapter} from "../src/PendlePTAdapter.sol";
import {OracleHub} from "../src/OracleHub.sol";
import {FloorPolicy} from "../src/libraries/FloorPolicy.sol";
import {RebalancePolicy} from "../src/libraries/RebalancePolicy.sol";
import {IPTAdapter} from "../src/interfaces/IPTAdapter.sol";
import {ILeg, IExecutionModule, IRateOracle} from "../src/interfaces/IVaultPeriphery.sol";
import {IPriceSource, ISwapRouter02} from "../src/interfaces/IExecutionPeriphery.sol";

/// @notice Deploys one share class of the CPPI vault stack on mainnet.
/// @dev Class selection via CLASS env var: FIXED90 | FIXED85 | STEP90 | LOCKED80.
///      Pendle market via PENDLE_MARKET env var (must accept USDC in AND out;
///      see the fork tests for the current compatible set). Keeper/guardian
///      via env. Run:
///        CLASS=FIXED90 PENDLE_MARKET=0x... forge script script/Deploy.s.sol \
///          --rpc-url $RPC --broadcast --private-key $PK
contract Deploy is Script {
    // mainnet constants
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant WSTETH_WETH_POOL_100 = 0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa;
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_PY_ORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;

    uint256 constant MULTIPLIER = 2e18; // protocol-fixed: breach risk lives here

    function run() external {
        string memory class_ = vm.envString("CLASS");
        address pendleMarket = vm.envAddress("PENDLE_MARKET");
        address keeper = vm.envAddress("KEEPER");
        address guardian = vm.envAddress("GUARDIAN");
        address owner = vm.envAddress("OWNER");

        FloorPolicy.Config memory fc = _classConfig(class_);
        RebalancePolicy.Config memory rc = RebalancePolicy.Config({
            minInterval: 1 hours, cadence: 1 days, driftSmallBps: 200, driftLargeBps: 500, cushionFloorBps: 300
        });

        vm.startBroadcast();

        CPPIVault vault = new CPPIVault(USDC, 6, msg.sender);
        CPPIController controller = new CPPIController(address(vault), MULTIPLIER, fc, rc);
        SafeLegManager safeLeg = new SafeLegManager(address(vault), USDC, 6, msg.sender);
        RiskyLegManager riskyLeg = new RiskyLegManager(WETH, WSTETH, msg.sender);
        ExecutionModule exec = new ExecutionModule(address(vault), USDC, WETH, WSTETH, msg.sender);
        OracleHub oracle = new OracleHub(CHAINLINK_ETH_USD, WSTETH, WSTETH_WETH_POOL_100, true, msg.sender);
        PendlePTAdapter pt =
            new PendlePTAdapter(PENDLE_ROUTER, PENDLE_PY_ORACLE, pendleMarket, USDC, USDC, 6, 900, msg.sender);

        // wiring
        vault.setController(controller);
        vault.setPeriphery(
            ILeg(address(safeLeg)),
            ILeg(address(riskyLeg)),
            IExecutionModule(address(exec)),
            IRateOracle(address(oracle))
        );
        vault.setHealthSource(IOracleHealth(address(oracle)));
        vault.setRoles(keeper, guardian);
        safeLeg.setPeriphery(IPTAdapter(address(pt)), address(exec), keeper);
        riskyLeg.setPeriphery(IPriceSource(address(oracle)), address(exec), keeper);
        exec.setPeriphery(safeLeg, riskyLeg, IPriceSource(address(oracle)), ISwapRouter02(SWAP_ROUTER_02), keeper);
        oracle.setPtAdapter(IPTAdapter(address(pt)));
        pt.setManager(address(safeLeg));
        oracle.refresh();

        // ownership handoff last, after all wiring succeeded
        if (owner != msg.sender) {
            vault.transferOwnership(owner);
            safeLeg.transferOwnership(owner);
            riskyLeg.transferOwnership(owner);
            exec.transferOwnership(owner);
            oracle.transferOwnership(owner);
            pt.transferOwnership(owner);
        }

        vm.stopBroadcast();

        console.log("class     ", class_);
        console.log("vault     ", address(vault));
        console.log("controller", address(controller));
        console.log("safeLeg   ", address(safeLeg));
        console.log("riskyLeg  ", address(riskyLeg));
        console.log("executor  ", address(exec));
        console.log("oracleHub ", address(oracle));
        console.log("ptAdapter ", address(pt));
    }

    /// @dev Share classes per spec section 3; termStart/termEnd placeholders
    ///      are validated but replaced by the vault at startTerm.
    function _classConfig(string memory class_) internal view returns (FloorPolicy.Config memory fc) {
        fc.termStart = uint64(block.timestamp);
        fc.termEnd = uint64(block.timestamp + 365 days);
        bytes32 h = keccak256(bytes(class_));
        if (h == keccak256("FIXED90")) {
            fc.kind = FloorPolicy.Kind.Fixed;
            fc.protectionWad = 0.9e18;
        } else if (h == keccak256("FIXED85")) {
            fc.kind = FloorPolicy.Kind.Fixed;
            fc.protectionWad = 0.85e18;
        } else if (h == keccak256("STEP90")) {
            fc.kind = FloorPolicy.Kind.Step;
            fc.protectionWad = 0.9e18;
            fc.triggerWad = 1.8e18;
            fc.stepWad = 1.25e18;
        } else if (h == keccak256("LOCKED80")) {
            fc.kind = FloorPolicy.Kind.Tipp;
            fc.protectionWad = 0.9e18;
            fc.ratchetWad = 0.8e18;
        } else {
            revert("unknown CLASS");
        }
    }
}
