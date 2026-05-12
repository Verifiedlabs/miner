# Hash256 Miner

Multi-backend proof-of-work miner for the Hash256 contract on Ethereum. Auto-detects and uses the best available backend: **CUDA** (NVIDIA GPU) → **Metal** (Apple Silicon) → **CPU** fallback.

Contract: [`0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc`](https://etherscan.io/address/0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc)

## Backends

| Backend | Binary | Platform |
|---|---|---|
| CUDA | `keccak_miner_cuda` | NVIDIA GPUs (Linux/Windows) |
| Metal | `metal_miner` | Apple Silicon (macOS) |
| CPU | `keccak_miner` | Any platform, multi-worker |

The Node.js orchestrator picks the first available binary at runtime. No config needed.

## Requirements

- Node.js 18+
- Ethereum RPC endpoint (Alchemy, Infura, or your own node)
- A funded wallet for gas fees
- **For CUDA**: NVIDIA GPU + CUDA Toolkit 12.x
- **For Metal**: macOS 12+ on Apple Silicon
- **For CPU**: a C compiler (gcc/clang)

## Install

```bash
git clone https://github.com/Verifiedlabs/miner.git
cd miner
npm install
```

Build the native backends you want to use (at least one):

```bash
# CUDA (Linux/Windows with NVIDIA)
nvcc -O3 -o keccak_miner_cuda keccak_miner_cuda.cu

# Metal (Apple Silicon)
swiftc -O -o metal_miner metal_miner.swift

# CPU (portable)
cc -O3 -o keccak_miner keccak_miner.c
```

## Configure

Create `.env` in the project root:

```env
RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
PRIVATE_KEY=0x...
NUM_WORKERS=8         # CPU-only, defaults to CPU core count
```

## Run

```bash
node miner.js
```

The miner prints the active backend, current difficulty, live hashrate, and submits solutions automatically.

## Disclaimer

This is experimental software. You are responsible for your own private keys, gas costs, and any on-chain activity. Test on a burner wallet first.

## License

ISC
