// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IExecutionModule} from "./interfaces/IVaultPeriphery.sol";
import {IPriceSource, ISwapRouter02} from "./interfaces/IExecutionPeriphery.sol";
import {SafeLegManager} from "./SafeLegManager.sol";
import {RiskyLegManager} from "./RiskyLegManager.sol";

interface IVaultAccounting {
    function totalPendingDepositsWad() external view returns (uint256);
    function totalReservedPayoutsWad() external view returns (uint256);
}

/// @title ExecutionModule
/// @notice Routes every value flow between the legs through Uniswap V3 with
///         oracle-anchored slippage bounds. Atomic by construction: no async
///         dependency anywhere, so the permissionless emergency rebalance is
///         never blocked (spec invariant 5).
/// @dev Buy-side funding order: the vault's FREE idle first (settled deposit
///      cash awaiting allocation; pending-deposit and reserved-payout cash is
///      never touched), then the safe leg. Sell proceeds always land in the
///      safe leg via onInflow. Each swap tries the primary fee tier and falls
///      back to the secondary pool on revert.
contract ExecutionModule is IExecutionModule, Ownable {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    address public immutable vault;
    address public immutable usdc;
    address public immutable weth;
    address public immutable wsteth;
    uint256 internal constant USDC_SCALE = 1e12;

    SafeLegManager public safeLeg;
    RiskyLegManager public riskyLeg;
    IPriceSource public priceSource;
    ISwapRouter02 public router;
    address public keeper;

    uint24 public primaryFee = 500;
    uint24 public fallbackFee = 3000;
    uint24 public wstethPoolFee = 100;

    event RebalanceExecuted(int256 deltaWad, uint256 usdcMoved, uint256 wethMoved);
    event CompositionRebalanced(int256 wethToWstethWad);
    event AssetsFreed(uint256 amountWad);

    error NotVault();
    error NotKeeper();
    error ZeroDelta();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(address vault_, address usdc_, address weth_, address wsteth_, address owner_) {
        vault = vault_;
        usdc = usdc_;
        weth = weth_;
        wsteth = wsteth_;
        _initializeOwner(owner_);
    }

    function setPeriphery(
        SafeLegManager safeLeg_,
        RiskyLegManager riskyLeg_,
        IPriceSource priceSource_,
        ISwapRouter02 router_,
        address keeper_
    ) external onlyOwner {
        safeLeg = safeLeg_;
        riskyLeg = riskyLeg_;
        priceSource = priceSource_;
        router = router_;
        keeper = keeper_;
        usdc.safeApprove(address(router_), type(uint256).max);
        weth.safeApprove(address(router_), type(uint256).max);
        wsteth.safeApprove(address(router_), type(uint256).max);
    }

    // ---------- IExecutionModule ----------

    function executeRebalance(int256 deltaWad, uint256 maxSlippageBps) external onlyVault {
        if (deltaWad == 0) revert ZeroDelta();
        if (deltaWad > 0) {
            _buyRisky(uint256(deltaWad), maxSlippageBps);
        } else {
            _sellRisky(uint256(-deltaWad), maxSlippageBps);
        }
    }

    function freeAssets(uint256 amountWad) external onlyVault {
        safeLeg.provide(amountWad, vault);
        emit AssetsFreed(amountWad);
    }

    // ---------- composition maintenance (keeper) ----------

    /// @notice Move the risky leg's wstETH share toward its target, bounded
    ///         by `maxMoveWad` per call. WETH<->wstETH through the tight pool.
    function rebalanceComposition(uint256 maxMoveWad, uint256 maxSlippageBps) external {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        uint256 total = riskyLeg.value();
        if (total == 0) return;
        uint256 targetWad = total * riskyLeg.wstethTargetBps() / 10_000;
        uint256 currentWad = total * riskyLeg.wstethShareBps() / 10_000;
        uint256 ethUsd = priceSource.ethUsdWad();
        uint256 wstUsd = priceSource.wstethUsdWad();

        if (currentWad < targetWad) {
            uint256 moveWad = FixedPointMathLib.min(targetWad - currentWad, maxMoveWad);
            (uint256 wethGot,) = riskyLeg.provide(moveWad, address(this));
            if (wethGot == 0) return;
            uint256 minOut = moveWad.divWad(wstUsd) * (10_000 - maxSlippageBps) / 10_000;
            _swap(weth, wsteth, wstethPoolFee, wethGot, minOut, address(riskyLeg));
            emit CompositionRebalanced(int256(moveWad));
        } else if (currentWad > targetWad) {
            uint256 moveWad = FixedPointMathLib.min(currentWad - targetWad, maxMoveWad);
            uint256 wstethIn = moveWad.divWad(wstUsd);
            uint256 wstBal = SafeTransferLib.balanceOf(wsteth, address(riskyLeg));
            if (wstethIn > wstBal) wstethIn = wstBal;
            if (wstethIn == 0) return;
            riskyLeg.provideToken(wsteth, wstethIn, address(this));
            uint256 minOut = wstethIn.mulWad(wstUsd).divWad(ethUsd) * (10_000 - maxSlippageBps) / 10_000;
            _swap(wsteth, weth, wstethPoolFee, wstethIn, minOut, address(riskyLeg));
            emit CompositionRebalanced(-int256(moveWad));
        }
    }

    // ---------- internal ----------

    function _buyRisky(uint256 deltaWad, uint256 maxSlippageBps) internal {
        // funding: vault free idle first, then the safe leg
        uint256 freeIdleWad = _vaultFreeIdleWad();
        uint256 fromIdleWad = FixedPointMathLib.min(deltaWad, freeIdleWad);
        uint256 fromIdleUsdc = fromIdleWad / USDC_SCALE;
        if (fromIdleUsdc > 0) usdc.safeTransferFrom(vault, address(this), fromIdleUsdc);

        if (fromIdleWad < deltaWad) {
            safeLeg.provide(deltaWad - fromIdleWad, address(this));
        }
        uint256 usdcIn = SafeTransferLib.balanceOf(usdc, address(this));
        if (usdcIn == 0) return;

        uint256 minWethOut = (usdcIn * USDC_SCALE).divWad(priceSource.ethUsdWad()) * (10_000 - maxSlippageBps) / 10_000;
        uint256 wethOut = _swap(usdc, weth, primaryFee, usdcIn, minWethOut, address(riskyLeg));
        emit RebalanceExecuted(int256(deltaWad), usdcIn, wethOut);
    }

    function _sellRisky(uint256 deltaWad, uint256 maxSlippageBps) internal {
        (uint256 wethGot, uint256 wstethGot) = riskyLeg.provide(deltaWad, address(this));

        uint256 ethUsd = priceSource.ethUsdWad();
        if (wstethGot > 0) {
            // two hops: wstETH -> WETH in the tight pool, then joins the WETH sale
            uint256 minWeth =
                wstethGot.mulWad(priceSource.wstethUsdWad()).divWad(ethUsd) * (10_000 - maxSlippageBps) / 10_000;
            wethGot += _swap(wsteth, weth, wstethPoolFee, wstethGot, minWeth, address(this));
        }
        if (wethGot == 0) return;

        uint256 minUsdcOut = wethGot.mulWad(ethUsd) * (10_000 - maxSlippageBps) / 10_000 / USDC_SCALE;
        uint256 usdcOut = _swap(weth, usdc, primaryFee, wethGot, minUsdcOut, address(safeLeg));
        safeLeg.onInflow();
        emit RebalanceExecuted(-int256(deltaWad), usdcOut, wethGot);
    }

    /// @dev Try the primary fee tier; on any revert (thin pool, minOut miss),
    ///      retry once on the fallback tier with the same bound.
    function _swap(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 minOut, address recipient)
        internal
        returns (uint256 amountOut)
    {
        ISwapRouter02.ExactInputSingleParams memory p = ISwapRouter02.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: recipient,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });
        try router.exactInputSingle(p) returns (uint256 out) {
            return out;
        } catch {
            p.fee = fallbackFee;
            return router.exactInputSingle(p);
        }
    }

    function _vaultFreeIdleWad() internal view returns (uint256) {
        uint256 idleWad = SafeTransferLib.balanceOf(usdc, vault) * USDC_SCALE;
        uint256 owedWad =
            IVaultAccounting(vault).totalPendingDepositsWad() + IVaultAccounting(vault).totalReservedPayoutsWad();
        return idleWad > owedWad ? idleWad - owedWad : 0;
    }
}
