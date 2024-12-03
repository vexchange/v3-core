// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

contract ConstantProductPairGas is BaseTest {
    ConstantProductPair private _freshPair;
    ConstantProductPair private _simplePair;
    ConstantProductPair private _oraclePair;

    function setUp() external {
        _tokenA.mint(address(this), 100e18);
        _tokenB.mint(address(this), 100e18);
        _tokenC.mint(address(this), 100e18);
        _tokenD.mint(address(this), 100e18);

        // This pair is used to test initial mint cost.
        _freshPair = ConstantProductPair(_factory.createPair(IERC20(address(_tokenA)), IERC20(address(_tokenD)), 0));

        // Isolated pair to measure oracle cost.
        _oraclePair = ConstantProductPair(_factory.createPair(IERC20(address(_tokenB)), IERC20(address(_tokenC)), 0));
        _tokenB.mint(address(_oraclePair), 100e18);
        _tokenC.mint(address(_oraclePair), 100e18);
        _oraclePair.mint(_bob);

        // Take some oracle recordings and make storage slots non-zero.
        _skip(100);
        _tokenB.transfer(address(_oraclePair), 50e18);
        uint256 lOut = _oraclePair.swap(int256(-50e18), true, address(_bob), bytes(""));
        _skip(100);
        _tokenC.transfer(address(_oraclePair), lOut);
        _oraclePair.swap(int256(lOut), true, address(_bob), bytes(""));
        _skip(100);
        _oraclePair.burn(address(this));

        // This pair will let a user swap without writing the oracle.
        // solhint-disable-next-line reentrancy
        _simplePair = ConstantProductPair(_factory.createPair(IERC20(address(_tokenA)), IERC20(address(_tokenC)), 0));
        _tokenA.mint(address(_simplePair), 100e18);
        _tokenC.mint(address(_simplePair), 100e18);
        _simplePair.mint(_bob);
    }

    function testGasMint() external {
        _tokenA.transfer(address(_simplePair), 50e18);
        _tokenC.transfer(address(_simplePair), 50e18);
        _simplePair.mint(address(this));
    }

    function testGasMint_Initial() external {
        _tokenA.transfer(address(_freshPair), 50e18);
        _tokenD.transfer(address(_freshPair), 50e18);
        _freshPair.mint(address(this));
    }

    function testGasSwap() external {
        _tokenA.transfer(address(_simplePair), 50e18);
        _simplePair.swap(int256(50e18), true, address(this), bytes(""));
    }

    function testGasSwap_UpdateOracle() external {
        _skip(10_000);
        _tokenB.transfer(address(_oraclePair), 0.1e18);
        _oraclePair.swap(int256(-0.1e18), true, address(_bob), bytes(""));
    }

    function testGasSwap_UpdateOracleClamped() external {
        _skip(10_000);
        _tokenB.transfer(address(_oraclePair), 50e18);
        _oraclePair.swap(int256(-50e18), true, address(_bob), bytes(""));
    }

    function testGasBurn() external {
        vm.prank(_bob);
        _simplePair.transfer(address(_simplePair), Constants.INITIAL_MINT_AMOUNT / 2);
        _simplePair.burn(address(this));
    }
}
