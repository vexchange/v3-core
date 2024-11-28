// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// adapted from https://github.com/AngleProtocol/merkl-contracts/blob/main/contracts/Distributor.sol
interface IDistributor {
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;

    function toggleOperator(address user, address operator) external;
}
