pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { ReservoirPair, Observation } from "src/ReservoirPair.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { ConstantProductOracleMath } from "src/libraries/ConstantProductOracleMath.sol";
import { StableOracleMath } from "src/libraries/StableOracleMath.sol";
import { Buffer } from "src/libraries/Buffer.sol";
import { GenericFactory } from "src/GenericFactory.sol";
import { Constants } from "src/Constants.sol";

contract OracleWriterTest is BaseTest {
    using FactoryStoreLib for GenericFactory;

    event OracleCallerUpdated(address oldCaller, address newCaller);
    event MaxChangeRateUpdated(uint256 oldMaxChangeRate, uint256 newMaxChangeRate);

    ReservoirPair[] internal _pairs;
    ReservoirPair internal _pair;

    function setUp() public {
        _pairs.push(_constantProductPair);
        _pairs.push(_stablePair);
    }

    modifier allPairs() {
        for (uint256 i = 0; i < _pairs.length; ++i) {
            uint256 lBefore = vm.snapshot();
            _pair = _pairs[i];
            _;
            vm.revertTo(lBefore);
        }
    }

    // returns spot price for a given pair
    function _calcPriceForCurve(ReservoirPair aPair) internal view returns (uint256 rSpotPrice, int256 rLogSpotPrice) {
        (uint256 lReserve0, uint256 lReserve1,,) = aPair.getReserves();
        uint256 lAdjustedReserves0 = lReserve0 * aPair.token0PrecisionMultiplier();
        uint256 lAdjustedReserves1 = lReserve1 * aPair.token1PrecisionMultiplier();

        if (aPair == _constantProductPair) {
            (rSpotPrice, rLogSpotPrice) = ConstantProductOracleMath.calcLogPrice(lAdjustedReserves0, lAdjustedReserves1);
        } else if (aPair == _stablePair) {
            (rSpotPrice, rLogSpotPrice) =
                StableOracleMath.calcLogPrice(_stablePair.getCurrentAPrecise(), lAdjustedReserves0, lAdjustedReserves1);
        }
    }

    function testWriteObservations() external allPairs {
        // arrange
        // swap 1
        _stepTime(1);
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        _tokenA.mint(address(_pair), 5e18);
        _pair.swap(5e18, true, address(this), "");

        // swap 2
        _stepTime(1);
        (lReserve0, lReserve1,,) = _pair.getReserves();
        _tokenA.mint(address(_pair), 5e18);
        _pair.swap(5e18, true, address(this), "");

        // sanity
        (,,, uint16 lIndex) = _pair.getReserves();
        assertEq(lIndex, 1);

        Observation memory lObs = _oracleCaller.observation(_pair, 0);
        assertEq(lObs.logAccRawPrice, 0);
        assertEq(lObs.logAccClampedPrice, 0);
        assertNotEq(lObs.logInstantRawPrice, 0);
        assertNotEq(lObs.logInstantClampedPrice, 0);
        assertNotEq(lObs.timestamp, 0);

        lObs = _oracleCaller.observation(_pair, 1);
        assertNotEq(lObs.logAccRawPrice, 0);
        assertNotEq(lObs.logAccClampedPrice, 0);
        assertNotEq(lObs.logInstantRawPrice, 0);
        assertNotEq(lObs.logInstantClampedPrice, 0);
        assertNotEq(lObs.timestamp, 0);

        // act
        _writeObservation(_pair, 0, int24(123), int24(-456), int88(789), int56(-1011), uint32(666));

        // assert
        lObs = _oracleCaller.observation(_pair, 0);
        assertEq(lObs.logInstantRawPrice, int24(123));
        assertEq(lObs.logInstantClampedPrice, int24(-456));
        assertEq(lObs.logAccRawPrice, int88(789));
        assertEq(lObs.logAccClampedPrice, int88(-1011));
        assertEq(lObs.timestamp, uint32(666));

        lObs = _oracleCaller.observation(_pair, 1);
        assertNotEq(lObs.logAccRawPrice, 0);
        assertNotEq(lObs.logAccClampedPrice, 0);
        assertNotEq(lObs.timestamp, 0);
    }

    function testObservation_NotOracleCaller(uint256 aIndex) external allPairs {
        // assume
        uint256 lIndex = bound(aIndex, 0, type(uint16).max);

        // act & assert
        vm.expectRevert("RP: NOT_ORACLE_CALLER");
        _pair.observation(lIndex);
    }

    function testUpdateOracleCaller() external allPairs {
        // arrange
        address lNewOracleCaller = address(0x555);
        _factory.write("Shared::oracleCaller", lNewOracleCaller);

        // act
        vm.expectEmit(false, false, false, true);
        emit OracleCallerUpdated(address(_oracleCaller), lNewOracleCaller);
        _pair.updateOracleCaller();

        // assert
        assertEq(_pair.oracleCaller(), lNewOracleCaller);
    }

    function testUpdateOracleCaller_NoChange() external allPairs {
        // arrange
        address lBefore = _pair.oracleCaller();

        // act
        _pair.updateOracleCaller();

        // assert
        assertEq(_pair.oracleCaller(), lBefore);
    }

    function testMaxChangeRate_Default() external allPairs {
        // assert
        assertEq(_pair.maxChangeRate(), Constants.DEFAULT_MAX_CHANGE_RATE);
    }

    function testSetMaxChangeRate_OnlyFactory() external allPairs {
        // act & assert
        vm.expectRevert();
        _pair.setMaxChangeRate(1);

        vm.prank(address(_factory));
        vm.expectEmit(false, false, false, true);
        emit MaxChangeRateUpdated(Constants.DEFAULT_MAX_CHANGE_RATE, 1);
        _pair.setMaxChangeRate(1);
        assertEq(_pair.maxChangeRate(), 1);
    }

    function testSetMaxChangeRate_TooLow() external allPairs {
        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert("RP: INVALID_CHANGE_PER_SECOND");
        _pair.setMaxChangeRate(0);
    }

    function testSetMaxChangeRate_TooHigh(uint256 aMaxChangeRate) external allPairs {
        // assume
        uint256 lMaxChangeRate = bound(aMaxChangeRate, 0.01e18 + 1, type(uint256).max);

        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert("RP: INVALID_CHANGE_PER_SECOND");
        _pair.setMaxChangeRate(lMaxChangeRate);
    }

    function testOracle_NoWriteInSameTimestamp() public allPairs {
        // arrange
        (,,, uint16 lInitialIndex) = _pair.getReserves();
        uint256 lAmountToSwap = 1e17;

        // act
        _tokenA.mint(address(_pair), lAmountToSwap);
        _pair.swap(int256(lAmountToSwap), true, address(this), "");

        vm.prank(_alice);
        _pair.transfer(address(_pair), 1e18);
        _pair.burn(address(this));

        _pair.sync();

        // assert
        (,,, uint16 lFinalIndex) = _pair.getReserves();
        assertEq(lFinalIndex, lInitialIndex);
    }

    // instant price should update when multiple activities happen in the same block
    function testUpdateOracle_MintThenSwapSameBlock() external allPairs {
        // arrange
        uint256 lOriginalPrice = 1e18;
        uint256 lSwapAmt = 10e18;

        // sanity
        (,,, uint16 lIndex) = _pair.getReserves();
        Observation memory lObs = _oracleCaller.observation(_pair, lIndex);
        assertEq(lIndex, Buffer.SIZE - 1);
        assertEq(LogCompression.fromLowResLog(lObs.logInstantRawPrice), lOriginalPrice, "instant 1");

        // act
        _tokenA.mint(address(_pair), lSwapAmt);
        _pair.swap(int256(lSwapAmt), true, address(this), "");

        // assert
        (,,, lIndex) = _pair.getReserves();
        lObs = _oracleCaller.observation(_pair, lIndex);

        assertEq(lIndex, Buffer.SIZE - 1);
        assertNotEq(LogCompression.fromLowResLog(lObs.logInstantRawPrice), lOriginalPrice);
        assertNotEq(LogCompression.fromLowResLog(lObs.logInstantClampedPrice), lOriginalPrice);

        (, int256 lLogSpotPrice) = _calcPriceForCurve(_pair);
        assertEq(lObs.logInstantRawPrice, lLogSpotPrice);
        assertEq(lObs.logInstantClampedPrice, lLogSpotPrice);
    }

    // accumulator should not update but instant prices should update
    function testUpdateOracle_MultipleSwapsSameBlock() external allPairs {
        // arrange
        _stepTime(5);
        uint256 lSwapAmt = 5e18;

        // act
        // first swap
        _tokenA.mint(address(_pair), lSwapAmt);
        _pair.swap(int256(lSwapAmt), true, address(this), "");

        // sanity - observation after first swap
        (,,, uint16 lIndex) = _pair.getReserves();
        assertEq(lIndex, 0);
        Observation memory lObs0 = _oracleCaller.observation(_pair, lIndex);

        // second swap
        _tokenA.mint(address(_pair), lSwapAmt);
        _pair.swap(int256(lSwapAmt), true, address(this), "");

        Observation memory lObs1 = _oracleCaller.observation(_pair, lIndex);

        // third swap
        _tokenA.mint(address(_pair), lSwapAmt);
        _pair.swap(int256(lSwapAmt), true, address(this), "");

        Observation memory lObs2 = _oracleCaller.observation(_pair, lIndex);

        // assert
        assertEq(lObs0.timestamp, lObs1.timestamp);
        assertEq(lObs1.timestamp, lObs2.timestamp);
        assertEq(lObs0.logAccRawPrice, lObs1.logAccRawPrice);
        assertEq(lObs1.logAccRawPrice, lObs2.logAccRawPrice);
        assertEq(lObs0.logAccClampedPrice, lObs1.logAccClampedPrice);
        assertEq(lObs1.logAccClampedPrice, lObs2.logAccClampedPrice);
        assertNotEq(lObs0.logInstantRawPrice, lObs1.logInstantRawPrice);
        assertNotEq(lObs1.logInstantRawPrice, lObs2.logInstantRawPrice);
    }

    function testUpdateOracle_AccumulateOldPricesNotNew() external allPairs {
        // arrange
        uint256 lJumpAhead = 10;
        uint256 lOriginalPrice = 1e18; // both tokenA and B are INITIAL_MINT_AMOUNT
        (uint104 lReserve0,,,) = _pair.getReserves();
        assertEq(lReserve0, Constants.INITIAL_MINT_AMOUNT);
        _tokenA.mint(address(_pair), 10e18);

        // act - call sync to trigger a write to the oracle
        _stepTime(lJumpAhead);
        _pair.sync();

        // assert - make sure that the accumulator accumulated with the previous prices, not the new prices
        (uint256 lNewReserve0,,, uint16 lIndex) = _pair.getReserves();

        Observation memory lObs = _oracleCaller.observation(_pair, lIndex);
        assertEq(lNewReserve0, 110e18);
        assertApproxEqRel(
            LogCompression.fromLowResLog(lObs.logAccRawPrice / int88(int256(lJumpAhead))), lOriginalPrice, 0.0001e18
        );
    }

    function testUpdateOracle_LatestTimestampWritten(uint256 aJumpAhead) external allPairs {
        // assume
        uint256 lJumpAhead = bound(aJumpAhead, 10, type(uint16).max);

        // arrange
        uint256 lStartingTimestamp = block.timestamp;
        _stepTime(lJumpAhead);

        // act
        _tokenA.mint(address(_pair), 5e18);
        _pair.swap(5e18, true, address(this), "");

        // assert
        (,,, uint16 lIndex) = _pair.getReserves();
        Observation memory lObs = _oracleCaller.observation(_pair, lIndex);
        assertEq(lObs.timestamp, lStartingTimestamp + lJumpAhead);
    }

    function testOracle_SameReservesDiffPrice(uint32 aNewStartTime) external randomizeStartTime(aNewStartTime) {
        // arrange
        ConstantProductPair lCP = ConstantProductPair(_createPair(address(_tokenB), address(_tokenC), 0));
        StablePair lSP = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));

        _tokenB.mint(address(lCP), 100e18);
        _tokenC.mint(address(lCP), 10e18);
        lCP.mint(address(this));

        _tokenB.mint(address(lSP), 100e18);
        _tokenC.mint(address(lSP), 10e18);
        lSP.mint(address(this));

        // act
        _stepTime(12);
        lCP.sync();
        lSP.sync();
        _stepTime(12);
        lCP.sync();
        lSP.sync();

        // assert
        Observation memory lObsCP1 = _oracleCaller.observation(lCP, 1);
        Observation memory lObsSP1 = _oracleCaller.observation(lSP, 1);
        if (lCP.token0() == IERC20(address(_tokenB))) {
            assertGt(lObsSP1.logAccRawPrice, lObsCP1.logAccRawPrice);
        } else {
            assertGt(lObsCP1.logAccRawPrice, lObsSP1.logAccRawPrice);
        }
    }

    // this test case shows how different reserves in respective curves can result in the same price
    // and that for an oracle consumer, it would choose CP as the more trustworthy source as it has greater liquidity
    function testOracle_SamePriceDiffLiq(uint32 aNewStartTime) external randomizeStartTime(aNewStartTime) {
        // arrange
        ConstantProductPair lCP = ConstantProductPair(_createPair(address(_tokenB), address(_tokenC), 0));
        StablePair lSP = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));

        _tokenB.mint(address(lCP), 100e18);
        _tokenC.mint(address(lCP), 50e18);
        lCP.mint(address(this));

        _tokenB.mint(address(lSP), 100e18);
        _tokenC.mint(address(lSP), 1.1061e18);
        lSP.mint(address(this));

        // act
        _stepTime(12);
        lCP.sync();
        lSP.sync();
        _stepTime(12);
        lCP.sync();
        lSP.sync();

        // sanity - ensure that two oracle observations have been written at slots 1 and 2
        (,,, uint16 lIndex) = lCP.getReserves();
        assertEq(lIndex, 1);
        (,,, lIndex) = lSP.getReserves();
        assertEq(lIndex, 1);

        // assert
        Observation memory lObs0CP = _oracleCaller.observation(lCP, 0);
        Observation memory lObs1CP = _oracleCaller.observation(lCP, 1);
        Observation memory lObs0SP = _oracleCaller.observation(lSP, 0);
        Observation memory lObs1SP = _oracleCaller.observation(lSP, 1);
        uint256 lUncompressedPriceCP =
            LogCompression.fromLowResLog((lObs1CP.logAccRawPrice - lObs0CP.logAccRawPrice) / 12);
        uint256 lUncompressedPriceSP =
            LogCompression.fromLowResLog((lObs1SP.logAccRawPrice - lObs0SP.logAccRawPrice) / 12);
        assertEq(lUncompressedPriceCP, lUncompressedPriceSP);
    }

    // this test case demonstrates how the two curves can have identical liquidity and price recorded by the oracle
    function testOracle_SamePriceSameLiq(uint32 aNewStartTime) external randomizeStartTime(aNewStartTime) {
        // arrange
        ConstantProductPair lCP = ConstantProductPair(_createPair(address(_tokenB), address(_tokenC), 0));
        StablePair lSP = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));

        _tokenB.mint(address(lCP), 7.436733153744324e18 * 2);
        _tokenC.mint(address(lCP), 7.436733153744324e18);
        lCP.mint(address(this));

        _tokenB.mint(address(lSP), 100e18);
        _tokenC.mint(address(lSP), 1.1061e18);
        lSP.mint(address(this));

        // act
        _stepTime(12);
        lCP.sync();
        lSP.sync();
        _stepTime(12);
        lCP.sync();
        lSP.sync();
        Observation memory lObsCP0 = _oracleCaller.observation(lCP, 0);
        Observation memory lObsCP1 = _oracleCaller.observation(lCP, 1);
        Observation memory lObsSP0 = _oracleCaller.observation(lSP, 0);
        Observation memory lObsSP1 = _oracleCaller.observation(lSP, 1);
        uint256 lUncompressedPriceCP =
            LogCompression.fromLowResLog((lObsCP1.logAccRawPrice - lObsCP0.logAccRawPrice) / 12);
        uint256 lUncompressedPriceSP =
            LogCompression.fromLowResLog((lObsSP1.logAccRawPrice - lObsSP0.logAccRawPrice) / 12);
        assertEq(lUncompressedPriceCP, lUncompressedPriceSP);
    }

    function testOracle_WrapsAroundAfterFull() public allPairs {
        // arrange
        uint256 lAmountToSwap = 1e15;
        uint256 lMaxObservations = 2 ** 16;

        // act
        for (uint256 i = 0; i < lMaxObservations + 4; ++i) {
            _stepTime(5);
            _tokenA.mint(address(_pair), lAmountToSwap);
            _pair.swap(int256(lAmountToSwap), true, address(this), "");
        }

        // assert
        (,,, uint16 lIndex) = _pair.getReserves();
        assertEq(lIndex, 3);
    }

    function testOracle_OverflowAccPrice(uint32 aNewStartTime) public randomizeStartTime(aNewStartTime) allPairs {
        // assume
        vm.assume(aNewStartTime >= 1);

        // arrange - make the last observation close to overflowing
        (,,, uint16 lIndex) = _stablePair.getReserves();
        _writeObservation(
            _stablePair, lIndex, 1e3, 1e3, type(int88).max, type(int88).max, uint32(block.timestamp % 2 ** 31)
        );
        Observation memory lPrevObs = _oracleCaller.observation(_stablePair, lIndex);

        // act
        uint256 lAmountToSwap = 5e18;
        _tokenB.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(-int256(lAmountToSwap), true, address(this), "");

        _stepTime(5);
        _stablePair.sync();

        // assert - when it overflows it goes from a very positive number to a very negative number
        (,,, lIndex) = _stablePair.getReserves();
        Observation memory lCurrObs = _oracleCaller.observation(_stablePair, lIndex);
        assertLt(lCurrObs.logAccRawPrice, lPrevObs.logAccRawPrice);
    }

}
