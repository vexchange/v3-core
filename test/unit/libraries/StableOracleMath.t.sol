// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import { StableOracleMath, StableMath } from "src/libraries/StableOracleMath.sol";
import { Constants } from "src/Constants.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { StableOracleMathCanonical } from "test/__mocks/StableOracleMathCanonical.sol";

contract StableOracleMathTest is Test {
    uint256 internal _defaultAmp = Constants.DEFAULT_AMP_COEFF * StableMath.A_PRECISION;

    // estimates the spot price by giving a very small input to simulate dx (an infinitesimally small x)
    function estimateSpotPrice(
        uint256 reserve0,
        uint256 reserve1,
        uint256 token0Multiplier,
        uint256 token1Multiplier,
        uint256 N_A
    ) internal pure returns (uint256 rPrice) {
        uint256 lInputAmt = 1e8; // anything smaller than 1e7 the error becomes larger, as experimented
        uint256 lOut = _getAmountOut(lInputAmt, reserve0, reserve1, token0Multiplier, token1Multiplier, true, 0, N_A);
        rPrice = lOut.divWadUp(lInputAmt);
    }

    function testPrice_Token0MoreExpensive() external {
        // arrange
        uint256 lToken0Amt = 1_000_000e18;
        uint256 lToken1Amt = 2_000_000e18;

        // act
        uint256 lPrice = StableOracleMath.calcSpotPrice(_defaultAmp, lToken0Amt, lToken1Amt);

        // assert
        assertEq(lPrice, 1_000_842_880_946_746_931);
    }

    function testPrice_Token1MoreExpensive() external {
        // arrange
        uint256 lToken0Amt = 2_000_000e18;
        uint256 lToken1Amt = 1_000_000e18;

        // act
        uint256 lPrice = StableOracleMath.calcSpotPrice(_defaultAmp, lToken0Amt, lToken1Amt);

        // assert
        assertEq(lPrice, 999_157_828_903_224_444);
    }

    function testCalcSpotPrice_CanonicalVersion_VerySmallAmounts(uint256 aToken0Amt, uint256 aToken1Amt) external {
        // assume - if token amounts exceed these amounts then they will probably not revert
        uint256 lToken0Amt = bound(aToken0Amt, 1, 1e6);
        uint256 lToken1Amt = bound(aToken1Amt, 1, 6e6);

        // act & assert - reverts when the amount is very small
        vm.expectRevert();
        uint256 lPrice = StableOracleMathCanonical.calcSpotPrice(_defaultAmp, lToken0Amt, lToken1Amt);
    }

    function testCalcSpotPrice_VerySmallAmounts(uint256 aToken0Amt, uint256 aToken1Amt) external {
        // assume
        uint256 lToken0Amt = bound(aToken0Amt, 1, 1e6);
        uint256 lToken1Amt = bound(aToken1Amt, 1, 6e6);

        // act - does not revert in this case, but instead just returns 1e18
        uint256 lPrice = StableOracleMath.calcSpotPrice(_defaultAmp, lToken0Amt, lToken1Amt);

        // assert
        assertEq(lPrice, 1e18);
    }

    function testEstimated(uint256 aReserve0, uint256 aReserve1) external {
        // assume
        uint256 lReserve0 = bound(aReserve0, 1e18, 1000e18);
        uint256 lReserve1 = bound(aReserve1, 1e18, 1000e18);

        // act
        uint256 lSpotEstimated = estimateSpotPrice(lReserve0, lReserve1, 1, 1, _defaultAmp * 2);
        uint256 lSpotCalculated = StableOracleMath.calcSpotPrice(_defaultAmp, lReserve0, lReserve1);

        // assert
        assertApproxEqRel(lSpotEstimated, lSpotCalculated, 0.000001e18); // 1% of 1bp, or a 0.0001% error
    }
}
