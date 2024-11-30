// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { ERC20 } from "solady/tokens/ERC20.sol";

contract ReservoirERC20 is ERC20 {
    function name() public pure override returns (string memory) {
        return "Reservoir LP Token";
    }

    function symbol() public pure override returns (string memory) {
        return "RES-LP";
    }
}
