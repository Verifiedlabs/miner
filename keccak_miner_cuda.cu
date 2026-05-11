#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <cuda_runtime.h>

typedef uint64_t u64;
typedef uint32_t u32;
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

__constant__ int ROTC[24] = {1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44};
__constant__ int PILN[24] = {10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1};

#define ROL64(x,n) (((x)<<(n))|((x)>>(64-(n))))

__device__ __forceinline__ u64 bswap64(u64 x) {
    x = ((x & 0x00FF00FF00FF00FFULL) << 8)  | ((x & 0xFF00FF00FF00FF00ULL) >> 8);
    x = ((x & 0x0000FFFF0000FFFFULL) << 16) | ((x & 0xFFFF0000FFFF0000ULL) >> 16);
    x = (x << 32) | (x >> 32);
    return x;
}

__device__ __forceinline__ void keccak_f(u64 *s) {
    #pragma unroll 1
    for (int r = 0; r < 24; r++) {
        u64 bc[5];
        #pragma unroll
        for (int i = 0; i < 5; i++)
            bc[i] = s[i] ^ s[i+5] ^ s[i+10] ^ s[i+15] ^ s[i+20];

        #pragma unroll
        for (int i = 0; i < 5; i++) {
            u64 d = bc[(i+4) % 5] ^ ROL64(bc[(i+1) % 5], 1);
            s[i]    ^= d; s[i+5]  ^= d; s[i+10] ^= d;
            s[i+15] ^= d; s[i+20] ^= d;
        }

        u64 t = s[1];
        #pragma unroll
        for (int i = 0; i < 24; i++) {
            int j = PILN[i];
            u64 tmp = s[j];
            s[j] = ROL64(t, ROTC[i]);
            t = tmp;
        }

        #pragma unroll
        for (int j = 0; j < 25; j += 5) {
            u64 a0 = s[j], a1 = s[j+1], a2 = s[j+2], a3 = s[j+3], a4 = s[j+4];
            s[j]   = a0 ^ (~a1 & a2);
            s[j+1] = a1 ^ (~a2 & a3);
            s[j+2] = a2 ^ (~a3 & a4);
            s[j+3] = a3 ^ (~a4 & a0);
            s[j+4] = a4 ^ (~a0 & a1);
        }

        s[0] ^= RC[r];
    }
}

struct Result {
    int found;
    u64 nonce;
};

__global__ void mine_kernel(
    u64 c0, u64 c1, u64 c2, u64 c3,
    u64 t0, u64 t1, u64 t2, u64 t3,
    u64 nonce_base,
    Result *result
) {
    u64 nonce = nonce_base + (u64)blockIdx.x * blockDim.x + threadIdx.x;

    u64 s[25];
    s[0] = c0;
    s[1] = c1;
    s[2] = c2;
    s[3] = c3;
    s[4] = 0;
    s[5] = 0;
    s[6] = 0;
    s[7] = bswap64(nonce);
    s[8] = 0x01ULL;
    #pragma unroll
    for (int i = 9; i < 16; i++) s[i] = 0;
    s[16] = 0x8000000000000000ULL;
    #pragma unroll
    for (int i = 17; i < 25; i++) s[i] = 0;

    keccak_f(s);

    u64 h0 = bswap64(s[0]);
    if (h0 < t0) {
        if (atomicCAS(&result->found, 0, 1) == 0) result->nonce = nonce;
        return;
    }
    if (h0 == t0) {
        u64 h1 = bswap64(s[1]);
        if (h1 < t1) {
            if (atomicCAS(&result->found, 0, 1) == 0) result->nonce = nonce;
            return;
        }
        if (h1 == t1) {
            u64 h2 = bswap64(s[2]);
            if (h2 < t2 || (h2 == t2 && bswap64(s[3]) < t3)) {
                if (atomicCAS(&result->found, 0, 1) == 0) result->nonce = nonce;
            }
        }
    }
}

static u8 hb(char c) { return c>='a'?c-'a'+10:c>='A'?c-'A'+10:c-'0'; }

static u64 load_u64_le(const u8 *b) {
    u64 v = 0;
    for (int i = 0; i < 8; i++) v |= ((u64)b[i]) << (i * 8);
    return v;
}

static u64 load_u64_be(const u8 *b) {
    u64 v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | b[i];
    return v;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <challenge_hex> <target_hex>\n", argv[0]);
        return 1;
    }

    const char *ch = argv[1] + (argv[1][0]=='0' && argv[1][1]=='x' ? 2 : 0);
    const char *tg = argv[2] + (argv[2][0]=='0' && argv[2][1]=='x' ? 2 : 0);

    u8 challenge[32], target[32];
    for (int i = 0; i < 32; i++) challenge[i] = (hb(ch[i*2])<<4)|hb(ch[i*2+1]);
    for (int i = 0; i < 32; i++) target[i]    = (hb(tg[i*2])<<4)|hb(tg[i*2+1]);

    u64 c0 = load_u64_le(challenge + 0);
    u64 c1 = load_u64_le(challenge + 8);
    u64 c2 = load_u64_le(challenge + 16);
    u64 c3 = load_u64_le(challenge + 24);

    u64 t0 = load_u64_be(target + 0);
    u64 t1 = load_u64_be(target + 8);
    u64 t2 = load_u64_be(target + 16);
    u64 t3 = load_u64_be(target + 24);

    Result *d_result;
    Result h_result = {0, 0};
    cudaMalloc(&d_result, sizeof(Result));

    const int THREADS = 256;
    const u64 BATCH   = 1ULL << 26;
    const int BLOCKS  = (int)(BATCH / THREADS);

    srand(time(NULL));
    u64 nonce_base = ((u64)rand() << 32) | (u32)rand();

    u64 total = 0;
    struct timespec t_now, t_last;
    clock_gettime(CLOCK_MONOTONIC, &t_last);

    while (1) {
        cudaMemcpy(d_result, &h_result, sizeof(Result), cudaMemcpyHostToDevice);
        mine_kernel<<<BLOCKS, THREADS>>>(c0, c1, c2, c3, t0, t1, t2, t3, nonce_base, d_result);
        cudaDeviceSynchronize();
        cudaMemcpy(&h_result, d_result, sizeof(Result), cudaMemcpyDeviceToHost);

        total += BATCH;
        nonce_base += BATCH;

        if (h_result.found) {
            u64 n = h_result.nonce;
            printf("FOUND:");
            for (int i = 0; i < 24; i++) printf("00");
            for (int i = 7; i >= 0; i--) printf("%02x", (u8)(n >> (i * 8)));
            printf("\n");
            fflush(stdout);
            break;
        }

        clock_gettime(CLOCK_MONOTONIC, &t_now);
        double elapsed = (t_now.tv_sec - t_last.tv_sec) + (t_now.tv_nsec - t_last.tv_nsec) / 1e9;
        if (elapsed >= 2.0) {
            double hps = (double)total / elapsed;
            fprintf(stderr, "PROGRESS:0:%llu\n", (unsigned long long)hps);
            fflush(stderr);
            t_last = t_now;
            total = 0;
        }
    }

    cudaFree(d_result);
    return 0;
}
