// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import { Create2Lib } from "src/libraries/Create2Lib.sol";
import { ReservoirDeployer } from "src/ReservoirDeployer.sol";

contract BaseScript is Script {
    ReservoirDeployer internal _deployer;

    // use private key for testing / dev purposes
    function _ensureDeployerExists(uint256 aPrivateKey, address aGuardian1, address aGuardian2, address aGuardian3)
        internal
    {
        vm.broadcast(aPrivateKey);
        _calculateAddressAndDeployIfNeeded(aGuardian1, aGuardian2, aGuardian3);
    }

    // use address for production / deployment purposes (e.g. with a hardware wallet)
    function _ensureDeployerExists(address aAddress, address aGuardian1, address aGuardian2, address aGuardian3)
        internal
    {
        vm.broadcast(aAddress);
        _calculateAddressAndDeployIfNeeded(aGuardian1, aGuardian2, aGuardian3);
    }

    function _calculateAddressAndDeployIfNeeded(address aGuardian1, address aGuardian2, address aGuardian3) internal {
        bytes memory lInitCode = abi.encodePacked(type(ReservoirDeployer).creationCode);
        lInitCode = abi.encodePacked(lInitCode, abi.encode(aGuardian1, aGuardian2, aGuardian3));
        address lDeployer = Create2Lib.computeAddress(CREATE2_FACTORY, lInitCode, bytes32(0));
        if (lDeployer.code.length == 0) {
            _deployer = new ReservoirDeployer{ salt: bytes32(0) }(aGuardian1, aGuardian2, aGuardian3);
            require(address(_deployer) == lDeployer, "CREATE2 ADDRESS MISMATCH");
            require(address(_deployer) != address(0), "DEPLOY FACTORY FAILED");
        } else {
            _deployer = ReservoirDeployer(lDeployer);
        }
    }
}
