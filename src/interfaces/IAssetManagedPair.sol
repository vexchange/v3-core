// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";

interface IAssetManagedPair {
    event AssetManager(IAssetManager manager);

    function token0Managed() external view returns (uint104);
    function token1Managed() external view returns (uint104);

    function token0() external view returns (IERC20);
    function token1() external view returns (IERC20);

    function getReserves()
        external
        view
        returns (uint104 rReserve0, uint104 rReserve1, uint32 rBlockTimestampLast, uint16 rIndex);

    function assetManager() external view returns (IAssetManager);
    function setManager(IAssetManager manager) external;

    function adjustManagement(int256 token0Change, int256 token1Change) external;
    function skimExcessManaged(IERC20 aToken) external returns (uint256 rAmtSkimmed);
}
