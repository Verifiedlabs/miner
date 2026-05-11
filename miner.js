const { ethers } = require("ethers");
const { spawn } = require("child_process");
const path = require("path");
const fs = require("fs");
const ABI = require("./abi");

const CONTRACT = "0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc";

const CUDA_BINARY = path.join(__dirname, "keccak_miner_cuda");
const CPU_BINARY  = path.join(__dirname, "keccak_miner");
const USE_CUDA    = fs.existsSync(CUDA_BINARY);
const BINARY      = USE_CUDA ? CUDA_BINARY : CPU_BINARY;
const NUM_WORKERS = USE_CUDA ? 1 : parseInt(process.env.NUM_WORKERS || require("os").cpus().length);

async function main() {
  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) {
    console.error("Set PRIVATE_KEY env variable");
    process.exit(1);
  }

  const provider = process.env.RPC_URL
    ? new ethers.JsonRpcProvider(process.env.RPC_URL)
    : new ethers.FallbackProvider([
        { provider: new ethers.JsonRpcProvider("https://ethereum.publicnode.com"), priority: 1, weight: 1 },
        { provider: new ethers.JsonRpcProvider("https://1rpc.io/eth"), priority: 2, weight: 1 },
        { provider: new ethers.JsonRpcProvider("https://eth.drpc.org"), priority: 3, weight: 1 },
      ], 1);

  const wallet = new ethers.Wallet(privateKey, provider);
  const contract = new ethers.Contract(CONTRACT, ABI, wallet);

  console.log("Miner address:", wallet.address);
  console.log("Mode:", USE_CUDA ? "GPU (CUDA)" : "CPU");
  console.log("Workers:", NUM_WORKERS);

  await mineLoop(contract, wallet, provider);
}

async function mineLoop(contract, wallet, provider) {
  while (true) {
    try {
      const [challenge, state] = await Promise.all([
        contract.getChallenge(wallet.address),
        contract.miningState()
      ]);

      const target = state[2];
      const reward = state[1];
      const epoch = state[5];
      const targetHex = target.toString(16).padStart(64, "0");

      console.log(`\nEpoch: ${epoch} | Challenge: ${challenge}`);
      console.log(`Target: 0x${targetHex.slice(0, 16)}...`);
      console.log(`Reward: ${ethers.formatEther(reward)} HASH`);

      const nonce = await bruteForce(challenge, targetHex, epoch, contract);
      if (!nonce) {
        console.log(`\nEpoch changed, restarting...`);
        continue;
      }
      console.log(`\nFound nonce: ${nonce}`);

      const currentState = await contract.miningState();
      const currentEpoch = currentState[5];
      if (currentEpoch.toString() !== epoch.toString()) {
        console.log(`Epoch changed (${epoch} -> ${currentEpoch}), skipping submit...`);
        continue;
      }

      console.log("Submitting...");

      const maxGwei = BigInt(process.env.MAX_GWEI || "50");
      const maxFee = ethers.parseUnits(maxGwei.toString(), "gwei");

      while (true) {
        const feeData = await provider.getFeeData();
        if (feeData.maxFeePerGas && feeData.maxFeePerGas <= maxFee) break;
        const currentGwei = ethers.formatUnits(feeData.maxFeePerGas || 0n, "gwei");
        console.log(`\nGas too high: ${parseFloat(currentGwei).toFixed(2)} Gwei (max: ${maxGwei}). Waiting...`);
        await sleep(15000);
      }

      const feeData = await provider.getFeeData();
      const tipGwei = process.env.TIP_GWEI || "2";
      const priorityFee = ethers.parseUnits(tipGwei, "gwei");
      const tx = await contract.mine(BigInt("0x" + nonce), {
        gasLimit: 300000n,
        maxFeePerGas: feeData.maxFeePerGas,
        maxPriorityFeePerGas: priorityFee > (feeData.maxPriorityFeePerGas || 0n)
          ? priorityFee
          : feeData.maxPriorityFeePerGas,
      });
      console.log(`TX: ${tx.hash}`);
      const receipt = await tx.wait();
      console.log(`Confirmed in block ${receipt.blockNumber}`);

      const balance = await contract.balanceOf(wallet.address);
      console.log(`Balance: ${ethers.formatEther(balance)} HASH`);
    } catch (err) {
      console.error("Error:", err.shortMessage || err.message);
      if (err.info) console.error("RPC info:", JSON.stringify(err.info?.error || err.info, null, 2));
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
        const line = data.toString().trim();
        if (line.startsWith("PROGRESS:")) {
          const parts = line.split(":");
          workerStats[parseInt(parts[1])] = parseInt(parts[2]);
          const totalMHs = workerStats.reduce((a, b) => a + b, 0) / 1e6;
          const elapsedSec = (Date.now() - startTime) / 1000;
          const totalHashes = totalMHs * 1e6 * elapsedSec;
          const expectedHashes = 1 / probability;
          const remainingHashes = Math.max(0, expectedHashes - totalHashes);
          const etaSec = totalMHs > 0 ? remainingHashes / (totalMHs * 1e6) : 0;
          const etaMin = (etaSec / 60).toFixed(1);
          const totalHashesM = (totalMHs * elapsedSec).toFixed(1);
          process.stdout.write(
            `\rWorkers: ${NUM_WORKERS} | ${totalMHs.toFixed(2)} MH/s | ${totalHashesM}M hashes | diff: 0x${targetHex.slice(0, 8)}... | ETA: ~${etaMin}m`
          );
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
