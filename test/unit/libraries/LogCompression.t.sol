pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { LogCompression, LogExpMath } from "src/libraries/LogCompression.sol";

contract LogCompressionTest is Test {
    function testToLowResLog_Clamped() external {
        // act
        int256 lResult = LogCompression.toLowResLog(1);

        // assert
        assertEq(lResult, LogExpMath.MIN_NATURAL_EXPONENT / 1e14);
    }

    function testToLowResLog_MaxReturnValue(uint256 aInput) external {
        // assume
        uint256 lInput = bound(aInput, 1, 2 ** 255 - 1);

        // act
        int256 lRes = LogCompression.toLowResLog(lInput);

        // assert
        assertLe(lRes, LogExpMath.MAX_NATURAL_EXPONENT / 1e14);
        // this should never revert
        LogCompression.fromLowResLog(lRes);
    }

    function testToLowResLog_MinReturnValue(uint256 aInput) external {
        // assume
        uint256 lInput = bound(aInput, 1, 2 ** 255 - 1);

        // act
        int256 lRes = LogCompression.toLowResLog(lInput);

        // assert
        assertGe(lRes, LogExpMath.MIN_NATURAL_EXPONENT / 1e14);
        // this should never revert
        LogCompression.fromLowResLog(lRes);
    }
}
