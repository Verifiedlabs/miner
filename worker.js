const { workerData, parentPort } = require("worker_threads");
const { randomFillSync } = require("crypto");
const keccak = require("keccak");

const { challenge, target, workerId } = workerData;

const challengeBytes = Buffer.from(challenge.slice(2), "hex");
const targetBuf = Buffer.from(BigInt(target).toString(16).padStart(64, "0"), "hex");

const input = Buffer.allocUnsafe(64);
challengeBytes.copy(input, 0);
const nonceBuf = input.subarray(32);
randomFillSync(nonceBuf);

let hashes = 0;
const start = Date.now();
let lastReport = start;

function bufLessThan(a, b) {
  for (let i = 0; i < 32; i++) {
    if (a[i] < b[i]) return true;
    if (a[i] > b[i]) return false;
  }
  return false;
}

function incrementNonce() {
  for (let i = 31; i >= 0; i--) {
    if (++nonceBuf[i] !== 0) break;
  }
}

while (true) {
  incrementNonce();

  const hash = keccak("keccak256").update(input).digest();

  hashes++;

  if (bufLessThan(hash, targetBuf)) {
    const nonceBig = BigInt("0x" + nonceBuf.toString("hex"));
    parentPort.postMessage({
      type: "found",
      nonce: nonceBig.toString(),
      hash: "0x" + hash.toString("hex"),
      hashes,
      workerId
    });
    break;
  }

  const now = Date.now();
  if (now - lastReport >= 2000) {
    const elapsed = (now - start) / 1000;
    parentPort.postMessage({
      type: "progress",
      hashes,
      hashrate: Math.floor(hashes / elapsed),
      workerId
    });
    lastReport = now;
  }
}
