// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IUniswapV3Pool} from "./external/uniswap/IUniswapV3Pool.sol";
import {TickMath} from "./external/uniswap/TickMath.sol";

/// @title MockUniV3Pool
/// @notice ====================  MOCK  ====================
///         Implements the REAL IUniswapV3Pool read surface, but the price is a
///         SETTABLE state variable instead of emerging from swaps. Tests drive the
///         market by calling setSqrtPriceX96 / setTick. The VALUE path in LpManager
///         consumes only `slot0().sqrtPriceX96` from here and feeds it into the real
///         audited TickMath / LiquidityAmounts — so valuation stays canary-faithful;
///         only the price INPUT is mocked. Real pool swap math is validated at P7.
contract MockUniV3Pool is IUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    uint160 private _sqrtPriceX96;
    int24 private _tick;
    uint128 private _liquidity;

    event PriceSet(uint160 sqrtPriceX96, int24 tick);

    constructor(address _token0, address _token1, uint24 _fee, int24 _tickSpacing, uint160 sqrtPriceX96_) {
        require(_token0 < _token1, "pool: token order");
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
        _setPrice(sqrtPriceX96_);
    }

    // ---------- settable market (MOCK control surface) ----------

    function setSqrtPriceX96(uint160 sqrtPriceX96_) external {
        _setPrice(sqrtPriceX96_);
    }

    /// @notice Convenience: set the price from a tick (uses real TickMath).
    function setTick(int24 tick_) external {
        _setPrice(TickMath.getSqrtRatioAtTick(tick_));
    }

    function setLiquidity(uint128 liquidity_) external {
        _liquidity = liquidity_;
    }

    function _setPrice(uint160 sqrtPriceX96_) internal {
        require(sqrtPriceX96_ >= TickMath.MIN_SQRT_RATIO && sqrtPriceX96_ < TickMath.MAX_SQRT_RATIO, "pool: price range");
        _sqrtPriceX96 = sqrtPriceX96_;
        _tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96_);
        emit PriceSet(sqrtPriceX96_, _tick);
    }

    // ---------- IUniswapV3Pool read surface ----------

    function slot0()
        external
        view
        override
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (_sqrtPriceX96, _tick, 0, 1, 1, 0, true);
    }

    function liquidity() external view override returns (uint128) {
        return _liquidity;
    }
}
