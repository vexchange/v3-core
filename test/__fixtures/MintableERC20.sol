// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { ERC20 } from "solady/tokens/ERC20.sol";

contract MintableERC20 is ERC20 {
    uint8 private _decimals;

    // solhint-disable-next-line no-empty-blocks
    constructor(string memory aName, string memory aSymbol, uint8 aDecimals) ERC20(aName, aSymbol, aDecimals) { }

    function mint(address aReceiver, uint256 aAmount) external {
        _mint(aReceiver, aAmount);
    }
}
