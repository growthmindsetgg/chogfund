// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PythPriceReader} from "./PythPriceReader.sol";
import {SafeSwapExecutor} from "./SafeSwapExecutor.sol";

interface ILogBook {
    function record(
        uint256 priceE8,
        uint256 bpsBefore,
        uint256 bpsAfter,
        uint256 navBefore,
        uint256 navAfter
    ) external;
}

/// @title HardenedVault
/// @notice Non-custodial 60/40 MON/USDC vault. Hardened on five fronts:
///   1. ERC4626 v5 share math with a virtual-shares / decimals-offset, PLUS a
///      dead-shares seed at deploy → first-depositor inflation attack defeated twice.
///   2. ReentrancyGuard on deposit / redeem / rebalance; checks-effects-interactions.
///   3. SafeERC20 for USDC; native MON sends happen after state changes, under the guard.
///   4. Internal accounting (_trackedUsdc / _trackedMon) — totalAssets() never reads
///      balanceOf, so a direct token donation cannot move the share price.
///   5. Trustless price from PythPriceReader; swaps only through the whitelisted,
///      minOut-enforced SafeSwapExecutor. The agent's sole power is rebalance().
///
/// Asset model: ERC4626 underlying is USDC (6 dec). Deposits are in USDC. MON
/// (native, 18 dec) enters ONLY via agent rebalance swaps and is valued into NAV
/// at the fresh Pyth price. Redemptions are IN-KIND, pro-rata of tracked MON+USDC,
/// so a withdrawal never depends on the oracle and never lacks liquidity.
contract HardenedVault is ERC4626, ReentrancyGuard, SafeSwapExecutor {
    using SafeERC20 for IERC20;

    PythPriceReader public immutable priceReader;
    ILogBook public immutable logBook;

    address public owner;
    address public agent;
    bool public paused;

    // ----- internal accounting (donation-resistant). NEVER read balanceOf for NAV. -----
    uint256 private _trackedUsdc; // 6 dec
    uint256 private _trackedMon;  // wei (18 dec)

    uint256 public constant BPS_TARGET = 6000; // 60% MON
    uint256 public constant BPS_BAND = 500;    // ±5%
    uint8   private constant DEC_OFFSET = 6;   // virtual-shares offset

    event Rebalanced(uint256 priceE8, uint256 bpsBefore, uint256 bpsAfter, bool monToUsdc, uint256 spent, uint256 received);
    event RedeemedInKind(address indexed owner, address indexed receiver, uint256 shares, uint256 usdcOut, uint256 monOut);
    event PausedSet(bool paused);
    event AgentSet(address indexed agent);

    error AgentBlocked();
    error NotOwner();
    error NotAgent();
    error Paused();
    error InKindOnly();
    error ZeroShares();
    error NativeSendFailed();
    error AmountExceedsTracked();
    error NotRebalanceable();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyAgent() { if (msg.sender != agent) revert NotAgent(); _; }
    modifier notAgent()  { if (msg.sender == agent) revert AgentBlocked(); _; }

    constructor(
        IERC20 usdcToken,
        PythPriceReader _priceReader,
        ILogBook _logBook,
        address _agent,
        uint256 _slippageBps
    ) ERC20("Chog Vault Share", "cvCHOG") ERC4626(usdcToken) {
        owner = msg.sender;
        agent = _agent;
        priceReader = _priceReader;
        logBook = _logBook;
        _setSlippageBps(_slippageBps);
    }

    // ----- mixin hooks -----
    function _swapOwner() internal view override returns (address) { return owner; }
    function _usdc() internal view override returns (address) { return asset(); }
    function _decimalsOffset() internal pure override returns (uint8) { return DEC_OFFSET; }

    // ----- NAV (internal accounting only) -----

    /// @notice NAV in USDC terms (6 dec) = tracked USDC + tracked MON valued at fresh Pyth price.
    ///         Reads tracked balances, NOT balanceOf → donations cannot move share price.
    function totalAssets() public view override returns (uint256) {
        if (_trackedMon == 0) return _trackedUsdc;
        uint256 p = priceReader.readPriceE8(); // reverts if stale / low-confidence
        return _trackedUsdc + _trackedMon * p / 1e20; // 18 + 8 - 20 = 6 dec
    }

    function trackedUsdc() external view returns (uint256) { return _trackedUsdc; }
    function trackedMon() external view returns (uint256) { return _trackedMon; }

    // ----- deposits (USDC, standard ERC4626) -----

    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        notAgent
        returns (uint256)
    {
        if (paused) revert Paused();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        notAgent
        returns (uint256)
    {
        if (paused) revert Paused();
        return super.mint(shares, receiver);
    }

    /// @dev Shares are computed (in super.deposit/mint) from NAV BEFORE this runs;
    ///      the USDC is pulled and shares minted here, then we track the new USDC.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
    {
        super._deposit(caller, receiver, assets, shares); // pulls USDC (SafeERC20), mints shares
        _trackedUsdc += assets;
    }

    // ----- single-asset ERC4626 exits are disabled; this vault redeems IN-KIND -----

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert InKindOnly();
    }

    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert InKindOnly();
    }

    /// @notice Burn `shares` and return pro-rata tracked MON + USDC. No oracle needed;
    ///         pure pro-rata of internal accounting. CEI + reentrancy-guarded native send.
    function redeemInKind(uint256 shares, address receiver)
        external
        nonReentrant
        notAgent
        returns (uint256 usdcOut, uint256 monOut)
    {
        if (shares == 0) revert ZeroShares();
        uint256 supply = totalSupply();

        // pro-rata of tracked assets (rounds down → dust stays in vault, never over-pays)
        usdcOut = _trackedUsdc * shares / supply;
        monOut  = _trackedMon  * shares / supply;

        // ---- effects ----
        _burn(msg.sender, shares);
        _trackedUsdc -= usdcOut;
        _trackedMon  -= monOut;

        // ---- interactions ----
        if (usdcOut > 0) IERC20(asset()).safeTransfer(receiver, usdcOut);
        if (monOut > 0) {
            (bool ok, ) = receiver.call{value: monOut}("");
            if (!ok) revert NativeSendFailed();
        }
        emit RedeemedInKind(msg.sender, receiver, shares, usdcOut, monOut);
    }

    // ----- agent rebalance -----

    /// @notice Agent triggers a 60/40 rebalance. Agent supplies the off-chain-quoted
    ///         route (router + callData + amountIn + direction); the CONTRACT derives
    ///         minOut from the fresh Pyth price and enforces it via SafeSwapExecutor.
    /// @param monToUsdc true to trim MON→USDC, false to buy MON with USDC.
    function rebalance(
        address router,
        bytes calldata swapData,
        bool monToUsdc,
        uint256 amountIn
    ) external onlyAgent nonReentrant {
        if (paused) revert Paused();

        uint256 p = priceReader.readPriceE8();
        (uint256 navBefore, uint256 bpsBefore) = _checkRebalance(monToUsdc, amountIn, p);

        address tokenIn  = monToUsdc ? NATIVE : asset();
        address tokenOut = monToUsdc ? asset() : NATIVE;

        // minOut floor is the Pyth-derived quote minus the on-chain slippage cap.
        (uint256 spent, uint256 received) =
            _safeSwap(router, swapData, tokenIn, tokenOut, amountIn, quoteMinOut(tokenIn, amountIn, p));

        // ---- accounting from MEASURED deltas (never balanceOf) ----
        if (monToUsdc) {
            _trackedMon  -= spent;
            _trackedUsdc += received;
        } else {
            _trackedUsdc -= spent;
            _trackedMon  += received;
        }

        _finalizeRebalance(p, navBefore, bpsBefore, monToUsdc, spent, received);
    }

    /// @dev Validates that a rebalance in `monToUsdc` direction is warranted (outside band)
    ///      and that amountIn does not exceed the TRACKED side (so donations are never spent).
    function _checkRebalance(bool monToUsdc, uint256 amountIn, uint256 p)
        internal
        view
        returns (uint256 navBefore, uint256 bpsBefore)
    {
        uint256 monValBefore = _trackedMon * p / 1e20; // 6 dec
        navBefore = monValBefore + _trackedUsdc;
        if (navBefore == 0) revert NotRebalanceable();
        bpsBefore = monValBefore * 10_000 / navBefore;

        uint256 target = navBefore * BPS_TARGET / 10_000;
        uint256 band = navBefore * BPS_BAND / 10_000;
        if (monToUsdc) {
            if (!(monValBefore > target && monValBefore - target > band)) revert NotRebalanceable();
            if (amountIn > _trackedMon) revert AmountExceedsTracked();
        } else {
            if (!(target > monValBefore && target - monValBefore > band)) revert NotRebalanceable();
            if (amountIn > _trackedUsdc) revert AmountExceedsTracked();
        }
    }

    function _finalizeRebalance(
        uint256 p,
        uint256 navBefore,
        uint256 bpsBefore,
        bool monToUsdc,
        uint256 spent,
        uint256 received
    ) internal {
        uint256 monValAfter = _trackedMon * p / 1e20;
        uint256 navAfter = monValAfter + _trackedUsdc;
        uint256 bpsAfter = navAfter == 0 ? 0 : monValAfter * 10_000 / navAfter;

        logBook.record(p, bpsBefore, bpsAfter, navBefore, navAfter);
        emit Rebalanced(p, bpsBefore, bpsAfter, monToUsdc, spent, received);
    }

    // ----- owner controls -----

    function setSlippageBps(uint256 bps) external onlyOwner { _setSlippageBps(bps); }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    function setAgent(address _agent) external onlyOwner {
        agent = _agent;
        emit AgentSet(_agent);
    }

    /// @dev Accept native MON only from the swap path (router returning MON during a
    ///      USDC→MON rebalance). Tracked accounting is updated explicitly in rebalance();
    ///      any unsolicited MON sent here is an untracked donation and never counts toward NAV.
    receive() external payable {}
}
