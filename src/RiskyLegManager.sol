// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ILeg} from "./interfaces/IVaultPeriphery.sol";
import {IPriceSource} from "./interfaces/IExecutionPeriphery.sol";

/// @title RiskyLegManager
/// @notice Holds the vault's risky exposure as WETH plus an optional capped
///         wstETH fraction, and hands tokens to the execution module on
///         de-risk flows. Holds tokens only; all swaps live in the executor.
/// @dev Stress sell order is WETH first, wstETH second: the discount-prone
///      asset is the reserve, not the front line (design record section 4).
///      Values are USD WAD via IPriceSource; the vault treats USD and its
///      USDC accounting unit as equivalent.
contract RiskyLegManager is ILeg, Ownable {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    address public immutable weth;
    address public immutable wsteth;
    IPriceSource public priceSource;
    address public executor;
    address public keeper;

    /// @notice Max wstETH share of the risky leg (spec: <= 50%).
    uint16 public wstethTargetBps = 0;
    uint16 public constant WSTETH_CAP_BPS = 5000;

    event Provided(address indexed to, uint256 amountWad, uint256 wethOut, uint256 wstethOut);
    event WstethTargetSet(uint16 bps);

    error NotAuthorized();
    error AboveCap();
    error InsufficientValue();

    modifier onlyFlow() {
        if (msg.sender != executor && msg.sender != keeper && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    constructor(address weth_, address wsteth_, address owner_) {
        weth = weth_;
        wsteth = wsteth_;
        _initializeOwner(owner_);
    }

    function setPeriphery(IPriceSource priceSource_, address executor_, address keeper_) external onlyOwner {
        priceSource = priceSource_;
        executor = executor_;
        keeper = keeper_;
    }

    function setWstethTarget(uint16 bps) external onlyOwner {
        if (bps > WSTETH_CAP_BPS) revert AboveCap();
        wstethTargetBps = bps;
        emit WstethTargetSet(bps);
    }

    // ---------- ILeg ----------

    function value() public view returns (uint256) {
        return _wethBal().mulWad(priceSource.ethUsdWad()) + _wstethBal().mulWad(priceSource.wstethUsdWad());
    }

    /// @notice wstETH share of the current risky leg, bps. Keeper input for
    ///         composition rebalancing via the executor.
    function wstethShareBps() external view returns (uint256) {
        uint256 total = value();
        if (total == 0) return 0;
        return _wstethBal().mulWad(priceSource.wstethUsdWad()) * 10_000 / total;
    }

    // ---------- flows ----------

    /// @notice Hand tokens worth `amountWad` USD to `to` (the executor, which
    ///         swaps them to the deposit asset). WETH leaves first; wstETH is
    ///         the reserve for when WETH is exhausted.
    function provide(uint256 amountWad, address to) external onlyFlow returns (uint256 wethOut, uint256 wstethOut) {
        uint256 ethUsd = priceSource.ethUsdWad();
        uint256 wstUsd = priceSource.wstethUsdWad();
        uint256 total = _wethBal().mulWad(ethUsd) + _wstethBal().mulWad(wstUsd);
        if (amountWad > total) revert InsufficientValue();

        uint256 wethBal = _wethBal();
        uint256 wethNeeded = amountWad.divWad(ethUsd);
        wethOut = wethNeeded > wethBal ? wethBal : wethNeeded;
        if (wethOut > 0) weth.safeTransfer(to, wethOut);

        uint256 coveredWad = wethOut.mulWad(ethUsd);
        if (coveredWad + 1e6 < amountWad) {
            wstethOut = (amountWad - coveredWad).divWad(wstUsd);
            uint256 wstBal = _wstethBal();
            if (wstethOut > wstBal) wstethOut = wstBal;
            if (wstethOut > 0) wsteth.safeTransfer(to, wstethOut);
        }
        emit Provided(to, amountWad, wethOut, wstethOut);
    }

    /// @notice Hand a specific token to the executor for composition trims.
    function provideToken(address token, uint256 amount, address to) external onlyFlow {
        if (token != weth && token != wsteth) revert NotAuthorized();
        token.safeTransfer(to, amount);
    }

    // ---------- internal ----------

    function _wethBal() internal view returns (uint256) {
        return SafeTransferLib.balanceOf(weth, address(this));
    }

    function _wstethBal() internal view returns (uint256) {
        return SafeTransferLib.balanceOf(wsteth, address(this));
    }
}
