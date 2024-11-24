// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

library Constants {
    uint256 public constant INITIAL_MINT_AMOUNT = 100e18;
    uint256 public constant DEFAULT_SWAP_FEE_CP = 3000; // 0.3%
    uint256 public constant DEFAULT_SWAP_FEE_SP = 100; // 0.01%
    uint256 public constant DEFAULT_PLATFORM_FEE = 250_000; // 25%
    uint256 public constant DEFAULT_AMP_COEFF = 1000;
    uint128 public constant DEFAULT_MAX_CHANGE_RATE = 0.0005e18;
    uint128 public constant DEFAULT_MAX_CHANGE_PER_TRADE = 0.03e18; // 3%
}
