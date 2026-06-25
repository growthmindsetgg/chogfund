// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PythPriceReader} from "../src/PythPriceReader.sol";
import {IPyth, PythStructs} from "../src/interfaces/IPyth.sol";

/// Mock Pyth contract: replicates getPriceNoOlderThan staleness behavior and a flat fee.
contract MockPyth is IPyth {
    mapping(bytes32 => PythStructs.Price) internal _prices;
    uint256 public fee = 1;
    uint256 public updateCalls;

    function set(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        _prices[id] = PythStructs.Price(price, conf, expo, publishTime);
    }

    function setFee(uint256 f) external {
        fee = f;
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age)
        external
        view
        returns (PythStructs.Price memory)
    {
        PythStructs.Price memory p = _prices[id];
        require(p.publishTime != 0, "PriceFeedNotFound");
        require(block.timestamp - p.publishTime <= age, "StalePrice");
        return p;
    }

    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) {
        return _prices[id];
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return fee;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {
        require(msg.value >= fee, "InsufficientFee");
        updateCalls++;
    }
}

contract PythPriceReaderTest is Test {
    MockPyth pyth;
    PythPriceReader reader;

    bytes32 constant FEED = 0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1;
    uint256 constant MAX_AGE = 60;
    uint256 constant CONF_BPS = 100; // 1%

    uint256 constant NOW = 1_782_000_000;

    function setUp() public {
        vm.warp(NOW);
        pyth = new MockPyth();
        reader = new PythPriceReader(IPyth(address(pyth)), FEED, MAX_AGE, CONF_BPS);
    }

    // (a) fresh valid price returns correct priceE8 — expo -8 is identity.
    function test_FreshValidPrice_ReturnsPriceE8() public {
        // MON/USD ~ $0.02006489, conf ~10bps
        pyth.set(FEED, int64(2_006_489), uint64(2_017), int32(-8), NOW);
        assertEq(reader.readPriceE8(), 2_006_489);
    }

    // (a') normalization across exponents -> always 8 decimals.
    function test_Normalization_Expo5() public {
        // price 200 @ expo -5 = $0.00200 -> priceE8 = 200 * 10^(−5+8)=200*1000 = 200000
        pyth.set(FEED, int64(200), uint64(0), int32(-5), NOW);
        assertEq(reader.readPriceE8(), 200_000);
    }

    function test_Normalization_Expo10() public {
        // price 123456789 @ expo -10 -> priceE8 = 123456789 / 10^2 = 1234567
        pyth.set(FEED, int64(123_456_789), uint64(0), int32(-10), NOW);
        assertEq(reader.readPriceE8(), 1_234_567);
    }

    // (b) stale price reverts.
    function test_StalePrice_Reverts() public {
        pyth.set(FEED, int64(2_006_489), uint64(10), int32(-8), NOW);
        vm.warp(NOW + MAX_AGE + 1);
        vm.expectRevert(bytes("StalePrice"));
        reader.readPriceE8();
    }

    function test_FreshAtExactBoundary_OK() public {
        pyth.set(FEED, int64(2_006_489), uint64(10), int32(-8), NOW);
        vm.warp(NOW + MAX_AGE); // exactly at boundary still valid
        assertEq(reader.readPriceE8(), 2_006_489);
    }

    // (c) low-confidence price reverts.
    function test_LowConfidence_Reverts() public {
        // conf/price = 30000/2000000 = 150 bps > 100 bps threshold
        pyth.set(FEED, int64(2_000_000), uint64(30_000), int32(-8), NOW);
        vm.expectRevert(
            abi.encodeWithSelector(
                PythPriceReader.ConfidenceTooLow.selector, uint64(30_000), uint64(2_000_000), CONF_BPS
            )
        );
        reader.readPriceE8();
    }

    function test_ConfidenceAtThreshold_OK() public {
        // conf/price = 20000/2000000 = 100 bps == threshold -> allowed (strict >)
        pyth.set(FEED, int64(2_000_000), uint64(20_000), int32(-8), NOW);
        assertEq(reader.readPriceE8(), 2_000_000);
    }

    // (d) negative / zero price reverts.
    function test_NegativePrice_Reverts() public {
        pyth.set(FEED, int64(-5), uint64(0), int32(-8), NOW);
        vm.expectRevert(abi.encodeWithSelector(PythPriceReader.NonPositivePrice.selector, int64(-5)));
        reader.readPriceE8();
    }

    function test_ZeroPrice_Reverts() public {
        pyth.set(FEED, int64(0), uint64(0), int32(-8), NOW);
        vm.expectRevert(abi.encodeWithSelector(PythPriceReader.NonPositivePrice.selector, int64(0)));
        reader.readPriceE8();
    }

    // fresh-push path: pays fee, refunds excess, then reads.
    function test_UpdateAndRead_PaysFeeAndRefunds() public {
        pyth.set(FEED, int64(2_006_489), uint64(2_017), int32(-8), NOW);
        pyth.setFee(1);
        bytes[] memory data = new bytes[](1);
        data[0] = hex"deadbeef";

        uint256 balBefore = address(this).balance;
        uint256 priceE8 = reader.updateAndReadPriceE8{value: 1 ether}(data);

        assertEq(priceE8, 2_006_489);
        assertEq(pyth.updateCalls(), 1);
        // only the 1 wei fee consumed; the rest refunded
        assertEq(address(this).balance, balBefore - 1);
    }

    function test_UpdatePrice_InsufficientFee_Reverts() public {
        pyth.setFee(100);
        bytes[] memory data = new bytes[](1);
        data[0] = hex"deadbeef";
        vm.expectRevert(
            abi.encodeWithSelector(PythPriceReader.InsufficientFee.selector, uint256(10), uint256(100))
        );
        reader.updatePrice{value: 10}(data);
    }

    // owner config is the ONLY owner power — and it cannot set a price.
    function test_SetConfig_OnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(PythPriceReader.NotOwner.selector);
        reader.setConfig(120, 50);

        reader.setConfig(120, 50);
        assertEq(reader.maxAge(), 120);
        assertEq(reader.confThresholdBps(), 50);
    }

    receive() external payable {}
}
