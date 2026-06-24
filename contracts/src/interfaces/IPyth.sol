// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

// Minimal subset of the Pyth EVM interface we depend on. Kept inline (rather
// than adding the pyth-sdk-solidity dependency) so the contract set stays
// self-contained and pinned to one solc version.
library PythStructs {
    struct Price {
        int64  price;       // price, scaled by 10^expo
        uint64 conf;        // confidence interval, same scale as price
        int32  expo;        // exponent (typically negative)
        uint256 publishTime; // unix timestamp of the price
    }

    struct PriceFeed {
        bytes32 id;
        Price price;
        Price emaPrice;
    }
}

interface IPyth {
    /// @notice Returns the price if it is not older than `age` seconds, else reverts (StalePrice).
    function getPriceNoOlderThan(bytes32 id, uint256 age)
        external
        view
        returns (PythStructs.Price memory price);

    /// @notice Returns the most recent price without any staleness check.
    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory price);

    /// @notice Fee (in wei) required to submit `updateData` to updatePriceFeeds.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

    /// @notice Submit fresh Pyth update data on-chain. Must send >= getUpdateFee() as value.
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}
