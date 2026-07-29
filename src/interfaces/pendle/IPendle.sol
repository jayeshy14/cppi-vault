// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Pendle V2 interfaces for the PT adapter: RouterV4 swap
///         actions, market token discovery, and the canonical PY/LP oracle.
/// @dev The structs mirror Pendle's IPAllActionTypeV3 ABI exactly. The adapter
///      always passes empty limit-order data and no external aggregator (a fully
///      onchain path), so the aggregator-related fields are left at their zero
///      values.

// ============================================================================
// Router action types (mirror Pendle's ABI)
// ============================================================================

/// @notice External-aggregator routing data for a swap. Left empty (swapType
///         NONE) on the adapter's fully-onchain path.
/// @param swapType The aggregator to route through (NONE for onchain-only).
/// @param extRouter The external router address (unused when NONE).
/// @param extCalldata The external router calldata (unused when NONE).
/// @param needScale Whether the external call needs input scaling.
struct SwapData {
    SwapType swapType;
    address extRouter;
    bytes extCalldata;
    bool needScale;
}

/// @notice The external aggregator to route a swap through. The adapter always
///         uses NONE (fully onchain).
enum SwapType {
    NONE, // no external aggregator; swap entirely through the SY/market
    KYBERSWAP,
    ODOS,
    ETH_WETH, // wrap/unwrap only
    OKX,
    ONE_INCH,
    RESERVE_1,
    RESERVE_2
}

/// @notice Input specification for minting SY / buying PT from a token.
/// @param tokenIn The token supplied.
/// @param netTokenIn The amount of tokenIn supplied.
/// @param tokenMintSy The token the SY is minted from.
/// @param pendleSwap The Pendle swap helper (unused on the onchain path).
/// @param swapData The external-aggregator routing data (empty on the onchain path).
struct TokenInput {
    address tokenIn;
    uint256 netTokenIn;
    address tokenMintSy;
    address pendleSwap;
    SwapData swapData;
}

/// @notice Output specification for redeeming SY / selling PT to a token.
/// @param tokenOut The token to receive.
/// @param minTokenOut The minimum acceptable tokenOut (slippage bound).
/// @param tokenRedeemSy The token the SY is redeemed to.
/// @param pendleSwap The Pendle swap helper (unused on the onchain path).
/// @param swapData The external-aggregator routing data (empty on the onchain path).
struct TokenOutput {
    address tokenOut;
    uint256 minTokenOut;
    address tokenRedeemSy;
    address pendleSwap;
    SwapData swapData;
}

/// @notice Binary-search parameters bounding Pendle's PT approximation.
/// @param guessMin Lower bound of the search.
/// @param guessMax Upper bound of the search.
/// @param guessOffchain Optional offchain-computed guess (0 to ignore).
/// @param maxIteration Max search iterations.
/// @param eps Convergence tolerance, in WAD.
struct ApproxParams {
    uint256 guessMin;
    uint256 guessMax;
    uint256 guessOffchain;
    uint256 maxIteration;
    uint256 eps;
}

/// @notice Side of a Pendle limit order. Unused by the adapter (no limit orders).
enum OrderType {
    SY_FOR_PT,
    PT_FOR_SY,
    SY_FOR_YT,
    YT_FOR_SY
}

/// @notice A Pendle limit order. Unused by the adapter; documented to mirror the ABI.
/// @param salt Order salt for uniqueness.
/// @param expiry Order expiry timestamp.
/// @param nonce Maker nonce.
/// @param orderType The order side.
/// @param token The token involved.
/// @param YT The yield token of the market.
/// @param maker The order maker.
/// @param receiver The fill receiver.
/// @param makingAmount The amount offered by the maker.
/// @param lnImpliedRate The log implied rate of the order.
/// @param failSafeRate The fail-safe rate bound.
/// @param permit Optional permit calldata.
struct Order {
    uint256 salt;
    uint256 expiry;
    uint256 nonce;
    OrderType orderType;
    address token;
    address YT;
    address maker;
    address receiver;
    uint256 makingAmount;
    uint256 lnImpliedRate;
    uint256 failSafeRate;
    bytes permit;
}

/// @notice Parameters to fill a single limit order. Unused by the adapter.
/// @param order The order to fill.
/// @param signature The maker's signature.
/// @param makingAmount The amount to fill.
struct FillOrderParams {
    Order order;
    bytes signature;
    uint256 makingAmount;
}

/// @notice Limit-order routing block. The adapter always passes this empty.
/// @param limitRouter The limit-order router (address(0) when unused).
/// @param epsSkipMarket Tolerance for skipping the AMM in favor of orders.
/// @param normalFills Standard fills to attempt.
/// @param flashFills Flash fills to attempt.
/// @param optData Optional extra routing data.
struct LimitOrderData {
    address limitRouter;
    uint256 epsSkipMarket;
    FillOrderParams[] normalFills;
    FillOrderParams[] flashFills;
    bytes optData;
}

// ============================================================================
// Router, market, SY, and oracle interfaces
// ============================================================================

/// @notice The Pendle RouterV4 actions the adapter uses: buy PT, sell PT, and
///         redeem PY at maturity.
interface IPendleRouter {
    /// @notice Swap an exact amount of a token for PT (buy PT).
    /// @param receiver The address that receives the PT.
    /// @param market The Pendle market to trade in.
    /// @param minPtOut The minimum acceptable PT out (slippage bound).
    /// @param guessPtOut The approximation search bounds for the fill.
    /// @param input The token-input specification.
    /// @param limit The limit-order routing block (empty on the onchain path).
    /// @return netPtOut The PT received.
    /// @return netSyFee The SY fee paid.
    /// @return netSyInterm The intermediate SY amount routed.
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);

    /// @notice Swap an exact amount of PT for a token (sell PT before maturity).
    /// @param receiver The address that receives the token.
    /// @param market The Pendle market to trade in.
    /// @param exactPtIn The PT amount to sell.
    /// @param output The token-output specification (carries minTokenOut).
    /// @param limit The limit-order routing block (empty on the onchain path).
    /// @return netTokenOut The token received.
    /// @return netSyFee The SY fee paid.
    /// @return netSyInterm The intermediate SY amount routed.
    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);

    /// @notice Redeem PY (PT at/after maturity) to a token at par.
    /// @param receiver The address that receives the token.
    /// @param YT The yield token identifying the PY.
    /// @param netPyIn The PY amount to redeem.
    /// @param output The token-output specification (carries minTokenOut).
    /// @return netTokenOut The token received.
    /// @return netSyInterm The intermediate SY amount routed.
    function redeemPyToToken(address receiver, address YT, uint256 netPyIn, TokenOutput calldata output)
        external
        returns (uint256 netTokenOut, uint256 netSyInterm);
}

/// @notice The Pendle market surface the adapter reads for token discovery,
///         oracle warmup, and maturity.
interface IPendleMarket {
    /// @notice The market's SY, PT, and YT token addresses.
    /// @return sy The standardized-yield token.
    /// @return pt The principal token.
    /// @return yt The yield token.
    function readTokens() external view returns (address sy, address pt, address yt);

    /// @notice Grow the market's oracle observation cardinality (permissionless setup).
    /// @param cardinalityNext The target observation cardinality.
    function increaseObservationsCardinalityNext(uint16 cardinalityNext) external;

    /// @notice The market's maturity timestamp.
    /// @return The maturity timestamp.
    function expiry() external view returns (uint256);

    /// @notice Whether the market has passed maturity.
    /// @return True if expired.
    function isExpired() external view returns (bool);
}

/// @notice The market's SY surface used to validate the deposit/redeem token.
interface IStandardizedYield {
    /// @notice Whether a token can mint this SY.
    /// @param token The token to check.
    /// @return True if the token is a valid mint input.
    function isValidTokenIn(address token) external view returns (bool);

    /// @notice Whether this SY can redeem to a token.
    /// @param token The token to check.
    /// @return True if the token is a valid redeem output.
    function isValidTokenOut(address token) external view returns (bool);
}

/// @notice The canonical Pendle PY/LP oracle used for valuation and warmup.
interface IPendlePYLpOracle {
    /// @notice PT-to-asset TWAP rate for a market over a duration.
    /// @param market The Pendle market.
    /// @param duration The TWAP window, in seconds.
    /// @return The PT/asset rate, in WAD.
    function getPtToAssetRate(address market, uint32 duration) external view returns (uint256);

    /// @notice Oracle readiness for a market/duration: whether cardinality must
    ///         grow and whether the TWAP window is already satisfied.
    /// @param market The Pendle market.
    /// @param duration The TWAP window, in seconds.
    /// @return increaseCardinalityRequired Whether cardinality must be increased.
    /// @return cardinalityRequired The cardinality needed for the duration.
    /// @return oldestObservationSatisfied Whether the window is already covered.
    function getOracleState(address market, uint32 duration)
        external
        view
        returns (bool increaseCardinalityRequired, uint16 cardinalityRequired, bool oldestObservationSatisfied);
}
