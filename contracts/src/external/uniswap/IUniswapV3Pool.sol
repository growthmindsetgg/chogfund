// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title Minimal subset of the real Uniswap V3 pool interface.
/// @notice We only depend on the read surface needed to VALUE a position
///         (current price/tick + pool liquidity). Mainnet canary swaps the mock
///         pool address for a real one with no code change here.
interface IUniswapV3Pool {
    /// @notice The 0th storage slot in the pool stores many values, packed.
    /// @return sqrtPriceX96 the current price of the pool as a sqrt(token1/token0) Q64.96 value
    /// @return tick the current tick of the pool
    /// @return observationIndex the index of the last oracle observation written
    /// @return observationCardinality the current maximum number of observations stored
    /// @return observationCardinalityNext the next maximum number of observations
    /// @return feeProtocol the protocol fee for both tokens of the pool
    /// @return unlocked whether the pool is currently locked to reentrancy
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /// @notice The currently in range liquidity available to the pool
    function liquidity() external view returns (uint128);

    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
}
