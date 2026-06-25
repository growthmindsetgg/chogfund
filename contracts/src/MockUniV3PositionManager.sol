// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "./external/uniswap/INonfungiblePositionManager.sol";
import {MockUniV3Pool} from "./MockUniV3Pool.sol";
import {TickMath} from "./external/uniswap/TickMath.sol";
import {LiquidityAmounts} from "./external/uniswap/LiquidityAmounts.sol";

/// @title MockUniV3PositionManager
/// @notice ====================  MOCK  ====================
///         Implements the REAL INonfungiblePositionManager surface used by LpManager
///         (mint / increase / decrease / collect / positions / burn / ownerOf).
///         Liquidity and token amounts are computed with the REAL audited
///         LiquidityAmounts library against the mock pool's settable price — so the
///         amount/value math is canary-faithful. Two things are MOCK-SIMPLIFIED and
///         deferred to the P7 mainnet canary:
///           1. Trading-fee accrual is injected by tests via `accrueFees()` instead
///              of emerging from real swaps + feeGrowthInside bookkeeping.
///           2. The manager custodies tokens directly (no separate core pool vault);
///              it must be seeded with buffer liquidity so a one-sided (out-of-range)
///              withdrawal is payable, mirroring how a real pool's aggregate reserves
///              back any single position.
contract MockUniV3PositionManager is INonfungiblePositionManager {
    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        address owner;
    }

    MockUniV3Pool public immutable pool;
    uint256 public nextId = 1;
    mapping(uint256 => Position) public pos;

    constructor(MockUniV3Pool _pool) {
        pool = _pool;
    }

    function _poolSqrt() internal view returns (uint160 s) {
        (s, , , , , , ) = pool.slot0();
    }

    function _bounds(int24 tickLower, int24 tickUpper) internal pure returns (uint160 a, uint160 b) {
        a = TickMath.getSqrtRatioAtTick(tickLower);
        b = TickMath.getSqrtRatioAtTick(tickUpper);
    }

    // ---------- mint ----------

    function mint(MintParams calldata p)
        external
        payable
        override
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (uint160 a, uint160 b) = _bounds(p.tickLower, p.tickUpper);
        uint160 s = _poolSqrt();
        liquidity = LiquidityAmounts.getLiquidityForAmounts(s, a, b, p.amount0Desired, p.amount1Desired);
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(s, a, b, liquidity);
        require(amount0 >= p.amount0Min && amount1 >= p.amount1Min, "mock-npm: slippage");

        if (amount0 > 0) require(IERC20(p.token0).transferFrom(msg.sender, address(this), amount0), "t0");
        if (amount1 > 0) require(IERC20(p.token1).transferFrom(msg.sender, address(this), amount1), "t1");

        tokenId = nextId++;
        pos[tokenId] = Position({
            token0: p.token0,
            token1: p.token1,
            fee: p.fee,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            liquidity: liquidity,
            tokensOwed0: 0,
            tokensOwed1: 0,
            owner: p.recipient
        });
    }

    // ---------- increase ----------

    function increaseLiquidity(IncreaseLiquidityParams calldata p)
        external
        payable
        override
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Position storage P = pos[p.tokenId];
        require(P.liquidity > 0 || P.owner != address(0), "mock-npm: no position");
        (uint160 a, uint160 b) = _bounds(P.tickLower, P.tickUpper);
        uint160 s = _poolSqrt();
        liquidity = LiquidityAmounts.getLiquidityForAmounts(s, a, b, p.amount0Desired, p.amount1Desired);
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(s, a, b, liquidity);
        require(amount0 >= p.amount0Min && amount1 >= p.amount1Min, "mock-npm: slippage");

        if (amount0 > 0) require(IERC20(P.token0).transferFrom(msg.sender, address(this), amount0), "t0");
        if (amount1 > 0) require(IERC20(P.token1).transferFrom(msg.sender, address(this), amount1), "t1");

        P.liquidity += liquidity;
    }

    // ---------- decrease (credits tokensOwed; collect pays out) ----------

    function decreaseLiquidity(DecreaseLiquidityParams calldata p)
        external
        payable
        override
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage P = pos[p.tokenId];
        require(p.liquidity <= P.liquidity, "mock-npm: too much");
        (uint160 a, uint160 b) = _bounds(P.tickLower, P.tickUpper);
        uint160 s = _poolSqrt();
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(s, a, b, p.liquidity);
        require(amount0 >= p.amount0Min && amount1 >= p.amount1Min, "mock-npm: slippage");

        P.liquidity -= p.liquidity;
        P.tokensOwed0 += uint128(amount0);
        P.tokensOwed1 += uint128(amount1);
    }

    // ---------- collect ----------

    function collect(CollectParams calldata p)
        external
        payable
        override
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage P = pos[p.tokenId];
        amount0 = P.tokensOwed0 < p.amount0Max ? P.tokensOwed0 : p.amount0Max;
        amount1 = P.tokensOwed1 < p.amount1Max ? P.tokensOwed1 : p.amount1Max;

        P.tokensOwed0 -= uint128(amount0);
        P.tokensOwed1 -= uint128(amount1);

        if (amount0 > 0) require(IERC20(P.token0).transfer(p.recipient, amount0), "c0");
        if (amount1 > 0) require(IERC20(P.token1).transfer(p.recipient, amount1), "c1");
    }

    function burn(uint256 tokenId) external payable override {
        Position storage P = pos[tokenId];
        require(P.liquidity == 0 && P.tokensOwed0 == 0 && P.tokensOwed1 == 0, "mock-npm: not clear");
        delete pos[tokenId];
    }

    function positions(uint256 tokenId)
        external
        view
        override
        returns (
            uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128
        )
    {
        Position memory P = pos[tokenId];
        return (0, P.owner, P.token0, P.token1, P.fee, P.tickLower, P.tickUpper, P.liquidity, 0, 0, P.tokensOwed0, P.tokensOwed1);
    }

    function ownerOf(uint256 tokenId) external view override returns (address) {
        return pos[tokenId].owner;
    }

    // ---------- MOCK control surface: simulate trading-fee accrual ----------

    /// @notice TEST/MOCK ONLY. Credits uncollected fees to a position as if swaps
    ///         had traded through its range. Real fee accrual (feeGrowthInside) is
    ///         validated at the mainnet canary (P7). Caller must have funded this
    ///         manager with the fee tokens so collect() is payable.
    function accrueFees(uint256 tokenId, uint128 fee0, uint128 fee1) external {
        Position storage P = pos[tokenId];
        require(P.owner != address(0), "mock-npm: no position");
        P.tokensOwed0 += fee0;
        P.tokensOwed1 += fee1;
    }
}
