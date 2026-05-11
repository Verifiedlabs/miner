module.exports = [
  {
    name: "getChallenge",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "miner", type: "address" }],
    outputs: [{ type: "bytes32" }]
  },
  {
    name: "miningState",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "era", type: "uint256" },
      { name: "reward", type: "uint256" },
      { name: "difficulty", type: "uint256" },
      { name: "minted", type: "uint256" },
      { name: "remaining", type: "uint256" },
      { name: "epoch", type: "uint256" },
      { name: "epochBlocksLeft", type: "uint256" }
    ]
  },
  {
    name: "totalMints",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }]
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }]
  },
  {
    name: "mine",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "nonce", type: "uint256" }],
    outputs: []
  }
];
