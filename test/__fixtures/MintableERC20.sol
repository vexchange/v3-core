// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { ERC20 } from "solady/tokens/ERC20.sol";

contract MintableERC20 is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory aName, string memory aSymbol, uint8 aDecimals) {
        _name = aName;
        _symbol = aSymbol;
        _decimals = aDecimals;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address aReceiver, uint256 aAmount) external {
        _mint(aReceiver, aAmount);
    }
}
