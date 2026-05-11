import Foundation
import Metal

let MSL_SOURCE = """
#include <metal_stdlib>
using namespace metal;

constant ulong RC[24] = {
    0x0000000000000001UL, 0x0000000000008082UL, 0x800000000000808aUL,
    0x8000000080008000UL, 0x000000000000808bUL, 0x0000000080000001UL,
    0x8000000080008081UL, 0x8000000000008009UL, 0x000000000000008aUL,
    0x0000000000000088UL, 0x0000000080008009UL, 0x000000008000000aUL,
    0x000000008000808bUL, 0x800000000000008bUL, 0x8000000000008089UL,
    0x8000000000008003UL, 0x8000000000008002UL, 0x8000000000000080UL,
    0x000000000000800aUL, 0x800000008000000aUL, 0x8000000080008081UL,
    0x8000000000008080UL, 0x0000000080000001UL, 0x8000000080008008UL
};
constant int ROTC[24] = {1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44};
constant int PILN[24] = {10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1};

inline ulong rol64(ulong x, uint n) { return (x << n) | (x >> (64 - n)); }

inline ulong bswap64(ulong x) {
    x = ((x & 0x00FF00FF00FF00FFUL) << 8)  | ((x & 0xFF00FF00FF00FF00UL) >> 8);
    x = ((x & 0x0000FFFF0000FFFFUL) << 16) | ((x & 0xFFFF0000FFFF0000UL) >> 16);
    x = (x << 32) | (x >> 32);
    return x;
}

struct Uniforms {
    ulong4 challenge;
    ulong4 target;
    ulong  nonce_base;
    uint   iters;
    uint   _pad;
};

struct Result {
    atomic_uint found;
    ulong       nonce;
};

kernel void mine(
    constant Uniforms &u [[buffer(0)]],
    device Result *r     [[buffer(1)]],
    uint gid             [[thread_position_in_grid]],
    uint gsize           [[threads_per_grid]]
) {
    for (uint it = 0; it < u.iters; it++) {
        ulong nonce = u.nonce_base + (ulong)gid + (ulong)it * (ulong)gsize;

        ulong s[25];
        s[0] = u.challenge.x;
        s[1] = u.challenge.y;
        s[2] = u.challenge.z;
        s[3] = u.challenge.w;
        s[4] = 0;
        s[5] = 0;
        s[6] = 0;
        s[7] = bswap64(nonce);
        s[8] = 0x01UL;
        for (int i = 9; i < 16; i++) s[i] = 0;
        s[16] = 0x8000000000000000UL;
        for (int i = 17; i < 25; i++) s[i] = 0;

        for (int rnd = 0; rnd < 24; rnd++) {
            ulong bc[5];
            for (int i = 0; i < 5; i++)
                bc[i] = s[i] ^ s[i+5] ^ s[i+10] ^ s[i+15] ^ s[i+20];
            for (int i = 0; i < 5; i++) {
                ulong d = bc[(i+4) % 5] ^ rol64(bc[(i+1) % 5], 1);
                s[i] ^= d; s[i+5] ^= d; s[i+10] ^= d; s[i+15] ^= d; s[i+20] ^= d;
            }
            ulong t = s[1];
            for (int i = 0; i < 24; i++) {
                int j = PILN[i];
                ulong tmp = s[j];
                s[j] = rol64(t, (uint)ROTC[i]);
                t = tmp;
            }
            for (int j = 0; j < 25; j += 5) {
                ulong a0=s[j],a1=s[j+1],a2=s[j+2],a3=s[j+3],a4=s[j+4];
                s[j]=a0^(~a1&a2); s[j+1]=a1^(~a2&a3); s[j+2]=a2^(~a3&a4);
                s[j+3]=a3^(~a4&a0); s[j+4]=a4^(~a0&a1);
            }
            s[0] ^= RC[rnd];
        }

        ulong h0 = bswap64(s[0]);
        bool hit = false;
        if (h0 < u.target.x) hit = true;
        else if (h0 == u.target.x) {
            ulong h1 = bswap64(s[1]);
            if (h1 < u.target.y) hit = true;
            else if (h1 == u.target.y) {
                ulong h2 = bswap64(s[2]);
                if (h2 < u.target.z) hit = true;
                else if (h2 == u.target.z && bswap64(s[3]) < u.target.w) hit = true;
            }
        }

        if (hit) {
            if (atomic_exchange_explicit(&r->found, 1u, memory_order_relaxed) == 0) {
                r->nonce = nonce;
            }
            return;
        }
    }
}
"""

func hexToBytes(_ s: String) -> [UInt8] {
    let h = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
    var out = [UInt8]()
    var i = h.startIndex
    while i < h.endIndex {
        let j = h.index(i, offsetBy: 2)
        out.append(UInt8(h[i..<j], radix: 16)!)
        i = j
    }
    return out
}

func loadU64LE(_ b: [UInt8], _ off: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(b[off+i]) << (i * 8) }
    return v
}

func loadU64BE(_ b: [UInt8], _ off: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v = (v << 8) | UInt64(b[off+i]) }
    return v
}

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write("usage: metal_miner <challenge_hex> <target_hex>\n".data(using: .utf8)!)
    exit(1)
}

let ch = hexToBytes(CommandLine.arguments[1])
let tg = hexToBytes(CommandLine.arguments[2])

guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write("Metal not available\n".data(using: .utf8)!)
    exit(1)
}

FileHandle.standardError.write("GPU: \(device.name)\n".data(using: .utf8)!)

let library: MTLLibrary
do {
    library = try device.makeLibrary(source: MSL_SOURCE, options: nil)
} catch {
    FileHandle.standardError.write("Shader compile error: \(error)\n".data(using: .utf8)!)
    exit(1)
}

guard let fn = library.makeFunction(name: "mine") else { exit(1) }
let pipeline = try! device.makeComputePipelineState(function: fn)
let queue = device.makeCommandQueue()!

struct Uniforms {
    var c0: UInt64 = 0, c1: UInt64 = 0, c2: UInt64 = 0, c3: UInt64 = 0
    var t0: UInt64 = 0, t1: UInt64 = 0, t2: UInt64 = 0, t3: UInt64 = 0
    var nonce_base: UInt64 = 0
    var iters: UInt32 = 0
    var _pad: UInt32 = 0
}

struct Result {
    var found: UInt32 = 0
    var nonce: UInt64 = 0
}

var u = Uniforms()
u.c0 = loadU64LE(ch, 0); u.c1 = loadU64LE(ch, 8); u.c2 = loadU64LE(ch, 16); u.c3 = loadU64LE(ch, 24)
u.t0 = loadU64BE(tg, 0); u.t1 = loadU64BE(tg, 8); u.t2 = loadU64BE(tg, 16); u.t3 = loadU64BE(tg, 24)
u.iters = 32

let THREADS = 1 << 20
let BATCH = UInt64(THREADS) * UInt64(u.iters)

let uBuf = device.makeBuffer(length: MemoryLayout<Uniforms>.size, options: .storageModeShared)!
let rBuf = device.makeBuffer(length: MemoryLayout<Result>.size, options: .storageModeShared)!

u.nonce_base = UInt64.random(in: 0..<UInt64.max)

var totalHashes: UInt64 = 0
var lastReport = Date()

while true {
    var zero = Result(found: 0, nonce: 0)
    withUnsafePointer(to: &zero) {
        rBuf.contents().copyMemory(from: $0, byteCount: MemoryLayout<Result>.size)
    }
    withUnsafePointer(to: &u) {
        uBuf.contents().copyMemory(from: $0, byteCount: MemoryLayout<Uniforms>.size)
    }

    let cmd = queue.makeCommandBuffer()!
    let enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pipeline)
    enc.setBuffer(uBuf, offset: 0, index: 0)
    enc.setBuffer(rBuf, offset: 0, index: 1)
    let gridSize = MTLSize(width: THREADS, height: 1, depth: 1)
    let tgSize = MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)
    enc.dispatchThreads(gridSize, threadsPerThreadgroup: tgSize)
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    let r = rBuf.contents().load(as: Result.self)
    totalHashes += BATCH
    u.nonce_base &+= BATCH

    if r.found != 0 {
        let nonce = r.nonce
        var out = "FOUND:"
        for _ in 0..<24 { out += "00" }
        for i in stride(from: 7, through: 0, by: -1) {
            out += String(format: "%02x", UInt8((nonce >> (i * 8)) & 0xFF))
        }
        print(out)
        break
    }

    let now = Date()
    let elapsed = now.timeIntervalSince(lastReport)
    if elapsed >= 2.0 {
        let hps = Double(totalHashes) / elapsed
        FileHandle.standardError.write("PROGRESS:0:\(Int(hps))\n".data(using: .utf8)!)
        lastReport = now
        totalHashes = 0
    }
}
