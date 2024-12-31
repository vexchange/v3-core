// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { ReentrancyGuardTransient as RGT } from "solady/utils/ReentrancyGuardTransient.sol";
import { Owned } from "solmate/auth/Owned.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { SafeCast } from "@openzeppelin/utils/math/SafeCast.sol";
import { Address } from "@openzeppelin/utils/Address.sol";

import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";
import { IAssetManager, IERC20 } from "src/interfaces/IAssetManager.sol";
import { IDistributor } from "src/interfaces/merkl/IDistributor.sol";
import { IERC4626 } from "lib/forge-std/src/interfaces/IERC4626.sol";
import { Constants } from "src/Constants.sol";

contract EulerV2Manager is IAssetManager, Owned(msg.sender), RGT {
    using FixedPointMathLib for uint256;
    using SafeCast for uint256;

    event Guardian(address newGuardian);
    event WindDownMode(bool windDown);
    event VaultForAsset(IERC20 indexed asset, IERC4626 indexed vault);
    event Thresholds(uint128 newLowerThreshold, uint128 newUpperThreshold);
    event Investment(IAssetManagedPair indexed pair, IERC20 indexed token, uint256 shares);
    event Divestment(IAssetManagedPair indexed pair, IERC20 indexed token, uint256 shares);

    error OutstandingSharesForVault();
    error ReturnAssetZeroAmount();

    /// @dev Mapping from an ERC20 token to an Euler V2 vault.
    /// This implies that for a given asset, there can only be one vault at any one time.
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
        return Address.functionCallWithValue(aTarget, aCalldata, aValue);
    }
    /*//////////////////////////////////////////////////////////////////////////
                                HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _increaseShares(IAssetManagedPair aPair, IERC20 aToken, IERC4626 aVault, uint256 aShares) private {
        totalShares[aVault] += aShares;
        shares[aPair][aToken] += aShares;
    }

    function _decreaseShares(IAssetManagedPair aPair, IERC20 aToken, IERC4626 aVault, uint256 aShares) private {
        totalShares[aVault] -= aShares;
        shares[aPair][aToken] -= aShares;
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

        if (aAmount0Change < 0) SafeTransferLib.safeApprove(address(lToken0), address(aPair), uint256(-aAmount0Change));
        if (aAmount1Change < 0) SafeTransferLib.safeApprove(address(lToken1), address(aPair), uint256(-aAmount1Change));
        // transfer tokens to/from pair
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
        uint256 lSharesBurned = aVault.withdraw(aAmount, address(this), address(this));
        _decreaseShares(aPair, aToken, aVault, lSharesBurned);

        emit Divestment(aPair, aToken, lSharesBurned);
    }

    function _doInvest(IAssetManagedPair aPair, IERC20 aToken, IERC4626 aVault, uint256 aAmount) private {
        SafeTransferLib.safeApprove(address(aToken), address(aVault), aAmount);

        uint256 lSharesReceived = aVault.deposit(aAmount, address(this));
        _increaseShares(aPair, aToken, aVault, lSharesReceived);

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

    function returnAsset(uint256 aToken0Amt, uint256 aToken1Amt) external {
        require(aToken0Amt > 0 || aToken1Amt > 0, ReturnAssetZeroAmount());
        _adjustManagement(IAssetManagedPair(msg.sender), -aToken0Amt.toInt256(), -aToken1Amt.toInt256());
    }

    function _calculateChangeAmount(uint256 aReserve, uint256 aManaged) internal view returns (int256 rAmountChange) {
        if (aManaged * Constants.WAD < aReserve * lowerThreshold) {
            rAmountChange = (aReserve.mulWad(uint256(lowerThreshold).avg(upperThreshold)) - aManaged).toInt256();
            assert(rAmountChange > 0);
        } else if (aManaged * Constants.WAD > aReserve * upperThreshold) {
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
            SafeTransferLib.safeTransfer(
                aTokens[i],
                msg.sender,
                // the amounts specified in the argument might not be the actual amounts disimbursed by the distributor,
                // due to the possibility of having done the claim previously thus it is necessary to use balanceOf
                // to transfer the correct amount
                IERC20(aTokens[i]).balanceOf(address(this))
            );
        }
    }

    /// @dev The guardian or owner would first call `claimRewards` and sell it for the underlying token.
    /// The asset manager pulls the assets, deposits it to the vault, and distribute the proceeds in the form of ERC4626
    /// shares to the pairs.
    /// Due to integer arithmetic the last pair of the array will get one or two more shares, so as to maintain the
    /// invariant that the sum of shares for all pair+token equals the totalShares.
    function distributeRewardForPairs(IERC20 aAsset, uint256 aAmount, IAssetManagedPair[] calldata aPairs)
        external
        onlyGuardianOrOwner
        nonReentrant
    {
        IERC4626 lVault = assetVault[aAsset];
        if (address(lVault) == address(0)) return;

        // pull assets from guardian / owner
        SafeTransferLib.safeTransferFrom(address(aAsset), msg.sender, address(this), aAmount);
        SafeTransferLib.safeApprove(address(aAsset), address(lVault), aAmount);
        uint256 lNewShares = lVault.deposit(aAmount, address(this));

        uint256 lOldTotalShares = totalShares[lVault];
        totalShares[lVault] = lOldTotalShares + lNewShares;

        for (uint256 i = 0; i < aPairs.length; ++i) {
            uint256 lOldShares = shares[aPairs[i]][aAsset];
            // no need for fullMulDiv for real life amounts, assumes that lOldTotalShares != 0, which would be the case
            // if there are pairs to distribute to anyway
            uint256 lNewSharesEntitled = lNewShares.mulDiv(lOldShares, lOldTotalShares);
            shares[aPairs[i]][aAsset] = lOldShares + lNewSharesEntitled;

            lNewShares -= lNewSharesEntitled;
            lOldTotalShares -= lOldShares;
        }
    }
}
