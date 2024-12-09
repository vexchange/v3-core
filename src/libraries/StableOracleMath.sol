// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { console2 } from "forge-std/console2.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";
import { StableMath } from "src/libraries/StableMath.sol";

// adapted from Balancer's impl at https://github.com/balancer/balancer-v2-monorepo/blob/903d34e491a5e9c5d59dabf512c7addf1ccf9bbd/pkg/pool-stable/contracts/meta/StableOracleMath.sol
library StableOracleMath {
    using FixedPointMathLib for uint256;

    /// @notice Calculates the spot price of token1/token0 for the stable pair.
    /// @param amplificationParameter The stable amplification parameter in precise form (see StableMath.A_PRECISION).
    /// @param reserve0 The reserve of token0 normalized to 18 decimals, and should never be 0 as checked by _update().
    /// @param reserve1 The reserve of token1 normalized to 18 decimals, and should never be 0 as checked by _update().
    /// @return spotPrice The price of token1/token0, a 18 decimal fixed point number.
    /// @return logSpotPrice The natural log of the spot price, a 4 decimal fixed point number.
    function calcLogPrice(uint256 amplificationParameter, uint256 reserve0, uint256 reserve1)
        internal
        pure
        returns (uint256 spotPrice, int256 logSpotPrice)
    {
        spotPrice = calcSpotPrice(amplificationParameter, reserve0, reserve1);

        logSpotPrice = LogCompression.toLowResLog(spotPrice);
    }

    /// @notice Calculates the spot price of token1 in token0. i.e. token0 is base, token1 is quote
    /// @param amplificationParameter The stable amplification parameter in precise form (see StableMath.A_PRECISION).
    /// @param reserve0 The reserve of token0 normalized to 18 decimals.
    /// @param reserve1 The reserve of token1 normalized to 18 decimals.
    /// @return spotPrice The price expressed as a 18 decimal fixed point number. Minimum price is 1e-18 (1 wei).
    function calcSpotPrice(uint256 amplificationParameter, uint256 reserve0, uint256 reserve1)
        internal
        pure
        returns (uint256 spotPrice)
    {
        //                                                                    //
        //                             2.a.x.y + a.y^2 + b.y                  //
        // spot price Y/X = - dx/dy = -----------------------                 //
        //                             2.a.x.y + a.x^2 + b.x                  //
        //                                                                    //
        // n = 2                                                              //
        // a = amp param * n                                                  //
        // b = D + a.(S - D)                                                  //
        // D = invariant                                                      //
        // S = sum of balances but x,y = 0 since x  and y are the only tokens //

        uint256 invariant =
            StableMath._computeLiquidityFromAdjustedBalances(reserve0, reserve1, 2 * amplificationParameter);

        uint256 a = (amplificationParameter * 2) / StableMath.A_PRECISION;
        uint256 b = (invariant * a) - invariant;

        uint256 axy2 = (a * 2 * reserve0).mulWad(reserve1); // n = 2

        uint256 by = b.mulWad(reserve1);
        uint256 ay2 = ((a * reserve1).mulWad(reserve1));
        if (by > axy2 + ay2) return 1e18;
        // dx = a.x.y.2 + a.y^2 - b.y
        uint256 derivativeX = axy2 + ay2 - by;

        // dy = a.x.y.2 + a.x^2 - b.x
        uint256 bx = (b.mulWad(reserve0));
        uint256 ax2 = ((a * reserve0).mulWad(reserve0));
        if (bx > axy2 + ax2) return 1e18;
        uint256 derivativeY = axy2 + ax2 - bx;

        // This is to prevent division by 0 which happens if reserve0 and reserve1 are sufficiently small (~1e6 after normalization) which can brick the pair
        // If the reserves are that small, their prices will not be serving as price oracles, thus this is safe.
        if (derivativeY == 0) return 1e18;

        // The rounding direction is irrelevant as we're about to introduce a much larger error when converting to log
        // space. We use `divWadUp` as it prevents the result from being zero, which would make the logarithm revert. A
        // result of zero is therefore only possible with zero balances, which are prevented via other means.
        spotPrice = derivativeX.divWadUp(derivativeY);
    }


}
