// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.8.0;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { LogCompression } from "src/libraries/LogCompression.sol";

library ConstantProductOracleMath {
    using FixedPointMathLib for uint256;

    /**
     * @notice Calculates the spot price of token1/token0 for the constant product pair.
     * @param reserve0 The reserve of token0 normalized to 18 decimals, and should never be 0 as checked by _updateAndUnlock().
     * @param reserve1 The reserve of token1 normalized to 18 decimals, and should never be 0 as checked by _updateAndUnlock().
     * @return spotPrice The price of token1/token0, expressed as a 18 decimals fixed point number. The minimum price is 1e-18 (1 wei), as we do not round to zero.
     * @return logSpotPrice The natural log of the spot price, 4 decimal fixed point number. Min value is 1.
     */
    function calcLogPrice(uint256 reserve0, uint256 reserve1)
        internal
        pure
        returns (uint256 spotPrice, int256 logSpotPrice)
    {
        // Scaled by 1e18, minimum will be 1 wei as we divUp.
        spotPrice = reserve1.divWadUp(reserve0);

        logSpotPrice = LogCompression.toLowResLog(spotPrice);
    }
}
