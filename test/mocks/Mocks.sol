// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ILeg, IExecutionModule, IRateOracle} from "../../src/interfaces/IVaultPeriphery.sol";

contract MockUSDC is ERC20 {
    function name() public pure override returns (string memory) {
        return "Mock USDC";
    }

    function symbol() public pure override returns (string memory) {
        return "mUSDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockLeg is ILeg {
    uint256 public value;

    function set(uint256 v) external {
        value = v;
    }

    function add(uint256 v) external {
        value += v;
    }

    function sub(uint256 v) external {
        value -= v;
    }
}

contract MockRateOracle is IRateOracle {
    uint256 public rateWad = 0.04e18;

    function set(uint256 r) external {
        rateWad = r;
    }
}

/// @dev Value-conserving mock: buys pull from safe leg first then vault idle;
///      sells push proceeds into the safe leg; freeAssets moves safe-leg
///      value back to vault idle (this mock holds a USDC float for that).
contract MockExecutor is IExecutionModule {
    using SafeTransferLib for address;

    address public immutable vault;
    address public immutable usdc;
    MockLeg public immutable safe;
    MockLeg public immutable risky;
    uint256 public lastSlippageBps;

    constructor(address vault_, address usdc_, MockLeg safe_, MockLeg risky_) {
        vault = vault_;
        usdc = usdc_;
        safe = safe_;
        risky = risky_;
    }

    function executeRebalance(int256 deltaWad, uint256 maxSlippageBps) external {
        lastSlippageBps = maxSlippageBps;
        if (deltaWad > 0) {
            uint256 buy = uint256(deltaWad);
            uint256 fromSafe = buy < safe.value() ? buy : safe.value();
            safe.sub(fromSafe);
            // idle-sourced portion rounds down to USDC precision so the mock
            // conserves value exactly
            uint256 idleUnits = (buy - fromSafe) / 1e12;
            if (idleUnits > 0) usdc.safeTransferFrom(vault, address(this), idleUnits);
            risky.add(fromSafe + idleUnits * 1e12);
        } else if (deltaWad < 0) {
            uint256 sell = uint256(-deltaWad);
            risky.sub(sell);
            safe.add(sell);
        }
    }

    function freeAssets(uint256 amountWad) external {
        safe.sub(amountWad);
        usdc.safeTransfer(vault, amountWad / 1e12);
    }
}
