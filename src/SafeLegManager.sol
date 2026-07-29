// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ILeg} from "./interfaces/IVaultPeriphery.sol";
import {IPTAdapter} from "./interfaces/IPTAdapter.sol";

/// @notice Minimal view the manager needs from the vault for buffer sizing.
interface INavSource {
    /// @notice Total value in the vault system, used to size the buffer bands.
    /// @return The vault's total NAV, in WAD.
    function totalNav() external view returns (uint256);
}

/// @title SafeLegManager
/// @notice Two-tier safe leg: a liquid deposit-asset buffer that absorbs
///         routine flows, and a PT tranche behind IPTAdapter holding the
///         fixed-yield floor funding. Buys drain the buffer before selling
///         PT; inflows refill the buffer to target before buying PT.
/// @dev Buffer bands are bps of vault totalNav (spec: target 3%, band 1-5%).
///      value() must never call back into the vault (totalNav calls value()),
///      so band math lives only in flow functions. All WAD unless suffixed.
contract SafeLegManager is ILeg, Ownable {
    using SafeTransferLib for address;

    // ============================================================================
    // Configuration and state
    // ============================================================================

    /// @notice The vault this leg serves; the NAV source used for buffer sizing.
    address public immutable vault;

    /// @notice The deposit asset (e.g. USDC) held in the liquid buffer.
    address public immutable asset;

    /// @dev Scale factor to convert the asset's native decimals to WAD (18 decimals).
    uint256 internal immutable assetScale;

    /// @notice The PT adapter holding the fixed-yield floor funding behind the buffer.
    IPTAdapter public pt;

    /// @notice The execution module authorized to pull buffer funds for risky-leg buys.
    address public executor;

    /// @notice The keeper authorized to run recipient-less buffer maintenance.
    address public keeper;

    /// @notice Target buffer size as a fraction of vault totalNav, in basis points.
    uint16 public bufferTargetBps = 300;

    /// @notice Lower band for the buffer as a fraction of vault totalNav, in basis points.
    uint16 public bufferMinBps = 100;

    /// @notice Upper band for the buffer as a fraction of vault totalNav, in basis points.
    uint16 public bufferMaxBps = 500;

    // ============================================================================
    // Events, errors, and modifiers
    // ============================================================================

    /// @notice Emitted when transferred-in assets are allocated across buffer and PT.
    /// @param assetsWad The buffer balance observed at allocation time, in WAD.
    /// @param toBufferWad The amount retained in the buffer, in WAD.
    /// @param toPtWad The amount routed into PT, in WAD.
    event Inflow(uint256 assetsWad, uint256 toBufferWad, uint256 toPtWad);

    /// @notice Emitted when value is delivered out of the safe leg to a recipient.
    /// @param to The recipient of the delivered assets.
    /// @param amountWad The requested delivery amount, in WAD.
    /// @param fromBufferWad The portion sourced from the buffer, in WAD.
    /// @param fromPtWad The portion sourced from PT, in WAD.
    event Provided(address indexed to, uint256 amountWad, uint256 fromBufferWad, uint256 fromPtWad);

    /// @notice Emitted when keeper maintenance moves value between buffer and PT.
    /// @param deltaWad Signed change in the buffer applied by the rebalance, in WAD.
    event BufferRebalanced(int256 deltaWad);

    /// @notice Emitted when the buffer bands are updated.
    /// @param minBps The new lower band, in basis points.
    /// @param targetBps The new target, in basis points.
    /// @param maxBps The new upper band, in basis points.
    event BandsSet(uint16 minBps, uint16 targetBps, uint16 maxBps);

    /// @notice Caller is not an authorized router or ops address for this action.
    error NotAuthorized();

    /// @notice Buffer bands were set out of order or above the hard cap.
    error BadBands();

    /// @notice The leg cannot cover the requested value.
    error InsufficientValue();

    /// @dev Value routing to a caller-chosen recipient. Excludes the keeper:
    ///      a hot automation key must never be able to send funds to an
    ///      arbitrary address. Every legitimate caller is the executor or vault.
    modifier onlyRouter() {
        if (msg.sender != vault && msg.sender != executor && msg.sender != owner()) {
            revert NotAuthorized();
        }
        _;
    }

    /// @dev Recipient-less maintenance (funds only move between buffer and PT).
    ///      Safe for the keeper to call; a compromise here grands no custody.
    modifier onlyOps() {
        if (msg.sender != vault && msg.sender != executor && msg.sender != keeper && msg.sender != owner()) {
            revert NotAuthorized();
        }
        _;
    }

    // ============================================================================
    // Wiring (owner setup)
    // ============================================================================

    /// @notice Deploy the safe leg bound to a vault and its deposit asset.
    /// @param vault_ The vault this leg serves and reads totalNav from.
    /// @param asset_ The deposit asset held in the buffer.
    /// @param assetDecimals The asset's native decimals, used to derive the WAD scale.
    /// @param owner_ The initial owner.
    constructor(address vault_, address asset_, uint8 assetDecimals, address owner_) {
        vault = vault_;
        asset = asset_;
        assetScale = 10 ** (18 - assetDecimals);
        _initializeOwner(owner_);
    }

    /// @notice Wire the PT adapter and the executor/keeper roles.
    /// @param pt_ The PT adapter holding the floor funding.
    /// @param executor_ The execution module allowed to pull for risky-leg buys.
    /// @param keeper_ The keeper allowed to run buffer maintenance.
    function setPeriphery(IPTAdapter pt_, address executor_, address keeper_) external onlyOwner {
        pt = pt_;
        executor = executor_;
        keeper = keeper_;
    }

    /// @notice Update the buffer bands, enforcing min <= target <= max <= 1000 bps.
    /// @param minBps The new lower band, in basis points.
    /// @param targetBps The new target, in basis points.
    /// @param maxBps The new upper band, in basis points.
    function setBands(uint16 minBps, uint16 targetBps, uint16 maxBps) external onlyOwner {
        if (minBps > targetBps || targetBps > maxBps || maxBps > 1000) revert BadBands();
        bufferTargetBps = targetBps;
        bufferMinBps = minBps;
        bufferMaxBps = maxBps;
        emit BandsSet(minBps, targetBps, maxBps);
    }

    // ============================================================================
    // ILeg views
    // ============================================================================

    /// @notice Total safe-leg value: the liquid buffer plus the PT tranche.
    /// @return The leg value, in WAD.
    function value() public view returns (uint256) {
        return bufferWad() + pt.value();
    }

    /// @notice The liquid deposit-asset buffer currently held by this leg.
    /// @return The buffer balance, in WAD.
    function bufferWad() public view returns (uint256) {
        return SafeTransferLib.balanceOf(asset, address(this)) * assetScale;
    }

    /// @notice The implied fixed rate of the underlying PT, used by the strategy.
    /// @return The implied rate, in WAD.
    function impliedRateWad() external view returns (uint256) {
        return pt.impliedRateWad();
    }

    // ============================================================================
    // Flows
    // ============================================================================

    /// @notice Allocate assets already transferred to this contract: refill
    ///         the buffer to target, buy PT with the rest.
    function onInflow() external onlyOps {
        uint256 buf = bufferWad();
        uint256 target = _bandWad(bufferTargetBps);
        uint256 toPtWad;
        if (buf > target) {
            toPtWad = buf - target;
            uint256 assets = toPtWad / assetScale;
            if (assets > 0) _buyPtBestEffort(assets);
        }
        emit Inflow(buf, buf - toPtWad, toPtWad);
    }

    /// @dev Move `assets` into PT, but never revert the caller if the Pendle
    ///      market is dislocated (audit M2): on failure the assets are pulled
    ///      back to the buffer. onInflow runs inside the permissionless
    ///      emergency rebalance, so a PT-buy revert must not unwind the
    ///      de-risk. Returns whether the buy succeeded.
    /// @param assets The deposit-asset amount to move into PT, in native units.
    /// @return True if the PT deposit succeeded, false if it was reclaimed to the buffer.
    function _buyPtBestEffort(uint256 assets) internal returns (bool) {
        asset.safeTransfer(address(pt), assets);
        try pt.deposit(assets) {
            return true;
        } catch {
            pt.reclaim(assets, address(this));
            return false;
        }
    }

    /// @notice Deliver up to `amountWad` of deposit asset to `to`: buffer down
    ///         to its minimum band first, PT for the remainder. Best-effort and
    ///         never reverts on PT conditions (audit M1).
    /// @dev A request that fits the deliverable buffer takes an oracle-free
    ///      fast path (no pt.value() read), so a Pendle-oracle outage cannot
    ///      block a buffer-only payout. When PT is needed, the withdraw is
    ///      wrapped: if the Pendle market cannot fill within its slippage
    ///      bound, the buffer portion is still delivered and the shortfall
    ///      simply reduces `deliveredAssets`, so the emergency de-risk and
    ///      redemption funding are never bricked by PT market conditions.
    /// @param amountWad The value to deliver, in WAD.
    /// @param to The recipient of the delivered deposit asset.
    /// @return deliveredAssets The deposit asset actually delivered, in native units.
    function provide(uint256 amountWad, address to) external onlyRouter returns (uint256 deliveredAssets) {
        uint256 buf = bufferWad();
        // The buffer-only payout must stay oracle-independent (audit M1 residual):
        // _bandWad -> vault.totalNav() -> safeLeg.value() -> pt.value(), so a
        // Pendle-oracle outage would otherwise brick even a buffer-coverable
        // payout despite the documented "fast path". Fall back to a zero reserve
        // band when totalNav is unavailable; rebalanceBuffer restores it later.
        uint256 minBuf = _bandWadOrZero(bufferMinBps);
        uint256 fromBuffer = buf > minBuf ? buf - minBuf : 0;
        if (fromBuffer > amountWad) fromBuffer = amountWad;

        uint256 fromPt = amountWad - fromBuffer;
        if (fromPt > 0) {
            // PT is needed. If its oracle is down we cannot value it; treat it
            // as 0 so the deliverable buffer is still paid best-effort rather
            // than reverting the whole payout.
            uint256 ptValue = _ptValueOrZero();
            if (fromPt > ptValue) {
                // PT cannot cover the remainder: dig into the protected band
                uint256 extra = fromPt - ptValue;
                fromPt = ptValue;
                fromBuffer = fromBuffer + extra > buf ? buf : fromBuffer + extra;
            }
        }

        if (fromBuffer > 0) {
            uint256 assets = fromBuffer / assetScale;
            asset.safeTransfer(to, assets);
            deliveredAssets = assets;
        }
        if (fromPt > 0) {
            try pt.withdraw(fromPt, to) returns (uint256 got) {
                deliveredAssets += got;
            } catch {
                // PT market could not fill within its bound; deliver buffer only
            }
        }
        emit Provided(to, amountWad, fromBuffer, fromPt);
    }

    /// @notice Keeper maintenance: pull the buffer back inside its bands.
    ///         Above max: spill excess into PT. Below min: top up from PT.
    function rebalanceBuffer() external onlyOps {
        uint256 buf = bufferWad();
        uint256 target = _bandWad(bufferTargetBps);
        if (buf > _bandWad(bufferMaxBps)) {
            uint256 excess = buf - target;
            uint256 assets = excess / assetScale;
            if (assets > 0 && _buyPtBestEffort(assets)) {
                emit BufferRebalanced(-int256(assets * assetScale));
            }
        } else if (buf < _bandWad(bufferMinBps)) {
            uint256 need = target - buf;
            uint256 ptValue = pt.value();
            if (need > ptValue) need = ptValue;
            if (need > 0) {
                pt.withdraw(need, address(this));
                emit BufferRebalanced(int256(need));
            }
        }
    }

    // ============================================================================
    // Internal helpers
    // ============================================================================

    /// @notice Band size as a fraction of vault totalNav.
    /// @dev Reverts if totalNav reverts (e.g. a PT-oracle outage through
    ///      safeLeg.value()); use _bandWadOrZero on the outbound payout path.
    /// @param bps The band as a fraction of totalNav, in basis points.
    /// @return The band size, in WAD.
    function _bandWad(uint256 bps) internal view returns (uint256) {
        return INavSource(vault).totalNav() * bps / 10_000;
    }

    /// @dev Band size, but resilient to a reverting totalNav (e.g. a PT-oracle
    ///      outage propagating through safeLeg.value()). Used only on the
    ///      outbound payout path, where a zero reserve band frees the full
    ///      buffer rather than bricking a buffer-coverable payout (audit M1).
    function _bandWadOrZero(uint256 bps) internal view returns (uint256) {
        try INavSource(vault).totalNav() returns (uint256 nav) {
            return nav * bps / 10_000;
        } catch {
            return 0;
        }
    }

    /// @dev pt.value() but 0 if the PT oracle read reverts, so a buffer-plus-PT
    ///      payout still delivers its buffer portion during an oracle outage
    ///      instead of reverting (audit M1).
    function _ptValueOrZero() internal view returns (uint256) {
        try pt.value() returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }
}
