//// SPDX-License-Identifier: GPL-3.0-or-later
//pragma solidity ^0.8.0;
//
//import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
//
//import {
//    IERC20,
//    Bytes32Lib,
//    FactoryStoreLib,
//    StableMath,
//    IGenericFactory,
//    StablePair
//} from "src/curve/stable/StablePair.sol";
//
//contract StableMintBurn is StablePair {
//    using FactoryStoreLib for IGenericFactory;
//    using Bytes32Lib for bytes32;
//    using FixedPointMathLib for uint256;
//
//    string private constant PAIR_SWAP_FEE_NAME = "SP::swapFee";
//
//    // solhint-disable-next-line no-empty-blocks
//    constructor() StablePair(IERC20(address(0)), IERC20(address(0))) {
//        // no additional initialization logic is required as all constructor logic is in StablePair
//    }
//
//    function token0() public view override returns (IERC20) {
//        return this.token0();
//    }
//
//    function token1() public view override returns (IERC20) {
//        return this.token1();
//    }
//
//    function token0PrecisionMultiplier() public view override returns (uint128) {
//        return this.token0PrecisionMultiplier();
//    }
//
//    function token1PrecisionMultiplier() public view override returns (uint128) {
//        return this.token1PrecisionMultiplier();
//    }
//
//
//    function swap(int256, bool, address, bytes calldata) external pure override returns (uint256) {
//        revert("SMB: IMPOSSIBLE");
//    }
//
//    function mintFee(uint256 aReserve0, uint256 aReserve1)
//        external
//        virtual
//        override
//        returns (uint256 rTotalSupply, uint256 rD)
//    {
//        require(msg.sender == address(this), "SP: NOT_SELF");
//        return _mintFee(aReserve0, aReserve1);
//    }
//
//    function _mintFee(uint256 aReserve0, uint256 aReserve1) internal returns (uint256 rTotalSupply, uint256 rD) {
//        bool lFeeOn = platformFee > 0;
//        rTotalSupply = totalSupply();
//        rD = StableMath._computeLiquidityFromAdjustedBalances(
//            aReserve0 * token0PrecisionMultiplier(), aReserve1 * token1PrecisionMultiplier(), 2 * lastInvariantAmp
//        );
//        if (lFeeOn) {
//            uint256 lDLast = lastInvariant;
//            if (rD > lDLast) {
//                // @dev `platformFee` % of increase in liquidity.
//                uint256 lPlatformFee = platformFee;
//                // will not phantom overflow as rTotalSupply is max 128 bits. and (rD - lDLast) is usually within 70 bits and lPlatformFee is max 1e6 (20 bits)
//                uint256 lNumerator = rTotalSupply * (rD - lDLast) * lPlatformFee;
//                // will not phantom overflow as FEE_ACCURACY and lPlatformFee are max 1e6 (20 bits), and rD and lDLast are max 128 bits
//                uint256 lDenominator = (FEE_ACCURACY - lPlatformFee) * rD + lPlatformFee * lDLast;
//                uint256 lPlatformShares = lNumerator / lDenominator;
//
//                if (lPlatformShares != 0) {
//                    address lPlatformFeeTo = this.factory().read(PLATFORM_FEE_TO_NAME).toAddress();
//
//                    _mint(lPlatformFeeTo, lPlatformShares);
//                    rTotalSupply += lPlatformShares;
//                }
//            }
//        }
//    }
//}
