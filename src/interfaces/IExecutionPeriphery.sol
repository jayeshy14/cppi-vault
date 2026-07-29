// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPriceSource
/// @notice USD price source for the risky-leg assets, in WAD. Feeds the
///         execution module's slippage anchoring and the risky-leg mark.
/// @dev Implemented by the OracleHub (Chainlink plus wstETH basis checks) and
///      mocked until that lands.
interface IPriceSource {
    /// @notice Latest ETH/USD price.
    /// @return ethUsd The ETH price in USD, in WAD.
    function ethUsdWad() external view returns (uint256);

    /// @notice Latest wstETH/USD price.
    /// @return wstethUsd The wstETH price in USD, in WAD.
    function wstethUsdWad() external view returns (uint256);

    /// @notice Whether composition buys into wstETH are currently allowed. False
    ///         when the wstETH rate-vs-pool basis breaches its limit or the feed
    ///         is stale, in which case composition buys must not proceed.
    /// @return allowed Whether wstETH buys are permitted right now.
    function wstethBuyAllowed() external view returns (bool);
}

/// @title ISwapRouter02
/// @notice Minimal Uniswap V3 SwapRouter02 surface the execution module uses to
///         swap between deposit asset and risky-leg tokens.
/// @dev Mirrors SwapRouter02, which drops the deadline field present on the
///      original SwapRouter.
interface ISwapRouter02 {
    /// @notice Parameters for a single-hop exact-input swap.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param fee The pool fee tier for the tokenIn/tokenOut pair.
    /// @param recipient The address that receives tokenOut.
    /// @param amountIn The exact amount of tokenIn to swap.
    /// @param amountOutMinimum The minimum acceptable tokenOut, enforcing slippage.
    /// @param sqrtPriceLimitX96 The price limit for the swap (0 for no limit).
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swap an exact amount of one token for as much of another as the
    ///         pool allows, above the caller's minimum.
    /// @param params The single-hop exact-input swap parameters.
    /// @return amountOut The amount of tokenOut delivered to the recipient.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
