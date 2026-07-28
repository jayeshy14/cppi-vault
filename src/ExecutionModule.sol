// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IExecutionModule} from "./interfaces/IVaultPeriphery.sol";
import {IPriceSource, ISwapRouter02} from "./interfaces/IExecutionPeriphery.sol";
import {SafeLegManager} from "./SafeLegManager.sol";
import {RiskyLegManager} from "./RiskyLegManager.sol";

/// @notice Minimal view of the vault's async accounting that the execution
///         module reads to compute how much idle cash is truly free to spend.
interface IVaultAccounting {
    /// @notice Total pending (unsettled) deposit cash held by the vault, in WAD.
    /// @return The sum of all deposit requests not yet settled, in WAD.
    function totalPendingDepositsWad() external view returns (uint256);

    /// @notice Total settled-but-unclaimed redemption payouts reserved by the vault, in WAD.
    /// @return The sum of all reserved payouts, in WAD.
    function totalReservedPayoutsWad() external view returns (uint256);

    /// @notice Total shares locked for redemption but not yet settled, in WAD.
    /// @return The sum of all pending redeem shares, in WAD.
    function totalPendingRedeemShares() external view returns (uint256);

    /// @notice Current NAV per share, used to value pending redeem shares.
    /// @return The NAV per share, in WAD.
    function navPerShare() external view returns (uint256);
}

/// @title ExecutionModule
/// @notice Routes every value flow between the legs through Uniswap V3 with
///         oracle-anchored slippage bounds. Atomic by construction: no async
///         dependency anywhere on the emergency path. The vault widens the
///         emergency bound while the oracle is degraded (audit H6) so a
///         lagging feed cannot brick the de-risk, and the guardian can widen
///         the healthy-oracle emergency bound during a thin- or attacker-
///         thinned-liquidity dislocation (audit L6). A swap can still revert
///         when no venue fills within the (widened) bound: either the market
///         is genuinely gapping past a fair exit (the >1/m gap case) or a
///         transient pool dislocation that the permissionless, re-callable
///         rebalance retries away as arbitrage re-aligns the pool. The de-risk
///         is therefore best-effort-within-bound, not unconditionally atomic.
/// @dev Buy-side funding order: the vault's FREE idle first (settled deposit
///      cash awaiting allocation; pending-deposit and reserved-payout cash is
///      never touched), then the safe leg. Sell proceeds always land in the
///      safe leg via onInflow. Each swap tries the primary fee tier and falls
///      back to the secondary pool on revert.
contract ExecutionModule is IExecutionModule, Ownable {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    // ============================================================================
    // Configuration and state
    // ============================================================================

    /// @notice The vault this module executes trades for; the only caller of the onlyVault entrypoints.
    address public immutable vault;

    /// @notice The deposit asset (USDC) that funds risky buys and receives sell proceeds.
    address public immutable usdc;

    /// @notice WETH, the base risky-leg exposure and the routing hop for every swap.
    address public immutable weth;

    /// @notice wstETH, the capped yield-bearing fraction of the risky leg.
    address public immutable wsteth;

    /// @dev Derived from the vault asset's decimals (audit I3), equal to
    ///      10^(18 - assetDecimals). The vault, safe leg and PT adapter all
    ///      parameterize assetDecimals, so this module must too rather than bake
    ///      in a 6-decimal (1e12) assumption that silently breaks every
    ///      conversion on a non-6-decimal redeployment.
    uint256 public immutable assetScale;

    /// @dev One whole asset unit, equal to 10^assetDecimals. Sweeps below this
    ///      are treated as dust and skipped since they are not worth a PT trade.
    uint256 public immutable dustFloor;

    /// @notice The safe leg manager: capital-protection side that funds and receives asset flows.
    SafeLegManager public safeLeg;

    /// @notice The risky leg manager: growth side that supplies and receives WETH/wstETH.
    RiskyLegManager public riskyLeg;

    /// @notice Oracle price source used to anchor every swap's slippage bound.
    IPriceSource public priceSource;

    /// @notice The Uniswap V3 router every swap is routed through.
    ISwapRouter02 public router;

    /// @notice The keeper authorized to run composition maintenance.
    address public keeper;

    /// @notice Primary Uniswap V3 fee tier tried first on every swap, in hundredths of a bip.
    uint24 public primaryFee = 500;

    /// @notice Fallback Uniswap V3 fee tier retried when the primary tier reverts, in hundredths of a bip.
    uint24 public fallbackFee = 3000;

    /// @notice Tight-pool fee tier used for the WETH<->wstETH hop, in hundredths of a bip.
    uint24 public wstethPoolFee = 100;

    /// @dev Ceiling on the caller-supplied composition-rebalance slippage
    ///      (audit L3): a keeper cannot drive minOut toward zero.
    uint256 internal constant MAX_COMPOSITION_SLIPPAGE_BPS = 500;

    // ============================================================================
    // Events and errors
    // ============================================================================

    /// @notice Emitted after a risky-leg rebalance swap completes.
    /// @param deltaWad Signed change in risky exposure applied, in WAD (positive buys, negative sells).
    /// @param usdcMoved USDC spent (buy) or received (sell) in the swap, in native asset units.
    /// @param wethMoved WETH received (buy) or sold (sell) in the swap, in wei.
    event RebalanceExecuted(int256 deltaWad, uint256 usdcMoved, uint256 wethMoved);

    /// @notice Emitted after a composition maintenance trade shifts the WETH/wstETH split.
    /// @param wethToWstethWad Signed WETH-equivalent moved, in WAD (positive buys wstETH, negative sells it).
    event CompositionRebalanced(int256 wethToWstethWad);

    /// @notice Emitted when assets are freed to the vault for redemption funding.
    /// @param amountWad The amount delivered to the vault, in WAD.
    event AssetsFreed(uint256 amountWad);

    /// @notice Caller of an onlyVault function is not the vault.
    error NotVault();

    /// @notice Caller of composition maintenance is neither the keeper nor the owner.
    error NotKeeper();

    /// @notice A rebalance was requested with a zero delta.
    error ZeroDelta();

    /// @notice Restricts a function to the vault.
    /// @dev Reverts NotVault for any other caller.
    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    // ============================================================================
    // Setup (owner, one-time wiring)
    // ============================================================================

    /// @notice Deploy the execution module for a vault and its token set.
    /// @dev Derives assetScale and dustFloor from the asset's decimals so all
    ///      conversions run in 18-decimal fixed point; the assetScale expression
    ///      reverts if assetDecimals_ exceeds 18, which it cannot represent.
    /// @param vault_ The vault this module executes for.
    /// @param usdc_ The deposit asset (USDC) address.
    /// @param weth_ The WETH address.
    /// @param wsteth_ The wstETH address.
    /// @param assetDecimals_ The deposit asset's token decimals (must be <= 18).
    /// @param owner_ The initial owner address.
    constructor(address vault_, address usdc_, address weth_, address wsteth_, uint8 assetDecimals_, address owner_) {
        vault = vault_;
        usdc = usdc_;
        weth = weth_;
        wsteth = wsteth_;
        assetScale = 10 ** (18 - assetDecimals_); // reverts if assetDecimals_ > 18
        dustFloor = 10 ** assetDecimals_;
        _initializeOwner(owner_);
    }

    /// @notice Wire the leg managers, price source, router, and keeper, and grant
    ///         the router spend approval for every traded token.
    /// @dev Approves the router to pull USDC, WETH, and wstETH up to the max so
    ///      swaps need no per-trade approvals.
    /// @param safeLeg_ The safe leg manager that funds buys and receives sell proceeds.
    /// @param riskyLeg_ The risky leg manager that supplies and receives WETH/wstETH.
    /// @param priceSource_ The oracle price source anchoring every swap's slippage bound.
    /// @param router_ The Uniswap V3 router every swap is routed through.
    /// @param keeper_ The keeper authorized to run composition maintenance.
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

    /// @notice Apply a signed change to risky exposure: buy when the delta is
    ///         positive, sell when negative, then sweep any leftover free idle
    ///         into the safe leg.
    /// @dev Vault-only. Reverts ZeroDelta on a zero delta. The buy path funds
    ///      from the vault's free idle first then the safe leg; sell proceeds
    ///      land in the safe leg. The trailing sweep runs only here, never on
    ///      the outbound freeAssets path.
    /// @param deltaWad The signed change in risky exposure to apply, in WAD.
    /// @param maxSlippageBps The slippage bound for the swap, in basis points.
    function executeRebalance(int256 deltaWad, uint256 maxSlippageBps) external onlyVault {
        if (deltaWad == 0) revert ZeroDelta();
        if (deltaWad > 0) {
            _buyRisky(uint256(deltaWad), maxSlippageBps);
        } else {
            _sellRisky(uint256(-deltaWad), maxSlippageBps);
        }
        _sweepIdle();
    }

    /// @notice Free up to `amountWad` of asset into vault custody for redemption
    ///         funding, drawing the safe leg first and selling the risky leg
    ///         only for the shortfall.
    /// @dev Redemption funding sources the safe leg first; if it cannot
    ///      cover the request (e.g. full exits while the vault still holds
    ///      ETH), the shortfall is sold from the risky leg at the emergency
    ///      bound, with a small margin so slippage cannot leave the transfer
    ///      short. Settlement prices at the vault reflect any cost paid.
    /// @param amountWad The asset amount to free into vault custody, in WAD.
    function freeAssets(uint256 amountWad) external onlyVault {
        uint256 safeVal = safeLeg.value();
        if (amountWad > safeVal) {
            uint256 shortfall = (amountWad - safeVal) * 10_250 / 10_000;
            uint256 riskyVal = riskyLeg.value();
            if (shortfall > riskyVal) shortfall = riskyVal;
            // Best-effort (audit L4): if the risky sale can't clear its bound,
            // still deliver the safe-leg portion below rather than reverting
            // the whole redemption funding. Self-call so try/catch applies.
            if (shortfall > 0) {
                try this.sellRiskySelf(shortfall) {} catch {}
            }
        }
        uint256 available = FixedPointMathLib.min(amountWad, safeLeg.value());
        safeLeg.provide(available, vault);
        emit AssetsFreed(available);
    }

    /// @notice Sell risky exposure through an external self-call so freeAssets
    ///         can wrap the sale in try/catch and stay best-effort (audit L4).
    /// @dev Self-call entrypoint so `freeAssets` can try/catch the risky sale.
    ///      Reverts NotVault for any caller other than this contract. Sells at
    ///      the 150bps emergency bound.
    /// @param deltaWad The risky exposure to sell, in WAD.
    function sellRiskySelf(uint256 deltaWad) external {
        if (msg.sender != address(this)) revert NotVault();
        _sellRisky(deltaWad, 150);
    }

    // ---------- composition maintenance (keeper) ----------

    /// @notice Move the risky leg's wstETH share toward its target, bounded
    ///         by `maxMoveWad` per call. WETH<->wstETH through the tight pool.
    /// @dev Keeper-only maintenance. The caller-supplied slippage is clamped
    ///      (audit L3) so it can never drive minOut to zero, and the whole
    ///      function is gated on wstethBuyAllowed() so neither branch trims at
    ///      a mispriced/stale mark (the buy branch already required this; the
    ///      sell branch did not). Composition maintenance simply pauses during
    ///      a depeg or feed outage; the keeper retries when healthy.
    /// @param maxMoveWad The maximum WETH-equivalent to shift this call, in WAD.
    /// @param maxSlippageBps The requested slippage bound, in basis points,
    ///        clamped to MAX_COMPOSITION_SLIPPAGE_BPS (audit L3).
    function rebalanceComposition(uint256 maxMoveWad, uint256 maxSlippageBps) external {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        if (maxSlippageBps > MAX_COMPOSITION_SLIPPAGE_BPS) maxSlippageBps = MAX_COMPOSITION_SLIPPAGE_BPS;
        if (!priceSource.wstethBuyAllowed()) return; // L3: no mispriced trims when stale/depegged

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

    /// @notice Buy `deltaWad` of risky exposure and deliver the resulting WETH
    ///         to the risky leg.
    /// @dev Funding order: the vault's FREE idle first, then the safe leg for
    ///      the remainder; idle owed to users is never spent (see
    ///      _vaultFreeIdleWad). minWethOut is oracle-anchored at the slippage
    ///      bound. No-ops when no USDC ends up available to spend.
    /// @param deltaWad The risky exposure to buy, in WAD.
    /// @param maxSlippageBps The slippage bound for the USDC->WETH swap, in basis points.
    function _buyRisky(uint256 deltaWad, uint256 maxSlippageBps) internal {
        // funding: vault free idle first, then the safe leg
        uint256 freeIdleWad = _vaultFreeIdleWad();
        uint256 fromIdleWad = FixedPointMathLib.min(deltaWad, freeIdleWad);
        uint256 fromIdleUsdc = fromIdleWad / assetScale;
        if (fromIdleUsdc > 0) usdc.safeTransferFrom(vault, address(this), fromIdleUsdc);

        if (fromIdleWad < deltaWad) {
            safeLeg.provide(deltaWad - fromIdleWad, address(this));
        }
        uint256 usdcIn = SafeTransferLib.balanceOf(usdc, address(this));
        if (usdcIn == 0) return;

        uint256 minWethOut = (usdcIn * assetScale).divWad(priceSource.ethUsdWad()) * (10_000 - maxSlippageBps) / 10_000;
        uint256 wethOut = _swap(usdc, weth, primaryFee, usdcIn, minWethOut, address(riskyLeg));
        emit RebalanceExecuted(int256(deltaWad), usdcIn, wethOut);
    }

    /// @notice Sell `deltaWad` of risky exposure and deliver the USDC proceeds
    ///         to the safe leg.
    /// @dev Pulls WETH (and any wstETH share) from the risky leg; any wstETH is
    ///      first hopped to WETH through the tight pool, then joins the WETH
    ///      sale. Proceeds land in the safe leg via onInflow. Each swap is
    ///      oracle-anchored at the slippage bound. No-ops when no WETH results.
    /// @param deltaWad The risky exposure to sell, in WAD.
    /// @param maxSlippageBps The slippage bound for each swap, in basis points.
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

        uint256 minUsdcOut = wethGot.mulWad(ethUsd) * (10_000 - maxSlippageBps) / 10_000 / assetScale;
        uint256 usdcOut = _swap(weth, usdc, primaryFee, wethGot, minUsdcOut, address(safeLeg));
        safeLeg.onInflow();
        emit RebalanceExecuted(-int256(deltaWad), usdcOut, wethGot);
    }

    /// @notice Execute an exact-input single-hop swap on Uniswap V3, retrying
    ///         the fallback fee tier if the primary tier reverts.
    /// @dev Try the primary fee tier; on any revert (thin pool, minOut miss),
    ///      retry once on the fallback tier with the same bound.
    /// @dev sqrtPriceLimitX96 = 0 is deliberate (audit L7). For an exact-input
    ///      single-hop swap the oracle-anchored `amountOutMinimum` already
    ///      bounds the output (hence the extractable sandwich value) to the
    ///      slippage bound: the swap either delivers >= minOut or reverts. A
    ///      price limit would only add exact-input partial-fill semantics
    ///      (leftover tokenIn to account for) without tightening that bound,
    ///      so it is intentionally omitted rather than risk a mis-set limit.
    /// @param tokenIn The input token sold into the pool.
    /// @param tokenOut The output token bought from the pool.
    /// @param fee The primary Uniswap V3 fee tier tried first, in hundredths of a bip.
    /// @param amountIn The exact input amount, in tokenIn units.
    /// @param minOut The minimum acceptable output, in tokenOut units.
    /// @param recipient The address that receives the output tokens.
    /// @return amountOut The output amount delivered, in tokenOut units.
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

    /// @notice Park leftover free idle cash into the safe leg after a delta
    ///         trade so uninvested cash earns the floor rate.
    /// @dev After the delta trade, park any remaining free idle in the safe
    ///      leg so uninvested cash earns the floor rate instead of sitting in
    ///      the vault. Never runs inside freeAssets (that flow is outbound).
    ///      Sub-dustFloor remainders are skipped as not worth a PT trade.
    function _sweepIdle() internal {
        uint256 freeWad = _vaultFreeIdleWad();
        uint256 assets = freeWad / assetScale;
        if (assets < dustFloor) return; // dust: not worth the PT trade
        usdc.safeTransferFrom(vault, address(safeLeg), assets);
        safeLeg.onInflow();
    }

    /// @notice The vault's idle cash truly free to spend: the USDC balance
    ///         minus all idle owed to users.
    /// @dev Idle owed to users is untouchable: pending deposit cash, reserved
    ///      payouts, AND requested-but-unsettled redemptions at current NAV
    ///      (else a rebalance between freeAssets and settleEpoch would claw
    ///      the funding back into the safe leg).
    /// @return The free idle balance in WAD, or 0 when owed cash meets or exceeds idle.
    function _vaultFreeIdleWad() internal view returns (uint256) {
        IVaultAccounting v = IVaultAccounting(vault);
        uint256 idleWad = SafeTransferLib.balanceOf(usdc, vault) * assetScale;
        uint256 owedWad = v.totalPendingDepositsWad() + v.totalReservedPayoutsWad()
            + v.totalPendingRedeemShares().mulWad(v.navPerShare());
        return idleWad > owedWad ? idleWad - owedWad : 0;
    }
}
