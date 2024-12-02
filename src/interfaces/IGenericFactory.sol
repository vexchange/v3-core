// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";

interface IGenericFactory {
    function get(bytes32 key) external view returns (bytes32 value);
    function set(bytes32 key, bytes32 value) external;

    function addCurve(bytes calldata initCode) external returns (uint256 curveId, bytes32 codeKey);

    function allPairs() external view returns (address[] memory);
    function getPair(IERC20 tokenA, IERC20 tokenB, uint256 curveId) external view returns (address);
    function createPair(IERC20 tokenA, IERC20 tokenB, uint256 curveId) external returns (address);
}
