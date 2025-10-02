// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title SwapMath
 * @notice Library for Uniswap V2 swap math calculations
 * @dev Used for calculating amountIn and amountOut with the 0.3% fee built-in
 */
library SwapMath {
    /**
     * @notice Calculates the input amount given an output amount
     * @param amountOut The output amount
     * @param reservesIn The input token reserves
     * @param reservesOut The output token reserves
     * @return amountIn The input amount required
     */
    function getAmountIn(
        uint256 amountOut,
        uint256 reservesIn,
        uint256 reservesOut
    )
        internal
        pure
        returns (uint256 amountIn)
    {
        uint256 numerator = reservesIn * amountOut * 1000;
        uint256 denominator = (reservesOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    /**
     * @notice Calculates the output amount given an input amount
     * @param amountIn The input amount
     * @param reserveIn The input token reserves
     * @param reserveOut The output token reserves
     * @return amountOut The output amount received
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    )
        internal
        pure
        returns (uint256 amountOut)
    {
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }
}
