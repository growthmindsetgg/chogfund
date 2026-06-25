// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockSwapRouter (testnet only)
/// @notice Stand-in swap venue for Monad testnet, where no DEX has a pool for our
///         MockUSDC against MON. The vault's SafeSwapExecutor treats it like any
///         whitelisted router: it sends tokenIn and the router pays out tokenOut
///         from its own pre-funded liquidity. The agent quotes `pushOut` off-chain;
///         the vault still enforces minOut + balance-delta asserts on-chain, so this
///         mock cannot bypass the safety guarantees being demonstrated.
///         NOT for mainnet — it has no pricing logic of its own.
contract MockSwapRouter {
    address public constant NATIVE = address(0);
    address public owner;

    event Swapped(address indexed caller, address tokenIn, address tokenOut, uint256 pulled, uint256 pushed);

    constructor() {
        owner = msg.sender;
    }

    /// @param tokenIn  address(0) for native MON, else ERC20
    /// @param tokenOut address(0) for native MON, else ERC20
    /// @param pullIn   amount of ERC20 tokenIn to pull from caller (ignored for native in)
    /// @param pushOut  amount of tokenOut to pay the caller
    function swap(address tokenIn, address tokenOut, uint256 pullIn, uint256 pushOut) external payable {
        if (tokenIn != NATIVE && pullIn > 0) {
            require(IERC20(tokenIn).transferFrom(msg.sender, address(this), pullIn), "router: pull fail");
        }
        if (pushOut > 0) {
            if (tokenOut == NATIVE) {
                (bool ok, ) = msg.sender.call{value: pushOut}("");
                require(ok, "router: native send");
            } else {
                require(IERC20(tokenOut).transfer(msg.sender, pushOut), "router: erc20 send");
            }
        }
        emit Swapped(msg.sender, tokenIn, tokenOut, pullIn, pushOut);
    }

    /// @notice Owner can recover liquidity (testnet housekeeping).
    function sweep(address token, address to, uint256 amount) external {
        require(msg.sender == owner, "router: not owner");
        if (token == NATIVE) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "router: sweep native");
        } else {
            require(IERC20(token).transfer(to, amount), "router: sweep erc20");
        }
    }

    receive() external payable {}
}
