// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { Address } from "@openzeppelin/utils/Address.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { Constants } from "src/Constants.sol";

import { GenericFactory } from "src/GenericFactory.sol";

contract ReservoirDeployer {
    using FactoryStoreLib for GenericFactory;

    error GuardianAddressZero();
    error OutOfOrder();
    error FactoryHash();
    error DeployFactoryFailed();
    error ConstantProductHash();
    error StableHash();
    error Threshold();
    error NotOwner();

    // Steps.
    uint256 public constant TERMINAL_STEP = 3;
    uint256 public step = 0;

    // Bytecode hashes.
    bytes32 public constant FACTORY_HASH = bytes32(0x87b0f73fafcf4bb41e013c8423dc679f6885527007d6c3f1e1834a670cbaadc5);
    bytes32 public constant CONSTANT_PRODUCT_HASH =
        bytes32(0xca5638aa898eb1a1ac18f8d0d604a7a9266f3a735b08a462115588b5ee7c9111);
    bytes32 public constant STABLE_HASH = bytes32(0xabdefb731a70385767ad3c64d191a67f1d4eb3a12f71e533d38ac677f93ef4c5);

    // Deployment addresses.
    GenericFactory public factory;

    constructor(address aGuardian1, address aGuardian2, address aGuardian3) {
        require(aGuardian1 != address(0) && aGuardian2 != address(0) && aGuardian3 != address(0), GuardianAddressZero());
        guardian1 = aGuardian1;
        guardian2 = aGuardian2;
        guardian3 = aGuardian3;
    }

    function isDone() external view returns (bool) {
        return step == TERMINAL_STEP;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            DEPLOYMENT STEPS
    //////////////////////////////////////////////////////////////////////////*/

    function deployFactory(bytes memory aFactoryBytecode) external returns (GenericFactory) {
        require(step == 0, OutOfOrder());
        require(keccak256(aFactoryBytecode) == FACTORY_HASH, FactoryHash());

        // Manual deployment from validated bytecode.
        address lFactoryAddress;
        assembly ("memory-safe") {
            lFactoryAddress :=
                create(
                    0, // value
                    add(aFactoryBytecode, 0x20), // offset
                    mload(aFactoryBytecode) // size
                )
        }
        require(lFactoryAddress != address(0), DeployFactoryFailed());

        // Write the factory address so we can start configuring it.
        factory = GenericFactory(lFactoryAddress);

        // Set global parameters.
        factory.write("Shared::platformFee", Constants.DEFAULT_PLATFORM_FEE);
        factory.write("Shared::platformFeeTo", address(this));
        factory.write("Shared::recoverer", address(this));
        factory.write("Shared::maxChangeRate", Constants.DEFAULT_MAX_CHANGE_RATE);
        factory.write("Shared::maxChangePerTrade", Constants.DEFAULT_MAX_CHANGE_PER_TRADE);

        // Step complete.
        step += 1;

        return factory;
    }

    function deployConstantProduct(bytes memory aConstantProductBytecode) external {
        require(step == 1, OutOfOrder());
        require(keccak256(aConstantProductBytecode) == CONSTANT_PRODUCT_HASH, ConstantProductHash());

        // Add curve & curve specific parameters.
        factory.addCurve(aConstantProductBytecode);
        factory.write("CP::swapFee", Constants.DEFAULT_SWAP_FEE_CP);

        // Step complete.
        step += 1;
    }

    function deployStable(bytes memory aStableBytecode) external {
        require(step == 2, OutOfOrder());
        require(keccak256(aStableBytecode) == STABLE_HASH, StableHash());

        // Add curve & curve specific parameters.
        factory.addCurve(aStableBytecode);
        factory.write("SP::swapFee", Constants.DEFAULT_SWAP_FEE_SP);
        factory.write("SP::amplificationCoefficient", Constants.DEFAULT_AMP_COEFF);

        // Step complete.
        step += 1;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            OWNERSHIP CLAIM
    //////////////////////////////////////////////////////////////////////////*/

    uint256 public constant GUARDIAN_THRESHOLD = 2;

    address public immutable guardian1;
    address public immutable guardian2;
    address public immutable guardian3;

    mapping(address => mapping(address => uint256)) public proposals;

    function proposeOwner(address aOwner) external {
        proposals[msg.sender][aOwner] = 1;
    }

    function clearProposedOwner(address aOwner) external {
        proposals[msg.sender][aOwner] = 0;
    }

    function claimOwnership() external {
        uint256 lGuardian1Support = proposals[guardian1][msg.sender];
        uint256 lGuardian2Support = proposals[guardian2][msg.sender];
        uint256 lGuardian3Support = proposals[guardian3][msg.sender];

        uint256 lSupport = lGuardian1Support + lGuardian2Support + lGuardian3Support;
        require(lSupport >= GUARDIAN_THRESHOLD, Threshold());

        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            OWNER ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    address public owner = address(0);

    modifier onlyOwner() {
        require(msg.sender == owner, NotOwner());
        _;
    }

    function claimFactory() external onlyOwner {
        factory.transferOwnership(msg.sender);
    }

    function rawCall(address aTarget, bytes calldata aCalldata, uint256 aValue)
        external
        onlyOwner
        returns (bytes memory)
    {
        return Address.functionCallWithValue(aTarget, aCalldata, aValue);
    }
}
