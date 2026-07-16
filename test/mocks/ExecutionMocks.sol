// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IPriceSource, ISwapRouter02} from "../../src/interfaces/IExecutionPeriphery.sol";

contract Mock18 is ERC20 {
    string internal _name;

    constructor(string memory n) {
        _name = n;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _name;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPriceSource is IPriceSource {
    uint256 public ethUsdWad = 2000e18;
    uint256 public wstethUsdWad = 2400e18;
    bool public wstethBuyAllowed = true;

    function setBuyAllowed(bool v) external {
        wstethBuyAllowed = v;
    }

    function setEth(uint256 p) external {
        ethUsdWad = p;
    }

    function setWsteth(uint256 p) external {
        wstethUsdWad = p;
    }
}

/// @dev Swap mock quoting from a MockPriceSource with a settable fee haircut
///      per fee tier; enforces minOut like the real router. Token decimals
///      are read to convert notional correctly (USDC 6 vs 18-dec tokens).
contract MockSwapRouter is ISwapRouter02 {
    using SafeTransferLib for address;

    MockPriceSource public immutable prices;
    address public immutable usdc;
    address public immutable weth;
    address public immutable wsteth;
    mapping(uint24 => uint256) public feeHaircutBps; // extra loss per tier
    mapping(uint24 => bool) public tierDisabled;

    error MinOut();
    error TierDisabled();

    constructor(MockPriceSource prices_, address usdc_, address weth_, address wsteth_) {
        prices = prices_;
        usdc = usdc_;
        weth = weth_;
        wsteth = wsteth_;
    }

    function setTier(uint24 fee, uint256 haircutBps, bool disabled) external {
        feeHaircutBps[fee] = haircutBps;
        tierDisabled[fee] = disabled;
    }

    function _usdWad(address token, uint256 amount) internal view returns (uint256) {
        if (token == usdc) return amount * 1e12;
        if (token == weth) return amount * prices.ethUsdWad() / 1e18;
        return amount * prices.wstethUsdWad() / 1e18;
    }

    function _fromUsdWad(address token, uint256 usdWad) internal view returns (uint256) {
        if (token == usdc) return usdWad / 1e12;
        if (token == weth) return usdWad * 1e18 / prices.ethUsdWad();
        return usdWad * 1e18 / prices.wstethUsdWad();
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        if (tierDisabled[p.fee]) revert TierDisabled();
        p.tokenIn.safeTransferFrom(msg.sender, address(this), p.amountIn);
        uint256 usdWad = _usdWad(p.tokenIn, p.amountIn);
        usdWad = usdWad * (10_000 - feeHaircutBps[p.fee]) / 10_000;
        amountOut = _fromUsdWad(p.tokenOut, usdWad);
        if (amountOut < p.amountOutMinimum) revert MinOut();
        // mock mints/uses pre-funded balance
        if (SafeTransferLib.balanceOf(p.tokenOut, address(this)) < amountOut) {
            revert MinOut();
        }
        p.tokenOut.safeTransfer(p.recipient, amountOut);
    }
}

/// @dev Vault stand-in: holds USDC, exposes the accounting the executor reads
///      and the NAV the safe leg's bands reference.
contract VaultStub {
    uint256 public totalPendingDepositsWad;
    uint256 public totalReservedPayoutsWad;
    uint256 public totalPendingRedeemShares;
    uint256 public navPerShare = 1e18;
    uint256 public totalNav;

    function set(uint256 pending, uint256 reserved, uint256 nav) external {
        totalPendingDepositsWad = pending;
        totalReservedPayoutsWad = reserved;
        totalNav = nav;
    }

    function setRedeems(uint256 shares, uint256 price) external {
        totalPendingRedeemShares = shares;
        navPerShare = price;
    }

    function approveToken(address token, address spender) external {
        SafeTransferLib.safeApprove(token, spender, type(uint256).max);
    }
}
