// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "script/BaseScript.sol";

import { GenericFactory } from "src/GenericFactory.sol";
import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";
import { StablePair } from "src/curve/stable/StablePair.sol";

contract DeployScript is BaseScript {
    address internal _riley = 0x01569E14C2134d0b2e960654Cf47212e9cEc4bA9;
    address internal _oliver = 0x2F0066c884357e37d93fA1D030517be89d8F8EF3;
    address internal _alex = 0x2508b97B8041960ccA8AaBC7662F07EC8e285F6d;

    function run() external {
        _ensureDeployerExists(msg.sender, _riley, _oliver, _alex);
        _deployCore();
    }

    function _deployCore() internal {
        vm.startBroadcast(msg.sender);
        _deployer.deployFactory(type(GenericFactory).creationCode);
        _deployer.deployConstantProduct(type(ConstantProductPair).creationCode);
        _deployer.deployStable(type(StablePair).creationCode);
        vm.stopBroadcast();

        require(_deployer.guardian1() == _riley);
        require(_deployer.guardian2() == _oliver);
        require(_deployer.guardian3() == _alex);
    }
}
