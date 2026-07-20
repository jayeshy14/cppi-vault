// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PendlePTAdapter} from "../src/PendlePTAdapter.sol";
import {IPendleMarket, IStandardizedYield, IPendlePYLpOracle} from "../src/interfaces/pendle/IPendle.sol";
import {MockUSDC} from "./mocks/Mocks.sol";
import {Mock18} from "./mocks/ExecutionMocks.sol";

// ---- minimal Pendle mocks (audit I2 regression) ----

contract MockSY is IStandardizedYield {
    function isValidTokenIn(address) external pure returns (bool) {
        return true;
    }

    function isValidTokenOut(address) external pure returns (bool) {
        return true;
    }
}

contract MockPendleMarket is IPendleMarket {
    address public sy;
    address public pt;
    address public yt;
    uint256 public expiryTs;
    uint16 public lastCardinality;
    uint256 public cardinalityCalls;

    constructor(address sy_, address pt_, address yt_, uint256 expiry_) {
        sy = sy_;
        pt = pt_;
        yt = yt_;
        expiryTs = expiry_;
    }

    function readTokens() external view returns (address, address, address) {
        return (sy, pt, yt);
    }

    function increaseObservationsCardinalityNext(uint16 cardinalityNext) external {
        lastCardinality = cardinalityNext;
        cardinalityCalls++;
    }

    function expiry() external view returns (uint256) {
        return expiryTs;
    }

    function isExpired() external view returns (bool) {
        return block.timestamp >= expiryTs;
    }
}

contract MockPtOracle is IPendlePYLpOracle {
    struct State {
        bool increaseRequired;
        uint16 cardinalityRequired;
        bool oldestSatisfied;
    }

    mapping(address => State) internal _state;

    function set(address market, bool increaseRequired, uint16 cardinalityRequired, bool oldestSatisfied) external {
        _state[market] = State(increaseRequired, cardinalityRequired, oldestSatisfied);
    }

    function getOracleState(address market, uint32) external view returns (bool, uint16, bool) {
        State memory s = _state[market];
        return (s.increaseRequired, s.cardinalityRequired, s.oldestSatisfied);
    }

    function getPtToAssetRate(address, uint32) external pure returns (uint256) {
        return 1e18;
    }
}

contract PendlePTAdapterPrepareTest is Test {
    PendlePTAdapter adapter;
    MockUSDC usdc;
    MockPtOracle oracle;
    MockPendleMarket readyMarket;
    MockPendleMarket coldMarket;

    address owner = makeAddr("owner");
    address manager = makeAddr("manager");
    address router = makeAddr("router"); // only cast/approved, never called here

    function setUp() public {
        usdc = new MockUSDC();
        MockSY sy = new MockSY();
        Mock18 pt = new Mock18("PT");
        oracle = new MockPtOracle();

        uint256 exp = block.timestamp + 180 days;
        readyMarket = new MockPendleMarket(address(sy), address(pt), makeAddr("yt"), exp);
        coldMarket = new MockPendleMarket(address(sy), address(pt), makeAddr("yt2"), exp);

        // the initial (bound) market's oracle is warm so the constructor binds
        oracle.set(address(readyMarket), false, 0, true);
        // the target market is cold: needs a cardinality bump and its TWAP
        // window is not yet satisfied
        oracle.set(address(coldMarket), true, 200, false);

        adapter = new PendlePTAdapter(
            router, address(oracle), address(readyMarket), address(usdc), address(usdc), 6, 900, owner
        );
        vm.prank(owner);
        adapter.setManager(manager);
    }

    // I2: prepareMarket issues the cardinality increase and does NOT revert on a
    // cold oracle, so the bump persists (unlike the _bindMarket path below).
    function test_i2_prepareMarketPersistsCardinalityBump() public {
        assertEq(coldMarket.cardinalityCalls(), 0);
        vm.prank(owner);
        adapter.prepareMarket(address(coldMarket));
        assertEq(coldMarket.cardinalityCalls(), 1, "bump issued");
        assertEq(coldMarket.lastCardinality(), 200, "bump used the required cardinality");
    }

    // Contrast: binding the cold market via rollToMarket reverts OracleNotReady,
    // which rolls back the same-tx cardinality bump (the reason prepareMarket
    // exists). No deposits, so there is nothing to exit first.
    function test_i2_bindRollsBackBumpWhenOracleCold() public {
        vm.prank(manager);
        vm.expectRevert(PendlePTAdapter.OracleNotReady.selector);
        adapter.rollToMarket(address(coldMarket));
        assertEq(coldMarket.cardinalityCalls(), 0, "bump rolled back with the revert");
    }

    function test_i2_prepareMarket_ownerOnly() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        adapter.prepareMarket(address(coldMarket));
    }
}
