#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

static long long now_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

typedef uint64_t u64;
typedef uint8_t u8;

static const u64 RC[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL,
    0x8000000080008000ULL, 0x000000000000808bULL, 0x0000000080000001ULL,
    0x8000000080008081ULL, 0x8000000000008009ULL, 0x000000000000008aULL,
    0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL,
    0x8000000000008003ULL, 0x8000000000008002ULL, 0x8000000000000080ULL,
    0x000000000000800aULL, 0x800000008000000aULL, 0x8000000080008081ULL,
    0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL
};

static const int RHO[24] = {
    1,  3,  6,  10, 15, 21, 28, 36, 45, 55, 2,  14,
    27, 41, 56, 8,  25, 43, 62, 18, 39, 61, 20, 44
};

static const int PI[24] = {
    10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4,
    15, 23, 19, 13, 12, 2, 20, 14, 22, 9,  6,  1
};

#define ROL64(x, n) (((x) << (n)) | ((x) >> (64 - (n))))

static void keccak_f(u64 *state) {
    for (int round = 0; round < 24; round++) {
        u64 C[5], D[5], tmp;

        for (int i = 0; i < 5; i++)
            C[i] = state[i] ^ state[i+5] ^ state[i+10] ^ state[i+15] ^ state[i+20];

        for (int i = 0; i < 5; i++) {
            D[i] = C[(i+4)%5] ^ ROL64(C[(i+1)%5], 1);
            for (int j = 0; j < 25; j += 5)
                state[i+j] ^= D[i];
        }

        tmp = state[1];
        for (int i = 0; i < 24; i++) {
            int pi = PI[i];
            u64 t = state[pi];
            state[pi] = ROL64(tmp, RHO[i]);
            tmp = t;
        }

        for (int j = 0; j < 25; j += 5) {
            u64 t[5];
            for (int i = 0; i < 5; i++) t[i] = state[j+i];
            for (int i = 0; i < 5; i++)
                state[j+i] = t[i] ^ (~t[(i+1)%5] & t[(i+2)%5]);
        }

        state[0] ^= RC[round];
    }
}

static void keccak256(const u8 *input, size_t len, u8 *output) {
    u64 state[25] = {0};
    u8 block[136] = {0};
    size_t rate = 136;

    memcpy(block, input, len);
    block[len] = 0x01;
    block[rate - 1] |= 0x80;

    for (int i = 0; i < (int)(rate / 8); i++)
        state[i] ^= ((u64*)block)[i];

    keccak_f(state);

    memcpy(output, state, 32);
}

static int cmp_target(const u8 *hash, const u8 *target) {
    for (int i = 0; i < 32; i++) {
        if (hash[i] < target[i]) return 1;
        if (hash[i] > target[i]) return 0;
    }
    return 0;
}

static void increment_nonce(u8 *nonce) {
    for (int i = 31; i >= 0; i--) {
        if (++nonce[i] != 0) break;
    }
}

static u8 hex_byte(const char *s) {
    u8 hi = s[0] >= 'a' ? s[0]-'a'+10 : s[0]-'0';
    u8 lo = s[1] >= 'a' ? s[1]-'a'+10 : s[1]-'0';
    return (hi << 4) | lo;
}

int main(int argc, char *argv[]) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <challenge_hex> <target_hex> <worker_id>\n", argv[0]);
        return 1;
    }

    const char *challenge_hex = argv[1] + (argv[1][0]=='0' && argv[1][1]=='x' ? 2 : 0);
    const char *target_hex    = argv[2] + (argv[2][0]=='0' && argv[2][1]=='x' ? 2 : 0);
    int worker_id = atoi(argv[3]);

    u8 challenge[32], target[32], nonce[32], input[64], hash[32];

    for (int i = 0; i < 32; i++) challenge[i] = hex_byte(challenge_hex + i*2);
    for (int i = 0; i < 32; i++) target[i]    = hex_byte(target_hex    + i*2);

    memcpy(input, challenge, 32);

    srand((unsigned)now_ms() ^ (worker_id * 0xdeadbeef));
    for (int i = 0; i < 32; i++) nonce[i] = rand() & 0xff;
    memcpy(input + 32, nonce, 32);

    u64 hashes = 0;
    long long last_report = now_ms();

    while (1) {
        for (int batch = 0; batch < 10000; batch++) {
            increment_nonce(nonce);
            memcpy(input + 32, nonce, 32);
            keccak256(input, 64, hash);
            hashes++;

            if (cmp_target(hash, target)) {
                printf("FOUND:");
                for (int i = 0; i < 32; i++) printf("%02x", nonce[i]);
                printf("\n");
                fflush(stdout);
                return 0;
            }
        }

        long long now = now_ms();
        if (now - last_report >= 2000) {
            long long elapsed = now - last_report;
            fprintf(stderr, "PROGRESS:%d:%llu\n", worker_id, (unsigned long long)(hashes * 1000 / elapsed));
            fflush(stderr);
            last_report = now;
            hashes = 0;
        }
    }

    return 0;
}
