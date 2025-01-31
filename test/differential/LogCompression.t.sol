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

            if (lDecoded > LogExpMath.MAX_NATURAL_EXPONENT / 1e14) {
                assertEq(lLocalRes, LogExpMath.MAX_NATURAL_EXPONENT / 1e14);
            } else if (lDecoded < LogExpMath.MIN_NATURAL_EXPONENT / 1e14) {
                assertEq(lLocalRes, LogExpMath.MIN_NATURAL_EXPONENT / 1e14);
            } else {
                assertEq(lLocalRes, lDecoded);
            }
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
}
