# cppi-vault

An onchain capital-protected vault built on CPPI (constant proportion portfolio insurance): a 40-year-old TradFi technique for defending a floor without buying options. The vault holds a risky leg (ETH) and a safe leg (a Pendle PT, which behaves as a zero-coupon bond), and rebalances between them so that NAV at term maturity stays above a protected level.

**Status: work in progress, unaudited, not deployed. Do not use with real funds.**

## The mechanism in four equations

For a 12-month term with protection level P = 90% on a $100 deposit:

1. **Floor**: `floor_t = protected × e^(-r × timeLeft)`. The present value of the $90 promise, where r is the live PT-implied yield. Roughly $86.5 at term start, accreting to exactly $90 at maturity. A safe leg of exactly this size, held in PT, matures into the protected amount with no dependence on ETH.
2. **Cushion**: `cushion = NAV - floor`. The buffer above the promise, about $13.5 at start.
3. **Target exposure**: `risky = min(m × cushion, NAV)` with the multiplier m = 2. That is $27 of ETH at start. When ETH falls, the cushion shrinks and the vault sells ETH into PT; when ETH rises, it buys more.
4. **The failure mode**: a single move of size `1/m` between rebalances wipes the cushion before any rebalancer can act. At m = 2 that is a 50% one-move gap. The floor is therefore **probabilistic, not guaranteed**, and the modeled breach probability is a published product parameter, not a footnote.

## Where the parameters come from

Every number is derived rather than chosen, in a companion research repo (jump calibration and historical backtest over 2019-2026 ETH data, publication pending):

- **m = 2.0**: fitting a jump model to seven years of ETH daily returns gives a 12-month floor-breach probability of 4.3% at m = 2, versus roughly 13% at m = 2.5 and 46% at m = 4. The closed-form model (Cont & Tankov 2009) was validated against a 104-term rolling backtest, which measured breach frequencies within two points of the model's predictions, and at m = 2 the floor held in every term including March 2020.
- **Daily rebalancing with a 2% drift band**: discrete-trading risk at daily cadence is four orders of magnitude below jump risk (Balder, Brandl & Mahayni 2009). Rebalancing faster buys almost nothing, because the multiplier is what survives gaps. A 5-minute-resolution replay of the October 10, 2025 crash confirmed no breach at any sane multiplier even at 24-hour rebalance latency.
- **Payoff shape at m = 2, P = 90%** (104 rolling 12-month terms): worst term -9.4% versus -69.7% holding ETH, median +4.1% versus +50.2%, top decile +348%. The floor is paid for out of the median, and that trade-off is the product, stated plainly.

## Floor policies (share classes)

One engine, one immutable multiplier, three floor policies selected per share class:

| policy | behavior | backtest (worst / median / p90) |
|---|---|---|
| Fixed | floor accretes from P × term-start NAV | -9.4% / +4.1% / +348% |
| Step ratchet | fixed behavior until NAV ≥ T × floor, then the protected amount steps up by k (T=1.8, k=1.25 keeps the safe leg from ever fully emptying) | -9.4% / +4.3% / +211% |
| TIPP | floor additionally tracks 80% of high-water NAV, locking gains continuously | -9.4% / +13.7% / +114% |

All policies share the same worst case and breach probability, because those belong to the multiplier alone. Floor policy only redistributes the upside.

## Architecture

Built and tested:

- `src/libraries/CPPIMath.sol`: the four equations. Floor PV via expWad discounting, cushion, clamped target, drift and cushion health in bps, and the 1/m gap bound.
- `src/libraries/FloorPolicy.sol`: the floor-policy family as one function, `max(PV(protected, liveRate, timeLeft), policy term)`, monotone-clamped within a term so no rate move or policy path can lower an established floor.
- `src/libraries/RebalancePolicy.sol`: two-tier trigger classification. A keeper-gated scheduled path (cadence AND drift above a small band) and a **permissionless emergency path** (drift above a large band OR cushion below a health floor), so anyone can save the vault if the keeper is down during a crash. A global minimum interval anti-thrashes both paths.
- `src/CPPIController.sol`: the per-class state machine. Term lifecycle with onchain shortfall reporting at settlement, rebalance assessment, and a clamped live-rate input (hard cap plus bounded per-update change) so the floor cannot be manipulated through the PT-yield oracle.

In progress (spec'd, not yet implemented): the ERC-7540 vault with term-based share accounting, the safe-leg manager (PT adapter with maturity rolls plus a liquid buffer absorbing routine flows), the risky-leg manager (WETH plus a capped wstETH fraction), and the execution module (direct Uniswap V3 with oracle-anchored minOut and a fallback venue; the emergency path is atomic by design).

## Testing philosophy

The Solidity is pinned to the research harness: reference values such as the $86.47 floor and the 27.06% initial exposure are asserted against the Python backtest to a relative precision of 1e-12, so the contracts and the research can never silently disagree. Beyond unit tests, fuzz suites enforce the invariants that matter: the floor is monotone within a term across arbitrary NAV/rate/time paths, the target never exceeds NAV, the emergency trigger dominates whenever its conditions hold, and ratchet loops terminate. 37 tests currently pass.

```bash
forge test
```

## References

Black & Perold (1992), Theory of Constant Proportion Portfolio Insurance. Cont & Tankov (2009), Constant Proportion Portfolio Insurance in the Presence of Jumps in Asset Prices, Mathematical Finance 19(3). Balder, Brandl & Mahayni (2009), Effectiveness of CPPI Strategies under Discrete-Time Trading, JEDC 33. Estep & Kritzman (1988), TIPP: Insurance without Complexity.

Background writing on the design is on [@0xjayeshyadav](https://x.com/0xjayeshyadav): the self-defending loan piece, the capital-protection follow-up, and the build-in-public thread of posts this repo grew out of.
