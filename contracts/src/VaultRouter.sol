// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PythPriceReader} from "./PythPriceReader.sol";

/// @title VaultRouter — the parked-yield leg of the allocator.
/// @notice Parks idle base assets into whitelisted ERC4626 vaults: USDC → USDC
///         vaults, WMON → MON/LST vaults. Same hardening as the rest of the system:
///           * Owner-managed whitelist, MULTIPLE vaults per asset (primary + backup).
///             Adding/removing a vault is an OWNER/HUMAN tx — never the agent. A
///             removed vault stops accepting NEW parks but is still valued + unwound
///             (funds are never stranded).
///           * Every state-changing call is `onlyVault`; redemptions always pay the
///             VAULT, so funds can never leave to any other address.
///           * VALUE is `previewRedeem(shareBalance)` (real ERC4626 math); the WMON
///             leg is priced through the trustless Pyth reader.
///           * ROTATION COST GATE: `shouldRotate` enforces the penalty-free rule —
///             only move when the candidate's yield beats the incumbent by MORE than
///             the full round-trip cost. `selectBestVault` ranks candidates by NET
///             (yield − cost) bps. These are decision tools the vault enforces.
contract VaultRouter {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IERC20 public immutable wmon;
    PythPriceReader public immutable priceReader;

    address public owner;
    address public vault;

    // Full history of added vaults (never shrinks → value/unwind always covers every
    // venue that may hold shares). `whitelisted` gates only NEW parks.
    address[] public usdcVaults;
    address[] public monVaults;
    mapping(address => bool) public whitelisted;
    mapping(address => bool) public isMonVault;
    mapping(address => bool) public known;

    event VaultSet(address indexed vault);
    event VaultWhitelisted(address indexed erc4626, bool isMon, bool allowed);
    event Parked(address indexed erc4626, uint256 assetsIn, uint256 sharesOut);
    event Unparked(address indexed erc4626, uint256 sharesIn, uint256 assetsOut);
    event Unwound(uint256 wmon, uint256 usdc);

    error NotOwner();
    error NotVault();
    error VaultAlreadySet();
    error NotWhitelisted(address erc4626);
    error WrongAsset();
    error LengthMismatch();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyVault() { if (msg.sender != vault) revert NotVault(); _; }

    constructor(IERC20 _usdc, IERC20 _wmon, PythPriceReader _priceReader) {
        usdc = _usdc;
        wmon = _wmon;
        priceReader = _priceReader;
        owner = msg.sender;
    }

    function setVault(address _vault) external onlyOwner {
        if (vault != address(0)) revert VaultAlreadySet();
        require(_vault != address(0), "router: zero vault");
        vault = _vault;
        emit VaultSet(_vault);
    }

    // ============================ owner whitelist (human) ============================

    function addUsdcVault(address erc4626) external onlyOwner {
        if (IERC4626(erc4626).asset() != address(usdc)) revert WrongAsset();
        if (!known[erc4626]) { usdcVaults.push(erc4626); known[erc4626] = true; }
        whitelisted[erc4626] = true;
        isMonVault[erc4626] = false;
        emit VaultWhitelisted(erc4626, false, true);
    }

    function addMonVault(address erc4626) external onlyOwner {
        if (IERC4626(erc4626).asset() != address(wmon)) revert WrongAsset();
        if (!known[erc4626]) { monVaults.push(erc4626); known[erc4626] = true; }
        whitelisted[erc4626] = true;
        isMonVault[erc4626] = true;
        emit VaultWhitelisted(erc4626, true, true);
    }

    /// @notice Stop NEW parks into a venue (e.g. it became risky). Existing shares
    ///         remain valued + unwindable — funds are never stranded.
    function removeVault(address erc4626) external onlyOwner {
        whitelisted[erc4626] = false;
        emit VaultWhitelisted(erc4626, isMonVault[erc4626], false);
    }

    function usdcVaultCount() external view returns (uint256) { return usdcVaults.length; }
    function monVaultCount() external view returns (uint256) { return monVaults.length; }

    // ============================ vault-only mutations ============================

    /// @notice Deposit `assets` of the venue's underlying (already transferred in by
    ///         the vault) into a WHITELISTED ERC4626. Shares are held by this router.
    function park(address erc4626, uint256 assets) external onlyVault returns (uint256 shares) {
        if (!whitelisted[erc4626]) revert NotWhitelisted(erc4626);
        IERC20 a = isMonVault[erc4626] ? wmon : usdc;
        a.forceApprove(erc4626, assets);
        shares = IERC4626(erc4626).deposit(assets, address(this));
        a.forceApprove(erc4626, 0);
        emit Parked(erc4626, assets, shares);
    }

    /// @notice Redeem `shares` from a venue, sending the underlying straight to the VAULT.
    function unpark(address erc4626, uint256 shares) external onlyVault returns (uint256 assetsOut) {
        assetsOut = IERC4626(erc4626).redeem(shares, vault, address(this));
        emit Unparked(erc4626, shares, assetsOut);
    }

    function sharesOf(address erc4626) public view returns (uint256) {
        return IERC20(erc4626).balanceOf(address(this));
    }

    /// @notice Redeem `numerator/denominator` of EVERY held position to the vault.
    function unwind(uint256 numerator, uint256 denominator)
        external
        onlyVault
        returns (uint256 wmonOut, uint256 usdcOut)
    {
        if (numerator == 0 || denominator == 0) return (0, 0);
        uint256 n = usdcVaults.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 bal = sharesOf(usdcVaults[i]);
            uint256 r = bal * numerator / denominator;
            if (r > 0) usdcOut += IERC4626(usdcVaults[i]).redeem(r, vault, address(this));
        }
        uint256 m = monVaults.length;
        for (uint256 j = 0; j < m; j++) {
            uint256 bal = sharesOf(monVaults[j]);
            uint256 r = bal * numerator / denominator;
            if (r > 0) wmonOut += IERC4626(monVaults[j]).redeem(r, vault, address(this));
        }
        emit Unwound(wmonOut, usdcOut);
    }

    // ============================ valuation ============================

    /// @notice Total parked value in USDC terms (6dec): Σ previewRedeem(shares) for
    ///         USDC venues at par + Σ previewRedeem(shares) for MON venues priced
    ///         through Pyth. Counts every known venue exactly once.
    function valueUsdc() external view returns (uint256 value) {
        uint256 n = usdcVaults.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 bal = sharesOf(usdcVaults[i]);
            if (bal > 0) value += IERC4626(usdcVaults[i]).previewRedeem(bal);
        }
        uint256 wmonAssets;
        uint256 m = monVaults.length;
        for (uint256 j = 0; j < m; j++) {
            uint256 bal = sharesOf(monVaults[j]);
            if (bal > 0) wmonAssets += IERC4626(monVaults[j]).previewRedeem(bal);
        }
        if (wmonAssets > 0) {
            uint256 p = priceReader.readPriceE8();
            value += wmonAssets * p / 1e20; // 18 + 8 - 20 = 6 dec
        }
    }

    function previewVenueUsdc(address erc4626) external view returns (uint256) {
        uint256 bal = sharesOf(erc4626);
        if (bal == 0) return 0;
        uint256 assets = IERC4626(erc4626).previewRedeem(bal);
        if (!isMonVault[erc4626]) return assets;
        return assets * priceReader.readPriceE8() / 1e20;
    }

    // ============================ rotation decision rules ============================

    /// @notice Penalty-free cost gate. Rotate ONLY if the candidate's expected yield
    ///         over the hold beats the incumbent by strictly MORE than the full
    ///         round-trip cost (swap slippage + gas + entry/exit), all in bps.
    function shouldRotate(
        uint256 currentYieldBps,
        uint256 candidateYieldBps,
        uint256 roundTripCostBps
    ) public pure returns (bool) {
        return int256(candidateYieldBps) - int256(roundTripCostBps) > int256(currentYieldBps);
    }

    /// @notice Rank whitelisted candidates by NET (yield − cost) bps for the expected
    ///         hold, returning the best venue and its net. Reverts if any candidate is
    ///         not currently whitelisted. Caller supplies the off-chain yield/cost
    ///         estimates; the WHITELIST (not these estimates) is the security boundary.
    function selectBestVault(
        address[] calldata candidates,
        uint256[] calldata yieldsBps,
        uint256[] calldata costsBps
    ) external view returns (address best, int256 bestNetBps) {
        uint256 len = candidates.length;
        if (len != yieldsBps.length || len != costsBps.length) revert LengthMismatch();
        bestNetBps = type(int256).min;
        for (uint256 i = 0; i < len; i++) {
            if (!whitelisted[candidates[i]]) revert NotWhitelisted(candidates[i]);
            int256 net = int256(yieldsBps[i]) - int256(costsBps[i]);
            if (net > bestNetBps) {
                bestNetBps = net;
                best = candidates[i];
            }
        }
    }
}
