// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice USD price source for the risky-leg assets, WAD. Implemented by the
///         OracleHub (Chainlink + wstETH basis checks); mocked until it lands.
interface IPriceSource {
    function ethUsdWad() external view returns (uint256);
    function wstethUsdWad() external view returns (uint256);
    /// @notice False when the wstETH rate-vs-pool basis breaches its limit
    ///         (or the feed is stale): composition buys must not proceed.
    function wstethBuyAllowed() external view returns (bool);
}

/// @notice Minimal Uniswap V3 SwapRouter02 surface (no deadline field).
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
