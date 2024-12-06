pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { MathUtils } from "src/libraries/MathUtils.sol";
import { EulerV2Manager, IAssetManager, IERC4626, IDistributor } from "src/asset-management/EulerV2Manager.sol";
import { GenericFactory, IERC20 } from "src/GenericFactory.sol";
import { IUSDC } from "test/interfaces/IUSDC.sol";
import { ReturnAssetExploit } from "../__mocks/ReturnAssetExploit.sol";

struct Network {
    string rpcUrl;
    uint256 blockNumber;
    address USDC;
    address masterMinterUSDC;
    address USDCVault;
    address merklDistributor;
}

struct Fork {
    bool created;
    uint256 forkId;
}

contract EulerIntegrationTest is BaseTest {
    using FactoryStoreLib for GenericFactory;
    using FixedPointMathLib for uint256;

    event Guardian(address newGuardian);
    event Transfer(address from, address to, uint256 amount);

    error TransferFailed();

    // this amount is tailored to USDC as it only has 6 decimal places
    // using the usual 100e18 would be too large and would break AAVE
    uint256 public constant MINT_AMOUNT = 1_000_000e6;

    EulerV2Manager private _manager;

    ReservoirPair[] internal _pairs;
    ReservoirPair internal _pair;

    Network[] private _networks;
    mapping(string => Fork) private _forks;
    // network specific variables
    IERC20 private USDC;
    address private masterMinterUSDC;
    IERC4626 private USDCVault;
    IDistributor private distributor;

    modifier allPairs() {
        for (uint256 i = 0; i < _pairs.length; ++i) {
            uint256 lBefore = vm.snapshotState();
            _pair = _pairs[i];
            _;
            require(vm.revertToStateAndDelete(lBefore), "revertToStateAndDelete failed");
        }
    }

    modifier allNetworks() {
        for (uint256 i = 0; i < _networks.length; ++i) {
            uint256 lBefore = vm.snapshotState();
            Network memory lNetwork = _networks[i];
            _setupRPC(lNetwork);
            require(block.number == lNetwork.blockNumber, "vm not at pinned block");
            _;
            require(vm.revertToStateAndDelete(lBefore), "revertToStateAndDelete failed");
        }
    }

    function _setupRPC(Network memory aNetwork) private {
        Fork memory lFork = _forks[aNetwork.rpcUrl];

        if (lFork.created == false) {
            uint256 lForkId = vm.createFork(aNetwork.rpcUrl, aNetwork.blockNumber);

            lFork = Fork(true, lForkId);
            _forks[aNetwork.rpcUrl] = lFork;
        }
        vm.selectFork(lFork.forkId);

        _deployer = _ensureDeployerExists();
        _factory = _deployer.deployFactory(type(GenericFactory).creationCode);
        _deployer.deployConstantProduct(type(ConstantProductPair).creationCode);
        _deployer.deployStable(type(StablePair).creationCode);

        _manager = new EulerV2Manager();
        USDC = IERC20(aNetwork.USDC);
        masterMinterUSDC = aNetwork.masterMinterUSDC;
        USDCVault = IERC4626(aNetwork.USDCVault);
        distributor = IDistributor(aNetwork.merklDistributor);

        _deal(address(USDC), address(this), MINT_AMOUNT);
        _constantProductPair = ConstantProductPair(_createPair(address(_tokenA), address(USDC), 0));
        USDC.transfer(address(_constantProductPair), MINT_AMOUNT);
        _tokenA.mint(address(_constantProductPair), MINT_AMOUNT);
        _constantProductPair.mint(_alice);
        vm.prank(address(_factory));
        _constantProductPair.setManager(_manager);

        _deal(address(USDC), address(this), MINT_AMOUNT);
        _stablePair = StablePair(_createPair(address(_tokenA), address(USDC), 1));
        USDC.transfer(address(_stablePair), MINT_AMOUNT);
        _tokenA.mint(address(_stablePair), 1_000_000e18);
        _stablePair.mint(_alice);
        vm.prank(address(_factory));
        _stablePair.setManager(_manager);

        _pairs.push(_constantProductPair);
        _pairs.push(_stablePair);

        _manager.setVaultForAsset(USDC, USDCVault);
    }

    function _createOtherPair() private returns (ConstantProductPair rOtherPair) {
        rOtherPair = ConstantProductPair(_createPair(address(_tokenB), address(USDC), 0));
        _tokenB.mint(address(rOtherPair), MINT_AMOUNT);
        _deal(address(USDC), address(this), MINT_AMOUNT);
        USDC.transfer(address(rOtherPair), MINT_AMOUNT);
        rOtherPair.mint(_alice);
        vm.prank(address(_factory));
        rOtherPair.setManager(_manager);
    }

    // this is a temporary workaround function to deal ERC20 tokens as forge-std's deal function is broken
    // at the moment
    function _deal(address aToken, address aRecipient, uint256 aAmount) private {
        if (aToken == address(USDC)) {
            vm.startPrank(masterMinterUSDC);
            IUSDC(address(USDC)).configureMinter(masterMinterUSDC, type(uint256).max);
            IUSDC(address(USDC)).mint(aRecipient, aAmount);
            vm.stopPrank();
        }
    }

    function setUp() external {
        _networks.push(
            Network(
                vm.rpcUrl("mainnet"),
                21_272_382, // pin to this block number
                0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
                0xE982615d461DD5cD06575BbeA87624fda4e3de17,
                0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9, // Euler Prime USDC vault
                0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae
            )
        );

        vm.makePersistent(address(_tokenA));
        vm.makePersistent(address(_tokenB));
        vm.makePersistent(address(_tokenC));
    }

    function testSetVaultForAsset() external allNetworks {
        // arrange
        IERC4626 lNewVault = IERC4626(address(5)); // any random address

        // act
        _manager.setVaultForAsset(USDC, lNewVault);

        // assert
        assertEq(address(_manager.assetVault(USDC)), address(lNewVault));
    }

    function testSetVaultForAsset_OutstandingShares() external allNetworks {
        // arrange
        _pair = _pairs[0];
        _increaseManagementOneToken(123);

        // act & assert
        vm.expectRevert(EulerV2Manager.OutstandingSharesForVault.selector);
        _manager.setVaultForAsset(USDC, USDCVault);
    }

    function testOnlyOwnerOrGuardian() external allNetworks {
        // arrange
        _manager.setGuardian(_alice);

        // act & assert
        vm.startPrank(_alice);
        _manager.setWindDownMode(true);
        assertTrue(_manager.windDownMode());

        _manager.setThresholds(0, 0);
        assertEq(_manager.lowerThreshold(), 0);
        assertEq(_manager.upperThreshold(), 0);
        vm.stopPrank();

        vm.startPrank(_bob);
        vm.expectRevert("AM: UNAUTHORIZED");
        _manager.setWindDownMode(false);

        vm.expectRevert("AM: UNAUTHORIZED");
        _manager.setThresholds(30, 30);
        vm.stopPrank();
    }

    function testSetGuardian() external allNetworks {
        // sanity
        address lGuardian = _manager.guardian();
        assertEq(lGuardian, address(0));

        // act
        vm.expectEmit(true, true, false, false);
        emit Guardian(_alice);
        _manager.setGuardian(_alice);

        // assert
        assertEq(_manager.guardian(), _alice);
    }

    function testSetGuardian_OnlyOwner(address aAddress) external allNetworks {
        // assume
        vm.assume(aAddress != address(this));

        // act & assert
        vm.prank(aAddress);
        vm.expectRevert("UNAUTHORIZED");
        _manager.setGuardian(_alice);
    }

    function testSetWindDownMode() external allNetworks {
        // sanity
        assertEq(_manager.windDownMode(), false);

        // act
        _manager.setWindDownMode(true);

        // assert
        assertEq(_manager.windDownMode(), true);
    }

    function testAdjustManagement_NoMarket(uint256 aAmountToManage) public allNetworks allPairs {
        // assume - we want negative numbers too
        int256 lAmountToManage = int256(bound(aAmountToManage, 0, type(uint256).max));

        // act
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? int256(0) : lAmountToManage,
            _pair.token1() == USDC ? int256(0) : lAmountToManage
        );

        // assert
        assertEq(_manager.getBalance(_pair, USDC), 0);
        assertEq(_manager.getBalance(_pair, IERC20(address(_tokenA))), 0);
    }

    function testAdjustManagement_NotOwner() public allNetworks allPairs {
        // act & assert
        vm.prank(_alice);
        vm.expectRevert("UNAUTHORIZED");
        _manager.adjustManagement(_pair, 1, 1);
    }

    function _increaseManagementOneToken(int256 aAmountToManage) private {
        // arrange
        int256 lAmountToManage0 = _pair.token0() == USDC ? aAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? aAmountToManage : int256(0);

        // act
        vm.expectCall(
            address(_pair), abi.encodeCall(ReservoirPair.adjustManagement, (lAmountToManage0, lAmountToManage1))
        );
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);
    }

    function testAdjustManagement_IncreaseManagementOneToken() public allNetworks allPairs {
        // arrange
        int256 lAmountToManage = 500e6;
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);

        // act
        _increaseManagementOneToken(lAmountToManage);

        // assert
        assertEq(_pair.token0Managed(), uint256(lAmountToManage0));
        assertEq(_pair.token1Managed(), uint256(lAmountToManage1));
        assertEq(USDC.balanceOf(address(_pair)), MINT_AMOUNT - uint256(lAmountToManage));

        uint256 lExpectedShares = USDCVault.convertToShares(uint256(lAmountToManage));

        assertEq(USDCVault.balanceOf(address(_manager)), lExpectedShares);
        assertEq(_manager.shares(_pair, USDC), lExpectedShares);
        assertEq(_manager.totalShares(USDCVault), lExpectedShares);
    }

    function testAdjustManagement_DecreaseManagementOneToken() public allNetworks allPairs {
        // arrange
        int256 lAmountToManage = 500e6;
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);
        _increaseManagementOneToken(lAmountToManage);
        uint256 lBalance = _manager.getBalance(_pair, USDC);

        // act
        _manager.adjustManagement(
            _pair,
            lAmountToManage0 == 0 ? lAmountToManage0 : -int256(lBalance),
            lAmountToManage1 == 0 ? lAmountToManage1 : -int256(lBalance)
        );

        // assert
        _pair.sync();
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertApproxEqAbs(USDC.balanceOf(address(_pair)), MINT_AMOUNT, 1);
        assertEq(USDCVault.balanceOf(address(_manager)), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(_manager.totalShares(USDCVault), 0);
    }

    function testAdjustManagement_DecreaseManagementBeyondShare() public allNetworks allPairs {
        // arrange
        ConstantProductPair lOtherPair = _createOtherPair();
        int256 lAmountToManage = 500e6;
        int256 lAmountToManage0Pair = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1Pair = _pair.token1() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage0Other = lOtherPair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1Other = lOtherPair.token1() == USDC ? lAmountToManage : int256(0);

        _manager.adjustManagement(_pair, lAmountToManage0Pair, lAmountToManage1Pair);
        _manager.adjustManagement(lOtherPair, lAmountToManage0Other, lAmountToManage1Other);

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        _manager.adjustManagement(lOtherPair, -lAmountToManage - 1, 0);
    }

    function testAdjustManagement_WindDown() external allNetworks allPairs {
        // arrange
        _increaseManagementOneToken(300e6);
        ReservoirPair lOtherPair = _createOtherPair();

        _manager.setWindDownMode(true);
        int256 lIncreaseAmt = 50e6;

        // act
        _manager.adjustManagement(
            _pair, _pair.token0() == USDC ? lIncreaseAmt : int256(0), _pair.token1() == USDC ? lIncreaseAmt : int256(0)
        );
        _manager.adjustManagement(
            lOtherPair,
            lOtherPair.token0() == USDC ? lIncreaseAmt : int256(0),
            lOtherPair.token1() == USDC ? lIncreaseAmt : int256(0)
        );

        // assert
        assertApproxEqAbs(_manager.getBalance(_pair, USDC), 300e6, 1);
        assertEq(_manager.getBalance(lOtherPair, USDC), 0);
    }

    function testGetBalance(uint256 aAmountToManage) public allNetworks allPairs {
        // assume
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int256 lAmountToManage = int256(bound(aAmountToManage, 3, lReserveUSDC));

        // arrange
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // act
        uint256 lBalance = _manager.getBalance(_pair, USDC);

        // assert
        assertApproxEqAbs(lBalance, uint256(lAmountToManage), 2);
    }

    function testGetBalance_TwoPairsInSameMarket(uint256 aAmountToManage1, uint256 aAmountToManage2)
        public
        allNetworks
        allPairs
    {
        // assume
        ConstantProductPair lOtherPair = _createOtherPair();
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int256 lAmountToManagePair = int256(bound(aAmountToManage1, 10, lReserveUSDC));
        int256 lAmountToManageOther = int256(bound(aAmountToManage2, 10, lReserveUSDC));

        // arrange
        int256 lAmountToManage0Pair = _pair.token0() == USDC ? lAmountToManagePair : int256(0);
        int256 lAmountToManage1Pair = _pair.token1() == USDC ? lAmountToManagePair : int256(0);
        int256 lAmountToManage0Other = lOtherPair.token0() == USDC ? lAmountToManageOther : int256(0);
        int256 lAmountToManage1Other = lOtherPair.token1() == USDC ? lAmountToManageOther : int256(0);

        // act
        _manager.adjustManagement(_pair, lAmountToManage0Pair, lAmountToManage1Pair);
        _manager.adjustManagement(lOtherPair, lAmountToManage0Other, lAmountToManage1Other);

        // assert
        assertApproxEqAbs(_manager.getBalance(_pair, USDC), uint256(lAmountToManagePair), 2);
        assertApproxEqAbs(_manager.getBalance(lOtherPair, USDC), uint256(lAmountToManageOther), 2);
    }

    function testGetBalance_AddingAfterProfit(uint256 aAmountToManage1, uint256 aAmountToManage2, uint256 aTime)
        public
        allNetworks
        allPairs
    {
        // assume
        ConstantProductPair lOtherPair = _createOtherPair();

        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int256 lAmountToManagePair = int256(bound(aAmountToManage1, 1e6, lReserveUSDC));
        int256 lAmountToManageOther = int256(bound(aAmountToManage2, 1e6, lReserveUSDC));
        uint256 lTime = bound(aTime, 1 days, 52 weeks);

        // arrange
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? lAmountToManagePair : int256(0),
            _pair.token1() == USDC ? lAmountToManagePair : int256(0)
        );
        uint256 lPairShares = _manager.shares(_pair, USDC);

        // act
        _skip(lTime);
        uint256 lBalanceAfterInterest = _manager.getBalance(_pair, USDC);
        uint256 lExpectedShares = USDCVault.previewDeposit(uint256(lAmountToManageOther));
        _manager.adjustManagement(
            lOtherPair,
            lOtherPair.token0() == USDC ? lAmountToManageOther : int256(0),
            lOtherPair.token1() == USDC ? lAmountToManageOther : int256(0)
        );

        // assert
        assertEq(_manager.shares(_pair, USDC), lPairShares); // ensure that _pair's shares did not change
        assertApproxEqAbs(_manager.getBalance(_pair, USDC), lBalanceAfterInterest, 2);
        assertEq(_manager.shares(lOtherPair, USDC), lExpectedShares);
        uint256 lBalance = _manager.getBalance(lOtherPair, USDC);
        assertApproxEqAbs(lBalance, uint256(lAmountToManageOther), 2);
    }

    function testShares(uint256 aAmountToManage) public allNetworks allPairs {
        // assume
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int256 lAmountToManage = int256(bound(aAmountToManage, 10, lReserveUSDC));

        // arrange
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);

        // act
        uint256 lShares = USDCVault.previewDeposit(uint256(lAmountToManage));
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // assert
        assertEq(lShares, _manager.shares(_pair, USDC));
        assertEq(_manager.totalShares(USDCVault), lShares);
    }

    function testShares_AdjustManagementAfterProfit(uint256 aAmountToManage1, uint256 aAmountToManage2)
        public
        allNetworks
        allPairs
    {
        // assume
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int256 lAmountToManage1 = int256(bound(aAmountToManage1, 1e6, lReserveUSDC / 2));
        int256 lAmountToManage2 = int256(bound(aAmountToManage2, 1e6, lReserveUSDC / 2));

        // arrange
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? lAmountToManage1 : int256(0),
            _pair.token1() == USDC ? lAmountToManage1 : int256(0)
        );

        // act - go forward in time to simulate accrual of profits
        _skip(30 days);
        uint256 lNewManaged = _manager.getBalance(_pair, USDC);
        assertGt(lNewManaged, uint256(lAmountToManage1));
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? lAmountToManage2 : int256(0),
            _pair.token1() == USDC ? lAmountToManage2 : int256(0)
        );

        // assert
        uint256 lBalance = _manager.getBalance(_pair, USDC);
        // pair not yet informed of the profits, so the numbers are less than what it actually has
        uint256 lUSDCManaged = _pair.token0() == USDC ? _pair.token0Managed() : _pair.token1Managed();
        assertLt(lUSDCManaged, lBalance);

        // after a sync, the pair should have the correct amount
        _pair.sync();
        uint256 lUSDCManagedAfterSync = _pair.token0() == USDC ? _pair.token0Managed() : _pair.token1Managed();
        assertEq(lUSDCManagedAfterSync, lBalance);
    }

    function testAfterLiquidityEvent_IncreaseInvestmentAfterMint() public allNetworks allPairs {
        // sanity
        uint256 lAmountManaged = _manager.getBalance(_pair, USDC);
        assertEq(lAmountManaged, 0);

        // act
        _tokenA.mint(address(_pair), 500e6);
        _deal(address(USDC), address(this), 500e6);
        USDC.transfer(address(_pair), 500e6);
        _pair.mint(address(this));

        // assert
        uint256 lNewAmount = _manager.getBalance(_pair, USDC);
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        assertApproxEqAbs(
            lNewAmount, lReserveUSDC.mulWad(uint256(_manager.lowerThreshold()).avg(_manager.upperThreshold())), 1
        );
    }

    function testAfterLiquidityEvent_DecreaseInvestmentAfterBurn(uint256 aInitialAmount) public allNetworks allPairs {
        // assume
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        uint256 lInitialAmount =
            bound(aInitialAmount, lReserveUSDC.mulWad(_manager.upperThreshold() + 0.02e18), lReserveUSDC);

        // arrange
        _manager.adjustManagement(_pair, 0, int256(lInitialAmount));

        // act
        vm.prank(_alice);
        _pair.transfer(address(_pair), 100e6);
        _pair.burn(address(this));

        // assert
        uint256 lNewManagedAmt = _manager.getBalance(_pair, USDC);
        (uint256 lReserve0After, uint256 lReserve1After,,) = _pair.getReserves();
        uint256 lReserveUSDCAfter = _pair.token0() == USDC ? lReserve0After : lReserve1After;
        assertTrue(
            MathUtils.within1(
                lNewManagedAmt, lReserveUSDCAfter.divWad(_manager.lowerThreshold() + _manager.upperThreshold()) / 2
            )
        );
    }

    function testAfterLiquidityEvent_RevertIfNotPair() public allNetworks {
        // act & assert
        vm.expectRevert();
        _manager.afterLiquidityEvent();

        // act & assert
        vm.prank(_alice);
        vm.expectRevert();
        _manager.afterLiquidityEvent();
    }

    function testAfterLiquidityEvent_WindDown() external allNetworks allPairs {
        // arrange
        _pair.burn(address(this));
        assertGt(_pair.token0() == USDC ? _pair.token0Managed() : _pair.token1Managed(), 0);
        uint256 lAmtManaged = _manager.getBalance(_pair, USDC);

        // act
        _manager.setWindDownMode(true);

        // assert - burn should still succeed
        _pair.burn(address(this));
        // this call to increase management should have no effect
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? int256(100e6) : int256(0),
            _pair.token1() == USDC ? int256(100e6) : int256(0)
        );
        assertEq(_manager.getBalance(_pair, USDC), lAmtManaged);
        // a call to decrease management should have an effect
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? -int256(lAmtManaged) : int256(0),
            _pair.token1() == USDC ? -int256(lAmtManaged) : int256(0)
        );
        assertEq(_manager.getBalance(_pair, USDC), 0);
    }

    function testSwap_ReturnAsset() public allNetworks allPairs {
        // arrange
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        (uint256 lReserveUSDC, uint256 lReserveTokenA) =
            _pair.token0() == USDC ? (lReserve0, lReserve1) : (lReserve1, lReserve0);
        // manage half
        _manager.adjustManagement(
            _pair,
            int256(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int256(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );

        // sanity
        assertEq(USDC.balanceOf(address(_pair)), MINT_AMOUNT / 2);

        // act - request more than what is available in the pair
        int256 lOutputAmt = _pair.token0() == USDC ? int256(MINT_AMOUNT / 2 + 10) : -int256(MINT_AMOUNT / 2 + 10);
        (int256 lExpectedToken0Calldata, int256 lExpectedToken1Calldata) =
            _pair.token0() == USDC ? (int256(-10), int256(0)) : (int256(0), int256(-10));
        _tokenA.mint(address(_pair), lReserveTokenA * 2);
        vm.expectCall(address(_manager), abi.encodeCall(_manager.returnAsset, (_pair.token0() == USDC, 10)));
        vm.expectCall(
            address(_pair), abi.encodeCall(_pair.adjustManagement, (lExpectedToken0Calldata, lExpectedToken1Calldata))
        );
        _pair.swap(lOutputAmt, false, address(this), bytes(""));

        // assert
        (lReserve0, lReserve1,,) = _pair.getReserves();
        lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        assertEq(USDC.balanceOf(address(this)), MINT_AMOUNT / 2 + 10);
        assertEq(USDC.balanceOf(address(_pair)), 0);
        assertEq(lReserveUSDC, MINT_AMOUNT / 2 - 10);
        assertApproxEqAbs(_manager.getBalance(_pair, USDC), MINT_AMOUNT / 2 - 10, 1);
    }

    function testSwap_ReturnAsset_WindDown() external allNetworks allPairs {
        // arrange
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        (uint256 lReserveUSDC, uint256 lReserveTokenA) =
            _pair.token0() == USDC ? (lReserve0, lReserve1) : (lReserve1, lReserve0);
        // manage half
        _manager.adjustManagement(
            _pair,
            int256(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int256(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );
        _manager.setWindDownMode(true);

        // act - request more than what is available in the pair
        int256 lOutputAmt = _pair.token0() == USDC ? int256(MINT_AMOUNT / 2 + 10) : -int256(MINT_AMOUNT / 2 + 10);
        (int256 lExpectedToken0Calldata, int256 lExpectedToken1Calldata) =
            _pair.token0() == USDC ? (int256(-10), int256(0)) : (int256(0), int256(-10));
        _tokenA.mint(address(_pair), lReserveTokenA * 2);
        vm.expectCall(address(_manager), abi.encodeCall(_manager.returnAsset, (_pair.token0() == USDC, 10)));
        vm.expectCall(
            address(_pair), abi.encodeCall(_pair.adjustManagement, (lExpectedToken0Calldata, lExpectedToken1Calldata))
        );
        _pair.swap(lOutputAmt, false, address(this), bytes(""));

        // assert
        (lReserve0, lReserve1,,) = _pair.getReserves();
        lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        assertEq(USDC.balanceOf(address(this)), MINT_AMOUNT / 2 + 10);
        assertEq(USDC.balanceOf(address(_pair)), 0);
        assertEq(lReserveUSDC, MINT_AMOUNT / 2 - 10);
        assertApproxEqAbs(_manager.getBalance(_pair, USDC), MINT_AMOUNT / 2 - 10, 1);
    }

    // the amount requested is within the balance of the pair, no need to return asset
    function testSwap_NoReturnAsset() public allNetworks allPairs {
        // arrange
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        (uint256 lReserveUSDC, uint256 lReserveTokenA) =
            _pair.token0() == USDC ? (lReserve0, lReserve1) : (lReserve1, lReserve0);
        // manage half
        _manager.adjustManagement(
            _pair,
            int256(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int256(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );

        // sanity
        assertEq(USDC.balanceOf(address(_pair)), MINT_AMOUNT / 2);

        // act - request exactly what is available in the pair
        int256 lOutputAmt = _pair.token0() == USDC ? int256(MINT_AMOUNT / 2) : -int256(MINT_AMOUNT / 2);
        _tokenA.mint(address(_pair), lReserveTokenA * 2);
        _pair.swap(lOutputAmt, false, address(this), bytes(""));

        // assert
        (lReserve0, lReserve1,,) = _pair.getReserves();
        lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        assertEq(USDC.balanceOf(address(this)), MINT_AMOUNT / 2);
        assertEq(USDC.balanceOf(address(_pair)), 0);
        assertEq(lReserveUSDC, MINT_AMOUNT / 2);
        assertApproxEqAbs(_manager.getBalance(_pair, USDC), MINT_AMOUNT / 2, 1);
    }

    function testBurn_ReturnAsset() public allNetworks allPairs {
        // arrange
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        // manage half
        _manager.adjustManagement(
            _pair,
            int256(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int256(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );

        // sanity
        assertEq(USDC.balanceOf(address(_pair)), lReserveUSDC / 2);

        // act
        vm.startPrank(_alice);
        _pair.transfer(address(_pair), _pair.balanceOf(_alice));
        vm.expectCall(address(_manager), bytes(""));
        vm.expectCall(address(_pair), bytes(""));
        _pair.burn(address(this));
        vm.stopPrank();

        // assert - range due to slight diff in liq between CP and SP
        assertApproxEqRel(USDC.balanceOf(address(this)), MINT_AMOUNT, 0.000000001001e18);
    }

    function testSetThresholds_BreachMaximum() public allNetworks {
        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLDS");
        _manager.setThresholds(0, 1e18 + 1);
    }

    function testSetThresholds_UpperLessThanLowerThreshold(uint256 aThreshold) public allNetworks {
        // assume
        uint128 lLowerThreshold = _manager.lowerThreshold();
        uint256 lThreshold = bound(aThreshold, 0, lLowerThreshold - 1);

        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLDS");
        _manager.setThresholds(lLowerThreshold, uint128(lThreshold));
    }

    function testSetThresholds_LowerMoreThanUpperThreshold(uint256 aThreshold) public allNetworks {
        // assume
        uint128 lUpperThreshold = _manager.upperThreshold();
        uint256 lThreshold = bound(aThreshold, lUpperThreshold + 1, type(uint128).max);

        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLDS");
        _manager.setThresholds(uint128(lThreshold), lUpperThreshold);
    }

    function testRawCall_OnlyOwner() public allNetworks {
        // act & assert
        uint256 lMintAmt = 500;
        _manager.rawCall(address(_tokenA), abi.encodeCall(_tokenA.mint, (address(this), lMintAmt)), 0);
        assertEq(_tokenA.balanceOf(address(this)), lMintAmt);
    }

    function testRawCall_NotOwner(address aCaller) public allNetworks {
        // assume
        vm.assume(aCaller != address(this));

        // act & assert
        vm.prank(aCaller);
        vm.expectRevert("UNAUTHORIZED");
        uint256 lMintAmt = 500;
        _manager.rawCall(address(_tokenA), abi.encodeCall(_tokenA.mint, (address(this), lMintAmt)), 0);
    }

    function testThresholdToZero_Migrate(
        uint256 aAmtToManage0,
        uint256 aAmtToManage1,
        uint256 aAmtToManage2,
        uint256 aFastForwardTime
    ) external allNetworks allPairs {
        // assume
        uint256 lAmtToManage0 = bound(aAmtToManage0, 10, MINT_AMOUNT);
        uint256 lAmtToManage1 = bound(aAmtToManage1, 10, MINT_AMOUNT);
        uint256 lAmtToManage2 = bound(aAmtToManage2, 10, MINT_AMOUNT);
        uint256 lFastForwardTime = bound(aFastForwardTime, 5 minutes, 60 days);

        // arrange
        ConstantProductPair lOtherPair = _createOtherPair();
        StablePair lThirdPair = StablePair(_createPair(address(USDC), address(_tokenC), 1));
        _deal(address(USDC), address(lThirdPair), MINT_AMOUNT);
        _tokenC.mint(address(lThirdPair), MINT_AMOUNT);
        lThirdPair.mint(_alice);
        vm.prank(address(_factory));
        lThirdPair.setManager(_manager);
        _increaseManagementOneToken(int256(lAmtToManage0));
        _manager.adjustManagement(
            lOtherPair,
            lOtherPair.token0() == USDC ? int256(lAmtToManage1) : int256(0),
            lOtherPair.token1() == USDC ? int256(lAmtToManage1) : int256(0)
        );
        _manager.adjustManagement(
            lThirdPair,
            lThirdPair.token0() == USDC ? int256(lAmtToManage2) : int256(0),
            lThirdPair.token1() == USDC ? int256(lAmtToManage2) : int256(0)
        );

        // act
        _manager.setThresholds(0, 0);
        // step some time to accumulate some profits
        _stepTime(lFastForwardTime);

        // assert
        _pair.burn(address(this));
        lOtherPair.burn(address(this));
        lThirdPair.burn(address(this));
        // attempts to migrate after this should succeed
        vm.startPrank(address(_factory));
        _pair.setManager(IAssetManager(address(0)));
        lOtherPair.setManager(IAssetManager(address(0)));
        lThirdPair.setManager(IAssetManager(address(0)));
        vm.stopPrank();
        assertEq(address(_pair.assetManager()), address(0));
        assertEq(address(lOtherPair.assetManager()), address(0));
        assertEq(address(lThirdPair.assetManager()), address(0));
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(lOtherPair.token0Managed(), 0);
        assertEq(lOtherPair.token1Managed(), 0);
        assertEq(lThirdPair.token0Managed(), 0);
        assertEq(lThirdPair.token1Managed(), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(_manager.shares(lOtherPair, USDC), 0);
        assertEq(_manager.shares(lThirdPair, USDC), 0);
    }

    function testFullRedeem_MultiplePairs(
        uint256 aAmtToManage0,
        uint256 aAmtToManage1,
        uint256 aAmtToManage2,
        uint256 aFastForwardTime
    ) external allNetworks allPairs {
        // assume
        uint256 lAmtToManage0 = bound(aAmtToManage0, 10, MINT_AMOUNT);
        uint256 lAmtToManage1 = bound(aAmtToManage1, 10, MINT_AMOUNT);
        uint256 lAmtToManage2 = bound(aAmtToManage2, 10, MINT_AMOUNT);
        uint256 lFastForwardTime = bound(aFastForwardTime, 10 days, 60 days);

        // arrange
        ConstantProductPair lOtherPair = _createOtherPair();
        StablePair lThirdPair = StablePair(_createPair(address(USDC), address(_tokenC), 1));
        _deal(address(USDC), address(lThirdPair), MINT_AMOUNT);
        _tokenC.mint(address(lThirdPair), MINT_AMOUNT);
        lThirdPair.mint(_alice);
        vm.prank(address(_factory));
        lThirdPair.setManager(_manager);
        _increaseManagementOneToken(int256(lAmtToManage0));
        _manager.adjustManagement(
            lOtherPair,
            lOtherPair.token0() == USDC ? int256(lAmtToManage1) : int256(0),
            lOtherPair.token1() == USDC ? int256(lAmtToManage1) : int256(0)
        );
        _manager.adjustManagement(
            lThirdPair,
            lThirdPair.token0() == USDC ? int256(lAmtToManage2) : int256(0),
            lThirdPair.token1() == USDC ? int256(lAmtToManage2) : int256(0)
        );

        // act
        _stepTime(lFastForwardTime);

        // divest everything
        lOtherPair.sync();
        _manager.adjustManagement(
            lOtherPair,
            lOtherPair.token0() == USDC ? -int256(_manager.getBalance(lOtherPair, USDC)) : int256(0),
            lOtherPair.token1() == USDC ? -int256(_manager.getBalance(lOtherPair, USDC)) : int256(0)
        );
        lThirdPair.sync();
        _manager.adjustManagement(
            lThirdPair,
            lThirdPair.token0() == USDC ? -int256(_manager.getBalance(lThirdPair, USDC)) : int256(0),
            lThirdPair.token1() == USDC ? -int256(_manager.getBalance(lThirdPair, USDC)) : int256(0)
        );
        _pair.sync();
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? -int256(_manager.getBalance(_pair, USDC)) : int256(0),
            _pair.token1() == USDC ? -int256(_manager.getBalance(_pair, USDC)) : int256(0)
        );

        // assert
        // actually these checks for managed amounts zero are kind of redundant
        // cuz it's checked in setManager anyway
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(lOtherPair.token0Managed(), 0);
        assertEq(lOtherPair.token1Managed(), 0);
        assertEq(lThirdPair.token0Managed(), 0);
        assertEq(lThirdPair.token1Managed(), 0);
        vm.startPrank(address(_factory));
        _pair.setManager(IAssetManager(address(0)));
        lOtherPair.setManager(IAssetManager(address(0)));
        lThirdPair.setManager(IAssetManager(address(0)));
        vm.stopPrank();
        assertEq(address(_pair.assetManager()), address(0));
        assertEq(address(lOtherPair.assetManager()), address(0));
        assertEq(address(lThirdPair.assetManager()), address(0));
        assertEq(_manager.totalShares(USDCVault), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(_manager.shares(lOtherPair, USDC), 0);
        assertEq(_manager.shares(lThirdPair, USDC), 0);
    }

    function testFullRedeem_MultiplePairsDifferentTimes(
        uint256 aAmtToManage0,
        uint256 aAmtToManage1,
        uint256 aAmtToManage2,
        uint256 aFastForwardTime1,
        uint256 aFastForwardTime2
    ) external allNetworks allPairs {
        // assume
        uint256 lAmtToManage0 = bound(aAmtToManage0, 10, MINT_AMOUNT);
        uint256 lAmtToManage1 = bound(aAmtToManage1, 10, MINT_AMOUNT);
        uint256 lAmtToManage2 = bound(aAmtToManage2, 10, MINT_AMOUNT);
        uint256 lFastForwardTime1 = bound(aFastForwardTime1, 10 days, 60 days);
        uint256 lFastForwardTime2 = bound(aFastForwardTime2, 10 days, 90 days);

        // arrange
        ConstantProductPair lPair2 = _createOtherPair();
        StablePair lPair3 = StablePair(_createPair(address(USDC), address(_tokenC), 1));
        _deal(address(USDC), address(lPair3), MINT_AMOUNT);
        _tokenC.mint(address(lPair3), MINT_AMOUNT);
        lPair3.mint(_alice);
        vm.prank(address(_factory));
        lPair3.setManager(_manager);
        _increaseManagementOneToken(int256(lAmtToManage0));

        // go forward in time to accumulate some rewards and then the second pair comes in
        _stepTime(lFastForwardTime1);
        _manager.adjustManagement(
            lPair2,
            lPair2.token0() == USDC ? int256(lAmtToManage1) : int256(0),
            lPair2.token1() == USDC ? int256(lAmtToManage1) : int256(0)
        );

        // go forward in time to accumulate some rewards and then the third pair comes in
        _stepTime(lFastForwardTime2);
        _manager.adjustManagement(
            lPair3,
            lPair3.token0() == USDC ? int256(lAmtToManage2) : int256(0),
            lPair3.token1() == USDC ? int256(lAmtToManage2) : int256(0)
        );

        // act - divest everything
        lPair2.sync();
        _manager.adjustManagement(
            lPair2,
            lPair2.token0() == USDC ? -int256(_manager.getBalance(lPair2, USDC)) : int256(0),
            lPair2.token1() == USDC ? -int256(_manager.getBalance(lPair2, USDC)) : int256(0)
        );
        lPair3.sync();
        _manager.adjustManagement(
            lPair3,
            lPair3.token0() == USDC ? -int256(_manager.getBalance(lPair3, USDC)) : int256(0),
            lPair3.token1() == USDC ? -int256(_manager.getBalance(lPair3, USDC)) : int256(0)
        );
        _pair.sync();
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? -int256(_manager.getBalance(_pair, USDC)) : int256(0),
            _pair.token1() == USDC ? -int256(_manager.getBalance(_pair, USDC)) : int256(0)
        );

        // assert
        // actually these checks for managed amounts zero are kind of redundant
        // cuz it's checked in setManager anyway
        assertEq(_pair.token0Managed(), 0, "pair token0Managed");
        assertEq(_pair.token1Managed(), 0, "pair token1Managed");
        assertEq(lPair2.token0Managed(), 0, "pair2 token0Managed");
        assertEq(lPair2.token1Managed(), 0, "pair2 token1Managed");
        assertEq(lPair3.token0Managed(), 0, "pair3 token0Managed");
        assertEq(lPair3.token1Managed(), 0, "pair3 token1Managed");
        vm.startPrank(address(_factory));
        _pair.setManager(IAssetManager(address(0)));
        lPair2.setManager(IAssetManager(address(0)));
        lPair3.setManager(IAssetManager(address(0)));
        vm.stopPrank();
        assertEq(address(_pair.assetManager()), address(0));
        assertEq(address(lPair2.assetManager()), address(0));
        assertEq(address(lPair3.assetManager()), address(0));
        assertEq(_manager.totalShares(USDCVault), 0, "total shares");
        assertEq(_manager.shares(_pair, USDC), 0, "pair shares");
        assertEq(_manager.shares(lPair2, USDC), 0, "pair2 shares");
        assertEq(_manager.shares(lPair3, USDC), 0, "pair3 shares");
    }

    // The following two test cases show that even with a third party intentionally / accidentally
    // transfers the underlying tokens to the asset manager, it would still function (deposit/withdraw) as normal
    function testResilientEvenWithUnexpectedTokens_Deposit() external allNetworks allPairs {
        // arrange
        _deal(address(USDC), address(_manager), 1_000_000e6);

        // act - adjustManagement should still succeed despite extra tokens
        int256 lAmtToManage = 2e6;
        _manager.adjustManagement(_pair, USDC == _pair.token0() ? lAmtToManage : int256(0), USDC == _pair.token1() ? lAmtToManage : int256(0));

        // assert
        assertGt(USDC.balanceOf(address(_manager)), 0);
        assertApproxEqAbs(_manager.getBalance(_pair, USDC), uint256(lAmtToManage), 1);
    }

    function testResilientEvenWithUnexpectedTokens_Withdraw() external allNetworks allPairs {
        // arrange
        int256 lAmtToManage = 2e6;
        _increaseManagementOneToken(lAmtToManage);
        uint256 lUnexpectedTokens = 33222;
        _deal(address(USDC), address(_manager), lUnexpectedTokens);

        // act
        uint256 lBalance = _manager.getBalance(_pair, USDC);
        _manager.adjustManagement(_pair, _pair.token0() == USDC ? -int256(lBalance) : int256(0), _pair.token1() == USDC ? -int256(lBalance) : int256(0));

        // assert
        assertEq(_manager.getBalance(_pair, USDC), 0);
        assertEq(USDCVault.balanceOf(address(_manager)), 0);
        assertEq(USDC.balanceOf(address(_manager)), lUnexpectedTokens);
    }

    // this test shows that the asset manager should still function properly with investing, divesting, showing balance
    // even if an external party transfers unsolicited shares into it
    function testResilientEvenInExternalShareTransfer() external allNetworks allPairs {
        // arrange
        _increaseManagementOneToken(12_312_322);
        uint256 lPairBalance = _manager.getBalance(_pair, USDC);
        uint256 lPairShares = _manager.shares(_pair, USDC);
        uint256 lOldTotalShares = _manager.totalShares(USDCVault);

        uint256 lAmtToSupply = 100_000e6;
        _deal(address(USDC), address(this), lAmtToSupply);
        USDC.approve(address(USDCVault), lAmtToSupply);
        uint256 lSharesReceived = USDCVault.deposit(lAmtToSupply, address(this));
        assertEq(lSharesReceived, USDCVault.balanceOf(address(this)));

        // act
        USDCVault.transfer(address(_manager), lSharesReceived);

        // assert
        assertEq(_manager.getBalance(_pair, USDC), lPairBalance); // pair's balance should not change
        assertEq(_manager.shares(_pair, USDC), lPairShares);
        assertEq(_manager.totalShares(USDCVault), lOldTotalShares);
        assertGt(USDCVault.balanceOf(address(_manager)), lOldTotalShares);

        _manager.adjustManagement(
            _pair,
            USDC == _pair.token0() ? -int256(lPairBalance) : int256(0),
            USDC == _pair.token1() ? -int256(lPairBalance) : int256(0)
        );

        assertEq(_manager.getBalance(_pair, USDC), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(_manager.totalShares(USDCVault), 0);

        // admins get the extra shares out
        _manager.rawCall(
            address(USDCVault),
            abi.encodeCall(IERC20.transfer, (address(this), USDCVault.balanceOf(address(_manager)))),
            0
        );
        assertEq(USDCVault.balanceOf(address(this)), lSharesReceived);
    }

    function testReturnAsset_Attack() external allNetworks allPairs {
        // arrange
        _increaseManagementOneToken(11e6);
        ReturnAssetExploit lExploit = new ReturnAssetExploit(_pair);

        // act & assert - attack should fail with our fix, and should succeed without the fix
        vm.expectRevert(stdError.arithmeticError);
        lExploit.attack(_manager);
    }

    function testClaimRewards() external allNetworks {
        // arrange
        // pin block to certain as it is before the user has claimed the reward
        // this is a replay of
        // https://etherscan.io/tx/0x2cc0e0161f84594ff755b8aac235efcf8ce59c1f9d63655356d9d5f09021ef5f
        vm.rollFork(21_197_813);
        address lVaultUser = address(0x00236feEAC26ef92552e3981096350D136084C64);
        uint256 lUSDCBalanceBefore = USDC.balanceOf(lVaultUser);
        uint256 lClaimAmt = 361_104_571;
        uint256 lActualAmt = 241_316_721;

        vm.prank(lVaultUser);
        distributor.toggleOperator(lVaultUser, address(_manager));

        address[] memory lUsers = new address[](1);
        lUsers[0] = lVaultUser;

        address[] memory lTokens = new address[](1);
        lTokens[0] = address(USDC);

        uint256[] memory lAmounts = new uint256[](1);
        lAmounts[0] = lClaimAmt;

        bytes32[][] memory lProofs = new bytes32[][](1);
        lProofs[0] = new bytes32[](14);
        lProofs[0][0] = 0xa9f5986cf9ba92e165a2422369577d29f776b2875b5675602e9e5f9df2ab7c7e;
        lProofs[0][1] = 0xbeaad48efe95eae938e5f48dd8cbad91bd2036dbab85ed913d5581e43a669884;
        lProofs[0][2] = 0xc8f64af9c4e202af243b02031900bccb59db3fb1ae7f7b6ef841539a27a89ccc;
        lProofs[0][3] = 0x5531d033f9e3ce60f1817f1121e6958d34970d41469aa34d72d5825efc54fbf4;
        lProofs[0][4] = 0x0d5a061463b6c619edaa4b88d8778565df55c30bb9cfcb0ee5e5b2947a6ecdd7;
        lProofs[0][5] = 0x83f3d530fbaa326a08b31e5d1418565ea6de97f93f26acab480f537cf159c63f;
        lProofs[0][6] = 0x423985ac01da6043a6e733135aa92b329528cc675c83b1de799b90d1061a3447;
        lProofs[0][7] = 0xfa65c6be585dd9b00347ef1a466d0bddcd16a84291d5c802882cbd51b6287dfb;
        lProofs[0][8] = 0x1f6dc43d4aacf37a7518a74d30b9abc3be28ab635485624a05201faff3d19ed7;
        lProofs[0][9] = 0x313bbbf9afd06d8f9e6754362938910ac15b5f17094cbec219e920b5304c3424;
        lProofs[0][10] = 0xceb058ef80e60f5868b3bfab410745217f303f7deaf4d37b4d865cc2378230f7;
        lProofs[0][11] = 0x9dd8679648e25847e3e4ec095dfb009624aeea68e8d5b74808e0d1115ea6834f;
        lProofs[0][12] = 0x90d5dc0ac9e6118eba554513548f3e5a2573d3eb77efe4b9f12dc57aa0bdab53;
        lProofs[0][13] = 0x0e81697f68dcbd6ed96fed3a63ddc140edb0de2ef18d9611104ae80ae0b759c7;

        // since all claims go to the actual user regardless of who claimed it
        // we are unable to get the claimed tokens into the asset manager
        // therefore we simulate it by dealing it the correct amount
        _deal(address(USDC), address(_manager), lActualAmt);

        // act & assert
        _manager.claimRewards(distributor, lUsers, lTokens, lAmounts, lProofs);

        // assert
        assertEq(USDC.balanceOf(address(this)), lActualAmt);
        assertEq(USDC.balanceOf(lVaultUser) - lUSDCBalanceBefore, lActualAmt);
    }

    function testDistributeRewardForPairs(
        uint256 aAmountToDistribute,
        uint256 aAmtToManage1,
        uint256 aAmtToManage2,
        uint256 aAmtToManage3
    ) external allNetworks allPairs {
        // assume
        uint256 lAmountToDistribute = bound(aAmountToDistribute, 100, 10_000_000e6);
        int256 lAmtToManage1 = int256(bound(aAmtToManage1, 1e6, 10_000e6));
        int256 lAmtToManage2 = int256(bound(aAmtToManage2, 1e6, 10_000e6));
        int256 lAmtToManage3 = int256(bound(aAmtToManage3, 1e6, 10_000e6));

        // arrange
        _deal(address(USDC), address(this), lAmountToDistribute);
        ConstantProductPair lPair2 = ConstantProductPair(_createPair(address(USDC), address(_tokenC), 0));
        StablePair lPair3 = StablePair(_createPair(address(USDC), address(_tokenC), 1));

        _deal(address(USDC), address(lPair2), MINT_AMOUNT);
        _tokenC.mint(address(lPair2), MINT_AMOUNT);
        lPair2.mint(_alice);
        vm.prank(address(_factory));
        lPair2.setManager(_manager);

        _deal(address(USDC), address(lPair3), MINT_AMOUNT);
        _tokenC.mint(address(lPair3), MINT_AMOUNT);
        lPair3.mint(_alice);
        vm.prank(address(_factory));
        lPair3.setManager(_manager);

        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? lAmtToManage1 : int256(0),
            _pair.token1() == USDC ? lAmtToManage1 : int256(0)
        );
        _manager.adjustManagement(
            lPair2,
            lPair2.token0() == USDC ? lAmtToManage2 : int256(0),
            lPair2.token1() == USDC ? lAmtToManage2 : int256(0)
        );
        _manager.adjustManagement(
            lPair3,
            lPair3.token0() == USDC ? lAmtToManage3 : int256(0),
            lPair3.token1() == USDC ? lAmtToManage3 : int256(0)
        );

        IAssetManagedPair[] memory lPairs = new IAssetManagedPair[](3);
        lPairs[0] = _pair;
        lPairs[1] = lPair2;
        lPairs[2] = lPair3;
        uint256 lPairSharesBefore = _manager.shares(_pair, USDC);
        uint256 lPair2SharesBefore = _manager.shares(lPair2, USDC);
        uint256 lPair3SharesBefore = _manager.shares(lPair3, USDC);

        // act
        USDC.approve(address(_manager), lAmountToDistribute);
        _manager.distributeRewardForPairs(USDC, lAmountToDistribute, lPairs);

        // assert
        uint256 lPairShares = _manager.shares(_pair, USDC);
        uint256 lPair2Shares = _manager.shares(lPair2, USDC);
        uint256 lPair3Shares = _manager.shares(lPair3, USDC);
        assertEq(lPairShares + lPair2Shares + lPair3Shares, _manager.totalShares(USDCVault));
        assertGe(lPairShares, lPairSharesBefore);
        assertGe(lPair2Shares, lPair2SharesBefore);
        assertGe(lPair3Shares, lPair3SharesBefore);
    }
}
