// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

struct Observation {
    // natural log (ln) of the raw instant price. Fits into int24 as the max value is 1353060
    // while the minimum value is -414465
    // See `LogCompressionTest` for more info
    int24 logInstantRawPrice;
    // natural log (ln) of the clamped instant price
    int24 logInstantClampedPrice;
    // natural log (ln) of the raw accumulated price (token1/token0)
    // in the case of maximum price supported by the oracle (~5.79e58 == e ** 135.3060)
    // (1353060) 21 bits multiplied by 32 bits of the timestamp gives 53 bits
    // which fits into int88
    int88 logAccRawPrice;
    // natural log (ln) of the clamped accumulated price (token1/token0)
    int88 logAccClampedPrice;
    // overflows every 136 years, in the year 2106
    uint32 timestamp;
}
