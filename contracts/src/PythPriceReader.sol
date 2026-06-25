// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPyth, PythStructs} from "./interfaces/IPyth.sol";

/// @title PythPriceReader
/// @notice Trustless price source for the vault. Reads MON/USD from the on-chain
///         Pyth contract, enforces freshness + confidence, and normalizes to an
///         8-decimal `priceE8` (USD-per-MON) used by the rest of the system.
///
///         There is NO owner setPrice path. No EOA can inject a price. The only
///         way a price enters the system is fresh, signed Pyth update data pushed
///         via updatePrice()/updateAndReadPriceE8(); reads always come straight
///         from the Pyth contract with staleness + confidence guards.
contract PythPriceReader {
    IPyth   public immutable pyth;
    bytes32 public immutable feedId;

    address public owner;

    /// @notice Max age (seconds) a Pyth price may have before reads revert.
    uint256 public maxAge;
    /// @notice Reject prices whose conf/price ratio exceeds this many bps.
    uint256 public confThresholdBps;

    uint256 private constant TARGET_DECIMALS = 8;
    int256  private constant MAX_ABS_EXP = 30; // guard against absurd exponents

    event ConfigUpdated(uint256 maxAge, uint256 confThresholdBps);
    event OwnerTransferred(address indexed from, address indexed to);
    event PricePushed(address indexed caller, uint256 fee);

    error NotOwner();
    error NonPositivePrice(int64 price);
    error ConfidenceTooLow(uint64 conf, uint64 price, uint256 thresholdBps);
    error ExpoOutOfRange(int32 expo);
    error InsufficientFee(uint256 sent, uint256 required);
    error RefundFailed();
    error ZeroConfig();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPyth _pyth, bytes32 _feedId, uint256 _maxAge, uint256 _confThresholdBps) {
        if (_maxAge == 0 || _confThresholdBps == 0) revert ZeroConfig();
        pyth = _pyth;
        feedId = _feedId;
        owner = msg.sender;
        maxAge = _maxAge;
        confThresholdBps = _confThresholdBps;
        emit ConfigUpdated(_maxAge, _confThresholdBps);
    }

    // ---------- owner config (risk params only — NOT a price setter) ----------

    function setConfig(uint256 _maxAge, uint256 _confThresholdBps) external onlyOwner {
        if (_maxAge == 0 || _confThresholdBps == 0) revert ZeroConfig();
        maxAge = _maxAge;
        confThresholdBps = _confThresholdBps;
        emit ConfigUpdated(_maxAge, _confThresholdBps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "reader: zero owner");
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---------- reads ----------

    /// @notice Fresh, guarded MON/USD price as priceE8 (8-decimal USD). Reverts if
    ///         the Pyth price is stale, too uncertain, or non-positive.
    function readPriceE8() public view returns (uint256 priceE8) {
        PythStructs.Price memory p = pyth.getPriceNoOlderThan(feedId, maxAge);

        if (p.price <= 0) revert NonPositivePrice(p.price);
        uint64 price = uint64(p.price);

        // conf and price share the same expo, so the ratio is scale-free:
        // reject when conf/price > threshold  <=>  conf * 1e4 > price * thresholdBps
        if (uint256(p.conf) * 10_000 > uint256(price) * confThresholdBps) {
            revert ConfidenceTooLow(p.conf, price, confThresholdBps);
        }

        priceE8 = _toE8(price, p.expo);
    }

    /// @notice priceE8 normalization: value = price * 10^expo, priceE8 = value * 10^8.
    function _toE8(uint64 price, int32 expo) internal pure returns (uint256) {
        int256 e = int256(expo) + int256(TARGET_DECIMALS); // expo + 8
        if (e >= 0) {
            if (e > MAX_ABS_EXP) revert ExpoOutOfRange(expo);
            return uint256(price) * (10 ** uint256(e));
        } else {
            uint256 d = uint256(-e);
            if (int256(d) > MAX_ABS_EXP) revert ExpoOutOfRange(expo);
            return uint256(price) / (10 ** d);
        }
    }

    // ---------- fresh-push helpers ----------

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256) {
        return pyth.getUpdateFee(updateData);
    }

    /// @notice Push fresh Hermes update data on-chain, paying the Pyth fee. Refunds excess.
    function updatePrice(bytes[] calldata updateData) external payable {
        _pushUpdate(updateData);
    }

    /// @notice Push fresh data then return the validated priceE8 in one flow.
    function updateAndReadPriceE8(bytes[] calldata updateData)
        external
        payable
        returns (uint256 priceE8)
    {
        _pushUpdate(updateData);
        priceE8 = readPriceE8();
    }

    function _pushUpdate(bytes[] calldata updateData) internal {
        uint256 fee = pyth.getUpdateFee(updateData);
        if (msg.value < fee) revert InsufficientFee(msg.value, fee);

        pyth.updatePriceFeeds{value: fee}(updateData);
        emit PricePushed(msg.sender, fee);

        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }
}
