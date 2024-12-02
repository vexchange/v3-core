pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { SafeCast } from "@openzeppelin/utils/math/SafeCast.sol";
import { MathUtils } from "src/libraries/MathUtils.sol";
import { ReservoirPair, IERC20 } from "src/ReservoirPair.sol";
import { AssetManager } from "test/__mocks/AssetManager.sol";

contract AssetManagedPairTest is BaseTest {
    AssetManager private _manager = new AssetManager();

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

    function testSetManager() external allPairs {
        // sanity
        assertEq(address(_pair.assetManager()), address(0));

        // act
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        // assert
        assertEq(address(_pair.assetManager()), address(_manager));
    }

    function testSetManager_CannotMigrateWithManaged(uint256 aAmount0, uint256 aAmount1) external allPairs {
        // assume
        int256 lAmount0 = int256(bound(aAmount0, 1, Constants.INITIAL_MINT_AMOUNT));
        int256 lAmount1 = int256(bound(aAmount1, 1, Constants.INITIAL_MINT_AMOUNT));

        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        _manager.adjustManagement(_pair, lAmount0, lAmount1);

        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert(ReservoirPair.AssetManagerStillActive.selector);
        _pair.setManager(AssetManager(address(0)));
    }

    function testAdjustManagement(uint256 aAmount0, uint256 aAmount1) external allPairs {
        // assume
        int256 lAmount0 = int256(bound(aAmount0, 1, Constants.INITIAL_MINT_AMOUNT));
        int256 lAmount1 = int256(bound(aAmount1, 1, Constants.INITIAL_MINT_AMOUNT));

        // arrange
        vm.prank(address(_factory));
        _pair.setManager(AssetManager(address(this)));

        // act
        _pair.adjustManagement(lAmount0, lAmount1);

        // assert
        assertEq(_tokenA.balanceOf(address(this)), uint256(lAmount0));
        assertEq(_tokenB.balanceOf(address(this)), uint256(lAmount1));
    }

    function testAdjustManagement_Int256Min() external allPairs {
        // arrange
        vm.prank(address(_factory));
        _pair.setManager(AssetManager(address(this)));

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        _pair.adjustManagement(type(int256).min, 0);
    }

    function testAdjustManagement_Uint104() external allPairs {
        // arrange
        vm.prank(address(_factory));
        _pair.setManager(AssetManager(address(this)));
        deal(address(_tokenB), address(_pair), type(uint104).max, true);

        // act
        _pair.adjustManagement(0, int256(uint256(type(uint104).max)));

        // assert
        assertEq(_pair.token1Managed(), type(uint104).max);
        assertEq(_tokenB.balanceOf(address(this)), type(uint104).max);
    }

    function testAdjustManagement_GreaterThanUint104() external allPairs {
        // arrange
        vm.prank(address(_factory));
        _pair.setManager(AssetManager(address(this)));

        // act & assert
        vm.expectPartialRevert(SafeCast.SafeCastOverflowedUintDowncast.selector);
        _pair.adjustManagement(0, int256(uint256(type(uint104).max)) + 1);
    }

    function testAdjustManagement_DecreaseManagement(uint256 aAmount0Decrease, uint256 aAmount1Decrease)
        external
        allPairs
    {
        // assume
        int256 lAmount0Decrease = -int256(bound(aAmount0Decrease, 1, 20e18));
        int256 lAmount1Decrease = -int256(bound(aAmount1Decrease, 1, 20e18));

        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        IERC20 lToken0 = _pair.token0();
        IERC20 lToken1 = _pair.token1();

        // sanity
        (uint104 lReserve0, uint104 lReserve1,,) = _pair.getReserves();
        uint256 lBal0Before = lToken0.balanceOf(address(_pair));
        uint256 lBal1Before = lToken1.balanceOf(address(_pair));

        _manager.adjustManagement(_pair, 20e18, 20e18);

        (uint104 lReserve0_1, uint104 lReserve1_1,,) = _pair.getReserves();
        uint256 lBal0After = lToken0.balanceOf(address(_pair));
        uint256 lBal1After = lToken1.balanceOf(address(_pair));

        assertEq(uint256(lReserve0_1), lReserve0);
        assertEq(uint256(lReserve1_1), lReserve1);
        assertEq(lBal0Before - lBal0After, 20e18);
        assertEq(lBal1Before - lBal1After, 20e18);

        assertEq(lToken0.balanceOf(address(_manager)), 20e18);
        assertEq(lToken1.balanceOf(address(_manager)), 20e18);
        assertEq(_manager.getBalance(_pair, lToken0), 20e18);
        assertEq(_manager.getBalance(_pair, lToken1), 20e18);

        // act
        _manager.adjustManagement(_pair, lAmount0Decrease, lAmount1Decrease);

        (uint104 lReserve0_2, uint104 lReserve1_2,,) = _pair.getReserves();

        // assert
        assertEq(uint256(lReserve0_2), lReserve0);
        assertEq(uint256(lReserve1_2), lReserve1);
        assertEq(lToken0.balanceOf(address(_manager)), 20e18 - uint256(-lAmount0Decrease));
        assertEq(lToken1.balanceOf(address(_manager)), 20e18 - uint256(-lAmount1Decrease));
        assertEq(_manager.getBalance(_pair, lToken0), 20e18 - uint256(-lAmount0Decrease));
        assertEq(_manager.getBalance(_pair, lToken1), 20e18 - uint256(-lAmount1Decrease));
    }

    function testAdjustManagement_KStillHolds(uint256 aMintAmt) external allPairs {
        // assume
        uint256 lMintAmt = bound(aMintAmt, 1, type(uint104).max / 3);

        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        // liquidity prior to adjustManagement
        _tokenA.mint(address(_pair), lMintAmt);
        _tokenB.mint(address(_pair), lMintAmt);
        uint256 lLiq1 = _pair.mint(address(this));

        _manager.adjustManagement(_pair, int256(lMintAmt), int256(lMintAmt));

        // act
        _tokenA.mint(address(_pair), lMintAmt);
        _tokenB.mint(address(_pair), lMintAmt);
        uint256 lLiq2 = _pair.mint(address(this));

        // assert
        assertEq(lLiq1, lLiq2);
    }

    function testAdjustManagement_AdjustAfterLoss(uint256 aNewManagedBalance0) external allPairs {
        // assume
        uint256 lNewManagedBalance0 = bound(aNewManagedBalance0, 1, 10e18);

        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        _manager.adjustManagement(_pair, 10e18, 10e18);
        _manager.adjustBalance(_pair, IERC20(address(_tokenA)), uint104(lNewManagedBalance0)); // some amount lost

        // sanity
        uint256 lTokenAManaged = _manager.getBalance(_pair, IERC20(address(_tokenA)));
        assertEq(lTokenAManaged, lNewManagedBalance0);

        // act
        _manager.adjustManagement(_pair, 20e18, 20e18);
        lTokenAManaged = _manager.getBalance(_pair, IERC20(address(_tokenA)));

        // assert
        assertEq(lTokenAManaged, 20e18 + lNewManagedBalance0);
        assertEq(_pair.token0Managed(), 20e18 + 10e18);
        _pair.sync();
        assertEq(_pair.token0Managed(), 20e18 + lNewManagedBalance0); // number is updated after sync
    }

    function testMint_AfterLoss(uint256 aNewManagedBalance0, uint256 aNewManagedBalance1) external allPairs {
        // assume
        uint256 lNewManagedBalance0 = bound(aNewManagedBalance0, 1, 9e18);
        uint256 lNewManagedBalance1 = bound(aNewManagedBalance1, 1, 9e18);

        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        _manager.adjustManagement(_pair, 10e18, 10e18);
        _manager.adjustBalance(_pair, IERC20(address(_tokenA)), uint104(lNewManagedBalance0)); // some amount lost
        _manager.adjustBalance(_pair, IERC20(address(_tokenB)), uint104(lNewManagedBalance1)); // some amount lost

        // act
        _tokenA.mint(address(_pair), 100e18);
        _tokenB.mint(address(_pair), 100e18);
        _pair.mint(address(this));

        // assert - the minter gets more than in the case where the loss didn't happen
        if (_pair == _constantProductPair) {
            assertGt(_pair.balanceOf(address(this)), 100e18); // sqrt(100e18 * 100e18)
        } else if (_pair == _stablePair) {
            assertGt(_pair.balanceOf(address(this)), 100e18 + 100e18);
        }
    }

    function testBurn_AfterLoss(uint256 aNewManagedBalance0, uint256 aNewManagedBalance1) external allPairs {
        // assume
        uint256 lNewManagedBalance0 = bound(aNewManagedBalance0, 1, 9e18);
        uint256 lNewManagedBalance1 = bound(aNewManagedBalance1, 1, 9e18);

        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        _manager.adjustManagement(_pair, 10e18, 10e18);
        _manager.adjustBalance(_pair, IERC20(address(_tokenA)), uint104(lNewManagedBalance0)); // some amount lost
        _manager.adjustBalance(_pair, IERC20(address(_tokenB)), uint104(lNewManagedBalance1)); // some amount lost

        // act
        uint256 lLpTokenBal = _pair.balanceOf(_alice);
        uint256 lTotalSupply = _pair.totalSupply();
        vm.prank(_alice);
        _pair.transfer(address(_pair), lLpTokenBal);
        _pair.burn(address(this));

        // assert - the burner gets less than in the case where the loss didn't happen
        assertLt(_tokenA.balanceOf(address(this)), lLpTokenBal * Constants.INITIAL_MINT_AMOUNT / lTotalSupply);
        assertLt(_tokenB.balanceOf(address(this)), lLpTokenBal * Constants.INITIAL_MINT_AMOUNT / lTotalSupply);
    }

    function testSwap_AfterLoss(uint256 aNewManagedBalance0) external allPairs {
        // assume
        uint256 lNewManagedBalance0 = bound(aNewManagedBalance0, 1, 9e18);

        // arrange
        int256 lSwapAmt = 1e18;
        uint256 lBefore = vm.snapshotState();
        _tokenA.mint(address(_pair), uint256(lSwapAmt));
        _pair.swap(lSwapAmt, true, address(this), "");
        uint256 lNoLossOutAmt = _tokenB.balanceOf(address(this));
        require(vm.revertToStateAndDelete(lBefore), "revertToStateAndDelete failed");

        vm.prank(address(_factory));
        _pair.setManager(_manager);

        _manager.adjustManagement(_pair, 10e18, 10e18);
        _manager.adjustBalance(_pair, IERC20(address(_tokenA)), uint104(lNewManagedBalance0)); // some amount lost

        _pair.sync();

        // act
        _tokenA.mint(address(_pair), uint256(lSwapAmt));
        _pair.swap(lSwapAmt, true, address(this), "");

        // assert - after losing some token A, it becomes more expensive as it is scarcer so
        // we get more token B out
        uint256 lAfterLossOutAmt = _tokenB.balanceOf(address(this));
        assertGt(lAfterLossOutAmt, lNoLossOutAmt);
    }

    function testSyncManaged_ConstantProduct(uint256 aNewManagedBalance0, uint256 aNewManagedBalance1) external {
        // assume - make them lose at least 1e18
        uint256 lNewManagedBalance0 = bound(aNewManagedBalance0, 1, 19e18);
        uint256 lNewManagedBalance1 = bound(aNewManagedBalance1, 1, 19e18);

        // arrange
        vm.prank(address(_factory));
        _constantProductPair.setManager(_manager);

        IERC20 lToken0 = _constantProductPair.token0();
        IERC20 lToken1 = _constantProductPair.token1();

        _manager.adjustManagement(_constantProductPair, 20e18, 20e18);
        _tokenA.mint(address(_constantProductPair), 10e18);
        _tokenB.mint(address(_constantProductPair), 10e18);
        uint256 lLiq = _constantProductPair.mint(address(this));

        // sanity
        assertEq(lLiq, 10e18); // sqrt 10e18 * 10e18
        assertEq(_tokenA.balanceOf(address(this)), 0);
        assertEq(_tokenB.balanceOf(address(this)), 0);
        assertEq(_manager.getBalance(_constantProductPair, lToken0), 20e18);
        assertEq(_manager.getBalance(_constantProductPair, lToken1), 20e18);

        // act
        _manager.adjustBalance(_constantProductPair, lToken0, uint104(lNewManagedBalance0)); // some amount lost
        _manager.adjustBalance(_constantProductPair, lToken1, uint104(lNewManagedBalance1)); // some amount lost
        _constantProductPair.transfer(address(_constantProductPair), 10e18);
        _constantProductPair.burn(address(this));

        // assert
        assertEq(_manager.getBalance(_constantProductPair, lToken0), lNewManagedBalance0);
        assertEq(_manager.getBalance(_constantProductPair, lToken1), lNewManagedBalance1);
        assertLt(_tokenA.balanceOf(address(this)), 10e18);
        assertLt(_tokenB.balanceOf(address(this)), 10e18);
    }

    function testSyncManaged_Stable(uint256 aNewManagedBalance0, uint256 aNewManagedBalance1) external {
        // assume - make them lose at least 1e18
        uint256 lNewManagedBalance0 = bound(aNewManagedBalance0, 1, 19e18);
        uint256 lNewManagedBalance1 = bound(aNewManagedBalance1, 1, 19e18);

        // arrange
        vm.prank(address(_factory));
        _stablePair.setManager(_manager);

        IERC20 lToken0 = _stablePair.token0();
        IERC20 lToken1 = _stablePair.token1();

        _manager.adjustManagement(_stablePair, 20e18, 20e18);
        _tokenA.mint(address(_stablePair), 10e18);
        _tokenB.mint(address(_stablePair), 10e18);
        uint256 lLiq = _stablePair.mint(address(this));

        // sanity
        assertEq(lLiq, 20e18); // 10e18 + 10e18
        assertEq(_tokenA.balanceOf(address(this)), 0);
        assertEq(_tokenB.balanceOf(address(this)), 0);
        assertEq(_manager.getBalance(_stablePair, lToken0), 20e18);
        assertEq(_manager.getBalance(_stablePair, lToken1), 20e18);

        // act
        _manager.adjustBalance(_stablePair, lToken0, uint104(lNewManagedBalance0)); // some amount lost
        _manager.adjustBalance(_stablePair, lToken1, uint104(lNewManagedBalance1)); // some amount lost
        _stablePair.transfer(address(_stablePair), 10e18);
        _stablePair.burn(address(this));

        // assert
        assertEq(_manager.getBalance(_stablePair, lToken0), lNewManagedBalance0);
        assertEq(_manager.getBalance(_stablePair, lToken1), lNewManagedBalance1);
        (uint104 lReserve0, uint104 lReserve1,,) = _stablePair.getReserves();
        assertTrue(
            MathUtils.within1(
                lReserve0, (Constants.INITIAL_MINT_AMOUNT - 20e18 + lNewManagedBalance0 + 10e18) * 210e18 / 220e18
            )
        );
        assertTrue(
            MathUtils.within1(
                lReserve1, (Constants.INITIAL_MINT_AMOUNT - 20e18 + lNewManagedBalance1 + 10e18) * 210e18 / 220e18
            )
        );
        assertLt(_tokenA.balanceOf(address(this)), 10e18);
        assertLt(_tokenB.balanceOf(address(this)), 10e18);
    }

    function testSync(uint256 aAmount0, uint256 aAmount1, uint256 aNewAmount0, uint256 aNewAmount1) external allPairs {
        // assume
        int256 lAmount0Managed = int256(bound(aAmount0, 1, Constants.INITIAL_MINT_AMOUNT));
        int256 lAmount1Managed = int256(bound(aAmount1, 1, Constants.INITIAL_MINT_AMOUNT));
        uint104 lAmount0NewBalance = uint104(bound(aNewAmount0, 1, type(uint104).max / 2));
        uint104 lAmount1NewBalance = uint104(bound(aNewAmount1, 1, type(uint104).max / 2));

        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);
        _manager.adjustManagement(_pair, lAmount0Managed, lAmount1Managed);
        _manager.adjustBalance(_pair, _pair.token0(), lAmount0NewBalance);
        _manager.adjustBalance(_pair, _pair.token1(), lAmount1NewBalance);

        // act
        _pair.sync();

        // assert
        (uint104 lReserve0, uint104 lReserve1,,) = _pair.getReserves();
        assertEq(_pair.token0Managed(), lAmount0NewBalance);
        assertEq(_pair.token1Managed(), lAmount1NewBalance);
        assertEq(lReserve0, Constants.INITIAL_MINT_AMOUNT - uint256(lAmount0Managed) + lAmount0NewBalance);
        assertEq(lReserve1, Constants.INITIAL_MINT_AMOUNT - uint256(lAmount1Managed) + lAmount1NewBalance);
    }

    function testBurn_AfterAlmostTotalLoss() external allPairs {
        // assume
        uint256 lNewManagedBalance0 = 1;
        uint256 lNewManagedBalance1 = 1;

        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        _manager.adjustManagement(_pair, 10e18, 10e18);
        _manager.adjustBalance(_pair, IERC20(address(_tokenA)), uint104(lNewManagedBalance0)); // some amount lost
        _manager.adjustBalance(_pair, IERC20(address(_tokenB)), uint104(lNewManagedBalance1)); // some amount lost

        // act
        uint256 lLpTokenBal = _pair.balanceOf(_alice);
        uint256 lTotalSupply = _pair.totalSupply();
        vm.prank(_alice);
        _pair.transfer(address(_pair), lLpTokenBal);
        _pair.burn(address(this));

        // assert - the burner gets less than in the case where the loss didn't happen
        assertLt(_tokenA.balanceOf(address(this)), lLpTokenBal * Constants.INITIAL_MINT_AMOUNT / lTotalSupply);
        assertLt(_tokenB.balanceOf(address(this)), lLpTokenBal * Constants.INITIAL_MINT_AMOUNT / lTotalSupply);
    }

    function testSkimExcessManaged() external allPairs {
        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        // act - make new managed balance exceed uint104.max
        _manager.adjustManagement(_pair, int256(Constants.INITIAL_MINT_AMOUNT), 0);
        _manager.adjustBalance(_pair, IERC20(address(_tokenA)), uint256(type(uint104).max) + 5);
        _pair.skimExcessManaged(_pair.token0());

        // assert
        assertEq(_manager.getBalance(_pair, _pair.token0()), type(uint104).max);
        assertEq(_pair.token0().balanceOf(_recoverer), 5);
    }

    function testSkimExcessManaged_NoExcess() external allPairs {
        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        // act
        _manager.adjustManagement(_pair, int256(Constants.INITIAL_MINT_AMOUNT), 0);
        _manager.adjustBalance(_pair, IERC20(address(_tokenA)), uint256(type(uint104).max));
        _pair.skimExcessManaged(_pair.token0());

        // assert
        assertEq(_pair.token0().balanceOf(_recoverer), 0);
    }

    function testSkimExcessManaged_InvalidToken() external allPairs {
        // act & assert
        vm.expectRevert(ReservoirPair.InvalidSkimToken.selector);
        _pair.skimExcessManaged(IERC20(address(_tokenD)));
    }
}
