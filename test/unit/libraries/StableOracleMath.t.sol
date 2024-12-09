// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import { StableOracleMath, StableMath } from "src/libraries/StableOracleMath.sol";
import { Constants } from "src/Constants.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

contract StableOracleMathTest is Test {

    uint256 internal _defaultAmp = Constants.DEFAULT_AMP_COEFF * StableMath.A_PRECISION;

    function testPrice_Token0MoreExpensive() external {
        // arrange
        uint256 lToken0Amt = 1_000_000e18;
        uint256 lToken1Amt = 2_000_000e18;

        // act
        uint256 lPrice = StableOracleMath.calcSpotPrice(_defaultAmp, lToken0Amt, lToken1Amt);

        // assert
        assertEq(lPrice, 1000842880946746931);
    }

    function testPrice_Token1MoreExpensive() external {
        // arrange
        uint256 lToken0Amt = 2_000_000e18;
        uint256 lToken1Amt = 1_000_000e18;

        // act
        uint256 lPrice = StableOracleMath.calcSpotPrice(_defaultAmp, lToken0Amt, lToken1Amt);

        // assert
        assertEq(lPrice, 999157828903224444);
    }

    function testCalcSpotPrice_VerySmallAmounts(uint256 aToken0Amt, uint256 aToken1Amt) external {
        // assume - if token amounts exceed these amounts then they will probably not revert
        uint256 lToken0Amt = bound(aToken0Amt, 1, 1e6) ;
        uint256 lToken1Amt = bound(aToken1Amt, 1, 6e6);

        // act & assert - reverts when the amount is very small
        vm.expectRevert();
        uint256 lPrice = StableOracleMath.calcSpottPrice(_defaultAmp, lToken0Amt, lToken1Amt);
    }
}
