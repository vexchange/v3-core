// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { MathUtils } from "src/libraries/MathUtils.sol";
import { StdMath } from "src/libraries/StdMath.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

library StableMath {
    using MathUtils for uint256;
    using StdMath for uint256;
    using FixedPointMathLib for uint256;

    /// @dev Extra precision for intermediate calculations.
    uint256 public constant A_PRECISION = 100;
    /// @dev Minimum time to the ramp A.
    uint256 public constant MIN_RAMP_TIME = 1 days;
    /// @dev Minimum amplification coefficient for the math to work.
    uint256 public constant MIN_A = 1;
    /// @dev Maximum amplification coefficient.
    uint256 public constant MAX_A = 10_000;
    /// @dev Maximum rate of change daily. Note that you can change by the rate each day, so you can
    /// exponentially ramp if you chain days together (e.g. ramp by a factor of 8 over 3 days, 2**3).
    uint256 public constant MAX_AMP_UPDATE_DAILY_RATE = 2;
    /// @dev Required as an upper limit for iterative calculations not guaranteed to converge.
    uint256 private constant MAX_LOOP_LIMIT = 256;
    /// @dev Maximum fee, which is 100%.
    uint256 private constant ONE_HUNDRED_PERCENT = 1_000_000;

    /// @notice Calculates the amount of output tokens for an exact in trade
    /// @param amountIn input amount, assumed to be type(uint104).max or less
    /// @param reserve0 reserves of token0, assumed to be type(uint104).max or less
    /// @param reserve1 reserves of token1, assumed to be type(uint104).max or less
    /// @param token0PrecisionMultiplier, multiplier for token0 to get to 1e18, assumed to be between 1 and 1e18
    /// @param token1PrecisionMultiplier, multiplier for token1 to get to 1e18, assumed to be between 1 and 1e18
    /// @param token0In, true for token0 in token1 out
    /// @param swapFee, assumed to be ReservoirPair::MAX_SWAP_FEE (0.02e6) or less
    /// @param N_A, number of tokens multiplied by the amplification coefficient, assumed to be 2 * MAX_A * A_PRECISION or less
    /// @return dy the amount of output tokens
    function _getAmountOut(
        uint256 amountIn,
        uint256 reserve0,
        uint256 reserve1,
        uint256 token0PrecisionMultiplier,
        uint256 token1PrecisionMultiplier,
        bool token0In,
        uint256 swapFee,
        uint256 N_A // solhint-disable-line var-name-mixedcase
    ) internal pure returns (uint256 dy) {
        // overflow and underflow are not possible as reserves, amountIn <= uint104, precision multipliers are maximum 1e18 (uint60)
        // and swapFee < ONE_HUNDRED_PERCENT
        unchecked {
            uint256 adjustedReserve0 = reserve0 * token0PrecisionMultiplier;
            uint256 adjustedReserve1 = reserve1 * token1PrecisionMultiplier;
            uint256 feeDeductedAmountIn = amountIn - (amountIn * swapFee) / ONE_HUNDRED_PERCENT;
            uint256 d = _computeLiquidityFromAdjustedBalances(adjustedReserve0, adjustedReserve1, N_A);

            if (token0In) {
                uint256 x = adjustedReserve0 + (feeDeductedAmountIn * token0PrecisionMultiplier);
                uint256 y = _getY(x, d, N_A);
                dy = adjustedReserve1 - y - 1;
                dy /= token1PrecisionMultiplier;
            } else {
                uint256 x = adjustedReserve1 + (feeDeductedAmountIn * token1PrecisionMultiplier);
                uint256 y = _getY(x, d, N_A);
                dy = adjustedReserve0 - y - 1;
                dy /= token0PrecisionMultiplier;
            }
        }
    }

    /// @notice Calculates the amount of input tokens for an exact out trade
    /// @param amountOut output amount, assumed to be type(uint104).max or less
    /// @param reserve0 reserves of token0, assumed to be type(uint104).max or less
    /// @param reserve1 reserves of token1, assumed to be type(uint104).max or less
    /// @param token0PrecisionMultiplier, multiplier for token0 to get to 1e18, assumed to be between 1 and 1e18
    /// @param token1PrecisionMultiplier, multiplier for token1 to get to 1e18, assumed to be between 1 and 1e18
    /// @param token0Out, true for token0 out token1 in
    /// @param swapFee, assumed to be ReservoirPair::MAX_SWAP_FEE (0.02e6) or less
    /// @param N_A, number of tokens multiplied by the amplification coefficient, assumed to be 2 * MAX_A * A_PRECISION or less
    /// @return dx the amount of input tokens
    function _getAmountIn(
        uint256 amountOut,
        uint256 reserve0,
        uint256 reserve1,
        uint256 token0PrecisionMultiplier,
        uint256 token1PrecisionMultiplier,
        bool token0Out,
        uint256 swapFee,
        uint256 N_A // solhint-disable-line var-name-mixedcase
    ) internal pure returns (uint256 dx) {
        // overflow and underflow are not possible as reserves, amountIn <= uint104 and precision multipliers are maximum 1e18 (uint60)
        // and swapFee < ONE_HUNDRED_PERCENT
        unchecked {
            uint256 adjustedReserve0 = reserve0 * token0PrecisionMultiplier;
            uint256 adjustedReserve1 = reserve1 * token1PrecisionMultiplier;
            uint256 d = _computeLiquidityFromAdjustedBalances(adjustedReserve0, adjustedReserve1, N_A);

            if (token0Out) {
                uint256 y = adjustedReserve0 - amountOut * token0PrecisionMultiplier;
                uint256 x = _getY(y, d, N_A);
                dx = x - adjustedReserve1 + 1;
                dx /= token1PrecisionMultiplier;
            } else {
                uint256 y = adjustedReserve1 - amountOut * token1PrecisionMultiplier;
                uint256 x = _getY(y, d, N_A);
                dx = x - adjustedReserve0 + 1;
                dx /= token0PrecisionMultiplier;
            }

            // Add the swap fee.
            dx = dx * (ONE_HUNDRED_PERCENT + swapFee) / ONE_HUNDRED_PERCENT;
        }
    }

    function _computeLiquidityFromAdjustedBalances(
        uint256 xp0,
        uint256 xp1,
        uint256 N_A // solhint-disable-line var-name-mixedcase
    ) internal pure returns (uint256) {
        uint256 s = xp0 + xp1;
        if (s == 0) {
            return 0;
        }

        uint256 prevD;
        // solhint-disable-next-line var-name-mixedcase
        uint256 D = s;
        (xp0, xp1) = xp0 < xp1 ? (xp0, xp1) : (xp1, xp0);
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            uint256 dP = ((D * D) / xp0).fullMulDiv(D, xp1) / 4;
            prevD = D;
            D = ((N_A * s) / A_PRECISION + 2 * dP).fullMulDiv(D, (N_A - A_PRECISION) * D / A_PRECISION + 3 * dP);
            if (D.within1(prevD)) {
                return D;
            }
        }

        revert("SM: COMPUTE_DID_NOT_CONVERGE");
    }

    /// @notice Calculate the new balance of one token given the balance of the other token
    /// @dev This function is used as a helper function to calculate how much TO/FROM token the user
    /// should receive/provide on swap.
    /// @dev Originally
    /// https://github.com/saddle-finance/saddle-contract/blob/0b76f7fb519e34b878aa1d58cffc8d8dc0572c12/contracts/SwapUtils.sol#L432.
    /// @param x The new total amount of FROM/TO token.
    /// @return y The amount of TO/FROM token that should remain in the pool.
    function _getY(
        uint256 x,
        uint256 D, // solhint-disable-line var-name-mixedcase
        uint256 N_A // solhint-disable-line var-name-mixedcase
    ) internal pure returns (uint256 y) {
        uint256 c = (D * D) / (x * 2);
        c = (c * D) * A_PRECISION / (N_A * 2);
        uint256 b = x + ((D * A_PRECISION) / N_A);
        uint256 yPrev;
        y = D;
        // @dev Iterative approximation.
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            yPrev = y;
            y = (y * y + c) / (y * 2 + b - D);
            if (y.within1(yPrev)) {
                return y;
            }
        }
        revert("SM: GETY_DID_NOT_CONVERGE");
    }
}
