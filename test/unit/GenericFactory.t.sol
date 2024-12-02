pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import "test/__fixtures/MintableERC20.sol";

import { BytesLib } from "test/helpers/BytesLib.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";

contract GenericFactoryTest is BaseTest {
    using BytesLib for bytes;

    function testCreatePair_AllCurves(uint256 aCurveId) public {
        // assume
        uint256 lCurveId = bound(aCurveId, 0, 1);

        // act
        address lPair = _factory.createPair(IERC20(address(_tokenA)), IERC20(address(_tokenC)), lCurveId);

        // assert
        assertEq(_factory.getPair(IERC20(address(_tokenA)), IERC20(address(_tokenC)), lCurveId), address(lPair));
    }

    function testCreatePair_MoreThan18Decimals(uint256 aCurveId) public {
        // assume
        uint256 lCurveId = bound(aCurveId, 0, 1);

        // act & assert
        vm.expectRevert("FACTORY: DEPLOY_FAILED");
        _createPair(address(_tokenE), address(_tokenA), lCurveId);
    }

    function testCreatePair_ZeroAddress(uint256 aCurveId) public {
        // assume
        uint256 lCurveId = bound(aCurveId, 0, 1);

        // act & assert
        vm.expectRevert("FACTORY: ZERO_ADDRESS");
        _createPair(address(0), address(_tokenA), lCurveId);
    }

    function testCreatePair_CurveDoesNotExist(uint256 aCurveId) public {
        // assume
        uint256 lCurveId = bound(aCurveId, 2, type(uint256).max);

        // act & assert
        vm.expectRevert(stdError.indexOOBError);
        _createPair(address(_tokenB), address(_tokenD), lCurveId);
    }

    function testCreatePair_IdenticalAddress(uint256 aCurveId) public {
        // assume
        uint256 lCurveId = bound(aCurveId, 0, 1);

        // act & assert
        vm.expectRevert("FACTORY: IDENTICAL_ADDRESSES");
        _createPair(address(_tokenD), address(_tokenD), lCurveId);
    }

    function testCreatePair_PairAlreadyExists(uint256 aCurveId) public {
        // assume
        uint256 lCurveId = bound(aCurveId, 0, 1);

        // act & assert
        vm.expectRevert("FACTORY: PAIR_EXISTS");
        _createPair(address(_tokenA), address(_tokenB), lCurveId);
    }

    function testCreatePair_Create2AddressCorrect() external {
        // arrange
        bytes32[] memory lCurves = _factory.curves();
        address lPair1 = _factory.createPair(IERC20(address(_tokenC)), IERC20(address(_tokenD)), 0);
        address lPair2 = _factory.createPair(IERC20(address(_tokenC)), IERC20(address(_tokenD)), 1);

        bytes memory lInitBytecode1 = _tokenC < _tokenD
            ? _factory.getBytecode(lCurves[0], IERC20(address(_tokenC)), IERC20(address(_tokenD)))
            : _factory.getBytecode(lCurves[0], IERC20(address(_tokenD)), IERC20(address(_tokenC)));
        bytes memory lInitBytecode2 = _tokenC < _tokenD
            ? _factory.getBytecode(lCurves[1], IERC20(address(_tokenC)), IERC20(address(_tokenD)))
            : _factory.getBytecode(lCurves[1], IERC20(address(_tokenD)), IERC20(address(_tokenC)));

        // act
        address lExpectedAddress1 = vm.computeCreate2Address(bytes32(0), keccak256(lInitBytecode1), address(_factory));
        address lExpectedAddress2 = vm.computeCreate2Address(bytes32(0), keccak256(lInitBytecode2), address(_factory));

        // assert
        assertEq(lPair1, lExpectedAddress1);
        assertEq(lPair2, lExpectedAddress2);
    }

    function testAllPairs() public {
        // arrange
        address lPair3 = _factory.createPair(IERC20(address(_tokenA)), IERC20(address(_tokenC)), 0);
        address lPair4 = _factory.createPair(IERC20(address(_tokenA)), IERC20(address(_tokenC)), 1);

        // act
        address[] memory lAllPairs = _factory.allPairs();

        // assert
        assertEq(lAllPairs.length, 4);
        assertEq(lAllPairs[0], address(_constantProductPair));
        assertEq(lAllPairs[1], address(_stablePair));
        assertEq(lAllPairs[2], lPair3);
        assertEq(lAllPairs[3], lPair4);
    }

    function testAddCurve() public {
        // arrange
        bytes memory lInitCode = bytes("dummy bytes");

        // act
        (uint256 lNewCurveId, bytes32 lCodeKey) = _factory.addCurve(lInitCode);

        // assert
        assertEq(lNewCurveId, 2);
        assertEq(lCodeKey, keccak256(lInitCode));
    }

    function testAddCurve_OnlyOwner() public {
        // arrange
        vm.prank(_alice);

        // act & assert
        vm.expectRevert("UNAUTHORIZED");
        _factory.addCurve(bytes("random bytes"));
    }

    function testGetPair() public {
        // assert - ensure double mapped
        assertEq(_factory.getPair(IERC20(address(_tokenA)), IERC20(address(_tokenB)), 0), address(_constantProductPair));
        assertEq(_factory.getPair(IERC20(address(_tokenB)), IERC20(address(_tokenA)), 0), address(_constantProductPair));
    }

    function testGetBytecode_CorrectConstructorData() external {
        // arrange
        bytes32[] memory lCurves = _factory.curves();

        // act
        bytes memory lBytecodeCP = _factory.getBytecode(lCurves[0], IERC20(address(_tokenA)), IERC20(address(_tokenB)));
        bytes memory lBytecodeSP = _factory.getBytecode(lCurves[1], IERC20(address(_tokenC)), IERC20(address(_tokenB)));

        // assert - the last bytes of the initCode should be the address of the second token, nothing more than that
        assertEq0(lBytecodeCP.slice(lBytecodeCP.length - 32, 32), abi.encode(_tokenB));
        assertEq0(lBytecodeSP.slice(lBytecodeSP.length - 32, 32), abi.encode(_tokenB));
    }
}
