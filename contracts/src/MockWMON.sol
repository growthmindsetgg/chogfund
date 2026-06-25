// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockWMON — WETH9-style wrapper for native MON.
/// @notice ====================  MOCK  ====================
///         Faithful to the WETH9 deposit/withdraw surface used at the LP boundary
///         (native MON must be wrapped to an ERC20 for a Uniswap V3 position).
///         On mainnet canary this is replaced by the real WMON contract address;
///         the LpManager / AllocatorVault code is unchanged (config swap only).
contract MockWMON is ERC20 {
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    constructor() ERC20("Wrapped MON (MOCK)", "WMON") {}

    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        _burn(msg.sender, wad);
        (bool ok, ) = msg.sender.call{value: wad}("");
        require(ok, "WMON: native send failed");
        emit Withdrawal(msg.sender, wad);
    }

    receive() external payable {
        deposit();
    }
}
