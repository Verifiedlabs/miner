const { ethers } = require("ethers");
const { spawn } = require("child_process");
const path = require("path");
const fs = require("fs");
const ABI = require("./abi");

const CONTRACT = "0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc";

const CUDA_BINARY  = path.join(__dirname, "keccak_miner_cuda");
const METAL_BINARY = path.join(__dirname, "metal_miner");
const CPU_BINARY   = path.join(__dirname, "keccak_miner");

const USE_CUDA  = fs.existsSync(CUDA_BINARY);
const USE_METAL = !USE_CUDA && fs.existsSync(METAL_BINARY);
const BINARY    = USE_CUDA ? CUDA_BINARY : (USE_METAL ? METAL_BINARY : CPU_BINARY);
const MODE      = USE_CUDA ? "GPU (CUDA)" : (USE_METAL ? "GPU (Metal)" : "CPU");
const NUM_WORKERS = (USE_CUDA || USE_METAL) ? 1 : parseInt(process.env.NUM_WORKERS || require("os").cpus().length);

function fmtHashrate(hps) {
  if (hps >= 1e9) return (hps / 1e9).toFixed(2) + " GH/s";
  if (hps >= 1e6) return (hps / 1e6).toFixed(2) + " MH/s";
  if (hps >= 1e3) return (hps / 1e3).toFixed(2) + " kH/s";
  return hps.toFixed(0) + " H/s";
}

function fmtNumber(n) {
  return n.toLocaleString("en-US");
}

function fmtDuration(sec) {
  if (sec < 60) return sec.toFixed(1) + "s";
  if (sec < 3600) return Math.floor(sec / 60) + "m " + Math.floor(sec % 60) + "s";
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  return h + "h " + m + "m";
}

function short(hex, head = 6, tail = 4) {
  if (!hex) return "—";
  const s = String(hex);
  if (s.length < head + tail + 2) return s;
  return s.slice(0, head + 2) + "…" + s.slice(-tail);
}

async function main() {
  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) {
    console.error("Set PRIVATE_KEY env variable");
    process.exit(1);
  }

  const readProvider = process.env.RPC_URL
    ? new ethers.JsonRpcProvider(process.env.RPC_URL)
    : new ethers.FallbackProvider([
        { provider: new ethers.JsonRpcProvider("https://ethereum.publicnode.com"), priority: 1, weight: 1 },
        { provider: new ethers.JsonRpcProvider("https://1rpc.io/eth"), priority: 2, weight: 1 },
        { provider: new ethers.JsonRpcProvider("https://eth.drpc.org"), priority: 3, weight: 1 },
      ], 1);

  const submitRpc = process.env.SUBMIT_RPC || "https://rpc.flashbots.net/fast";
  const submitProvider = new ethers.JsonRpcProvider(submitRpc);

  const readWallet = new ethers.Wallet(privateKey, readProvider);
  const submitWallet = new ethers.Wallet(privateKey, submitProvider);
  const readContract = new ethers.Contract(CONTRACT, ABI, readWallet);
  const submitContract = new ethers.Contract(CONTRACT, ABI, submitWallet);

  console.log("─".repeat(60));
  console.log("  hash256 miner");
  console.log("─".repeat(60));
  console.log("  address:    ", readWallet.address);
  console.log("  mode:       ", MODE);
  console.log("  workers:    ", NUM_WORKERS);
  console.log("  read rpc:   ", process.env.RPC_URL || "fallback");
  console.log("  submit rpc: ", submitRpc);
  console.log("─".repeat(60));

  await mineLoop(readContract, submitContract, readWallet, readProvider);
}

async function mineLoop(readContract, submitContract, wallet, provider) {
  while (true) {
    try {
      const [challenge, state, balance] = await Promise.all([
        readContract.getChallenge(wallet.address),
        readContract.miningState(),
        readContract.balanceOf(wallet.address)
      ]);

      const era = state[0];
      const reward = state[1];
      const target = state[2];
      const minted = state[3];
      const remaining = state[4];
      const epoch = state[5];
      const epochBlocksLeft = state[6];
      const targetHex = target.toString(16).padStart(64, "0");

      console.log();
      console.log("  era:         ", era.toString());
      console.log("  reward:      ", ethers.formatEther(reward), "HASH");
      console.log("  difficulty:  ", "0x" + targetHex.slice(0, 8) + "…" + targetHex.slice(-6));
      console.log("  epoch:       ", epoch.toString(), "(rotates in", epochBlocksLeft.toString(), "blk ~" + fmtDuration(Number(epochBlocksLeft) * 12) + ")");
      console.log("  minted:      ", ethers.formatEther(minted), "HASH");
      console.log("  remaining:   ", ethers.formatEther(remaining), "HASH");
      console.log("  balance:     ", ethers.formatEther(balance), "HASH");
      console.log("  challenge:   ", short(challenge, 10, 6));
      console.log();

      const nonce = await bruteForce(challenge, targetHex, epoch, readContract);
      if (!nonce) {
        console.log("  ↻ epoch rotated, restarting...");
        continue;
      }
      console.log();
      console.log("  ✓ FOUND: 0x" + nonce.slice(0, 16) + "…" + nonce.slice(-12));

      const currentState = await readContract.miningState();
      const currentEpoch = currentState[5];
      if (currentEpoch.toString() !== epoch.toString()) {
        console.log("  ✗ epoch rotated before submit, skipping...");
        continue;
      }

      console.log("  ⚡ submitting via private mempool...");

      const feeData = await provider.getFeeData();
      const tipGwei = process.env.TIP_GWEI || "2";
      const priorityFee = ethers.parseUnits(tipGwei, "gwei");
      const baseFee = feeData.maxFeePerGas || 0n;
      const maxFeePerGas = baseFee > priorityFee ? baseFee : priorityFee * 2n;

      const tx = await submitContract.mine(BigInt("0x" + nonce), {
        gasLimit: 300000n,
        maxFeePerGas,
        maxPriorityFeePerGas: priorityFee,
      });
      console.log("  tx:          ", tx.hash);
      console.log("  waiting for confirmation...");

      const receipt = await tx.wait();
      console.log();
      console.log("  ✓ CONFIRMED in block", receipt.blockNumber);

      const newBalance = await readContract.balanceOf(wallet.address);
      console.log("  balance:     ", ethers.formatEther(newBalance), "HASH (+" + ethers.formatEther(reward) + ")");
    } catch (err) {
      console.log();
      console.error("  ✗ error:", err.shortMessage || err.message);
      if (err.info) console.error("  rpc info:", JSON.stringify(err.info?.error || err.info, null, 2));
      await sleep(5000);
    }
  }
}

function bruteForce(challenge, targetHex, epoch, contract) {
  return new Promise((resolve, reject) => {
    const procs = [];
    let done = false;
    const workerStats = new Array(NUM_WORKERS).fill(0);
    const startTime = Date.now();

    const target = BigInt("0x" + targetHex);
    const maxVal = BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    const probability = Number(target) / Number(maxVal);

    const epochChecker = setInterval(async () => {
      try {
        const state = await contract.miningState();
        const currentEpoch = state[5];
        if (currentEpoch.toString() !== epoch.toString() && !done) {
          done = true;
          clearInterval(epochChecker);
          procs.forEach(p => p.kill());
          resolve(null);
        }
      } catch {}
    }, 12000);

    for (let i = 0; i < NUM_WORKERS; i++) {
      const proc = spawn(BINARY, [challenge, "0x" + targetHex, String(i)]);

      proc.stdout.on("data", (data) => {
        const line = data.toString().trim();
        if (line.startsWith("FOUND:") && !done) {
          done = true;
          clearInterval(epochChecker);
          procs.forEach(p => p.kill());
          resolve(line.slice(6));
        }
      });

      proc.stderr.on("data", (data) => {
        const str = data.toString();
        for (const line of str.split("\n")) {
          if (line.startsWith("PROGRESS:")) {
            const parts = line.split(":");
            workerStats[parseInt(parts[1])] = parseInt(parts[2]);
            const totalHps = workerStats.reduce((a, b) => a + b, 0);
            const elapsedSec = (Date.now() - startTime) / 1000;
            const totalHashes = totalHps * elapsedSec;
            const expectedHashes = 1 / probability;
            const remainingHashes = Math.max(0, expectedHashes - totalHashes);
            const etaSec = totalHps > 0 ? remainingHashes / totalHps : 0;
            process.stdout.write(
              `\r  searching · ${fmtHashrate(totalHps)} · ${fmtNumber(Math.floor(totalHashes))} hashes · ${fmtDuration(elapsedSec)} · ETA ~${fmtDuration(etaSec)}     `
            );
          }
        }
      });

      proc.on("error", reject);
      procs.push(proc);
    }
  });
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}

main().catch(console.error);
