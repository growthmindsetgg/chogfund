// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SafeSwapExecutor
/// @notice Best-output swap with on-chain safety. The agent chooses the route
///         OFF-CHAIN and passes (router, callData, tokenIn, tokenOut, amountIn,
///         minOut). The contract enforces, ON-CHAIN, that a bad or malicious
///         route cannot drain the vault:
///           1. `router` must be on an owner-managed whitelist (adding a router
///              is a human/owner action — never the agent).
///           2. Balances of tokenIn/tokenOut are snapshotted before the call.
///           3. After the call: received >= minOut AND spent <= amountIn, else revert.
///         minOut is derived from the trustless Pyth priceE8 minus an on-chain
///         slippage cap (`slippageBps`) — the "negligible loss" rule, enforced here.
///
///         MON is native (18 dec); USDC is ERC20 (6 dec). tokenIn/tokenOut use
///         address(0) (NATIVE) to mean native MON.
abstract contract SafeSwapExecutor {
    using SafeERC20 for IERC20;

    address internal constant NATIVE = address(0);

    /// @notice Owner-managed router whitelist. Agent cannot modify this.
    mapping(address => bool) public routerWhitelist;
    /// @notice On-chain slippage cap in bps applied to the Pyth-derived quote.
    uint256 public slippageBps;

    event RouterWhitelisted(address indexed router, bool allowed);
    event SlippageUpdated(uint256 slippageBps);
    event SwapExecuted(
        address indexed router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    error RouterNotWhitelisted(address router);
    error MinOutNotMet(uint256 received, uint256 minOut);
    error OverSpent(uint256 spent, uint256 amountIn);
    error RouterCallFailed(bytes ret);
    error BadSlippage();
    error ZeroPrice();

    /// @dev Inheriting contract supplies the owner authorized to manage routers/slippage.
    function _swapOwner() internal view virtual returns (address);
    /// @dev Inheriting contract supplies the USDC token address (the ERC20 leg).
    function _usdc() internal view virtual returns (address);

    modifier onlySwapOwner() {
        require(msg.sender == _swapOwner(), "swap: not owner");
        _;
    }

    // ---------- owner controls ----------

    function setRouterWhitelist(address router, bool allowed) external onlySwapOwner {
        require(router != address(0), "swap: zero router");
        routerWhitelist[router] = allowed;
        emit RouterWhitelisted(router, allowed);
    }

    function _setSlippageBps(uint256 bps) internal {
        if (bps == 0 || bps > 1_000) revert BadSlippage(); // 0 < cap <= 10%
        slippageBps = bps;
        emit SlippageUpdated(bps);
    }

    // ---------- quote ----------

    /// @notice minOut = expected output from Pyth priceE8, minus the slippage cap.
    ///         MON(18)->USDC(6): amountIn * priceE8 / 1e20
    ///         USDC(6)->MON(18): amountIn * 1e20 / priceE8
    function quoteMinOut(address tokenIn, uint256 amountIn, uint256 priceE8)
        public
        view
        returns (uint256 minOut)
    {
        if (priceE8 == 0) revert ZeroPrice();
        uint256 gross;
        if (tokenIn == NATIVE) {
            gross = amountIn * priceE8 / 1e20; // 18 + 8 - 20 = 6 dec
        } else {
            gross = amountIn * 1e20 / priceE8; // 6 + 20 - 8 = 18 dec
        }
        minOut = gross * (10_000 - slippageBps) / 10_000;
    }

    // ---------- core ----------

    function _balanceOf(address token) internal view returns (uint256) {
        return token == NATIVE ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @dev Caller MUST guard against reentrancy (the vault's external entry is nonReentrant).
    function _safeSwap(
        address router,
        bytes memory callData,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) internal returns (uint256 amountOut) {
        if (!routerWhitelist[router]) revert RouterNotWhitelisted(router);

        uint256 inBefore = _balanceOf(tokenIn);
        uint256 outBefore = _balanceOf(tokenOut);

        uint256 value;
        if (tokenIn == NATIVE) {
            value = amountIn;
        } else {
            // approve EXACTLY amountIn, cleared to 0 after — no lingering allowance.
            IERC20(tokenIn).forceApprove(router, amountIn);
        }

        (bool ok, bytes memory ret) = router.call{value: value}(callData);
        if (!ok) revert RouterCallFailed(ret);

        if (tokenIn != NATIVE) {
            IERC20(tokenIn).forceApprove(router, 0);
        }

        uint256 inAfter = _balanceOf(tokenIn);
        uint256 outAfter = _balanceOf(tokenOut);

        uint256 spent = inBefore - inAfter;
        amountOut = outAfter - outBefore;

        if (amountOut < minOut) revert MinOutNotMet(amountOut, minOut);
        if (spent > amountIn) revert OverSpent(spent, amountIn);

        emit SwapExecuted(router, tokenIn, tokenOut, spent, amountOut);
    }
}
