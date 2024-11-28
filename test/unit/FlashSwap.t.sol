pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { IReservoirCallee } from "src/interfaces/IReservoirCallee.sol";

import { ReservoirPair } from "src/ReservoirPair.sol";

contract FlashSwapTest is BaseTest, IReservoirCallee {
    ReservoirPair[] internal _pairs;
    ReservoirPair internal _pair;

    modifier allPairs() {
        for (uint256 i = 0; i < _pairs.length; ++i) {
            uint256 lBefore = vm.snapshotState();
            _pair = _pairs[i];
            _;
            require(vm.revertToStateAndDelete(lBefore), "revertToStateAndDelete failed");
        }
    }

    function setUp() public {
        _pairs.push(_constantProductPair);
        _pairs.push(_stablePair);
    }

    // solhint-disable-next-line no-unused-vars
    function reservoirCall(address, int256 aAmount0, int256 aAmount1, bytes calldata aData) external {
        if (keccak256(aData) == keccak256("no pay")) {
            return;
        }

        if (aAmount0 < 0) {
            _tokenA.mint(msg.sender, uint256(-aAmount0));
        } else if (aAmount1 < 0) {
            _tokenB.mint(msg.sender, uint256(-aAmount1));
        }
    }

    function testSwap_FlashSwap_ExactIn(uint256 aSwapAmt) external allPairs {
        // assume
        int256 lSwapAmt = int256(bound(aSwapAmt, 1, type(uint104).max / 2));

        // act
        uint256 lAmtOut = _pair.swap(lSwapAmt, true, address(this), "some bytes");

        // assert
        assertEq(_tokenB.balanceOf(address(this)), lAmtOut);
    }

    function testSwap_FlashSwap_ExactOut(uint256 aSwapAmt) external allPairs {
        // assume
        int256 lSwapAmt = -int256(bound(aSwapAmt, 1, Constants.INITIAL_MINT_AMOUNT / 2));

        // act
        _pair.swap(lSwapAmt, false, address(this), "some bytes");

        // assert
        assertEq(_tokenB.balanceOf(address(this)), uint256(-lSwapAmt));
    }

    function testSwap_FlashSwap_NoPay(uint256 aSwapAmt) external allPairs {
        // assume
        int256 lSwapAmt = int256(bound(aSwapAmt, 1, type(uint104).max / 2));

        // act & assert
        vm.expectRevert();
        _pair.swap(lSwapAmt, true, address(this), "no pay");
    }
}
