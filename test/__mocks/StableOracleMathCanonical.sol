// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { StableMath } from "src/libraries/StableMath.sol";

// the original implementation without safeguards as implemented by balancer
// https://github.com/balancer/balancer-v2-monorepo/blob/903d34e491a5e9c5d59dabf512c7addf1ccf9bbd/pkg/pool-stable/contracts/meta/StableOracleMath.sol
library StableOracleMathCanonical {
    using FixedPointMathLib for uint256;

    function calcSpotPrice(uint256 amplificationParameter, uint256 reserve0, uint256 reserve1)
        internal
        view
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

        // dx = a.x.y.2 + a.y^2 - b.y
        uint256 derivativeX = axy2 + ((a * reserve1).mulWad(reserve1)) - (b.mulWad(reserve1));

        // dy = a.x.y.2 + a.x^2 - b.x
        uint256 derivativeY = axy2 + ((a * reserve0).mulWad(reserve0)) - (b.mulWad(reserve0));

        // The rounding direction is irrelevant as we're about to introduce a much larger error when converting to log
        // space. We use `divWadUp` as it prevents the result from being zero, which would make the logarithm revert. A
        // result of zero is therefore only possible with zero balances, which are prevented via other means.
        spotPrice = derivativeX.divWadUp(derivativeY);
    }
}
