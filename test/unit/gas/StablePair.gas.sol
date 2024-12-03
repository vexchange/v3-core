// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

contract StablePairGas is BaseTest {
    StablePair private _freshPair;
    StablePair private _oraclePair;

    function setUp() external {
        _tokenA.mint(address(this), 100e18);
        _tokenB.mint(address(this), 100e18);
        _tokenC.mint(address(this), 100e18);
        _tokenD.mint(address(this), 100e18);

        // This pair measures initial mint cost.
        _freshPair = StablePair(_factory.createPair(IERC20(address(_tokenA)), IERC20(address(_tokenD)), 1));

        // This pair measures oracle writing cost.
        _oraclePair = StablePair(_factory.createPair(IERC20(address(_tokenA)), IERC20(address(_tokenC)), 1));
        _tokenA.mint(address(_oraclePair), 100e18);
        _tokenC.mint(address(_oraclePair), 100e18);
        _oraclePair.mint(_bob);

        // Take some recordings to unzero the oracle pair slots.
        _skip(100);
        _tokenA.transfer(address(_oraclePair), 50e18);
        uint256 lOut = _oraclePair.swap(int256(50e18), true, address(_bob), bytes(""));
        _skip(100);
        _tokenC.transfer(address(_oraclePair), lOut);
        _oraclePair.swap(-int256(lOut), true, address(_bob), bytes(""));
        _skip(100);
        _oraclePair.burn(address(this));
    }

    function testGasMint() external {
        _tokenA.transfer(address(_oraclePair), 50e18);
        _tokenC.transfer(address(_oraclePair), 50e18);
        _oraclePair.mint(address(this));
    }

    function testGasMint_Initial() external {
        _tokenA.transfer(address(_freshPair), 50e18);
        _tokenD.transfer(address(_freshPair), 50e18);
        _freshPair.mint(address(this));
    }

    function testGasSwap() external {
        _tokenA.transfer(address(_oraclePair), 50e18);
        _oraclePair.swap(int256(50e18), true, address(_bob), bytes(""));
    }

    function testGasSwap_UpdateOracle() external {
        _skip(10_000);
        _tokenA.transfer(address(_oraclePair), 0.1e18);
        _oraclePair.swap(int256(0.1e18), true, address(_bob), bytes(""));
    }

    function testGasSwap_UpdateOracleClamped() external {
        _skip(10_000);
        _tokenA.transfer(address(_oraclePair), 50e18);
        _oraclePair.swap(int256(50e18), true, address(_bob), bytes(""));
    }

    function testGasBurn() external {
        vm.prank(_bob);
        _oraclePair.transfer(address(_oraclePair), Constants.INITIAL_MINT_AMOUNT / 2);
        _oraclePair.burn(address(this));
    }
}
