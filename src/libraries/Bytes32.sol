// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

library Bytes32Lib {
    function toBytes32(bool aValue) internal pure returns (bytes32) {
        return aValue ? bytes32(uint256(1)) : bytes32(uint256(0));
    }

    function toBytes32(uint256 aValue) internal pure returns (bytes32) {
        return bytes32(aValue);
    }

    function toBytes32(int256 aValue) internal pure returns (bytes32) {
        return bytes32(uint256(aValue));
    }

    function toBytes32(address aValue) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(aValue)));
    }

    function toBool(bytes32 aValue) internal pure returns (bool) {
        return uint256(aValue) % 2 == 1;
    }

    function toUint64(bytes32 aValue) internal pure returns (uint64) {
        return uint64(uint256(aValue));
    }

    function toUint128(bytes32 aValue) internal pure returns (uint128) {
        return uint128(uint256(aValue));
    }

    function toUint256(bytes32 aValue) internal pure returns (uint256) {
        return uint256(aValue);
    }

    function toInt256(bytes32 aValue) internal pure returns (int256) {
        return int256(uint256(aValue));
    }

    function toAddress(bytes32 aValue) internal pure returns (address) {
        return address(uint160(uint256(aValue)));
    }
}
