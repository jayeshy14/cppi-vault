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

    // ============================================================================
    // Configuration and state
    // ============================================================================

    /// @notice WETH: the base risky-leg exposure and the front-line sell asset.
    address public immutable weth;

    /// @notice wstETH: the optional, capped yield-bearing fraction of the leg.
    address public immutable wsteth;

    /// @notice Oracle price source used to mark both tokens in USD WAD.
    IPriceSource public priceSource;

    /// @notice The execution module; the only non-owner address allowed to pull tokens out.
    address public executor;

    /// @notice The keeper role, kept for periphery symmetry. It is never granted
    ///         custody here (onlyRouter excludes it), so a compromised keeper
    ///         cannot move risky-leg tokens.
    address public keeper;

    /// @notice Target wstETH share of the risky leg, in basis points (spec: <= 50%).
    uint16 public wstethTargetBps = 0;

    /// @notice Hard cap on the wstETH target share, in basis points (50%).
    uint16 public constant WSTETH_CAP_BPS = 5000;

    // ============================================================================
    // Events, errors, and modifiers
    // ============================================================================

    /// @notice Emitted when tokens are handed to a recipient on a de-risk or trim flow.
    /// @param to The recipient (the executor).
    /// @param amountWad The requested value delivered, in USD WAD.
    /// @param wethOut The WETH transferred out, in wei.
    /// @param wstethOut The wstETH transferred out, in wei.
    event Provided(address indexed to, uint256 amountWad, uint256 wethOut, uint256 wstethOut);

    /// @notice Emitted when the wstETH target share is updated.
    /// @param bps The new wstETH target, in basis points.
    event WstethTargetSet(uint16 bps);

    /// @notice Caller is not an authorized router (the executor or the owner).
    error NotAuthorized();

    /// @notice The requested wstETH target exceeds the hard cap.
    error AboveCap();

    /// @notice The leg cannot cover the requested value.
    error InsufficientValue();

    /// @dev Value routing to a caller-chosen recipient. Excludes the keeper by
    ///      design: a hot key must never move risky-leg tokens to an arbitrary
    ///      address. The executor is the only legitimate caller (composition
    ///      trims and de-risk sells both originate there).
    modifier onlyRouter() {
        if (msg.sender != executor && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    // ============================================================================
    // Wiring (owner setup)
    // ============================================================================

    /// @notice Deploy the risky leg over its two token addresses.
    /// @param weth_ The WETH token address.
    /// @param wsteth_ The wstETH token address.
    /// @param owner_ The initial owner.
    constructor(address weth_, address wsteth_, address owner_) {
        weth = weth_;
        wsteth = wsteth_;
        _initializeOwner(owner_);
    }

    /// @notice Wire the price source and the executor/keeper roles.
    /// @param priceSource_ The oracle price source used to mark the tokens.
    /// @param executor_ The execution module allowed to pull tokens.
    /// @param keeper_ The keeper address.
    function setPeriphery(IPriceSource priceSource_, address executor_, address keeper_) external onlyOwner {
        priceSource = priceSource_;
        executor = executor_;
        keeper = keeper_;
    }

    /// @notice Set the target wstETH share of the leg, bounded by the hard cap.
    /// @param bps The new wstETH target, in basis points (must be <= WSTETH_CAP_BPS).
    function setWstethTarget(uint16 bps) external onlyOwner {
        if (bps > WSTETH_CAP_BPS) revert AboveCap();
        wstethTargetBps = bps;
        emit WstethTargetSet(bps);
    }

    // ============================================================================
    // ILeg views
    // ============================================================================

    /// @notice Total risky-leg value: WETH plus wstETH, each marked in USD WAD.
    /// @return The leg value, in USD WAD.
    function value() public view returns (uint256) {
        return _wethBal().mulWad(priceSource.ethUsdWad()) + _wstethBal().mulWad(priceSource.wstethUsdWad());
    }

    /// @notice wstETH share of the current risky leg, bps. Keeper input for
    ///         composition rebalancing via the executor.
    /// @return The wstETH share of leg value, in basis points (0 when the leg is empty).
    function wstethShareBps() external view returns (uint256) {
        uint256 total = value();
        if (total == 0) return 0;
        return _wstethBal().mulWad(priceSource.wstethUsdWad()) * 10_000 / total;
    }

    // ============================================================================
    // Flows
    // ============================================================================

    /// @notice Hand tokens worth `amountWad` USD to `to` (the executor, which
    ///         swaps them to the deposit asset). WETH leaves first; wstETH is
    ///         the reserve for when WETH is exhausted.
    /// @param amountWad The value to deliver, in USD WAD.
    /// @param to The recipient (the executor).
    /// @return wethOut The WETH transferred out, in wei.
    /// @return wstethOut The wstETH transferred out, in wei.
    function provide(uint256 amountWad, address to) external onlyRouter returns (uint256 wethOut, uint256 wstethOut) {
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
    /// @param token The token to transfer (must be WETH or wstETH).
    /// @param amount The token amount to transfer, in the token's native units.
    /// @param to The recipient (the executor).
    function provideToken(address token, uint256 amount, address to) external onlyRouter {
        if (token != weth && token != wsteth) revert NotAuthorized();
        token.safeTransfer(to, amount);
    }

    // ============================================================================
    // Internal helpers
    // ============================================================================

    /// @notice This leg's current WETH balance.
    /// @return The WETH balance, in wei.
    function _wethBal() internal view returns (uint256) {
        return SafeTransferLib.balanceOf(weth, address(this));
    }

    /// @notice This leg's current wstETH balance.
    /// @return The wstETH balance, in wei.
    function _wstethBal() internal view returns (uint256) {
        return SafeTransferLib.balanceOf(wsteth, address(this));
    }
}
