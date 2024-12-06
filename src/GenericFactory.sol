// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/utils/math/Math.sol";
import { Address } from "@openzeppelin/utils/Address.sol";
import { Owned } from "solmate/auth/Owned.sol";
import { SSTORE2 } from "solady/utils/SSTORE2.sol";

import { Bytes32Lib } from "src/libraries/Bytes32.sol";

import { IGenericFactory, IERC20 } from "src/interfaces/IGenericFactory.sol";

uint256 constant MAX_SSTORE_SIZE = 0x6000 - 1;

contract GenericFactory is IGenericFactory, Owned(msg.sender) {
    using Bytes32Lib for address;

    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();
    error DeployFailed();

    /*//////////////////////////////////////////////////////////////////////////
                                    CONFIG
    //////////////////////////////////////////////////////////////////////////*/

    mapping(bytes32 => bytes32) public get;

    function set(bytes32 aKey, bytes32 aValue) public onlyOwner {
        get[aKey] = aValue;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    BYTECODES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Mapping storing the bytecodes (as chunked pointers) this factory
    ///         can deploy.
    mapping(bytes32 => address[]) private _getByteCode;

    function _writeBytecode(bytes32 aCodeKey, bytes calldata aInitCode) internal {
        uint256 lChunk = 0;
        uint256 lInitCodePointer = 0;
        while (lInitCodePointer < aInitCode.length) {
            // Cut the initCode into chunks at most 24kb (EIP-170). The stored
            // data is prefixed with STOP, so we must store 1 less than max.
            uint256 lChunkEnd = Math.min(aInitCode.length, lInitCodePointer + MAX_SSTORE_SIZE);

            _getByteCode[aCodeKey].push(SSTORE2.write(aInitCode[lInitCodePointer:lChunkEnd]));

            lChunk += 1;
            lInitCodePointer = lChunkEnd;
        }
    }

    function getBytecode(bytes32 aCodeKey, IERC20 aToken0, IERC20 aToken1) public view returns (bytes memory) {
        address[] memory lByteCode = _getByteCode[aCodeKey];
        uint256 lByteCodeChunks = lByteCode.length;

        bytes memory lInitCode;
        // SAFETY:
        // This block updates the memory pointer before returning to solidity.
        assembly ("memory-safe") {
            lInitCode := mload(0x40)

            let free_mem := add(lInitCode, 0x20)
            for { let i := 0 } lt(i, lByteCodeChunks) { i := add(i, 1) } {
                // Load lByteCode[i] using yul.
                let offset := mul(i, 0x20)
                let chunk_addr := mload(add(add(lByteCode, offset), 0x20))

                // size = lByteCode[i].code.length - 1;
                let size := sub(extcodesize(chunk_addr), 0x01)

                // Copy the external code (skipping the first byte which is a
                // STOP instruction). Then update the stack free_mem pointer to
                // the new HEAD of memory.
                extcodecopy(chunk_addr, free_mem, 0x01, size)
                free_mem := add(free_mem, size)
            }

            // Store the two tokens as cstr args.
            mstore(free_mem, aToken0)
            mstore(add(free_mem, 0x20), aToken1)

            // Write initCode length and update free mem. Note that we are using
            // the difference between free_mem (stack) and mem pointer (memory)
            // to know how much memory we just wrote and thus the size of the
            // bytecode.
            //
            // Because solidity arrays in memory store their length in the first
            // word, we get the array size using the following formula:
            //
            // old_free_memory = mload(0x40)
            // new_free_memory = free_mem + 64 (the two tokens)
            // array_length = new_free_memory - old_free_memory - 32 (the length word)
            mstore(lInitCode, add(sub(free_mem, mload(0x40)), 32))
            mstore(0x40, add(free_mem, 64))
        }

        return lInitCode;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    CURVES
    //////////////////////////////////////////////////////////////////////////*/

    bytes32[] public _curves;

    function curves() external view returns (bytes32[] memory) {
        return _curves;
    }

    function addCurve(bytes calldata aInitCode) external onlyOwner returns (uint256 rCurveId, bytes32 rCodeKey) {
        rCurveId = _curves.length;
        rCodeKey = keccak256(aInitCode);
        _curves.push(rCodeKey);

        _writeBytecode(rCodeKey, aInitCode);
    }

    function _loadCurve(uint256 aCurveId, IERC20 aToken0, IERC20 aToken1) private view returns (bytes memory) {
        bytes32 lCodeKey = _curves[aCurveId];

        return getBytecode(lCodeKey, aToken0, aToken1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    PAIRS
    //////////////////////////////////////////////////////////////////////////*/

    event Pair(IERC20 indexed token0, IERC20 indexed token1, uint256 curveId, address pair);

    /// @notice maps tokenA, tokenB addresses, and curveId, to pair address, where the order of tokenA and tokenB does not matter
    mapping(IERC20 => mapping(IERC20 => mapping(uint256 => address))) public getPair;
    address[] private _allPairs;

    function allPairs() external view returns (address[] memory) {
        return _allPairs;
    }

    function _sortAddresses(IERC20 a, IERC20 b) private pure returns (IERC20 r0, IERC20 r1) {
        (r0, r1) = a < b ? (a, b) : (b, a);
    }

    function createPair(IERC20 aTokenA, IERC20 aTokenB, uint256 aCurveId) external returns (address rPair) {
        require(aTokenA != aTokenB, IdenticalAddresses());
        require(address(aTokenA) != address(0), ZeroAddress());
        require(getPair[aTokenA][aTokenB][aCurveId] == address(0), PairExists());

        (IERC20 lToken0, IERC20 lToken1) = _sortAddresses(aTokenA, aTokenB);

        bytes memory lInitCode = _loadCurve(aCurveId, lToken0, lToken1);

        // SAFETY:
        // Does not write to memory
        assembly ("memory-safe") {
            // Create2 the pair, uniqueness guaranteed by args.
            rPair :=
                create2(
                    0, // value
                    add(lInitCode, 0x20), // offset - skip first word, which is just the length
                    mload(lInitCode), // size
                    0 // salt
                )
        }
        require(rPair != address(0), DeployFailed());

        // Double-map the newly created pair for reverse lookup.
        getPair[lToken0][lToken1][aCurveId] = rPair;
        getPair[lToken1][lToken0][aCurveId] = rPair;
        _allPairs.push(rPair);

        emit Pair(lToken0, lToken1, aCurveId, rPair);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    EXECUTE
    //////////////////////////////////////////////////////////////////////////*/

    function rawCall(address aTarget, bytes calldata aCalldata, uint256 aValue)
        external
        onlyOwner
        returns (bytes memory)
    {
        return Address.functionCallWithValue(aTarget, aCalldata, aValue);
    }
}
