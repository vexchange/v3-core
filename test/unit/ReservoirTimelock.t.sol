pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { ReservoirTimelock } from "src/ReservoirTimelock.sol";
import { StableMath } from "src/libraries/StableMath.sol";

contract ReservoirTimelockTest is BaseTest {
    ReservoirTimelock internal _timelock = new ReservoirTimelock();

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
        _factory.transferOwnership(address(_timelock));
    }

    function testSetCustomSwapFee(uint256 aSwapFee) external allPairs {
        // assume
        uint256 lSwapFee = bound(aSwapFee, 0, _pair.MAX_SWAP_FEE());

        // act
        _timelock.setCustomSwapFee(_factory, address(_pair), lSwapFee);

        // assert
        assertEq(_pair.customSwapFee(), lSwapFee);
        assertEq(_pair.swapFee(), lSwapFee);
    }

    function testSetCustomSwapFee_NotAdmin() external allPairs {
        // act & assert
        vm.prank(_alice);
        vm.expectRevert(_timelock.Unauthorized.selector);
        _timelock.setCustomSwapFee(_factory, address(_pair), 500);
    }

    function testSetCustomPlatformFee(uint256 aPlatformFee) external allPairs {
        // assume
        uint256 lPlatformFee = bound(aPlatformFee, 0, _pair.MAX_PLATFORM_FEE());

        // act
        _timelock.setCustomPlatformFee(_factory, address(_pair), lPlatformFee);

        // assert
        assertEq(_pair.customPlatformFee(), lPlatformFee);
        assertEq(_pair.platformFee(), lPlatformFee);
    }

    function testSetCustomPlatformFee_NotAdmin() external allPairs {
        // act & assert
        vm.prank(_alice);
        vm.expectRevert(_timelock.Unauthorizedselector);
        _timelock.setCustomPlatformFee(_factory, address(_pair), 500);
    }

    function testRampA(uint32 aNewStartTime) external randomizeStartTime(aNewStartTime) {
        // assume
        // we need this, if not _getCurrentAPrecise would underflow cuz we're going back in time
        vm.assume(aNewStartTime >= 1);

        // act
        uint64 lFutureATime = uint64(block.timestamp) + 2 days;
        _timelock.rampA(_factory, address(_stablePair), 500, lFutureATime);

        // assert
        (, uint64 futureA,, uint64 futureATime) = _stablePair.ampData();
        assertEq(futureA, 500 * StableMath.A_PRECISION);
        assertEq(futureATime, lFutureATime);
    }

    function testRampA_NotAdmin() external {
        // act & assert
        vm.prank(_alice);
        vm.expectRevert(_timelock.Unauthorized.selector);
        _timelock.rampA(_factory, address(_stablePair), 500, 500);
    }
}
