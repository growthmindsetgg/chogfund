// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {INonfungiblePositionManager} from "./external/uniswap/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "./external/uniswap/IUniswapV3Pool.sol";
import {TickMath} from "./external/uniswap/TickMath.sol";
import {LiquidityAmounts} from "./external/uniswap/LiquidityAmounts.sol";
import {PythPriceReader} from "./PythPriceReader.sol";

/// @title LpManager — the MON/USDC concentrated-liquidity leg of the allocator.
/// @notice Holds ONE Uniswap V3 position on behalf of the vault. Hardened to the
///         same rules as the P3 core:
///           * Protocol addresses (position manager, pool, WMON, USDC) come from a
///             CONFIG-DRIVEN registry, set ONCE at construction (= an owner/human
///             whitelist decision). No protocol address is hardcoded in logic, and
///             swapping to real Uniswap at the mainnet canary (P7) is a config swap.
///           * Every state-changing call is `onlyVault`. The agent can only act
///             THROUGH the vault, and every fund movement out of this contract is
///             hardcoded to `vault` — funds can never leave to any other address.
///           * VALUATION uses the REAL audited TickMath / LiquidityAmounts against
///             the pool's live sqrtPriceX96, plus uncollected fees → canary-faithful.
///
///         Token convention: this contract speaks WMON (wrapped MON, 18dec) + USDC
///         (6dec). The vault wraps/unwraps native MON at the boundary. token0/token1
///         ordering is read from the pool and handled internally.
contract LpManager {
    using SafeERC20 for IERC20;

    // ----- config registry (owner/human-set; no hardcoded protocol addresses) -----
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Pool public immutable pool;
    PythPriceReader public immutable priceReader;
    address public immutable wmon;
    address public immutable usdc;
    uint24 public immutable fee;
    bool public immutable usdcIsToken0;

    address public owner;
    address public vault;

    // ----- the single live position -----
    uint256 public tokenId;     // 0 = no open position
    int24 public tickLower;
    int24 public tickUpper;

    event VaultSet(address indexed vault);
    event PositionOpened(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event PositionIncreased(uint256 indexed tokenId, uint128 liquidity);
    event FeesCollected(uint256 indexed tokenId, uint256 wmon, uint256 usdc);
    event RangeShifted(uint256 indexed oldTokenId, uint256 indexed newTokenId, int24 tickLower, int24 tickUpper);
    event Unwound(uint256 indexed tokenId, uint256 wmon, uint256 usdc);

    error NotOwner();
    error NotVault();
    error VaultAlreadySet();
    error NoPosition();
    error PositionExists();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyVault() { if (msg.sender != vault) revert NotVault(); _; }

    constructor(
        INonfungiblePositionManager _positionManager,
        IUniswapV3Pool _pool,
        PythPriceReader _priceReader,
        address _wmon,
        address _usdc
    ) {
        positionManager = _positionManager;
        pool = _pool;
        priceReader = _priceReader;
        wmon = _wmon;
        usdc = _usdc;
        fee = _pool.fee();
        owner = msg.sender;

        address t0 = _pool.token0();
        address t1 = _pool.token1();
        require(
            (t0 == _wmon && t1 == _usdc) || (t0 == _usdc && t1 == _wmon),
            "lp: pool/token mismatch"
        );
        usdcIsToken0 = (t0 == _usdc);
    }

    /// @notice One-time wiring of the controlling vault (owner/human action).
    function setVault(address _vault) external onlyOwner {
        if (vault != address(0)) revert VaultAlreadySet();
        require(_vault != address(0), "lp: zero vault");
        vault = _vault;
        emit VaultSet(_vault);
    }

    // ============================ token ordering helpers ============================

    function _toToken01(uint256 wmonAmt, uint256 usdcAmt) internal view returns (uint256 a0, uint256 a1) {
        return usdcIsToken0 ? (usdcAmt, wmonAmt) : (wmonAmt, usdcAmt);
    }

    function _toWmonUsdc(uint256 a0, uint256 a1) internal view returns (uint256 w, uint256 u) {
        return usdcIsToken0 ? (a1, a0) : (a0, a1);
    }

    function _bounds() internal view returns (uint160 a, uint160 b) {
        a = TickMath.getSqrtRatioAtTick(tickLower);
        b = TickMath.getSqrtRatioAtTick(tickUpper);
    }

    function _poolSqrt() internal view returns (uint160 s) {
        (s, , , , , , ) = pool.slot0();
    }

    /// @dev Sweep all idle WMON/USDC held here back to the vault — this contract
    ///      holds ONLY the NFT position between calls, so value() never has to
    ///      account for an idle-token leg (avoids a double-count / dropped leg).
    function _sweepToVault() internal returns (uint256 wmonSwept, uint256 usdcSwept) {
        wmonSwept = IERC20(wmon).balanceOf(address(this));
        usdcSwept = IERC20(usdc).balanceOf(address(this));
        if (wmonSwept > 0) IERC20(wmon).safeTransfer(vault, wmonSwept);
        if (usdcSwept > 0) IERC20(usdc).safeTransfer(vault, usdcSwept);
    }

    // ============================ open / increase ============================

    /// @notice Open the position. The vault MUST transfer `wmonAmount` WMON +
    ///         `usdcAmount` USDC to this contract immediately before calling.
    ///         `wmonMin`/`usdcMin` are the slippage floors (Pyth-derived, set by the
    ///         vault) on the amounts actually deployed. Unused dust is swept back.
    function openPosition(
        uint256 wmonAmount,
        uint256 usdcAmount,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 wmonMin,
        uint256 usdcMin
    ) external onlyVault returns (uint256 _tokenId, uint128 liquidity) {
        if (tokenId != 0) revert PositionExists();
        tickLower = _tickLower;
        tickUpper = _tickUpper;

        (address t0, address t1) = usdcIsToken0 ? (usdc, wmon) : (wmon, usdc);
        (uint256 d0, uint256 d1) = _toToken01(wmonAmount, usdcAmount);
        (uint256 m0, uint256 m1) = _toToken01(wmonMin, usdcMin);

        IERC20(t0).forceApprove(address(positionManager), d0);
        IERC20(t1).forceApprove(address(positionManager), d1);

        (_tokenId, liquidity, , ) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: fee,
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                amount0Desired: d0,
                amount1Desired: d1,
                amount0Min: m0,
                amount1Min: m1,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        IERC20(t0).forceApprove(address(positionManager), 0);
        IERC20(t1).forceApprove(address(positionManager), 0);

        tokenId = _tokenId;
        emit PositionOpened(_tokenId, _tickLower, _tickUpper, liquidity);
        _sweepToVault();
    }

    /// @notice Add to the existing position. Vault transfers tokens in first.
    function increasePosition(
        uint256 wmonAmount,
        uint256 usdcAmount,
        uint256 wmonMin,
        uint256 usdcMin
    ) external onlyVault returns (uint128 liquidity) {
        if (tokenId == 0) revert NoPosition();
        (address t0, address t1) = usdcIsToken0 ? (usdc, wmon) : (wmon, usdc);
        (uint256 d0, uint256 d1) = _toToken01(wmonAmount, usdcAmount);
        (uint256 m0, uint256 m1) = _toToken01(wmonMin, usdcMin);

        IERC20(t0).forceApprove(address(positionManager), d0);
        IERC20(t1).forceApprove(address(positionManager), d1);

        (liquidity, , ) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: d0,
                amount1Desired: d1,
                amount0Min: m0,
                amount1Min: m1,
                deadline: block.timestamp
            })
        );

        IERC20(t0).forceApprove(address(positionManager), 0);
        IERC20(t1).forceApprove(address(positionManager), 0);

        emit PositionIncreased(tokenId, liquidity);
        _sweepToVault();
    }

    // ============================ collect fees ============================

    /// @notice Collect uncollected fees straight to the vault.
    function collectFees() external onlyVault returns (uint256 wmonOut, uint256 usdcOut) {
        if (tokenId == 0) revert NoPosition();
        (uint256 c0, uint256 c1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: vault,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        (wmonOut, usdcOut) = _toWmonUsdc(c0, c1);
        emit FeesCollected(tokenId, wmonOut, usdcOut);
    }

    // ============================ range shift ============================

    /// @notice Close the current position fully (principal + fees), then re-open at
    ///         a new range with everything collected. Value is preserved up to the
    ///         modeled cost (in the mock that cost is ~0; real swap/gas/LP cost is
    ///         validated at the P7 mainnet canary). Leftover dust swept to vault.
    function shiftRange(
        int24 _tickLower,
        int24 _tickUpper,
        uint256 wmonMin,
        uint256 usdcMin
    ) external onlyVault returns (uint256 newTokenId, uint128 liquidity) {
        if (tokenId == 0) revert NoPosition();
        uint256 oldId = tokenId;

        // 1. pull ALL liquidity out (credits principal to tokensOwed)
        (, , , , , , , uint128 liq, , , , ) = positionManager.positions(oldId);
        if (liq > 0) {
            positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: oldId,
                    liquidity: liq,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }
        // 2. collect principal + fees into THIS contract
        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: oldId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        positionManager.burn(oldId);
        tokenId = 0;

        // 3. re-open at the new range with everything we now hold
        uint256 wBal = IERC20(wmon).balanceOf(address(this));
        uint256 uBal = IERC20(usdc).balanceOf(address(this));
        (newTokenId, liquidity) = this.openPositionInternal(wBal, uBal, _tickLower, _tickUpper, wmonMin, usdcMin);

        emit RangeShifted(oldId, newTokenId, _tickLower, _tickUpper);
    }

    /// @dev External-self trampoline so shiftRange can reuse open logic under the
    ///      onlyVault gate. Restricted to self-calls only.
    function openPositionInternal(
        uint256 wmonAmount,
        uint256 usdcAmount,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 wmonMin,
        uint256 usdcMin
    ) external returns (uint256 _tokenId, uint128 liquidity) {
        require(msg.sender == address(this), "lp: only self");
        if (tokenId != 0) revert PositionExists();
        tickLower = _tickLower;
        tickUpper = _tickUpper;

        (address t0, address t1) = usdcIsToken0 ? (usdc, wmon) : (wmon, usdc);
        (uint256 d0, uint256 d1) = _toToken01(wmonAmount, usdcAmount);
        (uint256 m0, uint256 m1) = _toToken01(wmonMin, usdcMin);

        IERC20(t0).forceApprove(address(positionManager), d0);
        IERC20(t1).forceApprove(address(positionManager), d1);

        (_tokenId, liquidity, , ) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: t0, token1: t1, fee: fee,
                tickLower: _tickLower, tickUpper: _tickUpper,
                amount0Desired: d0, amount1Desired: d1,
                amount0Min: m0, amount1Min: m1,
                recipient: address(this), deadline: block.timestamp
            })
        );

        IERC20(t0).forceApprove(address(positionManager), 0);
        IERC20(t1).forceApprove(address(positionManager), 0);

        tokenId = _tokenId;
        emit PositionOpened(_tokenId, _tickLower, _tickUpper, liquidity);
        _sweepToVault();
    }

    // ============================ unwind (pro-rata to vault) ============================

    /// @notice Remove `numerator/denominator` of the position (principal + the same
    ///         fraction of uncollected fees) and send the proceeds to the VAULT only.
    ///         Used by the vault's pro-rata in-kind redemption.
    function unwind(uint256 numerator, uint256 denominator)
        external
        onlyVault
        returns (uint256 wmonOut, uint256 usdcOut)
    {
        if (tokenId == 0 || numerator == 0 || denominator == 0) return (0, 0);

        (, , , , , , , uint128 liq, , , uint128 owed0, uint128 owed1) = positionManager.positions(tokenId);

        uint128 dl = uint128(uint256(liq) * numerator / denominator);
        uint256 p0;
        uint256 p1;
        if (dl > 0) {
            (p0, p1) = positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: dl,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }

        // collect freed principal + the SAME fraction of pre-existing fees; leave the
        // rest of the fees in the position for the remaining holders (no over-pay).
        uint256 c0 = p0 + uint256(owed0) * numerator / denominator;
        uint256 c1 = p1 + uint256(owed1) * numerator / denominator;

        (uint256 got0, uint256 got1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: vault,
                amount0Max: uint128(c0),
                amount1Max: uint128(c1)
            })
        );

        // If we burned the whole position, clear the slot so a new one can open.
        if (numerator >= denominator) tokenId = 0;

        (wmonOut, usdcOut) = _toWmonUsdc(got0, got1);
        emit Unwound(tokenId, wmonOut, usdcOut);
    }

    // ============================ valuation ============================

    /// @notice Value of the LP leg in USDC terms (6dec): principal (from liquidity +
    ///         live sqrtPriceX96, via real TickMath/LiquidityAmounts) + uncollected
    ///         fees, with the WMON side priced through the trustless Pyth reader.
    function valueUsdc() external view returns (uint256) {
        if (tokenId == 0) return 0;
        (, , , , , , , uint128 liq, , , uint128 owed0, uint128 owed1) = positionManager.positions(tokenId);

        (uint160 a, uint160 b) = _bounds();
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(_poolSqrt(), a, b, liq);

        uint256 total0 = amt0 + owed0;
        uint256 total1 = amt1 + owed1;
        (uint256 wmonAmt, uint256 usdcAmt) = _toWmonUsdc(total0, total1);

        uint256 p = priceReader.readPriceE8();            // reverts if stale / low-confidence
        return usdcAmt + wmonAmt * p / 1e20;              // 18 + 8 - 20 = 6 dec
    }

    /// @notice Raw position amounts (token0/token1 principal + fees) for off-chain
    ///         tracing and the agent's range/fee decisions.
    function positionAmounts()
        external
        view
        returns (uint128 liq, uint256 wmonAmt, uint256 usdcAmt, uint256 wmonFees, uint256 usdcFees)
    {
        if (tokenId == 0) return (0, 0, 0, 0, 0);
        uint128 owed0;
        uint128 owed1;
        (, , , , , , , liq, , , owed0, owed1) = positionManager.positions(tokenId);
        (uint160 a, uint160 b) = _bounds();
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(_poolSqrt(), a, b, liq);
        (wmonAmt, usdcAmt) = _toWmonUsdc(amt0, amt1);
        (wmonFees, usdcFees) = _toWmonUsdc(owed0, owed1);
    }
}
