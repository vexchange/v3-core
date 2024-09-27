// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

 import { GenericFactory } from "src/ReservoirDeployer.sol";
import { AaveManager, IAssetManagedPair} from "src/asset-management/AaveManager.sol";
import { ReservoirTimelock } from "src/ReservoirTimelock.sol";

contract SetAssetManagerForPair is Script {

    GenericFactory internal _factory = GenericFactory(0xDd723D9273642D82c5761a4467fD5265d94a22da);
    ReservoirTimelock internal _timelock = ReservoirTimelock(payable(0xF820eCe0eaaeF4AF1535865Fb6F230f576e586c0));
    AaveManager internal _assetManager = AaveManager(0xbe8A6DDDA2D2AA6BC88972801Be1119BD228f55e);

    function run() external {
        _queueSetManagerForPair(IAssetManagedPair(0x146D00567Cef404c1c0aAF1dfD2abEa9F260B8C7));
    }

    function _queueSetManagerForPair(IAssetManagedPair aPair) internal {
        vm.startBroadcast(msg.sender);

        bytes memory lCalldataForFactory = abi.encodeCall(IAssetManagedPair.setManager, (_assetManager));
        bytes memory lCalldataForTimelock = abi.encodeCall(_factory.rawCall, (address(aPair) , lCalldataForFactory, 0));
        _timelock.queueTransaction(address(_factory), 0, "rawCall(address,bytes,uint256)", lCalldataForTimelock, 1687452720);

        vm.stopBroadcast();
    }
}
