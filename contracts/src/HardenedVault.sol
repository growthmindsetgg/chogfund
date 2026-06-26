// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    // `internal` so allocator subclasses (P4) can move base assets into legs and back
    // while keeping totalAssets()/redeemInKind the single source of truth.
    uint256 internal _trackedUsdc; // 6 dec
    uint256 internal _trackedMon;  // wei (18 dec)

    uint256 public constant BPS_TARGET = 6000; // 60% MON
    uint256 public constant BPS_BAND = 500;    // ±5%
    uint8   private constant DEC_OFFSET = 6;   // virtual-shares offset

    event Rebalanced(uint256 priceE8, uint256 bpsBefore, uint256 bpsAfter, bool monToUsdc, uint256 spent, uint256 received);
    event RedeemedInKind(address indexed owner, address indexed receiver, uint256 shares, uint256 usdcOut, uint256 monOut);
    event DepositedMON(address indexed caller, address indexed receiver, uint256 monIn, uint256 priceE8, uint256 monValueUsdc, uint256 shares);
    event PausedSet(bool paused);
    event AgentSet(address indexed agent);

    error AgentBlocked();
    error NotOwner();
    error NotAgent();
    error Paused();
    error InKindOnly();
    error ZeroShares();
    error ZeroDeposit();
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

    /// @notice NAV in USDC terms (6 dec) = tracked USDC + tracked MON valued at fresh
    ///         Pyth price + the value of any allocator legs (LP / parked vaults — P4).
    ///         Reads tracked balances, NOT balanceOf → donations cannot move share price.
    function totalAssets() public view override returns (uint256) {
        uint256 nav = _trackedUsdc;
        if (_trackedMon != 0) {
            uint256 p = priceReader.readPriceE8(); // reverts if stale / low-confidence
            nav += _trackedMon * p / 1e20;         // 18 + 8 - 20 = 6 dec
        }
        return nav + _legsValueUsdc(); // each extra leg counted exactly once (default 0)
    }

    // ----- allocator-leg hooks (P4). Default: no extra legs → identical P3 behavior. -----

    /// @dev USDC-6dec value of every extra allocator leg (LP position, parked vault
    ///      shares). Overridden by AllocatorVault. MUST count each leg exactly once.
    function _legsValueUsdc() internal view virtual returns (uint256) { return 0; }

    /// @dev Unwind `shares/supply` of every allocator leg back into THIS vault as base
    ///      USDC + native MON, returning the amounts to forward to the redeemer.
    ///      Default no-op (P3 two-leg vault). Override pulls LP / parked pro-rata.
    function _unwindLegs(uint256 /*shares*/, uint256 /*supply*/)
        internal
        virtual
        returns (uint256 usdcFromLegs, uint256 monFromLegs)
    {
        return (0, 0);
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

    /// @notice Deposit NATIVE MON and receive vault shares.
    /// @dev Unlike the USDC path, this values the deposit through the oracle, so it
    ///      uses the UPDATE-THEN-MINT pattern: the caller supplies the latest Hermes
    ///      `priceUpdate`, which is pushed on-chain in THIS tx, so the price is fresh
    ///      by construction (closes the stale-price dilution surface — see design).
    ///      `msg.value` = the Pyth update fee + the MON being deposited.
    ///
    ///      Shares are computed against NAV-BEFORE-credit via the inherited ERC4626
    ///      `_convertToShares` (same virtual-shares / decimals-offset inflation guard
    ///      the USDC path uses), then the MON is tracked and shares minted. CEI: the
    ///      only external call (the trusted price push) happens before any effects;
    ///      `_mint` has no receiver callback and no native MON is sent out, so there
    ///      is no reentrancy vector (and `nonReentrant` guards regardless).
    /// @param priceUpdate Hermes update data (bytes[]) for the MON/USD feed.
    /// @param receiver    recipient of the minted shares.
    /// @return shares     shares minted to `receiver`.
    function depositMON(bytes[] calldata priceUpdate, address receiver)
        external
        payable
        nonReentrant
        notAgent
        returns (uint256 shares)
    {
        if (paused) revert Paused();

        // 1) Push fresh Pyth data in THIS tx (trusted external call). Pay the EXACT
        //    fee so the reader's excess-refund .call never fires.
        uint256 fee = priceReader.getUpdateFee(priceUpdate);
        if (msg.value <= fee) revert ZeroDeposit(); // must leave > 0 MON after the fee
        priceReader.updatePrice{value: fee}(priceUpdate);
        uint256 monIn = msg.value - fee;

        // 2) Fresh, guarded price (staleness + confidence + non-positive enforced in
        //    readPriceE8). monValue in 6-dec USDC terms: 18 + 8 - 20 = 6.
        uint256 p = priceReader.readPriceE8();
        uint256 monValue = monIn * p / 1e20;
        if (monValue == 0) revert ZeroDeposit();

        // 3) Shares vs NAV-BEFORE-credit, with the ERC4626 virtual-offset guard.
        shares = _convertToShares(monValue, Math.Rounding.Floor);
        if (shares == 0) revert ZeroShares();

        // 4) EFFECTS last. Native MON rests in the vault, tracked like rebalance MON;
        //    redeemInKind already pays it back pro-rata.
        _trackedMon += monIn;
        _mint(receiver, shares);
        emit DepositedMON(msg.sender, receiver, monIn, p, monValue, shares);
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

        // base pro-rata of tracked assets (rounds down → dust stays in vault, never over-pays)
        uint256 baseUsdc = _trackedUsdc * shares / supply;
        uint256 baseMon  = _trackedMon  * shares / supply;

        // ---- effects (base accounting) ----
        _burn(msg.sender, shares);
        _trackedUsdc -= baseUsdc;
        _trackedMon  -= baseMon;

        // ---- unwind allocator legs pro-rata INTO this vault (native MON + USDC) ----
        // Uses the PRE-burn `supply`. Default no-op for the P3 vault. Same rounding
        // (down) as the base legs, so a redemption never over-pays any leg.
        (uint256 usdcLeg, uint256 monLeg) = _unwindLegs(shares, supply);

        usdcOut = baseUsdc + usdcLeg;
        monOut  = baseMon  + monLeg;

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
