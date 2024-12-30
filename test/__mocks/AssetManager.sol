// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { SafeCast } from "@openzeppelin/utils/math/SafeCast.sol";

import { IAssetManager, IERC20 } from "src/interfaces/IAssetManager.sol";
import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";

contract AssetManager is IAssetManager {
    using SafeCast for uint256;

    mapping(IAssetManagedPair => mapping(IERC20 => uint256)) public getBalance;

    function adjustManagement(IAssetManagedPair aPair, int256 aToken0Amount, int256 aToken1Amount) public {
        require(aToken0Amount != type(int256).min && aToken1Amount != type(int256).min, "AM: OVERFLOW");

        if (aToken0Amount < 0) {
            uint256 lAbs = uint256(-aToken0Amount);

            aPair.token0().approve(address(aPair), lAbs);
            getBalance[aPair][aPair.token0()] -= lAbs;
        }
        if (aToken1Amount < 0) {
            uint256 lAbs = uint256(-aToken1Amount);

            aPair.token1().approve(address(aPair), lAbs);
            getBalance[aPair][aPair.token1()] -= lAbs;
        }

        aPair.adjustManagement(aToken0Amount, aToken1Amount);

        if (aToken0Amount >= 0) {
            uint256 lAbs = uint256(aToken0Amount);

            getBalance[aPair][aPair.token0()] += lAbs;
        }
        if (aToken1Amount >= 0) {
            uint256 lAbs = uint256(aToken1Amount);

            getBalance[aPair][aPair.token1()] += lAbs;
        }
    }

    function adjustBalance(IAssetManagedPair aOwner, IERC20 aToken, uint256 aNewAmount) external {
        getBalance[aOwner][aToken] = aNewAmount;
    }

    // solhint-disable-next-line no-empty-blocks
    function afterLiquidityEvent() external { }

    function returnAsset(uint256 aToken0Amt, uint256 aToken1Amt) external {
        IAssetManagedPair lPair = IAssetManagedPair(msg.sender);
        lPair.token0().approve(address(msg.sender), aToken0Amt);
        lPair.token1().approve(address(msg.sender), aToken1Amt);
        adjustManagement(lPair, -aToken0Amt.toInt256(), -aToken1Amt.toInt256());
    }
}
