// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { Buffer } from "src/libraries/Buffer.sol";

contract BufferTest is Test {
    using Buffer for uint16;

    function testPrev_AtLimit() external {
        // arrange
        uint16 lIndex = 0;

        // act & assert
        assertEq(lIndex.prev(), Buffer.SIZE - 1);
    }

    function testNext_AtLimit() external {
        // arrange
        uint16 lLimit = Buffer.SIZE - 1;

        // act & assert
        assertEq(lLimit.next(), 0);
    }

    function testNext_GreaterThanBufferSize(uint16 aStartingIndex) external {
        // assume
        uint16 lStartingIndex = uint16(bound(aStartingIndex, Buffer.SIZE, type(uint16).max));

        // act & assert
        unchecked {
            assertEq(lStartingIndex.next(), (lStartingIndex + 1) % Buffer.SIZE);
        }
        assertLt(lStartingIndex.next(), Buffer.SIZE); // index returned always within bounds of Buffer.SIZE
    }

    function testAdd_IndexGreaterThanBufferSize(uint16 aStartingIndex, uint16 aOffset) external {
        // assume
        uint16 lStartingIndex = uint16(bound(aStartingIndex, Buffer.SIZE, type(uint16).max));

        // act
        uint16 lResult = lStartingIndex.add(aOffset);

        // assert
        assertLt(lResult, Buffer.SIZE);
    }

    function testSub_IndexGreaterThanBufferSize(uint16 aStartingIndex, uint16 aOffset) external {
        // assume
        uint16 lStartingIndex = uint16(bound(aStartingIndex, Buffer.SIZE, type(uint16).max));

        // act
        uint16 lResult = lStartingIndex.sub(aOffset);

        // assert
        assertLt(lResult, Buffer.SIZE);
    }
}
