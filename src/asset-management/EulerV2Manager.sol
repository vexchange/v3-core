// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { ReentrancyGuard } from "solmate/utils/ReentrancyGuard.sol";
import { Owned } from "solmate/auth/Owned.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { SafeCast } from "@openzeppelin/utils/math/SafeCast.sol";
import { Address } from "@openzeppelin/utils/Address.sol";

import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";
import { IAssetManager, IERC20 } from "src/interfaces/IAssetManager.sol";
import { IDistributor } from "src/interfaces/merkl/IDistributor.sol";
import { IERC4626 } from "lib/forge-std/src/interfaces/IERC4626.sol";

contract EulerV2Manager is IAssetManager, Owned(msg.sender), ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using SafeCast for uint256;

    event Guardian(address newGuardian);
    event WindDownMode(bool windDown);
    event VaultForAsset(IERC20 asset, IERC4626 vault);
    event Thresholds(uint128 newLowerThreshold, uint128 newUpperThreshold);
    event Investment(IAssetManagedPair pair, IERC20 token, uint256 shares);
    event Divestment(IAssetManagedPair pair, IERC20 token, uint256 shares);

    error OutstandingSharesForVault();

    /// @dev Mapping from an ERC20 token to an Euler V2 vault.
    /// This implies that for a given asset, there can only be one vault.
    /// If the admin of the manager wishes to specify a different vault for an asset, they would have to manually ensure that all pairs have
    /// divested, otherwise the pairs might not be able to retrieve their assets.
    mapping(IERC20 => IERC4626) public assetVault;

    /// @dev Tracks how many shares each pair+token owns.
    mapping(IAssetManagedPair => mapping(IERC20 => uint256)) public shares;

    /// @dev Tracks the total number of shares for a given vault held by this contract.
    mapping(IERC4626 => uint256) public totalShares;

    /// @dev Percentage of the pool's assets, above and below which
    /// the manager will divest the shortfall and invest the excess.
    /// 1e18 == 100%
    uint128 public upperThreshold = 0.7e18; // 70%
    uint128 public lowerThreshold = 0.3e18; // 30%

    /// @dev Trusted party to adjust asset management parameters such as thresholds and windDownMode and
    /// to claim and sell additional rewards (through a DEX/aggregator) into the corresponding
    /// underlying tokens on behalf of the asset manager and then transfers them back into the manager.
    address public guardian;

    /// @dev When set to true by the owner or guardian, it will only allow divesting but not investing by
    /// the pairs in this mode to facilitate replacement of asset managers to newer versions.
    bool public windDownMode;

    // solhint-disable-next-line no-empty-blocks
    constructor() { }

    /*//////////////////////////////////////////////////////////////////////////
                                    MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier onlyGuardianOrOwner() {
        require(msg.sender == guardian || msg.sender == owner, "AM: UNAUTHORIZED");
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ADMIN ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function setVaultForAsset(IERC20 aAsset, IERC4626 aVault) external onlyOwner {
        IERC4626 lVault = assetVault[aAsset];
        // this is to prevent accidental moving of vaults when there are still shares outstanding
        // as it will prevent the AMM pairs from redeeming underlying tokens from the vault
        if (address(lVault) != address(0) && totalShares[lVault] != 0) {
            revert OutstandingSharesForVault();
        }

        assetVault[aAsset] = aVault;
        emit VaultForAsset(aAsset, aVault);
    }

    function setGuardian(address aGuardian) external onlyOwner {
        guardian = aGuardian;
        emit Guardian(aGuardian);
    }

    function setWindDownMode(bool aWindDown) external onlyGuardianOrOwner {
        windDownMode = aWindDown;
        emit WindDownMode(aWindDown);
    }

    function setThresholds(uint128 aLowerThreshold, uint128 aUpperThreshold) external onlyGuardianOrOwner {
        require(aUpperThreshold <= 1e18 && aUpperThreshold >= aLowerThreshold, "AM: INVALID_THRESHOLDS");
        (lowerThreshold, upperThreshold) = (aLowerThreshold, aUpperThreshold);
        emit Thresholds(aLowerThreshold, aUpperThreshold);
    }

    function rawCall(address aTarget, bytes calldata aCalldata, uint256 aValue)
        external
        onlyOwner
        returns (bytes memory)
    {
        return Address.functionCallWithValue(aTarget, aCalldata, aValue, "AM: RAW_CALL_REVERTED");
    }
    /*//////////////////////////////////////////////////////////////////////////
                                HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _increaseShares(IAssetManagedPair aPair, IERC20 aToken, IERC4626 aVault, uint256 aAmount)
        private
        returns (uint256 rShares)
    {
        rShares = aVault.previewDeposit(aAmount);
        totalShares[aVault] += rShares;
        shares[aPair][aToken] += rShares;
    }

    function _decreaseShares(IAssetManagedPair aPair, IERC20 aToken, IERC4626 aVault, uint256 aAmount)
        private
        returns (uint256 rShares)
    {
        rShares = aVault.previewWithdraw(aAmount);
        totalShares[aVault] -= rShares;
        shares[aPair][aToken] -= rShares;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                GET BALANCE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Returns the balance of the underlying token managed the asset manager in the native precision.
    function getBalance(IAssetManagedPair aOwner, IERC20 aToken) external view returns (uint256) {
        return _getBalance(aOwner, aToken);
    }

    function _getBalance(IAssetManagedPair aOwner, IERC20 aToken) private view returns (uint256 rTokenBalance) {
        IERC4626 lVault = assetVault[aToken];

        if (address(lVault) != address(0)) {
            uint256 lShares = shares[aOwner][aToken];
            rTokenBalance = lVault.convertToAssets(lShares);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ADJUST MANAGEMENT
    //////////////////////////////////////////////////////////////////////////*/

    function adjustManagement(IAssetManagedPair aPair, int256 aAmount0Change, int256 aAmount1Change)
        external
        onlyOwner
    {
        _adjustManagement(aPair, aAmount0Change, aAmount1Change);
    }

    function _adjustManagement(IAssetManagedPair aPair, int256 aAmount0Change, int256 aAmount1Change)
        private
        nonReentrant
    {
        IERC20 lToken0 = aPair.token0();
        IERC20 lToken1 = aPair.token1();

        IERC4626 lToken0Vault = assetVault[lToken0];
        IERC4626 lToken1Vault = assetVault[lToken1];

        // do not do anything if there isn't a designated vault for the token
        if (address(lToken0Vault) == address(0)) {
            aAmount0Change = 0;
        }
        if (address(lToken1Vault) == address(0)) {
            aAmount1Change = 0;
        }

        if (windDownMode) {
            if (aAmount0Change > 0) {
                aAmount0Change = 0;
            }
            if (aAmount1Change > 0) {
                aAmount1Change = 0;
            }
        }

        // withdraw from the vault
        if (aAmount0Change < 0) {
            uint256 lAmount0Change;
            unchecked {
                lAmount0Change = uint256(-aAmount0Change);
            }
            _doDivest(aPair, lToken0, lToken0Vault, lAmount0Change);
        }
        if (aAmount1Change < 0) {
            uint256 lAmount1Change;
            unchecked {
                lAmount1Change = uint256(-aAmount1Change);
            }
            _doDivest(aPair, lToken1, lToken1Vault, lAmount1Change);
        }

        // transfer tokens to/from the pair
        aPair.adjustManagement(aAmount0Change, aAmount1Change);

        // transfer the managed tokens to the destination
        if (aAmount0Change > 0) {
            _doInvest(aPair, lToken0, lToken0Vault, uint256(aAmount0Change));
        }
        if (aAmount1Change > 0) {
            _doInvest(aPair, lToken1, lToken1Vault, uint256(aAmount1Change));
        }
    }

    function _doDivest(IAssetManagedPair aPair, IERC20 aToken, IERC4626 aVault, uint256 aAmount) private {
        uint256 lShares = _decreaseShares(aPair, aToken, aVault, aAmount);
        uint256 lSharesBurned = aVault.withdraw(aAmount, address(this), address(this));

        require(lShares == lSharesBurned, "AM: DIVEST_SHARES_MISMATCH");

        emit Divestment(aPair, aToken, lShares);
        SafeTransferLib.safeApprove(address(aToken), address(aPair), aAmount);
    }

    function _doInvest(IAssetManagedPair aPair, IERC20 aToken, IERC4626 aVault, uint256 aAmount) private {
        require(aToken.balanceOf(address(this)) == aAmount, "AM: TOKEN_AMOUNT_MISMATCH");
        uint256 lExpectedShares = _increaseShares(aPair, aToken, aVault, aAmount);
        SafeTransferLib.safeApprove(address(aToken), address(aVault), aAmount);

        uint256 lSharesReceived = aVault.deposit(aAmount, address(this));
        require(lExpectedShares == lSharesReceived, "AM: INVEST_SHARES_MISMATCH");

        emit Investment(aPair, aToken, lSharesReceived);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CALLBACKS FROM PAIR
    //////////////////////////////////////////////////////////////////////////*/

    function afterLiquidityEvent() external {
        IAssetManagedPair lPair = IAssetManagedPair(msg.sender);
        IERC20 lToken0 = lPair.token0();
        IERC20 lToken1 = lPair.token1();
        (uint256 lReserve0, uint256 lReserve1,,) = lPair.getReserves();

        uint256 lToken0Managed = _getBalance(lPair, lToken0);
        uint256 lToken1Managed = _getBalance(lPair, lToken1);

        int256 lAmount0Change = _calculateChangeAmount(lReserve0, lToken0Managed);
        int256 lAmount1Change = _calculateChangeAmount(lReserve1, lToken1Managed);

        _adjustManagement(lPair, lAmount0Change, lAmount1Change);
    }

    function returnAsset(bool aToken0, uint256 aAmount) external {
        require(aAmount > 0, "AM: ZERO_AMOUNT_REQUESTED");
        IAssetManagedPair lPair = IAssetManagedPair(msg.sender);
        int256 lAmount0Change = aToken0 ? -aAmount.toInt256() : int256(0);
        int256 lAmount1Change = aToken0 ? int256(0) : -aAmount.toInt256();
        _adjustManagement(lPair, lAmount0Change, lAmount1Change);
    }

    function _calculateChangeAmount(uint256 aReserve, uint256 aManaged) internal view returns (int256 rAmountChange) {
        uint256 lRatio = aManaged.divWad(aReserve);
        if (lRatio < lowerThreshold) {
            rAmountChange = (aReserve.mulWad(uint256(lowerThreshold).avg(upperThreshold)) - aManaged).toInt256();
            assert(rAmountChange > 0);
        } else if (lRatio > upperThreshold) {
            rAmountChange =
                aReserve.mulWad(uint256(lowerThreshold).avg(upperThreshold)).toInt256() - aManaged.toInt256();
            assert(rAmountChange < 0);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ADDITIONAL REWARDS
    //////////////////////////////////////////////////////////////////////////*/

    function claimRewards(
        IDistributor aDistributor,
        address[] calldata aUsers,
        address[] calldata aTokens,
        uint256[] calldata aAmounts,
        bytes32[][] calldata aProofs
    ) external onlyGuardianOrOwner {
        aDistributor.claim(aUsers, aTokens, aAmounts, aProofs);

        for (uint256 i = 0; i < aTokens.length; ++i) {
            SafeTransferLib.safeTransfer(aTokens[i], msg.sender, aAmounts[i]);
        }
    }

    /// @dev The guardian or owner would first claim rewards on behalf of the asset manager by calling `claimRewards` and sell it for the underlying token.
    /// The asset manager pulls the assets, deposits it to the vault, and distribute the proceeds in the form of ERC4626 shares to the pairs.
    /// Due to integer arithmetic the last pair of the array will get one or two more shares, so as to maintain the invariant that
    /// the sum of shares for all pair+token equals the totalShares.
    function distributeRewardForPairs(IERC20 aAsset, uint256 aAmount, IAssetManagedPair[] calldata aPairs)
        external
        onlyGuardianOrOwner
    {
        // pull assets from guardian / owner
        SafeTransferLib.safeTransferFrom(address(aAsset), msg.sender, address(this), aAmount);
        IERC4626 lVault = assetVault[aAsset];
        SafeTransferLib.safeApprove(address(aAsset), address(lVault), aAmount);
        uint256 lNewShares = lVault.deposit(aAmount, address(this));

        uint256 lOldTotalShares = totalShares[lVault];
        totalShares[lVault] = lOldTotalShares + lNewShares;
        uint256 lSharesAllocated;
        uint256 lLength = aPairs.length;
        for (uint256 i = 0; i < lLength - 1; ++i) {
            uint256 lOldShares = shares[aPairs[i]][aAsset];
            uint256 lNewSharesEntitled = lNewShares.mulDiv(lOldShares, lOldTotalShares);
            shares[aPairs[i]][aAsset] = lOldShares + lNewSharesEntitled;
            lSharesAllocated += lNewSharesEntitled;
        }

        // the last in the list will take all the remaining shares, and sometimes will get 1 or 2 more than they're entitled to
        // due to the rounding down in previous calculations for other pairs
        // this is to prevent the sum of each pair+token's shares not summing up to totalShares
        shares[aPairs[lLength - 1]][aAsset] = lNewShares - lSharesAllocated;
        lSharesAllocated += shares[aPairs[lLength - 1]][aAsset];
        require(lSharesAllocated == lNewShares, "AM: REWARD_SHARES_MISMATCH");
    }
}
