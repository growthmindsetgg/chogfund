// ABIs for the P3 hardened contract set (PythPriceReader, HardenedVault) and the
// raw on-chain Pyth contract. Kept separate from the legacy abi.ts so the old
// OracleAMM/RebalanceVault scripts keep compiling unchanged.

export const pythReaderAbi = [
  { type: "function", name: "readPriceE8", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "feedId", stateMutability: "view", inputs: [], outputs: [{ type: "bytes32" }] },
  { type: "function", name: "maxAge", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "confThresholdBps", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function", name: "getUpdateFee", stateMutability: "view",
    inputs: [{ name: "updateData", type: "bytes[]" }], outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "updatePrice", stateMutability: "payable",
    inputs: [{ name: "updateData", type: "bytes[]" }], outputs: [],
  },
  {
    type: "function", name: "updateAndReadPriceE8", stateMutability: "payable",
    inputs: [{ name: "updateData", type: "bytes[]" }], outputs: [{ type: "uint256" }],
  },
] as const;

export const hardenedVaultAbi = [
  { type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "trackedUsdc", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "trackedMon", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "paused", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { type: "function", name: "agent", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "owner", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "asset", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  {
    type: "function", name: "quoteMinOut", stateMutability: "view",
    inputs: [{ name: "tokenIn", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "priceE8", type: "uint256" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "deposit", stateMutability: "nonpayable",
    inputs: [{ name: "assets", type: "uint256" }, { name: "receiver", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "redeemInKind", stateMutability: "nonpayable",
    inputs: [{ name: "shares", type: "uint256" }, { name: "receiver", type: "address" }],
    outputs: [{ name: "usdcOut", type: "uint256" }, { name: "monOut", type: "uint256" }],
  },
  {
    type: "function", name: "rebalance", stateMutability: "nonpayable",
    inputs: [
      { name: "router", type: "address" },
      { name: "swapData", type: "bytes" },
      { name: "monToUsdc", type: "bool" },
      { name: "amountIn", type: "uint256" },
    ],
    outputs: [],
  },
  { type: "function", name: "setRouterWhitelist", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "bool" }], outputs: [] },
] as const;

// Raw Pyth contract — used for read-only getUpdateFee and parse simulation.
export const pythAbi = [
  {
    type: "function", name: "getUpdateFee", stateMutability: "view",
    inputs: [{ name: "updateData", type: "bytes[]" }], outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "parsePriceFeedUpdates", stateMutability: "payable",
    inputs: [
      { name: "updateData", type: "bytes[]" },
      { name: "priceIds", type: "bytes32[]" },
      { name: "minPublishTime", type: "uint64" },
      { name: "maxPublishTime", type: "uint64" },
    ],
    outputs: [
      {
        name: "priceFeeds", type: "tuple[]",
        components: [
          { name: "id", type: "bytes32" },
          {
            name: "price", type: "tuple",
            components: [
              { name: "price", type: "int64" },
              { name: "conf", type: "uint64" },
              { name: "expo", type: "int32" },
              { name: "publishTime", type: "uint256" },
            ],
          },
          {
            name: "emaPrice", type: "tuple",
            components: [
              { name: "price", type: "int64" },
              { name: "conf", type: "uint64" },
              { name: "expo", type: "int32" },
              { name: "publishTime", type: "uint256" },
            ],
          },
        ],
      },
    ],
  },
  // MockSwapRouter.swap — for building rebalance calldata against the testnet mock router.
  {
    type: "function", name: "swap", stateMutability: "payable",
    inputs: [
      { name: "tokenIn", type: "address" },
      { name: "tokenOut", type: "address" },
      { name: "pullIn", type: "uint256" },
      { name: "pushOut", type: "uint256" },
    ],
    outputs: [],
  },
] as const;
