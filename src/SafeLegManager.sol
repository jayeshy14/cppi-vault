// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ILeg} from "./interfaces/IVaultPeriphery.sol";
import {IPTAdapter} from "./interfaces/IPTAdapter.sol";

/// @notice Minimal view the manager needs from the vault for buffer sizing.
interface INavSource {
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

    address public immutable vault;
    address public immutable asset;
    uint256 internal immutable assetScale;

    IPTAdapter public pt;
    address public executor; // may pull for risky-leg buys
    address public keeper;

    uint16 public bufferTargetBps = 300;
    uint16 public bufferMinBps = 100;
    uint16 public bufferMaxBps = 500;

    event Inflow(uint256 assetsWad, uint256 toBufferWad, uint256 toPtWad);
    event Provided(address indexed to, uint256 amountWad, uint256 fromBufferWad, uint256 fromPtWad);
    event BufferRebalanced(int256 deltaWad);
    event BandsSet(uint16 minBps, uint16 targetBps, uint16 maxBps);

    error NotAuthorized();
    error BadBands();
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

    constructor(address vault_, address asset_, uint8 assetDecimals, address owner_) {
        vault = vault_;
        asset = asset_;
        assetScale = 10 ** (18 - assetDecimals);
        _initializeOwner(owner_);
    }

    function setPeriphery(IPTAdapter pt_, address executor_, address keeper_) external onlyOwner {
        pt = pt_;
        executor = executor_;
        keeper = keeper_;
    }

    function setBands(uint16 minBps, uint16 targetBps, uint16 maxBps) external onlyOwner {
        if (minBps > targetBps || targetBps > maxBps || maxBps > 1000) revert BadBands();
        bufferTargetBps = targetBps;
        bufferMinBps = minBps;
        bufferMaxBps = maxBps;
        emit BandsSet(minBps, targetBps, maxBps);
    }

    // ---------- ILeg ----------

    function value() public view returns (uint256) {
        return bufferWad() + pt.value();
    }

    function bufferWad() public view returns (uint256) {
        return SafeTransferLib.balanceOf(asset, address(this)) * assetScale;
    }

    function impliedRateWad() external view returns (uint256) {
        return pt.impliedRateWad();
    }

    // ---------- flows ----------

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
    function provide(uint256 amountWad, address to) external onlyRouter returns (uint256 deliveredAssets) {
        uint256 buf = bufferWad();
        uint256 minBuf = _bandWad(bufferMinBps);
        uint256 fromBuffer = buf > minBuf ? buf - minBuf : 0;
        if (fromBuffer > amountWad) fromBuffer = amountWad;

        uint256 fromPt = amountWad - fromBuffer;
        if (fromPt > 0) {
            // only now touch the PT/oracle path
            uint256 ptValue = pt.value();
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

    // ---------- internal ----------

    function _bandWad(uint256 bps) internal view returns (uint256) {
        return INavSource(vault).totalNav() * bps / 10_000;
    }
}
