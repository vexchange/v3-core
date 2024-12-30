// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { SafeCast } from "@openzeppelin/utils/math/SafeCast.sol";

import { IAssetManager, IERC20 } from "src/interfaces/IAssetManager.sol";
import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";
import { ReservoirPair } from "src/ReservoirPair.sol";

contract AssetManagerReenter is IAssetManager {
    using SafeCast for uint256;

    mapping(IAssetManagedPair => mapping(IERC20 => uint256)) public _getBalance;

    // this is solely to test reentrancy for ReservoirPair::mint/burn when the pair syncs
    // with the asset manager at the beginning of the functions
    function getBalance(IAssetManagedPair, IERC20) external returns (uint256) {
        ReservoirPair(msg.sender).mint(address(this));
        return 0;
    }

    function adjustManagement(IAssetManagedPair aPair, int256 aToken0Amount, int256 aToken1Amount) external {
        require(aToken0Amount != type(int256).min && aToken1Amount != type(int256).min, "AM: OVERFLOW");

        if (aToken0Amount >= 0) {
            uint256 lAbs = uint256(int256(aToken0Amount));

            _getBalance[aPair][aPair.token0()] += lAbs;
        } else {
            uint256 lAbs = uint256(int256(-aToken0Amount));

            aPair.token0().approve(address(aPair), lAbs);
            _getBalance[aPair][aPair.token0()] -= lAbs;
        }
        if (aToken1Amount >= 0) {
            uint256 lAbs = uint256(int256(aToken1Amount));

            _getBalance[aPair][aPair.token1()] += lAbs;
        } else {
            uint256 lAbs = uint256(int256(-aToken1Amount));

            aPair.token1().approve(address(aPair), lAbs);
            _getBalance[aPair][aPair.token1()] -= lAbs;
        }

        aPair.adjustManagement(aToken0Amount, aToken1Amount);
    }

    function adjustBalance(IAssetManagedPair aOwner, IERC20 aToken, uint256 aNewAmount) external {
        _getBalance[aOwner][aToken] = aNewAmount;
    }

    // solhint-disable-next-line no-empty-blocks
    function afterLiquidityEvent() external { }

    function returnAsset(uint256 aToken0Amt, uint256 aToken1Amt) external {
        IAssetManagedPair(msg.sender).token0().approve(msg.sender, aToken0Amt);
        IAssetManagedPair(msg.sender).token1().approve(msg.sender, aToken1Amt);

        IAssetManagedPair(msg.sender).adjustManagement(-aToken0Amt.toInt256(), -aToken1Amt.toInt256());
    }
}

