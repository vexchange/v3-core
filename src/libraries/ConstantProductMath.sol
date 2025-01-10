// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

library ConstantProductMath {
    uint256 public constant FEE_ACCURACY = 1_000_000; // 100%

    error CPM_InsufficientInputAmt();
    error CPM_InsufficientLiquidity();

    /// @dev the function assumes that the following args are within the respective bounds as enforced by ReservoirPair
    /// and therefore should not overflow. If overflow happens the transaction will revert
    /// aAmountIn   <= uint104
    /// aReserveIn  <= uint104
    /// aReserveOut <= uint104
    /// aSwapFee    <= 0.2e6
    function getAmountOut(uint256 aAmountIn, uint256 aReserveIn, uint256 aReserveOut, uint256 aSwapFee)
        internal
        pure
        returns (uint256 rAmountOut)
    {
        require(aAmountIn > 0, CPM_InsufficientInputAmt());
        require(aReserveIn > 0 && aReserveOut > 0, CPM_InsufficientLiquidity());

        uint256 lAmountInWithFee = aAmountIn * (FEE_ACCURACY - aSwapFee);
        uint256 lNumerator = lAmountInWithFee * aReserveOut;
        uint256 lDenominator = aReserveIn * FEE_ACCURACY + lAmountInWithFee;
        rAmountOut = lNumerator / lDenominator;
    }

    /// @dev the function assumes that the following args are within the respective bounds as enforced by ReservoirPair
    /// and therefore the arithmetic operations performed here would not overflow
    /// aAmountOut  <= uint104
    /// aReserveIn  <= uint104
    /// aReserveOut <= uint104
    /// aSwapFee    <= 0.2e6
    function getAmountIn(uint256 aAmountOut, uint256 aReserveIn, uint256 aReserveOut, uint256 aSwapFee)
        internal
        pure
        returns (uint256 rAmountIn)
    {
        require(aAmountOut > 0, CPM_InsufficientInputAmt());
        require(aReserveIn > 0 && aReserveOut > 0, CPM_InsufficientLiquidity());

        uint256 lNumerator = aReserveIn * aAmountOut * FEE_ACCURACY;
        uint256 lDenominator = (aReserveOut - aAmountOut) * (FEE_ACCURACY - aSwapFee);
        rAmountIn = lNumerator / lDenominator + 1;
    }
}
