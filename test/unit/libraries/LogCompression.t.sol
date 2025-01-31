pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { LogCompression, LogExpMath } from "src/libraries/LogCompression.sol";

contract LogCompressionTest is Test {
    function testToLowResLog() external {
        int256 lResult = LogCompression.toLowResLog(1);
        console.log(lResult);

        console.log(LogCompression.fromLowResLog(lResult));
    }
}
