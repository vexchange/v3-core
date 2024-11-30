// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";
import { MintableReservoirERC20 } from "test/__fixtures/MintableReservoirERC20.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";

contract ReservoirERC20Test is BaseTest {
    MintableReservoirERC20 private _token = new MintableReservoirERC20(18);

    function setUp() external {
        _token.mint(address(this), 100e18);
    }

    function testApprove_TransferAll() external {
        // act
        _token.approve(_alice, 50e18);

        // sanity
        assertEq(_token.allowance(address(this), _alice), 50e18);
        vm.prank(_alice);
        _token.transferFrom(address(this), _alice, 50e18);

        // assert
        assertEq(_token.allowance(address(this), _alice), 0);
    }

    function testApprove_TransferOne() external {
        // act
        _token.approve(_alice, 50e18);

        // assert
        vm.prank(_alice);
        _token.transferFrom(address(this), _alice, 1);

        // assert
        assertEq(_token.allowance(address(this), _alice), 50e18 - 1);
    }

    function testApprove_TransferTooMuch() external {
        // act
        _token.approve(_alice, 50e18);

        // assert
        vm.prank(_alice);
        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        _token.transferFrom(address(this), _alice, 50e18 + 1);

        // assert
        assertEq(_token.allowance(address(this), _alice), 50e18);
    }
}
