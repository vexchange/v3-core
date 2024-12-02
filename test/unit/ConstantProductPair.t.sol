pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";
import { Math } from "test/__fixtures/Math.sol";
import { stdStorage } from "forge-std/Test.sol";

import { MintableERC20 } from "test/__fixtures/MintableERC20.sol";
import { AssetManager } from "test/__mocks/AssetManager.sol";

import { LogCompression } from "src/libraries/LogCompression.sol";
import { Observation, RGT } from "src/ReservoirPair.sol";
import { IERC20 } from "src/GenericFactory.sol";
import { ConstantProductPair, IReservoirCallee } from "src/curve/constant-product/ConstantProductPair.sol";

contract ConstantProductPairTest is BaseTest, IReservoirCallee {
    using stdStorage for StdStorage;

    event Burn(address indexed sender, uint256 amount0, uint256 amount1);

    AssetManager private _manager = new AssetManager();

    function(address, int256, int256, bytes calldata) internal private _validateCallback;

    function reservoirCall(address aSwapper, int256 lToken0, int256 lToken1, bytes calldata aData) external {
        _validateCallback(aSwapper, lToken0, lToken1, aData);
    }

    function _calculateOutput(uint256 aReserveIn, uint256 aReserveOut, uint256 aAmountIn, uint256 aFee)
        private
        view
        returns (uint256 rExpectedOut)
    {
        uint256 lMaxFee = _constantProductPair.FEE_ACCURACY();
        uint256 lAmountInWithFee = aAmountIn * (lMaxFee - aFee);
        uint256 lNumerator = lAmountInWithFee * aReserveOut;
        uint256 lDenominator = aReserveIn * lMaxFee + lAmountInWithFee;

        rExpectedOut = lNumerator / lDenominator;
    }

    function _calculateInput(uint256 aReserveIn, uint256 aReserveOut, uint256 aAmountOut, uint256 aFee)
        private
        view
        returns (uint256 rExpectedIn)
    {
        uint256 lMaxFee = _constantProductPair.FEE_ACCURACY();
        uint256 lNumerator = aReserveIn * aAmountOut * lMaxFee;
        uint256 lDenominator = (aReserveOut - aAmountOut) * (lMaxFee - aFee);
        rExpectedIn = lNumerator / lDenominator + 1;
    }

    function _getToken0Token1(address aTokenA, address aTokenB)
        private
        pure
        returns (address rToken0, address rToken1)
    {
        (rToken0, rToken1) = aTokenA < aTokenB ? (aTokenA, aTokenB) : (aTokenB, aTokenA);
    }

    function testMint() public {
        // arrange
        uint256 lTotalSupplyLpToken = _constantProductPair.totalSupply();
        uint256 lLiquidityToAdd = 5e18;
        (uint256 reserve0,,,) = _constantProductPair.getReserves();

        // act
        _tokenA.mint(address(_constantProductPair), lLiquidityToAdd);
        _tokenB.mint(address(_constantProductPair), lLiquidityToAdd);
        _constantProductPair.mint(address(this));

        // assert
        uint256 lAdditionalLpTokens = lLiquidityToAdd * lTotalSupplyLpToken / reserve0;
        assertEq(_constantProductPair.balanceOf(address(this)), lAdditionalLpTokens);
    }

    function testMint_InitialMint() public {
        // assert
        uint256 lpTokenBalance = _constantProductPair.balanceOf(_alice);
        uint256 lExpectedLpTokenBalance =
            Math.sqrt(Constants.INITIAL_MINT_AMOUNT ** 2) - _constantProductPair.MINIMUM_LIQUIDITY();
        assertEq(lpTokenBalance, lExpectedLpTokenBalance);
    }

    function testMint_JustAboveMinimumLiquidity() public {
        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenC), 0));

        // act
        _tokenA.mint(address(lPair), 1001);
        _tokenC.mint(address(lPair), 1001);
        lPair.mint(address(this));

        // assert
        assertEq(lPair.balanceOf(address(this)), 1);
    }

    function testMint_MinimumLiquidity() public {
        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenC), 0));
        _tokenA.mint(address(lPair), 1000);
        _tokenC.mint(address(lPair), 1000);

        // act & assert
        vm.expectRevert("CP: INSUFFICIENT_LIQ_MINTED");
        lPair.mint(address(this));
    }

    function testMint_UnderMinimumLiquidity() public {
        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenC), 0));
        _tokenA.mint(address(lPair), 10);
        _tokenB.mint(address(lPair), 10);

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        lPair.mint(address(this));
    }

    function testSwap() public {
        // arrange
        (uint256 reserve0, uint256 reserve1,,) = _constantProductPair.getReserves();
        uint256 expectedOutput = _calculateOutput(reserve0, reserve1, 1e18, Constants.DEFAULT_SWAP_FEE_CP);

        // act
        address token0;
        address token1;
        (token0, token1) = _getToken0Token1(address(_tokenA), address(_tokenB));

        MintableERC20(token0).mint(address(_constantProductPair), 1e18);
        _constantProductPair.swap(1e18, true, address(this), "");

        // assert
        assertEq(MintableERC20(token1).balanceOf(address(this)), expectedOutput);
        assertEq(MintableERC20(token0).balanceOf(address(this)), 0);
    }

    function _reenterSwap(address aSwapper, int256 aToken0, int256 aToken1, bytes calldata aData) internal {
        assertEq(aSwapper, address(this));
        assertEq(aToken0, -1e18);
        assertApproxEqRel(aToken1, 1e18, 0.013e18);
        assertEq(aData, bytes(hex"00"));

        _constantProductPair.swap(1e18, true, address(this), "");
    }

    function testSwap_Reenter() external {
        // arrange
        _validateCallback = _reenterSwap;
        address lToken0;
        address lToken1;
        (lToken0, lToken1) = _getToken0Token1(address(_tokenA), address(_tokenB));

        // act
        MintableERC20(lToken0).mint(address(_constantProductPair), 1e18);
        vm.expectRevert(RGT.Reentrancy.selector);
        _constantProductPair.swap(1e18, true, address(this), bytes(hex"00"));
    }

    function testSwap_ExtremeAmounts() public {
        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenB), address(_tokenC), 0));
        uint256 lSwapAmount = 0.001e18;
        uint256 lAmountB = type(uint104).max - lSwapAmount;
        uint256 lAmountC = type(uint104).max;
        _tokenB.mint(address(lPair), lAmountB);
        _tokenC.mint(address(lPair), lAmountC);
        lPair.mint(address(this));

        // act
        _tokenB.mint(address(lPair), lSwapAmount);
        lPair.swap(
            lPair.token0() == IERC20(address(_tokenB)) ? int256(lSwapAmount) : -int256(lSwapAmount),
            true,
            address(this),
            bytes("")
        );

        // assert
        assertEq(_tokenB.balanceOf(address(lPair)), type(uint104).max);
        assertEq(_tokenC.balanceOf(address(this)), 0.000997e18);
    }

    function testSwap_MinInt256() external {
        // arrange
        int256 lSwapAmt = type(int256).min;

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        _constantProductPair.swap(lSwapAmt, true, address(this), "");
    }

    function testSwap_ExactOutExceedReserves() public {
        // act & assert
        vm.expectRevert("CP: NOT_ENOUGH_LIQ");
        _constantProductPair.swap(int256(Constants.INITIAL_MINT_AMOUNT), false, address(this), bytes(""));

        vm.expectRevert("CP: NOT_ENOUGH_LIQ");
        _constantProductPair.swap(int256(Constants.INITIAL_MINT_AMOUNT + 1), false, address(this), bytes(""));

        vm.expectRevert("CP: NOT_ENOUGH_LIQ");
        _constantProductPair.swap(-int256(Constants.INITIAL_MINT_AMOUNT), false, address(this), bytes(""));

        vm.expectRevert("CP: NOT_ENOUGH_LIQ");
        _constantProductPair.swap(-int256(Constants.INITIAL_MINT_AMOUNT + 1), false, address(this), bytes(""));
    }

    function testSwap_ExactOut(uint256 aAmountOut) public {
        // assume
        uint256 lMinNewReservesOut = Constants.INITIAL_MINT_AMOUNT ** 2 / type(uint104).max + 1;
        // this amount makes the new reserve of the input token stay within uint104 and not overflow
        uint256 lMaxOutputAmt = Constants.INITIAL_MINT_AMOUNT - lMinNewReservesOut;
        uint256 lAmountOut = bound(aAmountOut, 1, lMaxOutputAmt);

        // arrange
        vm.prank(address(_factory));
        _constantProductPair.setCustomSwapFee(0);
        (uint256 lReserve0, uint256 lReserve1,,) = _constantProductPair.getReserves();
        uint256 lAmountIn = _calculateInput(lReserve0, lReserve1, lAmountOut, _constantProductPair.swapFee());

        // act - exact token1 out
        _tokenA.mint(address(_constantProductPair), lAmountIn);
        uint256 lActualAmountOut = _constantProductPair.swap(-int256(lAmountOut), false, address(this), bytes(""));

        // assert
        assertGt(lAmountIn, lAmountOut);
        assertEq(lActualAmountOut, lAmountOut);
        assertEq(_tokenB.balanceOf(address(this)), lAmountOut);
    }

    function testSwap_ExactOut_NewReservesExceedUint104() public {
        // arrange
        vm.prank(address(_factory));
        _constantProductPair.setCustomSwapFee(0);
        uint256 lMinNewReservesOut = Constants.INITIAL_MINT_AMOUNT ** 2 / type(uint104).max + 1;
        uint256 lMaxOutputAmt = Constants.INITIAL_MINT_AMOUNT - lMinNewReservesOut;
        // 1 more than the max
        uint256 lAmountOut = lMaxOutputAmt + 1;
        (uint256 lReserve0, uint256 lReserve1,,) = _constantProductPair.getReserves();
        uint256 lAmountIn = _calculateInput(lReserve0, lReserve1, lAmountOut, _constantProductPair.swapFee());

        // act & assert
        _tokenA.mint(address(_constantProductPair), lAmountIn);
        vm.expectRevert("RP: OVERFLOW");
        _constantProductPair.swap(-int256(lAmountOut), false, address(this), bytes(""));
    }

    function testBurn() public {
        // arrange
        vm.startPrank(_alice);
        uint256 lLpTokenBalance = _constantProductPair.balanceOf(_alice);
        uint256 lLpTokenTotalSupply = _constantProductPair.totalSupply();
        (uint256 lReserve0, uint256 lReserve1,,) = _constantProductPair.getReserves();

        // act
        _constantProductPair.transfer(address(_constantProductPair), _constantProductPair.balanceOf(_alice));
        _constantProductPair.burn(_alice);
        vm.stopPrank();

        // assert
        assertEq(_constantProductPair.balanceOf(_alice), 0);
        (address lToken0, address lToken1) = _getToken0Token1(address(_tokenA), address(_tokenB));
        assertEq(ConstantProductPair(lToken0).balanceOf(_alice), lLpTokenBalance * lReserve0 / lLpTokenTotalSupply);
        assertEq(ConstantProductPair(lToken1).balanceOf(_alice), lLpTokenBalance * lReserve1 / lLpTokenTotalSupply);
    }

    function testBurn_Zero() public {
        // act
        vm.expectEmit(true, false, false, true);
        emit Burn(address(this), 0, 0);
        _constantProductPair.burn(address(this));

        // assert
        assertEq(_tokenA.balanceOf(address(this)), 0);
        assertEq(_tokenB.balanceOf(address(this)), 0);
        assertEq(_tokenA.balanceOf(address(_constantProductPair)), Constants.INITIAL_MINT_AMOUNT);
        assertEq(_tokenB.balanceOf(address(_constantProductPair)), Constants.INITIAL_MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ORACLE
    //////////////////////////////////////////////////////////////////////////*/

    function testOracle_CorrectPrice(uint32 aNewStartTime) public randomizeStartTime(aNewStartTime) {
        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenB), address(_tokenC), 0));
        _tokenB.mint(address(lPair), Constants.INITIAL_MINT_AMOUNT);
        _tokenC.mint(address(lPair), Constants.INITIAL_MINT_AMOUNT);
        lPair.mint(_alice);

        _stepTime(5);

        // act
        uint256 lAmountToSwap = 1e18;
        _tokenB.mint(address(lPair), lAmountToSwap);
        lPair.swap(
            lPair.token0() == IERC20(address(_tokenB)) ? int256(lAmountToSwap) : -int256(lAmountToSwap),
            true,
            address(this),
            ""
        ); // obs0 written here

        (uint256 lReserve0_1, uint256 lReserve1_1,,) = lPair.getReserves();
        uint256 lPrice1 = lReserve1_1 * 1e18 / lReserve0_1;
        _stepTime(5);

        _tokenB.mint(address(lPair), lAmountToSwap);
        lPair.swap(
            lPair.token0() == IERC20(address(_tokenB)) ? int256(lAmountToSwap) : -int256(lAmountToSwap),
            true,
            address(this),
            ""
        ); // obs1 written here
        (uint256 lReserve0_2, uint256 lReserve1_2,,) = lPair.getReserves();
        uint256 lPrice2 = lReserve1_2 * 1e18 / lReserve0_2;

        _stepTime(5);
        lPair.sync(); // obs2 written here

        // assert
        Observation memory lObs0 = lPair.observation(0);
        Observation memory lObs1 = lPair.observation(1);
        Observation memory lObs2 = lPair.observation(2);

        assertApproxEqRel(
            LogCompression.fromLowResLog(
                (lObs1.logAccRawPrice - lObs0.logAccRawPrice) / int32(lObs1.timestamp - lObs0.timestamp)
            ),
            lPrice1,
            0.0001e18
        );
        assertApproxEqRel(
            LogCompression.fromLowResLog(
                (lObs2.logAccRawPrice - lObs0.logAccRawPrice) / int32(lObs2.timestamp - lObs0.timestamp)
            ),
            Math.sqrt(lPrice1 * lPrice2),
            0.0001e18
        );
    }

    function testOracle_CorrectPriceDiffDecimals(uint32 aNewStartTime) public randomizeStartTime(aNewStartTime) {
        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenD), 0));
        _tokenA.mint(address(lPair), 100e18);
        _tokenD.mint(address(lPair), 50e6);
        lPair.mint(address(this));

        // act
        _stepTime(5);
        lPair.sync();
        _stepTime(5);
        lPair.sync();

        // assert
        Observation memory lObs0 = lPair.observation(0);
        Observation memory lObs1 = lPair.observation(1);
        assertApproxEqRel(
            LogCompression.fromLowResLog((lObs1.logAccRawPrice - lObs0.logAccRawPrice) / 5), 0.5e18, 0.0001e18
        );
    }

    function testOracle_SimplePrices(uint32 aNewStartTime) external randomizeStartTime(aNewStartTime) {
        // prices = [1, 4, 16]
        // geo_mean = sqrt3(1 * 4 * 16) = 4

        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenB), address(_tokenC), 0));
        _tokenB.mint(address(lPair), Constants.INITIAL_MINT_AMOUNT);
        _tokenC.mint(address(lPair), Constants.INITIAL_MINT_AMOUNT);
        lPair.mint(address(this));

        vm.prank(address(_factory));
        lPair.setCustomSwapFee(0);

        // price = 1 for 10 seconds
        _stepTime(10);

        // act
        // price = 4 for 10 seconds
        _tokenB.mint(address(lPair), 100e18);
        lPair.swap(lPair.token0() == IERC20(address(_tokenB)) ? int256(100e18) : int256(-100e18), true, _bob, ""); // obs0 is written here
        _stepTime(10);

        // price = 16 for 10 seconds
        _tokenB.mint(address(lPair), 200e18);
        lPair.swap(lPair.token0() == IERC20(address(_tokenB)) ? int256(200e18) : int256(-200e18), true, _bob, ""); // obs1 is written here
        _stepTime(10);

        lPair.sync(); // obs2 is written here

        // assert
        Observation memory lObs0 = lPair.observation(0);
        Observation memory lObs1 = lPair.observation(1);
        Observation memory lObs2 = lPair.observation(2);

        assertEq(lObs0.logAccRawPrice, LogCompression.toLowResLog(1e18) * 10, "1");
        assertEq(
            lObs1.logAccRawPrice, LogCompression.toLowResLog(1e18) * 10 + LogCompression.toLowResLog(4e18) * 10, "2"
        );
        assertEq(
            lObs2.logAccRawPrice,
            LogCompression.toLowResLog(1e18) * 10 + LogCompression.toLowResLog(4e18) * 10
                + LogCompression.toLowResLog(16e18) * 10,
            "3"
        );

        assertEq(lObs0.logInstantRawPrice, LogCompression.toLowResLog(4e18));
        assertEq(lObs1.logInstantRawPrice, LogCompression.toLowResLog(16e18));
        assertEq(lObs2.logInstantRawPrice, LogCompression.toLowResLog(16e18)); // spot price has not changed between obs1 and obs2

        // Price for observation window 0-1
        assertApproxEqRel(
            LogCompression.fromLowResLog(
                (lObs1.logAccRawPrice - lObs0.logAccRawPrice) / int32(lObs1.timestamp - lObs0.timestamp)
            ),
            4e18,
            0.0001e18
        );
        // Price for observation window 1-2
        assertApproxEqRel(
            LogCompression.fromLowResLog(
                (lObs2.logAccRawPrice - lObs1.logAccRawPrice) / int32(lObs2.timestamp - lObs1.timestamp)
            ),
            16e18,
            0.0001e18
        );
        // Price for observation window 0-2
        assertApproxEqRel(
            LogCompression.fromLowResLog(
                (lObs2.logAccRawPrice - lObs0.logAccRawPrice) / int32(lObs2.timestamp - lObs0.timestamp)
            ),
            8e18,
            0.0001e18
        );
    }

    function testOracle_ClampedPrice_NoDiffWithinLimit() external {
        // arrange
        _stepTime(5);
        uint256 lSwapAmt = 0.12e18;
        _tokenB.mint(address(_constantProductPair), lSwapAmt);
        _constantProductPair.swap(-int256(lSwapAmt), true, address(this), bytes(""));

        // act
        _stepTime(5);
        _constantProductPair.sync();

        // assert
        Observation memory lObs1 = _constantProductPair.observation(1);
        // no diff between raw and clamped prices
        assertEq(lObs1.logAccClampedPrice, lObs1.logAccRawPrice);
        assertEq(lObs1.logInstantClampedPrice, lObs1.logInstantRawPrice);
        assertLt(LogCompression.fromLowResLog(lObs1.logInstantClampedPrice), 1.0025e18);
    }

    function testOracle_ClampedPrice_AtLimit() external {
        // arrange
        _stepTime(5);
        // this swap amount would be such that the resulting spot price would be right at the limit of the clamp
        uint256 lSwapAmt = 0.125109637135501e18;
        _tokenB.mint(address(_constantProductPair), lSwapAmt);
        _constantProductPair.swap(-int256(lSwapAmt), true, address(this), bytes(""));

        // act
        _stepTime(5);
        _constantProductPair.sync();

        // assert
        Observation memory lObs1 = _constantProductPair.observation(1);
        // no diff between raw and clamped prices
        assertEq(lObs1.logAccClampedPrice, lObs1.logAccRawPrice);
        assertEq(lObs1.logInstantClampedPrice, lObs1.logInstantRawPrice);
    }

    function testOracle_ClampedPrice_OverLimit() external {
        // arrange
        _stepTime(5);
        // this swap amount would be such that the resulting spot price would be just over the limit of the clamp
        uint256 lSwapAmt = 0.127809637135502e18;
        _tokenB.mint(address(_constantProductPair), lSwapAmt);
        _constantProductPair.swap(-int256(lSwapAmt), true, address(this), bytes(""));

        // act
        _stepTime(5);
        _constantProductPair.sync();

        // assert
        Observation memory lObs1 = _constantProductPair.observation(1);
        assertGt(lObs1.logAccRawPrice, lObs1.logAccClampedPrice);
        assertApproxEqRel(LogCompression.fromLowResLog(lObs1.logInstantClampedPrice), 1.0025e18, 0.0002e18); // 0.02% error
    }
}
