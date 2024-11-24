// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "script/BaseScript.sol";

import { MintableERC20 } from "test/__fixtures/MintableERC20.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";

import { GenericFactory, IERC20 } from "src/GenericFactory.sol";
import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";
import { StablePair } from "src/curve/stable/StablePair.sol";

contract VaultScript is BaseScript {
    using FactoryStoreLib for GenericFactory;

    MintableERC20 internal _usdc;
    MintableERC20 internal _usdt;

    address internal _recoverer = _makeAddress("recoverer");
    address internal _platformFeeTo = _makeAddress("platformFeeTo");

    GenericFactory internal _factory;

    uint256 private _privateKey = vm.envUint("TEST_PRIVATE_KEY");
    address private _wallet = vm.rememberKey(_privateKey);

    function _makeAddress(string memory aName) internal returns (address) {
        address lAddress = address(uint160(uint256(keccak256(abi.encodePacked(aName)))));
        vm.label(lAddress, aName);

        return lAddress;
    }

    function run() external {
        _ensureDeployerExists(_privateKey, msg.sender, msg.sender, msg.sender);
        _deployInfra();
        _deployCore();
    }

    function _deployInfra() internal {
        vm.startBroadcast(_privateKey);
        _usdc = new MintableERC20("USD Circle", "USDC", 6);
        _usdt = new MintableERC20("USD Tether", "USDT", 6);
        vm.stopBroadcast();
    }

    function _deployCore() internal {
        vm.startBroadcast(_privateKey);

        _factory = _deployer.deployFactory(type(GenericFactory).creationCode);
        _deployer.deployConstantProduct(type(ConstantProductPair).creationCode);
        _deployer.deployStable(type(StablePair).creationCode);

        // Claim ownership of all contracts for our test contract.
        _deployer.proposeOwner(msg.sender);
        _deployer.claimOwnership();
        _deployer.claimFactory();

        _factory.createPair(IERC20(address(_usdt)), IERC20(address(_usdc)), 0);
        _factory.createPair(IERC20(address(_usdt)), IERC20(address(_usdc)), 1);
        vm.stopBroadcast();
    }
}
