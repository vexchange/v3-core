pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { ConstantProductOracleMath } from "src/libraries/ConstantProductOracleMath.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";

contract ConstantProductMathTest is BaseTest {
    function testConstantProductOracleMath() external {
        // assert
        (uint256 lSpotPrice, int256 lLogSpotPrice) = ConstantProductOracleMath.calcLogPrice(1e18, 1e18);
        assertEq(lSpotPrice, 1e18);
        assertEq(lLogSpotPrice, LogCompression.toLowResLog(1e18));

        (lSpotPrice, lLogSpotPrice) = ConstantProductOracleMath.calcLogPrice(type(uint104).max, type(uint104).max);
        assertEq(lSpotPrice, 1e18);
        assertEq(lLogSpotPrice, LogCompression.toLowResLog(1e18));

        (lSpotPrice, lLogSpotPrice) = ConstantProductOracleMath.calcLogPrice(type(uint104).max / 2, type(uint104).max);
        assertEq(lSpotPrice, 2e18 + 1);
        assertEq(lLogSpotPrice, LogCompression.toLowResLog(2e18));

        (lSpotPrice, lLogSpotPrice) = ConstantProductOracleMath.calcLogPrice(type(uint104).max, type(uint104).max / 2);
        assertEq(lSpotPrice, 0.5e18);
        assertEq(lLogSpotPrice, LogCompression.toLowResLog(0.5e18));

        (lSpotPrice, lLogSpotPrice) = ConstantProductOracleMath.calcLogPrice(type(uint104).max / 10, type(uint104).max);
        assertEq(lSpotPrice, 10e18 + 1);
        assertEq(lLogSpotPrice, LogCompression.toLowResLog(10e18));

        (lSpotPrice, lLogSpotPrice) = ConstantProductOracleMath.calcLogPrice(type(uint104).max, type(uint104).max / 10);
        assertEq(lSpotPrice, 0.1e18);
        assertEq(lLogSpotPrice, LogCompression.toLowResLog(0.1e18));

        (lSpotPrice, lLogSpotPrice) =
            ConstantProductOracleMath.calcLogPrice(type(uint104).max, type(uint104).max / 1e17);
        assertEq(lSpotPrice, 1e18 / 1e17);
        assertApproxEqRel(
            lLogSpotPrice,
            LogCompression.toLowResLog(1e18 / 1e17),
            // we are chopping off information from the reserves when we scale them by a non power of 2
            0.01e18
        );

        (lSpotPrice, lLogSpotPrice) =
            ConstantProductOracleMath.calcLogPrice(type(uint104).max / 1e17, type(uint104).max);
        // this small discrepancy occurs because we use divWadUp
        assertApproxEqRel(lSpotPrice, 1e18 * 1e17, 0.000000000000004e18);
        assertApproxEqRel(
            lLogSpotPrice,
            LogCompression.toLowResLog(1e18 * 1e17),
            // we are chopping off information from the reserves when we scale them by a non power of 2
            0.01e18
        );

        (lSpotPrice, lLogSpotPrice) =
            ConstantProductOracleMath.calcLogPrice(type(uint104).max, type(uint104).max / 1e18);
        assertEq(lSpotPrice, 1e18 / 1e18);
        assertApproxEqRel(lLogSpotPrice, LogCompression.toLowResLog(1e18 / 1e18), 0.1e18);

        (lSpotPrice, lLogSpotPrice) =
            ConstantProductOracleMath.calcLogPrice(type(uint104).max / 1e18, type(uint104).max);
        // this small discrepancy occurs because we use divWadUp
        assertApproxEqRel(lSpotPrice, 1e18 * 1e18, 0.00000000000004e18);
        assertApproxEqRel(lLogSpotPrice, LogCompression.toLowResLog(1e18 * 1e18), 0.1e18);
    }

    function testCalcLogPrice_ReturnsOneWeiWhenPriceDiffGreaterThan1e18(uint256 aReserve0, uint256 aReserve1) public {
        // arrange
        uint256 lReserve1 = bound(aReserve0, 1, type(uint104).max / 1e18);
        uint256 lReserve0 = bound(aReserve1, lReserve1 * 1e18, type(uint104).max);

        // act
        (, int256 lLogPrice) = ConstantProductOracleMath.calcLogPrice(lReserve0, lReserve1);

        // assert
        assertEq(lLogPrice, LogCompression.toLowResLog(1));
    }
}
