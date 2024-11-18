// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { MintableERC20 } from "test/__fixtures/MintableERC20.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { Create2Lib } from "src/libraries/Create2Lib.sol";
import { Constants } from "src/Constants.sol";
import { OracleCaller } from "src/oracle/OracleCaller.sol";

import { ReservoirDeployer } from "src/ReservoirDeployer.sol";
import { GenericFactory, IERC20 } from "src/GenericFactory.sol";
import { ReservoirPair } from "src/ReservoirPair.sol";
import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";
import { StablePair } from "src/curve/stable/StablePair.sol";

// solhint-disable-next-line max-states-count
abstract contract BaseTest is Test {
    using FactoryStoreLib for GenericFactory;

    ReservoirDeployer internal _deployer = _ensureDeployerExists();
    GenericFactory internal _factory;

    address internal _recoverer = address(_deployer);
    address internal _platformFeeTo = address(_deployer);
    address internal _alice = _makeAddress("alice");
    address internal _bob = _makeAddress("bob");
    address internal _cal = _makeAddress("cal");

    MintableERC20 internal _tokenA = new MintableERC20("TokenA", "TA", 18);
    MintableERC20 internal _tokenB = new MintableERC20("TokenB", "TB", 18);
    MintableERC20 internal _tokenC = new MintableERC20("TokenC", "TC", 18);
    MintableERC20 internal _tokenD = new MintableERC20("TokenD", "TD", 6);
    MintableERC20 internal _tokenE = new MintableERC20("TokenE", "TE", 25);
    MintableERC20 internal _tokenF = new MintableERC20("TokenF", "TF", 0);

    ConstantProductPair internal _constantProductPair;
    StablePair internal _stablePair;

    OracleCaller internal _oracleCaller;

    modifier randomizeStartTime(uint32 aNewStartTime) {
        vm.assume(aNewStartTime > 1);

        vm.warp(aNewStartTime);
        _;
    }

    constructor() {
        try vm.envString("FOUNDRY_PROFILE") returns (string memory lProfile) {
            if (keccak256(abi.encodePacked(lProfile)) == keccak256(abi.encodePacked("coverage"))) {
                vm.writeJson(_deployerMetadata(), "script/unoptimized-deployer-meta");
            }
        } catch {
            vm.writeJson(_deployerMetadata(), "script/optimized-deployer-meta");
        }

        // Execute standard & deterministic Reservoir deployment.
        _factory = _deployer.deployFactory(type(GenericFactory).creationCode);
        _deployer.deployConstantProduct(type(ConstantProductPair).creationCode);
        _deployer.deployStable(type(StablePair).creationCode);
        _oracleCaller = _deployer.deployOracleCaller(type(OracleCaller).creationCode);

        // Claim ownership of all contracts for our test contract.
        _deployer.proposeOwner(address(this));
        _deployer.claimOwnership();
        _deployer.claimFactory();
        _deployer.claimOracleCaller();

        // Whitelist our test contract to call the oracle.
        _oracleCaller.whitelistAddress(address(this), true);

        // Setup default ConstantProductPair.
        _constantProductPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenB), 0));
        _tokenA.mint(address(_constantProductPair), Constants.INITIAL_MINT_AMOUNT);
        _tokenB.mint(address(_constantProductPair), Constants.INITIAL_MINT_AMOUNT);
        _constantProductPair.mint(_alice);

        // Setup default StablePair.
        _stablePair = StablePair(_createPair(address(_tokenA), address(_tokenB), 1));
        _tokenA.mint(address(_stablePair), Constants.INITIAL_MINT_AMOUNT);
        _tokenB.mint(address(_stablePair), Constants.INITIAL_MINT_AMOUNT);
        _stablePair.mint(_alice);
    }

    function _deployerMetadata() private returns (string memory rDeployerMetadata) {
        string memory lObjectKey = "qwerty";

        vm.serializeBytes32(lObjectKey, "factory_hash", keccak256(type(GenericFactory).creationCode));
        vm.serializeBytes32(lObjectKey, "constant_product_hash", keccak256(type(ConstantProductPair).creationCode));
        vm.serializeBytes32(lObjectKey, "stable_hash", keccak256(type(StablePair).creationCode));
        rDeployerMetadata =
            vm.serializeBytes32(lObjectKey, "oracle_caller_hash", keccak256(type(OracleCaller).creationCode));
    }

    function _ensureDeployerExists() internal returns (ReservoirDeployer rDeployer) {
        bytes memory lInitCode = abi.encodePacked(type(ReservoirDeployer).creationCode);
        lInitCode = abi.encodePacked(lInitCode, abi.encode(address(this), address(this), address(this)));
        address lDeployer = Create2Lib.computeAddress(address(this), lInitCode, bytes32(0));

        if (lDeployer.code.length == 0) {
            rDeployer = new ReservoirDeployer{salt: bytes32(0)}(address(this), address(this), address(this));
            require(address(rDeployer) == lDeployer, "CREATE2 ADDRESS MISMATCH");
            require(address(rDeployer) != address(0), "DEPLOY FACTORY FAILED");
        } else {
            rDeployer = ReservoirDeployer(lDeployer);
        }
    }

    function _makeAddress(string memory aName) internal returns (address) {
        address lAddress = address(uint160(uint256(keccak256(abi.encodePacked(aName)))));
        vm.label(lAddress, aName);

        return lAddress;
    }

    function _createPair(address aTokenA, address aTokenB, uint256 aCurveId) internal returns (address rPair) {
        rPair = _factory.createPair(IERC20(aTokenA), IERC20(aTokenB), aCurveId);
    }

    function _stepTime(uint256 aTime) internal {
        vm.roll(block.number + 1);
        skip(aTime);
    }

    function _writeObservation(
        ReservoirPair aPair,
        uint256 aIndex,
        int24 aLogInstantRawPrice,
        int24 aLogInstantClampedPrice,
        int88 aLogAccRawPrice,
        int88 aLogAccClampedPrice,
        uint32 aTime
    ) internal {
        require(aTime < 2 ** 31, "TIMESTAMP TOO BIG");
        bytes32 lEncoded = bytes32(
            bytes.concat(
                bytes4(aTime),
                bytes11(uint88(aLogAccClampedPrice)),
                bytes11(uint88(aLogAccRawPrice)),
                bytes3(uint24(aLogInstantClampedPrice)),
                bytes3(uint24(aLogInstantRawPrice))
            )
        );

        vm.record();
        _oracleCaller.observation(aPair, aIndex);
        (bytes32[] memory lAccesses,) = vm.accesses(address(aPair));
        require(lAccesses.length == 2, "invalid number of accesses");

        vm.store(address(aPair), lAccesses[1], lEncoded);
    }
}
