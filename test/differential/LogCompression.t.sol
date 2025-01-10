pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { LogCompression, LogExpMath } from "src/libraries/LogCompression.sol";

contract LogCompressionTest is Test {
    address private _balancerLogCompression = address(200);

    constructor() {
        // we use getDeployedCode since the library contract is stateless
        bytes memory lBytecode = vm.getDeployedCode(
            "./reference/balancer-v2-monorepo/pkg/solidity-utils/artifacts/contracts/helpers/LogCompressionWrapper.sol/LogCompressionWrapper.json"
        );
        vm.etch(_balancerLogCompression, lBytecode);
    }

    function testToLowResLog(uint256 aValue) external {
        // act
        (bool lSuccess, bytes memory lRes) =
            _balancerLogCompression.staticcall(abi.encodeWithSignature("toLowResLog(uint256)", aValue));

        // assert
        if (lSuccess) {
            int256 lLocalRes = LogCompression.toLowResLog(aValue);
            int256 lDecoded = abi.decode(lRes, (int256));
            assertEq(lLocalRes, lDecoded);
        } else {
            vm.expectRevert();
            LogCompression.toLowResLog(aValue);
        }
    }

    function testFromLowResLog(int256 aValue) external {
        // act
        (bool lSuccess, bytes memory lRes) =
            _balancerLogCompression.staticcall(abi.encodeWithSignature("fromLowResLog(int256)", aValue));

        // assert
        if (lSuccess) {
            uint256 lLocalRes = LogCompression.fromLowResLog(aValue);
            uint256 lDecoded = abi.decode(lRes, (uint256));
            assertEq(lLocalRes, lDecoded);
        } else {
            vm.expectRevert();
            LogCompression.fromLowResLog(aValue);
        }
    }

    function testToLowResLog_MaxReturnValue() external {
        // act & assert this is the maximum input that the function can take
        int256 lResLargest = LogCompression.toLowResLog(2 ** 255 - 1);
        assertEq(lResLargest, 1_353_060); // 135.3060

        // once the input exceeds the max input above, it reverts
        vm.expectRevert(LogExpMath.LEM_OutOfBounds.selector);
        LogCompression.toLowResLog(2 ** 255);
    }

    function testToLowResLog_MinReturnValue() external {
        // act & assert - this is the smallest input the function takes
        int256 lResSmallest = LogCompression.toLowResLog(1);
        assertEq(lResSmallest, -414_465); // -41.4465

        vm.expectRevert(LogExpMath.LEM_OutOfBounds.selector);
        LogCompression.toLowResLog(0);
    }
}
