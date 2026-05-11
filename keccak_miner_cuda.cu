#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <cuda_runtime.h>

typedef uint64_t u64;
typedef uint8_t u8;

__constant__ u64 RC[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL,
    0x8000000080008000ULL, 0x000000000000808bULL, 0x0000000080000001ULL,
    0x8000000080008081ULL, 0x8000000000008009ULL, 0x000000000000008aULL,
    0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL,
    0x8000000000008003ULL, 0x8000000000008002ULL, 0x8000000000000080ULL,
    0x000000000000800aULL, 0x800000008000000aULL, 0x8000000080008081ULL,
    0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL
};

__constant__ int RHO[24] = {1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44};
__constant__ int PI[24]  = {10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1};

#define ROL64(x,n) (((x)<<(n))|((x)>>(64-(n))))

__device__ void keccak_f(u64 *s) {
    for (int r = 0; r < 24; r++) {
        u64 C[5], D[5], tmp;
        #pragma unroll
        for (int i = 0; i < 5; i++) C[i] = s[i]^s[i+5]^s[i+10]^s[i+15]^s[i+20];
        #pragma unroll
        for (int i = 0; i < 5; i++) {
            D[i] = C[(i+4)%5] ^ ROL64(C[(i+1)%5], 1);
            #pragma unroll
            for (int j = 0; j < 25; j += 5) s[i+j] ^= D[i];
        }
        tmp = s[1];
        #pragma unroll
        for (int i = 0; i < 24; i++) { int p=PI[i]; u64 t=s[p]; s[p]=ROL64(tmp,RHO[i]); tmp=t; }
        #pragma unroll
        for (int j = 0; j < 25; j += 5) {
            u64 t[5];
            #pragma unroll
            for (int i = 0; i < 5; i++) t[i] = s[j+i];
            #pragma unroll
            for (int i = 0; i < 5; i++) s[j+i] = t[i] ^ (~t[(i+1)%5] & t[(i+2)%5]);
        }
        s[0] ^= RC[r];
    }
}

__device__ void keccak256(const u8 *in, u8 *out) {
    u64 state[25] = {0};
    u8 block[136] = {0};
    #pragma unroll
    for (int i = 0; i < 64; i++) block[i] = in[i];
    block[64] = 0x01;
    block[135] |= 0x80;
    #pragma unroll
    for (int i = 0; i < 17; i++) {
        u64 v = 0;
        #pragma unroll
        for (int b = 0; b < 8; b++) v |= ((u64)block[i*8+b]) << (b*8);
        state[i] ^= v;
    }
    keccak_f(state);
    #pragma unroll
    for (int i = 0; i < 4; i++)
        #pragma unroll
        for (int b = 0; b < 8; b++)
            out[i*8+b] = (u8)((state[i] >> (b*8)) & 0xff);
}

__device__ int cmp_target(const u8 *hash, const u8 *target) {
    #pragma unroll
    for (int i = 0; i < 32; i++) {
        if (hash[i] < target[i]) return 1;
        if (hash[i] > target[i]) return 0;
    }
    return 0;
}

struct Result {
    int found;
    u64 nonce;
};

__global__ void mine_kernel(
    const u8 *challenge,
    const u8 *target,
    u64 nonce_base,
    Result *result,
    int iters
) {
    if (result->found) return;

    u64 tid = (u64)blockIdx.x * blockDim.x + threadIdx.x;

    for (int it = 0; it < iters; it++) {
        if (result->found) return;

        u64 nonce_val = nonce_base + tid + (u64)it * blockDim.x * gridDim.x;

        u8 input[64];
        #pragma unroll
        for (int i = 0; i < 32; i++) input[i] = challenge[i];

        #pragma unroll
        for (int i = 0; i < 8; i++)
            input[32+i] = (u8)((nonce_val >> (56 - i*8)) & 0xff);
        #pragma unroll
        for (int i = 8; i < 32; i++) input[32+i] = 0;

        u8 hash[32];
        keccak256(input, hash);

        if (cmp_target(hash, target)) {
            if (atomicCAS(&result->found, 0, 1) == 0) {
                result->nonce = nonce_val;
            }
            return;
        }
    }
}

static u8 hb(char c) { return c>='a'?c-'a'+10:c>='A'?c-'A'+10:c-'0'; }

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <challenge_hex> <target_hex>\n", argv[0]);
        return 1;
    }

    const char *challenge_hex = argv[1] + (argv[1][0]=='0' && argv[1][1]=='x' ? 2 : 0);
    const char *target_hex    = argv[2] + (argv[2][0]=='0' && argv[2][1]=='x' ? 2 : 0);

    u8 challenge[32], target[32];
    for (int i = 0; i < 32; i++) challenge[i] = (hb(challenge_hex[i*2])<<4)|hb(challenge_hex[i*2+1]);
    for (int i = 0; i < 32; i++) target[i]    = (hb(target_hex[i*2])<<4)|hb(target_hex[i*2+1]);

    u8 *d_challenge, *d_target;
    Result *d_result;
    Result h_result = {0, 0};

    cudaMalloc(&d_challenge, 32);
    cudaMalloc(&d_target, 32);
    cudaMalloc(&d_result, sizeof(Result));

    cudaMemcpy(d_challenge, challenge, 32, cudaMemcpyHostToDevice);
    cudaMemcpy(d_target, target, 32, cudaMemcpyHostToDevice);

    const int THREADS = 256;
    const int BLOCKS  = 16384;
    const int ITERS   = 16;
    const u64 BATCH   = (u64)THREADS * BLOCKS * ITERS;

    u64 nonce_base = (u64)rand() << 32 | rand();
    u64 total = 0;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    struct timespec last = t0;

    while (1) {
        cudaMemcpy(d_result, &h_result, sizeof(Result), cudaMemcpyHostToDevice);
        mine_kernel<<<BLOCKS, THREADS>>>(d_challenge, d_target, nonce_base, d_result, ITERS);
        cudaDeviceSynchronize();
        cudaMemcpy(&h_result, d_result, sizeof(Result), cudaMemcpyDeviceToHost);

        total += BATCH;
        nonce_base += BATCH;

        if (h_result.found) {
            printf("FOUND:%016llx%016llx\n", (unsigned long long)0, (unsigned long long)h_result.nonce);
            fflush(stdout);
            break;
        }

        clock_gettime(CLOCK_MONOTONIC, &t1);
        double elapsed = (t1.tv_sec - last.tv_sec) + (t1.tv_nsec - last.tv_nsec) / 1e9;
        if (elapsed >= 2.0) {
            double hps = (double)total / elapsed;
            fprintf(stderr, "PROGRESS:0:%llu\n", (unsigned long long)hps);
            fflush(stderr);
            last = t1;
            total = 0;
        }
    }

    cudaFree(d_challenge);
    cudaFree(d_target);
    cudaFree(d_result);
    return 0;
}
