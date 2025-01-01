// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";

import { IReservoirCallee } from "src/interfaces/IReservoirCallee.sol";
import { IGenericFactory } from "src/interfaces/IGenericFactory.sol";

import { ReservoirPair, IERC20 } from "src/ReservoirPair.sol";
import { AmplificationData } from "src/structs/AmplificationData.sol";
import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { StableMath } from "src/libraries/StableMath.sol";
import { StableOracleMath } from "src/libraries/StableOracleMath.sol";

contract StablePair is ReservoirPair {
    using FactoryStoreLib for IGenericFactory;
    using Bytes32Lib for bytes32;
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;

    string private constant PAIR_SWAP_FEE_NAME = "SP::swapFee";
    string private constant AMPLIFICATION_COEFFICIENT_NAME = "SP::amplificationCoefficient";

    event RampA(uint64 initialAPrecise, uint64 futureAPrecise, uint64 initialTime, uint64 futureTime);
    event StopRampA(uint64 currentAPrecise, uint64 time);

    error InvalidA();
    error InvalidDuration();
    error AmpRateTooHigh();
    error NotSelf();
    error InvalidMintAmounts();
    error NonOptimalFeeTooLarge();

    AmplificationData public ampData;

    // We need the 2 variables below to calculate the growth in liquidity between
    // minting and burning, for the purpose of calculating platformFee.
    uint192 public lastInvariant;
    uint64 public lastInvariantAmp;

    constructor(IERC20 aToken0, IERC20 aToken1) ReservoirPair(aToken0, aToken1, PAIR_SWAP_FEE_NAME) {
        uint64 lImpreciseA = factory.read(AMPLIFICATION_COEFFICIENT_NAME).toUint64();
        require(lImpreciseA >= StableMath.MIN_A && lImpreciseA <= StableMath.MAX_A, InvalidA());

        ampData.initialA = lImpreciseA * uint64(StableMath.A_PRECISION);
        ampData.futureA = ampData.initialA;
        ampData.initialATime = uint64(block.timestamp);
        ampData.futureATime = uint64(block.timestamp);
    }

    function rampA(uint64 aFutureARaw, uint64 aFutureATime) external onlyFactory {
        require(aFutureARaw >= StableMath.MIN_A && aFutureARaw <= StableMath.MAX_A, InvalidA());

        uint64 lFutureAPrecise = aFutureARaw * uint64(StableMath.A_PRECISION);

        uint256 duration = aFutureATime - block.timestamp;
        require(duration >= StableMath.MIN_RAMP_TIME, InvalidDuration());

        uint64 lCurrentAPrecise = _getCurrentAPrecise();

        // Daily rate = (futureA / currentA) / duration * 1 day.
        require(
            lFutureAPrecise > lCurrentAPrecise
                ? lFutureAPrecise * 1 days <= lCurrentAPrecise * duration * StableMath.MAX_AMP_UPDATE_DAILY_RATE
                : lCurrentAPrecise * 1 days <= lFutureAPrecise * duration * StableMath.MAX_AMP_UPDATE_DAILY_RATE,
            AmpRateTooHigh()
        );

        ampData.initialA = lCurrentAPrecise;
        ampData.futureA = lFutureAPrecise;
        ampData.initialATime = uint64(block.timestamp);
        ampData.futureATime = aFutureATime;

        emit RampA(lCurrentAPrecise, lFutureAPrecise, uint64(block.timestamp), aFutureATime);
    }

    function stopRampA() external onlyFactory {
        uint64 lCurrentAPrecise = _getCurrentAPrecise();

        ampData.initialA = lCurrentAPrecise;
        ampData.futureA = lCurrentAPrecise;
        uint64 lTimestamp = uint64(block.timestamp);
        ampData.initialATime = lTimestamp;
        ampData.futureATime = lTimestamp;

        emit StopRampA(lCurrentAPrecise, lTimestamp);
    }

    function mint(address aTo) external virtual override nonReentrant returns (uint256 rLiquidity) {
        // NB: Must sync management PNL before we load reserves.
        (uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast, uint16 lIndex) = getReserves();
        (lReserve0, lReserve1) = _syncManaged(lReserve0, lReserve1);

        uint256 lBalance0 = _totalToken0();
        uint256 lBalance1 = _totalToken1();

        uint256 lNewLiq = _computeLiquidity(lBalance0, lBalance1);
        uint256 lAmount0 = lBalance0 - lReserve0;
        uint256 lAmount1 = lBalance1 - lReserve1;

        (uint256 lFee0, uint256 lFee1) = _nonOptimalMintFee(lAmount0, lAmount1, lReserve0, lReserve1);
        lReserve0 += lFee0;
        lReserve1 += lFee1;

        (uint256 lTotalSupply, uint256 lOldLiq) = _mintFee(lReserve0, lReserve1);

        if (lTotalSupply == 0) {
            require(lAmount0 > 0 && lAmount1 > 0, InvalidMintAmounts());
            rLiquidity = lNewLiq - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            // will only phantom overflow and revert when lTotalSupply and lNewLiq is in the range of uint128 which will
            // only happen if:
            // 1. both tokens have 0 decimals (1e18 is 60 bits) and the amounts are each around 68 bits
            // 2. both tokens have 6 decimals (1e12 is 40 bits) and the amounts are each around 88 bits
            // in which case the mint will fail anyway because it would have reverted at _computeLiquidity
            rLiquidity = (lNewLiq - lOldLiq) * lTotalSupply / lOldLiq;
        }
        require(rLiquidity != 0, InsufficientLiqMinted());
        _mint(aTo, rLiquidity);

        // Casting is safe as the max invariant would be 2 * uint104 * uint60 (in the case of tokens
        // with 0 decimal places).
        // Which results in 112 + 60 + 1 = 173 bits.
        // Which fits into uint192.
        lastInvariant = lNewLiq.toUint192();
        lastInvariantAmp = _getCurrentAPrecise();

        emit Mint(msg.sender, lAmount0, lAmount1);

        _update(lBalance0, lBalance1, lReserve0, lReserve1, lBlockTimestampLast, lIndex);
        _managerCallback();
    }

    function burn(address aTo) external override nonReentrant returns (uint256 rAmount0, uint256 rAmount1) {
        // NB: Must sync management PNL before we load reserves.
        (uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast, uint16 lIndex) = getReserves();
        (lReserve0, lReserve1) = _syncManaged(lReserve0, lReserve1);

        uint256 liquidity = balanceOf(address(this));

        uint256 lTotalSupply;
        // this is a safety feature that prevents revert when removing liquidity
        // i.e. removing liquidity should always succeed under all circumstances
        // so if the iterative functions revert, we just have to forgo the platformFee calculations
        // and use the current totalSupply of LP tokens for calculations since there is no new
        // LP tokens minted for platformFee
        try StablePair(this).mintFee(lReserve0, lReserve1) returns (uint256 rTotalSupply, uint256) {
            lTotalSupply = rTotalSupply;
        } catch {
            lTotalSupply = totalSupply();
        }

        rAmount0 = liquidity.fullMulDiv(lReserve0, lTotalSupply);
        rAmount1 = liquidity.fullMulDiv(lReserve1, lTotalSupply);

        _burn(address(this), liquidity);

        _checkedTransfer(token0, aTo, rAmount0, lReserve0, lReserve1);
        _checkedTransfer(token1, aTo, rAmount1, lReserve0, lReserve1);

        uint256 lBalance0 = _totalToken0();
        uint256 lBalance1 = _totalToken1();
        lastInvariant = uint192(_computeLiquidity(lBalance0, lBalance1));
        lastInvariantAmp = _getCurrentAPrecise();
        emit Burn(msg.sender, rAmount0, rAmount1);

        _update(lBalance0, lBalance1, lReserve0, lReserve1, lBlockTimestampLast, lIndex);
        _managerCallback();
    }

    function mintFee(uint256 aReserve0, uint256 aReserve1)
        external
        virtual
        returns (uint256 rTotalSupply, uint256 rD)
    {
        require(msg.sender == address(this), NotSelf());
        return _mintFee(aReserve0, aReserve1);
    }

    /// @dev This fee is charged to cover for `swapFee` when users add unbalanced liquidity.
    /// multiplications will not phantom overflow given the following conditions:
    /// 1. reserves are <= uint104
    /// 2. aAmount0 and aAmount1 <= uint104 as it would revert anyway at _update if above uint104
    /// 3. swapFee <= 0.02e6
    function _nonOptimalMintFee(uint256 aAmount0, uint256 aAmount1, uint256 aReserve0, uint256 aReserve1)
        internal
        view
        returns (uint256 rToken0Fee, uint256 rToken1Fee)
    {
        if (aReserve0 == 0 || aReserve1 == 0) return (0, 0);
        uint256 amount1Optimal = aAmount0 * aReserve1 / aReserve0;

        if (amount1Optimal <= aAmount1) {
            rToken1Fee = swapFee * (aAmount1 - amount1Optimal) / (2 * FEE_ACCURACY);
        } else {
            uint256 amount0Optimal = aAmount1 * aReserve0 / aReserve1;
            rToken0Fee = swapFee * (aAmount0 - amount0Optimal) / (2 * FEE_ACCURACY);
        }
        require(rToken0Fee <= type(uint104).max && rToken1Fee <= type(uint104).max, NonOptimalFeeTooLarge());
    }

    function _mintFee(uint256 aReserve0, uint256 aReserve1) internal returns (uint256 rTotalSupply, uint256 rD) {
        bool lFeeOn = platformFee > 0;
        rTotalSupply = totalSupply();
        rD = StableMath._computeLiquidityFromAdjustedBalances(
            aReserve0 * token0PrecisionMultiplier, aReserve1 * token1PrecisionMultiplier, 2 * lastInvariantAmp
        );
        if (lFeeOn) {
            uint256 lDLast = lastInvariant;
            if (rD > lDLast) {
                // @dev `platformFee` % of increase in liquidity.
                uint256 lPlatformFee = platformFee;
                // will not phantom overflow as rTotalSupply is max 128 bits. and (rD - lDLast) is usually within 70
                // bits and lPlatformFee is max 1e6 (20 bits)
                uint256 lNumerator = rTotalSupply * (rD - lDLast) * lPlatformFee;
                // will not phantom overflow as FEE_ACCURACY and lPlatformFee are max 1e6 (20 bits), and rD and lDLast
                // are max 128 bits
                uint256 lDenominator = (FEE_ACCURACY - lPlatformFee) * rD + lPlatformFee * lDLast;
                uint256 lPlatformShares = lNumerator / lDenominator;

                if (lPlatformShares != 0) {
                    address lPlatformFeeTo = this.factory().read(PLATFORM_FEE_TO_NAME).toAddress();

                    _mint(lPlatformFeeTo, lPlatformShares);
                    rTotalSupply += lPlatformShares;
                }
            }
        }
    }

    function swap(int256 aAmount, bool aExactIn, address aTo, bytes calldata aData)
        external
        virtual
        override
        nonReentrant
        returns (uint256 rAmountOut)
    {
        require(aAmount != 0, AmountZero());
        (uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast, uint16 lIndex) = getReserves();
        uint256 lAmountIn;
        IERC20 lTokenOut;

        if (aExactIn) {
            // swap token0 exact in for token1 variable out
            if (aAmount > 0) {
                lTokenOut = token1;
                lAmountIn = uint256(aAmount);
                rAmountOut = _getAmountOut(lAmountIn, lReserve0, lReserve1, true);
            }
            // swap token1 exact in for token0 variable out
            else {
                lTokenOut = token0;
                unchecked {
                    lAmountIn = uint256(-aAmount);
                }
                rAmountOut = _getAmountOut(lAmountIn, lReserve0, lReserve1, false);
            }
        } else {
            // swap token1 variable in for token0 exact out
            if (aAmount > 0) {
                rAmountOut = uint256(aAmount);
                require(rAmountOut < lReserve0, InsufficientLiq());
                lTokenOut = token0;
                lAmountIn = _getAmountIn(rAmountOut, lReserve0, lReserve1, true);
            }
            // swap token0 variable in for token1 exact out
            else {
                unchecked {
                    rAmountOut = uint256(-aAmount);
                }
                require(rAmountOut < lReserve1, InsufficientLiq());
                lTokenOut = token1;
                lAmountIn = _getAmountIn(rAmountOut, lReserve0, lReserve1, false);
            }
        }

        _checkedTransfer(lTokenOut, aTo, rAmountOut, lReserve0, lReserve1);

        if (aData.length > 0) {
            IReservoirCallee(aTo).reservoirCall(
                msg.sender,
                lTokenOut == token0 ? int256(rAmountOut) : -int256(lAmountIn),
                lTokenOut == token1 ? int256(rAmountOut) : -int256(lAmountIn),
                aData
            );
        }

        uint256 lBalance0 = _totalToken0();
        uint256 lBalance1 = _totalToken1();

        uint256 lReceived = lTokenOut == token0 ? lBalance1 - lReserve1 : lBalance0 - lReserve0;
        require(lReceived >= lAmountIn, InsufficientAmtIn());

        _update(lBalance0, lBalance1, uint104(lReserve0), uint104(lReserve1), lBlockTimestampLast, lIndex);
        emit Swap(msg.sender, lTokenOut == token1, lReceived, rAmountOut, aTo);
    }

    function _getAmountOut(uint256 aAmountIn, uint256 aReserve0, uint256 aReserve1, bool aToken0In)
        private
        view
        returns (uint256)
    {
        return StableMath._getAmountOut(
            aAmountIn,
            aReserve0,
            aReserve1,
            token0PrecisionMultiplier,
            token1PrecisionMultiplier,
            aToken0In,
            swapFee,
            _getNA()
        );
    }

    function _getAmountIn(uint256 aAmountOut, uint256 aReserve0, uint256 aReserve1, bool aToken0Out)
        private
        view
        returns (uint256)
    {
        return StableMath._getAmountIn(
            aAmountOut,
            aReserve0,
            aReserve1,
            token0PrecisionMultiplier,
            token1PrecisionMultiplier,
            aToken0Out,
            swapFee,
            _getNA()
        );
    }

    /// @notice Calculates D, the StableSwap invariant, based on a set of balances and a particular A.
    /// See the StableSwap paper for details.
    /// @dev Originally
    /// https://github.com/saddle-finance/saddle-contract/blob/0b76f7fb519e34b878aa1d58cffc8d8dc0572c12/contracts/SwapUtils.sol#L319.
    /// @return rLiquidity The invariant, at the precision of the pool.
    function _computeLiquidity(uint256 aReserve0, uint256 aReserve1) internal view returns (uint256 rLiquidity) {
        unchecked {
            uint256 adjustedReserve0 = aReserve0 * token0PrecisionMultiplier;
            uint256 adjustedReserve1 = aReserve1 * token1PrecisionMultiplier;
            rLiquidity = StableMath._computeLiquidityFromAdjustedBalances(adjustedReserve0, adjustedReserve1, _getNA());
        }
    }

    function _getCurrentAPrecise() internal view returns (uint64 rCurrentA) {
        uint64 futureA = ampData.futureA;
        uint64 futureATime = ampData.futureATime;

        if (block.timestamp < futureATime) {
            uint64 initialA = ampData.initialA;
            uint64 initialATime = ampData.initialATime;
            uint64 rampDuration = futureATime - initialATime;
            uint64 rampElapsed = uint64(block.timestamp) - initialATime;

            if (futureA > initialA) {
                uint64 rampDelta = futureA - initialA;
                rCurrentA = initialA + rampElapsed * rampDelta / rampDuration;
            } else {
                uint64 rampDelta = initialA - futureA;
                rCurrentA = initialA - rampElapsed * rampDelta / rampDuration;
            }
        } else {
            rCurrentA = futureA;
        }
    }

    /// @dev number of coins in the pool multiplied by A precise
    function _getNA() internal view returns (uint256) {
        return 2 * _getCurrentAPrecise();
    }

    function getCurrentA() external view returns (uint64) {
        return _getCurrentAPrecise() / uint64(StableMath.A_PRECISION);
    }

    function getCurrentAPrecise() external view returns (uint64) {
        return _getCurrentAPrecise();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ORACLE METHODS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ReservoirPair
    function _calcSpotAndLogPrice(uint256 aBalance0, uint256 aBalance1)
        internal
        view
        override
        returns (uint256 spotPrice, int256 logSpotPrice)
    {
        return StableOracleMath.calcLogPrice(
            _getCurrentAPrecise(), aBalance0 * token0PrecisionMultiplier, aBalance1 * token1PrecisionMultiplier
        );
    }
}
