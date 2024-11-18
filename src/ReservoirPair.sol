// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { SafeCast } from "@openzeppelin/utils/math/SafeCast.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { StdMath } from "src/libraries/StdMath.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";
import { Buffer } from "src/libraries/Buffer.sol";

import { IAssetManager, IERC20 } from "src/interfaces/IAssetManager.sol";
import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";
import { IGenericFactory } from "src/interfaces/IGenericFactory.sol";

import { Observation } from "src/structs/Observation.sol";
import { Slot0 } from "src/structs/Slot0.sol";
import { ReservoirERC20 } from "src/ReservoirERC20.sol";

abstract contract ReservoirPair is IAssetManagedPair, ReservoirERC20 {
    using FactoryStoreLib for IGenericFactory;
    using Bytes32Lib for bytes32;
    using SafeCast for uint256;
    using SafeTransferLib for address;
    using StdMath for uint256;
    using FixedPointMathLib for uint256;
    using Buffer for uint16;

    uint256 public constant MINIMUM_LIQUIDITY = 1e3;
    uint256 public constant FEE_ACCURACY = 1_000_000; // 100%

    IGenericFactory public immutable factory;

    modifier onlyFactory() {
        require(msg.sender == address(factory), "RP: FORBIDDEN");
        _;
    }

    constructor(IERC20 aToken0, IERC20 aToken1, string memory aSwapFeeName, bool aNotStableMintBurn) {
        factory = IGenericFactory(msg.sender);
        _token0 = aToken0;
        _token1 = aToken1;

        _token0PrecisionMultiplier = aNotStableMintBurn ? uint128(10) ** (18 - aToken0.decimals()) : 0;
        _token1PrecisionMultiplier = aNotStableMintBurn ? uint128(10) ** (18 - aToken1.decimals()) : 0;
        swapFeeName = keccak256(bytes(aSwapFeeName));

        if (aNotStableMintBurn) {
            updateSwapFee();
            updatePlatformFee();
            updateOracleCaller();
            setMaxChangeRate(factory.read(MAX_CHANGE_RATE_NAME).toUint256());
        }
    }

    /*//////////////////////////////////////////////////////////////////////////

                                IMMUTABLE GETTERS

    Allows StableMintBurn to override the immutables to instead make a call to
    address(this) so the action is delegatecall safe.

    //////////////////////////////////////////////////////////////////////////*/

    IERC20 internal immutable _token0;
    IERC20 internal immutable _token1;

    // Multipliers for each pooled token's precision to get to POOL_PRECISION_DECIMALS. For example,
    // TBTC has 18 decimals, so the multiplier should be 1. WBTC has 8, so the multiplier should be
    // 10 ** 18 / 10 ** 8 => 10 ** 10.
    uint128 internal immutable _token0PrecisionMultiplier;
    uint128 internal immutable _token1PrecisionMultiplier;

    function token0() public view virtual returns (IERC20) {
        return _token0;
    }

    function token1() public view virtual returns (IERC20) {
        return _token1;
    }

    function token0PrecisionMultiplier() public view virtual returns (uint128) {
        return _token0PrecisionMultiplier;
    }

    function token1PrecisionMultiplier() public view virtual returns (uint128) {
        return _token1PrecisionMultiplier;
    }

    /*//////////////////////////////////////////////////////////////////////////

                                SLOT0 & RESERVES

    //////////////////////////////////////////////////////////////////////////*/

    Slot0 internal _slot0 = Slot0({ reserve0: 0, reserve1: 0, packedTimestamp: 0, index: Buffer.SIZE - 1});

    function _currentTime() internal view returns (uint32) {
        return uint32(block.timestamp & 0x7FFFFFFF);
    }

    function _splitSlot0Timestamp(uint32 aPackedTimestamp) internal pure returns (uint32 rTimestamp, bool rLocked) {
        rLocked = aPackedTimestamp >> 31 == 1;
        rTimestamp = aPackedTimestamp & 0x7FFFFFFF;
    }

    /// @notice Writes the packed timestamp & re-entrancy guard into slot0.
    /// @dev The timestamp argument must not exceed 2**31.
    function _writeSlot0Timestamp(Slot0 storage sSlot0, uint32 aTimestamp, bool aLocked) internal {
        uint32 lLocked = aLocked ? uint32(1 << 31) : uint32(0);
        sSlot0.packedTimestamp = aTimestamp | lLocked;
    }

    function _lockAndLoad()
        internal
        returns (Slot0 storage, uint104 rReserve0, uint104 rReserve1, uint32 rBlockTimestampLast, uint16 rIndex)
    {
        Slot0 storage sSlot0 = _slot0;

        // Load slot0 values.
        bool lLock;
        rReserve0 = sSlot0.reserve0;
        rReserve1 = sSlot0.reserve1;
        (rBlockTimestampLast, lLock) = _splitSlot0Timestamp(sSlot0.packedTimestamp);
        rIndex = sSlot0.index;

        // Acquire reentrancy lock.
        require(!lLock, "REENTRANCY");
        _writeSlot0Timestamp(sSlot0, rBlockTimestampLast, true);

        return (sSlot0, rReserve0, rReserve1, rBlockTimestampLast, rIndex);
    }

    function _unlock(Slot0 storage sSlot0, uint32 aBlockTimestampLast) internal {
        _writeSlot0Timestamp(sSlot0, aBlockTimestampLast, false);
    }

    /// @notice Updates reserves with new balances.
    /// @notice On the first call per block, accumulate price oracle using previous instant prices and write the new instant prices.
    /// @dev The price is not updated on subsequent swaps as manipulating
    /// the instantaneous price does not materially affect the TWAP, especially when using clamped pricing.
    function _updateAndUnlock(
        Slot0 storage sSlot0,
        uint256 aBalance0,
        uint256 aBalance1,
        uint256 aReserve0,
        uint256 aReserve1,
        uint32 aBlockTimestampLast
    ) internal {
        require(aBalance0 <= type(uint104).max && aBalance1 <= type(uint104).max, "RP: OVERFLOW");
        require(aReserve0 <= type(uint104).max && aReserve1 <= type(uint104).max, "RP: OVERFLOW");

        uint32 lBlockTimestamp = _currentTime();
        uint32 lTimeElapsed;
        unchecked {
            // underflow is desired
            // however in the case where no swaps happen in ~68 years (2 ** 31 seconds) the timeElapsed would underflow twice
            lTimeElapsed = lBlockTimestamp - aBlockTimestampLast;

            // both balance should never be zero, but necessary to check so we don't pass 0 values into arithmetic operations
            // shortcut to calculate aBalance0 > 0 && aBalance1 > 0
            if (aBalance0 * aBalance1 > 0) {
                Observation storage lPrevious = _observations[sSlot0.index];
                (uint256 lInstantRawPrice, int256 lLogInstantRawPrice) = _calcSpotAndLogPrice(aBalance0, aBalance1);

                // a new sample is not written for the first mint
                // shortcut to calculate lTimeElapsed > 0 && aReserve0 > 0 && aReserve1 > 0
                if (lTimeElapsed * aReserve0 * aReserve1 > 0) {
                    (, int256 lLogInstantClampedPrice) = _calcClampedPrice(
                        lInstantRawPrice,
                        lLogInstantRawPrice,
                        LogCompression.fromLowResLog(lPrevious.logInstantClampedPrice),
                        lTimeElapsed,
                        aBlockTimestampLast // assert: aBlockTimestampLast == lPrevious.timestamp
                    );
                    _updateOracleNewSample(
                        sSlot0, lPrevious, lLogInstantRawPrice, lLogInstantClampedPrice, lTimeElapsed, lBlockTimestamp
                    );
                } else {
                    // for instant price updates in the same timestamp, we use the time difference from the previous oracle observation as the time elapsed
                    lTimeElapsed = lBlockTimestamp - lPrevious.timestamp;

                    (, int256 lLogInstantClampedPrice) = _calcClampedPrice(
                        lInstantRawPrice,
                        lLogInstantRawPrice,
                        LogCompression.fromLowResLog(lPrevious.logInstantClampedPrice),
                        lTimeElapsed,
                        lPrevious.timestamp
                    );

                    _updateOracleInstantPrices(lPrevious, lLogInstantRawPrice, lLogInstantClampedPrice);
                }
            }
        }

        // update reserves to match latest balances
        sSlot0.reserve0 = uint104(aBalance0);
        sSlot0.reserve1 = uint104(aBalance1);
        _writeSlot0Timestamp(sSlot0, lBlockTimestamp, false);

        emit Sync(uint104(aBalance0), uint104(aBalance1));
    }

    function getReserves()
        public
        view
        returns (uint104 rReserve0, uint104 rReserve1, uint32 rBlockTimestampLast, uint16 rIndex)
    {
        Slot0 memory lSlot0 = _slot0;

        rReserve0 = lSlot0.reserve0;
        rReserve1 = lSlot0.reserve1;
        (rBlockTimestampLast,) = _splitSlot0Timestamp(lSlot0.packedTimestamp);
        rIndex = lSlot0.index;
    }

    /// @notice Force reserves to match balances.
    function sync() external {
        (Slot0 storage sSlot0, uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        (lReserve0, lReserve1) = _syncManaged(lReserve0, lReserve1);

        _updateAndUnlock(sSlot0, _totalToken0(), _totalToken1(), lReserve0, lReserve1, lBlockTimestampLast);
    }

    /// @notice Force balances to match reserves.
    function skim(address aTo) external {
        (Slot0 storage sSlot0, uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();

        _checkedTransfer(token0(), aTo, _totalToken0() - lReserve0, lReserve0, lReserve1);
        _checkedTransfer(token1(), aTo, _totalToken1() - lReserve1, lReserve0, lReserve1);
        _unlock(sSlot0, lBlockTimestampLast);
    }

    /*//////////////////////////////////////////////////////////////////////////

                                ADMIN ACTIONS

    //////////////////////////////////////////////////////////////////////////*/

    event SwapFee(uint256 newSwapFee);
    event CustomSwapFee(uint256 newCustomSwapFee);
    event PlatformFee(uint256 newPlatformFee);
    event CustomPlatformFee(uint256 newCustomPlatformFee);

    string internal constant PLATFORM_FEE_TO_NAME = "Shared::platformFeeTo";
    string private constant PLATFORM_FEE_NAME = "Shared::platformFee";
    string private constant RECOVERER_NAME = "Shared::recoverer";
    bytes4 private constant TRANSFER = bytes4(keccak256("transfer(address,uint256)"));
    bytes32 internal immutable swapFeeName;

    /// @notice Maximum allowed swap fee, which is 2%.
    uint256 public constant MAX_SWAP_FEE = 0.02e6;
    /// @notice Current swap fee.
    uint256 public swapFee;
    /// @notice Custom swap fee override for the pair, max uint256 indicates no override.
    uint256 public customSwapFee = type(uint256).max;

    /// @notice Maximum allowed platform fee, which is 100%.
    uint256 public constant MAX_PLATFORM_FEE = 1e6;
    /// @notice Current platformFee.
    uint256 public platformFee;
    /// @notice Custom platformFee override for the pair, max uint256 indicates no override.
    uint256 public customPlatformFee = type(uint256).max;

    function setCustomSwapFee(uint256 aCustomSwapFee) external onlyFactory {
        emit CustomSwapFee(aCustomSwapFee);
        customSwapFee = aCustomSwapFee;

        updateSwapFee();
    }

    function setCustomPlatformFee(uint256 aCustomPlatformFee) external onlyFactory {
        emit CustomPlatformFee(aCustomPlatformFee);
        customPlatformFee = aCustomPlatformFee;

        updatePlatformFee();
    }

    function updateSwapFee() public {
        uint256 _swapFee = customSwapFee != type(uint256).max ? customSwapFee : factory.get(swapFeeName).toUint256();
        if (_swapFee == swapFee) return;

        require(_swapFee <= MAX_SWAP_FEE, "RP: INVALID_SWAP_FEE");

        emit SwapFee(_swapFee);
        swapFee = _swapFee;
    }

    function updatePlatformFee() public {
        uint256 _platformFee =
            customPlatformFee != type(uint256).max ? customPlatformFee : factory.read(PLATFORM_FEE_NAME).toUint256();
        if (_platformFee == platformFee) return;

        require(_platformFee <= MAX_PLATFORM_FEE, "RP: INVALID_PLATFORM_FEE");

        emit PlatformFee(_platformFee);
        platformFee = _platformFee;
    }

    function recoverToken(IERC20 aToken) external {
        require(aToken != token0() && aToken != token1(), "RP: INVALID_TOKEN_TO_RECOVER");
        address _recoverer = factory.read(RECOVERER_NAME).toAddress();
        uint256 _amountToRecover = aToken.balanceOf(address(this));

        address(aToken).safeTransfer(_recoverer, _amountToRecover);
    }

    /*//////////////////////////////////////////////////////////////////////////

                                TRANSFER HELPERS

    //////////////////////////////////////////////////////////////////////////*/

    function _safeTransfer(IERC20 aToken, address aTo, uint256 aValue) internal returns (bool) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = address(aToken).call(abi.encodeWithSelector(TRANSFER, aTo, aValue));
        return success && (data.length == 0 || abi.decode(data, (bool)));
    }

    // performs a transfer, if it fails, it attempts to retrieve assets from the
    // AssetManager before retrying the transfer
    function _checkedTransfer(
        IERC20 aToken,
        address aDestination,
        uint256 aAmount,
        uint256 aReserve0,
        uint256 aReserve1
    ) internal {
        if (!_safeTransfer(aToken, aDestination, aAmount)) {
            bool lIsToken0 = aToken == token0();
            uint256 lTokenOutManaged = lIsToken0 ? token0Managed : token1Managed;
            uint256 lReserveOut = lIsToken0 ? aReserve0 : aReserve1;

            if (lReserveOut - lTokenOutManaged < aAmount) {
                assetManager.returnAsset(lIsToken0, aAmount - (lReserveOut - lTokenOutManaged));
                require(_safeTransfer(aToken, aDestination, aAmount), "RP: TRANSFER_FAILED");
            } else {
                revert("RP: TRANSFER_FAILED");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////

                                CORE AMM FUNCTIONS

    //////////////////////////////////////////////////////////////////////////*/

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1);
    event Swap(address indexed sender, bool zeroForOne, uint256 amountIn, uint256 amountOut, address indexed to);
    event Sync(uint104 reserve0, uint104 reserve1);

    /// @dev Mints LP tokens using tokens sent to this contract.
    function mint(address aTo) external virtual returns (uint256 liquidity);

    /// @dev Burns LP tokens sent to this contract.
    function burn(address aTo) external virtual returns (uint256 amount0, uint256 amount1);

    /// @notice Swaps one token for another. The router must prefund this contract and ensure there isn't too much
    ///         slippage.
    /// @param aAmount positive to indicate token0, negative to indicate token1
    /// @param aExactIn true to indicate an exact in trade, false to indicate an exact out trade
    /// @param aTo address to send the output token and leftover input tokens, callee for the flash swap
    /// @param aData calls to with this data, in the event of a flash swap
    function swap(int256 aAmount, bool aExactIn, address aTo, bytes calldata aData)
        external
        virtual
        returns (uint256 rAmountOut);

    /*//////////////////////////////////////////////////////////////////////////
                                ASSET MANAGEMENT

    Asset management is supported via a two-way interface. The pool is able to
    ask the current asset manager for the latest view of the balances. In turn
    the asset manager can move assets in/out of the pool. This section
    implements the pool side of the equation. The manager's side is abstracted
    behind the IAssetManager interface.

    //////////////////////////////////////////////////////////////////////////*/

    event Profit(IERC20 token, uint256 amount);
    event Loss(IERC20 token, uint256 amount);

    IAssetManager public assetManager;

    function setManager(IAssetManager manager) external onlyFactory {
        require(token0Managed == 0 && token1Managed == 0, "RP: AM_STILL_ACTIVE");
        assetManager = manager;
        emit AssetManager(manager);
    }

    uint104 public token0Managed;
    uint104 public token1Managed;

    function _totalToken0() internal view returns (uint256) {
        return token0().balanceOf(address(this)) + uint256(token0Managed);
    }

    function _totalToken1() internal view returns (uint256) {
        return token1().balanceOf(address(this)) + uint256(token1Managed);
    }

    function _handleReport(IERC20 aToken, uint256 aReserve, uint256 aPrevBalance, uint256 aNewBalance)
        private
        returns (uint256 rUpdatedReserve)
    {
        if (aNewBalance > aPrevBalance) {
            // report profit
            uint256 lProfit = aNewBalance - aPrevBalance;

            emit Profit(aToken, lProfit);

            rUpdatedReserve = aReserve + lProfit;
        } else if (aNewBalance < aPrevBalance) {
            // report loss
            uint256 lLoss = aPrevBalance - aNewBalance;

            emit Loss(aToken, lLoss);

            rUpdatedReserve = aReserve - lLoss;
        } else {
            // Balances are equal, return the original reserve.
            rUpdatedReserve = aReserve;
        }
    }

    function _syncManaged(uint256 aReserve0, uint256 aReserve1)
        internal
        returns (uint256 rReserve0, uint256 rReserve1)
    {
        if (address(assetManager) == address(0)) {
            return (aReserve0, aReserve1);
        }

        IERC20 lToken0 = token0();
        IERC20 lToken1 = token1();

        uint256 lToken0Managed = assetManager.getBalance(this, lToken0);
        uint256 lToken1Managed = assetManager.getBalance(this, lToken1);

        rReserve0 = _handleReport(lToken0, aReserve0, token0Managed, lToken0Managed);
        rReserve1 = _handleReport(lToken1, aReserve1, token1Managed, lToken1Managed);

        token0Managed = lToken0Managed.toUint104();
        token1Managed = lToken1Managed.toUint104();
    }

    function _managerCallback() internal {
        if (address(assetManager) == address(0)) {
            return;
        }

        assetManager.afterLiquidityEvent();
    }

    function adjustManagement(int256 aToken0Change, int256 aToken1Change) external {
        require(msg.sender == address(assetManager), "RP: AUTH_NOT_MANAGER");

        if (aToken0Change > 0) {
            uint104 lDelta = uint256(aToken0Change).toUint104();

            token0Managed += lDelta;

            address(token0()).safeTransfer(msg.sender, lDelta);
        } else if (aToken0Change < 0) {
            uint104 lDelta = uint256(-aToken0Change).toUint104();

            // solhint-disable-next-line reentrancy
            token0Managed -= lDelta;

            address(token0()).safeTransferFrom(msg.sender, address(this), lDelta);
        }

        if (aToken1Change > 0) {
            uint104 lDelta = uint256(aToken1Change).toUint104();

            // solhint-disable-next-line reentrancy
            token1Managed += lDelta;

            address(token1()).safeTransfer(msg.sender, lDelta);
        } else if (aToken1Change < 0) {
            uint104 lDelta = uint256(-aToken1Change).toUint104();

            // solhint-disable-next-line reentrancy
            token1Managed -= lDelta;

            address(token1()).safeTransferFrom(msg.sender, address(this), lDelta);
        }
    }

    function skimExcessManaged(IERC20 aToken) external returns (uint256 rAmtSkimmed) {
        require(aToken == token0() || aToken == token1(), "RP: INVALID_SKIM_TOKEN");
        uint256 lTokenAmtManaged = assetManager.getBalance(this, aToken);

        if (lTokenAmtManaged > type(uint104).max) {
            address lRecoverer = factory.read(RECOVERER_NAME).toAddress();

            rAmtSkimmed = lTokenAmtManaged - type(uint104).max;

            assetManager.returnAsset(aToken == token0(), rAmtSkimmed);
            address(aToken).safeTransfer(lRecoverer, rAmtSkimmed);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                            ORACLE WRITING

    Our oracle implementation records both the raw price and clamped price.
    The clamped price mechanism is introduced by Reservoir to counter the possibility
    of oracle manipulation as ETH transitions to PoS when validators can control
    multiple blocks in a row. See also https://chainsecurity.com/oracle-manipulation-after-merge/

    //////////////////////////////////////////////////////////////////////////*/

    event OracleCallerUpdated(address oldCaller, address newCaller);
    event MaxChangeRateUpdated(uint256 oldMaxChangePerSecond, uint256 newMaxChangePerSecond);

    // 100 basis points per second which is 60% per minute
    uint256 internal constant MAX_CHANGE_PER_SEC = 0.01e18;
    string internal constant MAX_CHANGE_RATE_NAME = "Shared::maxChangeRate";
    string internal constant ORACLE_CALLER_NAME = "Shared::oracleCaller";

    mapping(uint256 => Observation) internal _observations;

    // maximum allowed rate of change of price per second to mitigate oracle manipulation attacks in the face of
    // post-merge ETH. 1e18 == 100%
    uint256 public maxChangeRate;

    address public oracleCaller;

    function observation(uint256 aIndex) external view returns (Observation memory rObservation) {
        require(msg.sender == oracleCaller, "RP: NOT_ORACLE_CALLER");
        rObservation = _observations[aIndex];
    }

    function updateOracleCaller() public {
        address lNewCaller = factory.read(ORACLE_CALLER_NAME).toAddress();
        if (lNewCaller != oracleCaller) {
            emit OracleCallerUpdated(oracleCaller, lNewCaller);
            oracleCaller = lNewCaller;
        }
    }

    function setMaxChangeRate(uint256 aMaxChangeRate) public onlyFactory {
        require(0 < aMaxChangeRate && aMaxChangeRate <= MAX_CHANGE_PER_SEC, "RP: INVALID_CHANGE_PER_SECOND");
        emit MaxChangeRateUpdated(maxChangeRate, aMaxChangeRate);
        maxChangeRate = aMaxChangeRate;
    }

    function _calcClampedPrice(
        uint256 aCurrRawPrice,
        int256 aCurrLogRawPrice,
        uint256 aPrevClampedPrice,
        uint256 aTimeElapsed,
        uint256 aPreviousTimestamp
    ) internal virtual returns (uint256 rClampedPrice, int256 rClampedLogPrice) {
        // call to `percentDelta` will revert if the difference between aCurrRawPrice and aPrevClampedPrice is
        // greater than uint196 (1e59). It is extremely unlikely that one trade can change the price by 1e59
        // if aPreviousTimestamp is 0, this is the first calculation of clamped price, and so should be set to the raw price
        if (aPreviousTimestamp == 0 || aCurrRawPrice.percentDelta(aPrevClampedPrice) <= maxChangeRate * aTimeElapsed) {
            (rClampedPrice, rClampedLogPrice) = (aCurrRawPrice, aCurrLogRawPrice);
        } else {
            // clamp the price
            // multiplication of maxChangeRate and aTimeElapsed would not overflow as
            // maxChangeRate <= 0.01e18 (50 bits)
            // aTimeElapsed <= 32 bits
            if (aCurrRawPrice > aPrevClampedPrice) {
                rClampedPrice = aPrevClampedPrice.fullMulDiv(1e18 + maxChangeRate * aTimeElapsed, 1e18);
            } else {
                assert(aPrevClampedPrice > aCurrRawPrice);
                rClampedPrice = aPrevClampedPrice.fullMulDiv(1e18 - maxChangeRate * aTimeElapsed, 1e18);
            }
            rClampedLogPrice = LogCompression.toLowResLog(rClampedPrice);
        }
    }

    function _updateOracleNewSample(
        Slot0 storage aSlot0,
        Observation storage aPrevious,
        int256 aLogInstantRawPrice,
        int256 aLogInstantClampedPrice,
        uint32 aTimeElapsed,
        uint32 aCurrentTimestamp
    ) internal {
        // overflow is desired here as the consumer of the oracle will be reading the difference in those accumulated log values
        // when the index overflows it will overwrite the oldest observation to form a loop
        unchecked {
            int88 logAccRawPrice =
                aPrevious.logAccRawPrice + aPrevious.logInstantRawPrice * int88(int256(uint256(aTimeElapsed)));
            int88 logAccClampedPrice =
                aPrevious.logAccClampedPrice + aPrevious.logInstantClampedPrice * int88(int256(uint256(aTimeElapsed)));
            aSlot0.index = aSlot0.index.next();
            _observations[aSlot0.index] = Observation(
                int24(aLogInstantRawPrice),
                int24(aLogInstantClampedPrice),
                logAccRawPrice,
                logAccClampedPrice,
                aCurrentTimestamp
            );
        }
    }

    function _updateOracleInstantPrices(
        Observation storage aPrevious,
        int256 aLogInstantRawPrice,
        int256 aLogInstantClampedPrice
    ) internal {
        aPrevious.logInstantRawPrice = int24(aLogInstantRawPrice);
        aPrevious.logInstantClampedPrice = int24(aLogInstantClampedPrice);
    }

    /// @param aBalance0 The balance of token0 in its native precision.
    /// @param aBalance1 The balance of token1 in its native precision.
    /// @return spotPrice Expressed as 1e18 == 1.
    /// @return logSpotPrice The natural log (ln) of the spotPrice.
    function _calcSpotAndLogPrice(uint256 aBalance0, uint256 aBalance1)
        internal
        virtual
        returns (uint256 spotPrice, int256 logSpotPrice);
}
