// Runtime library for Mantiq/Nizam compiled programs.
//
// Provides the ABI contract that generated LLVM IR calls into:
//   - Memory management: mantiq_malloc / mantiq_free / mantiq_realloc
//     (backed by mimalloc or libc malloc)
//   - Parallel execution: __mantiq_parallel_for (trampoline dispatch)
//   - Quantum simulation: 16-qubit state-vector simulator (Complex[NUM_STATES],
//     H/CNOT/measure operators, mantiq_quantum_init / mantiq_run_qasm)
//   - String operations: mantiq_string_compare, mantiq_string_concat
//   - IO: mantiq_print_{i32,f64,cstr,string}, mantiq_read_input,
//     mantiq_process_args (/proc/self/cmdline parsing)
//   - Concurrency: mantiq_spawn / mantiq_await (pthread-based actor model)
//   - Collections: MantiqDict (open-addressing hash table),
//     MantiqList (dynamic array with element-byte-size)
//   - Misc: mantiq_get_time, mantiq_random_f64, mantiq_fs_close,
//     mantiq_sleep, mantiq_abort

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif
#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
    #include <windows.h>
    #include <process.h>
#elif defined(__wasi__)
    #include <unistd.h>
    #include <fcntl.h>
    #include <sys/stat.h>
    #include <sys/types.h>
#else
    #include <pthread.h>
    #include <unistd.h>
    #include <fcntl.h>
    #include <sys/stat.h>
    #include <sys/types.h>
    #include <sys/ioctl.h>
    #include <time.h>
    #include <sys/resource.h>
    #include <sys/wait.h>
#endif

#define sys_malloc malloc
#define sys_free free
#define sys_realloc realloc
#define ALLOCATOR_NAME "libc-malloc"

// ── Target Configuration ──────────────────────────────────────────────
static int g_nizam_target_pointer_size = 8;

void nizam_set_target_ptr_size(int sz) {
    g_nizam_target_pointer_size = sz;
}

int nizam_get_target_ptr_size(void) {
    return g_nizam_target_pointer_size;
}

// Simulated thread pool / parallel loop execution
void __mantiq_parallel_for(int start, int end, void (*closure)(void*, int), void* env) {
    printf("[Runtime] Dispatching parallel loop from %d to %d to thread pool...\n", start, end);
    for (int i = start; i < end; i++) {
        // In a real implementation, this would be pushed to a thread queue
        closure(env, i);
    }
    printf("[Runtime] Parallel loop completed.\n");
}

#include <math.h>
#include <string.h>
#include <limits.h>

#define MAX_QUBITS 16
#define NUM_STATES (1 << MAX_QUBITS)

typedef struct {
    double real;
    double imag;
} Complex;

static Complex global_state[NUM_STATES];
static int active_qubits = 0;

typedef struct {
    void* ptr;
    int num_qubits;
} QReg;

QReg quantum_qreg(int num) {
    if (active_qubits + num > MAX_QUBITS) {
        printf("[Runtime] Quantum Error: Maximum of 16 qubits exceeded.\n");
        exit(1);
    }
    // Initialize to |0...0>
    if (active_qubits == 0) {
        memset(global_state, 0, sizeof(global_state));
        global_state[0].real = 1.0;
        global_state[0].imag = 0.0;
    }
    QReg reg;
    reg.ptr = NULL; // Dummy ptr
    reg.num_qubits = num;
    active_qubits += num;
    printf("[Runtime] Allocated quantum register with %d qubits (total %d/16).\n", num, active_qubits);
    return reg;
}

int quantum_H(int target) {
    if (target >= active_qubits) return target;
    double inv_sqrt2 = 1.0 / sqrt(2.0);
    for (int i = 0; i < NUM_STATES; i++) {
        if ((i & (1 << target)) == 0) {
            int j = i | (1 << target);
            Complex a = global_state[i];
            Complex b = global_state[j];
            global_state[i].real = (a.real + b.real) * inv_sqrt2;
            global_state[i].imag = (a.imag + b.imag) * inv_sqrt2;
            global_state[j].real = (a.real - b.real) * inv_sqrt2;
            global_state[j].imag = (a.imag - b.imag) * inv_sqrt2;
        }
    }
    printf("[Runtime] Applied Hadamard gate on qubit %d.\n", target);
    return target;
}

void quantum_CNOT(int control, int target) {
    if (control >= active_qubits || target >= active_qubits) return;
    for (int i = 0; i < NUM_STATES; i++) {
        if ((i & (1 << control)) != 0 && (i & (1 << target)) == 0) {
            int j = i | (1 << target);
            Complex temp = global_state[i];
            global_state[i] = global_state[j];
            global_state[j] = temp;
        }
    }
    printf("[Runtime] Applied CNOT gate (control: %d, target: %d).\n", control, target);
}

void quantum_measure(int target) {
    if (target >= active_qubits) return;
    double prob_1 = 0.0;
    for (int i = 0; i < NUM_STATES; i++) {
        if (i & (1 << target)) {
            prob_1 += global_state[i].real * global_state[i].real + global_state[i].imag * global_state[i].imag;
        }
    }
    // Simplistic collapse simulation based on probability
    static int seeded = 0;
    if (!seeded) { srand((unsigned)time(NULL)); seeded = 1; }
    double r = (double)rand() / (double)RAND_MAX;
    int result = (r < prob_1) ? 1 : 0;
    printf("[Runtime] Quantum state measured on qubit %d: Result = %d (Prob |1> = %.2f).\n", target, result, prob_1);
    
    // Normalize state
    double norm = 1.0 / sqrt(result == 1 ? prob_1 : (1.0 - prob_1));
    for (int i = 0; i < NUM_STATES; i++) {
        int bit = (i & (1 << target)) ? 1 : 0;
        if (bit == result) {
            global_state[i].real *= norm;
            global_state[i].imag *= norm;
        } else {
            global_state[i].real = 0.0;
            global_state[i].imag = 0.0;
        }
    }
}

// Allocation tracking counters
static long long _alloc_count = 0;
static long long _alloc_bytes = 0;
static long long _free_count = 0;
static int _mantiq_profile_active = 0;

void mantiq_set_profile_active(int active) {
    _mantiq_profile_active = active;
}

int mantiq_is_profile_active(void) {
    return _mantiq_profile_active;
}

long long mantiq_alloc_count(void) { return _alloc_count; }
long long mantiq_alloc_bytes(void) { return _alloc_bytes; }
long long mantiq_free_count(void) { return _free_count; }

// Memory Management for Closures and Objects
void* mantiq_malloc(int64_t size) {
    if (size < 0 || size > 500000000LL) {
        fprintf(stderr, "[Runtime] Invalid malloc size: %lld\n", (long long)size);
        abort();
    }
    void* ptr = calloc(1, (size_t)(size ? size : 1));
    if (!ptr) {
        fprintf(stderr, "[Runtime] Fatal: memory allocation of %lld bytes failed\n", (long long)size);
        abort();
    }
    if (__builtin_expect(_mantiq_profile_active, 0)) {
        _alloc_count++;
        _alloc_bytes += (long long)(size ? size : 1);
    }
    return ptr;
}

void* mantiq_malloc_raw(int64_t size) {
    if (size < 0 || size > 500000000LL) {
        fprintf(stderr, "[Runtime] Invalid malloc size: %lld\n", (long long)size);
        abort();
    }
    void* ptr = sys_malloc((size_t)(size ? size : 1));
    if (!ptr) {
        fprintf(stderr, "[Runtime] Fatal: memory allocation of %lld bytes failed\n", (long long)size);
        abort();
    }
    if (__builtin_expect(_mantiq_profile_active, 0)) {
        _alloc_count++;
        _alloc_bytes += (long long)(size ? size : 1);
    }
    return ptr;
}

// ── 32-Byte Slab Bump Allocator ───────────────────────────────────────
#define MANTIQ_BOX32_SLAB_SIZE 65536
static uint8_t* _mantiq_box32_slab = NULL;
static size_t _mantiq_box32_offset = MANTIQ_BOX32_SLAB_SIZE;

void* mantiq_alloc_box32(void) {
    if (_mantiq_box32_offset + 32 > MANTIQ_BOX32_SLAB_SIZE) {
        _mantiq_box32_slab = (uint8_t*)sys_malloc(MANTIQ_BOX32_SLAB_SIZE);
        if (!_mantiq_box32_slab) {
            fprintf(stderr, "[Runtime] Fatal: 32-byte slab allocation failed\n");
            abort();
        }
        _mantiq_box32_offset = 0;
    }
    void* ptr = _mantiq_box32_slab + _mantiq_box32_offset;
    _mantiq_box32_offset += 32;
    if (__builtin_expect(_mantiq_profile_active, 0)) {
        _alloc_count++;
        _alloc_bytes += 32;
    }
    return ptr;
}

int64_t mantiq_get_alloc_count(void) {
    return (int64_t)_alloc_count;
}

int64_t mantiq_get_alloc_bytes(void) {
    return (int64_t)_alloc_bytes;
}

int mantiq_is_arena_ptr(void* ptr);

void mantiq_free(void* ptr) {
    if (!ptr) return;
    if (mantiq_is_arena_ptr(ptr)) return;
    if (__builtin_expect(_mantiq_profile_active, 0)) {
        _free_count++;
    }
    sys_free(ptr);
}


void* mantiq_realloc(void* ptr, int64_t new_size) {
    if (new_size < 0 || new_size > 500000000LL) {
        fprintf(stderr, "[Runtime] Invalid realloc size: %lld\n", (long long)new_size);
        abort();
    }
    void* new_ptr = sys_realloc(ptr, (size_t)new_size);
    if (!new_ptr && new_size > 0) {
        fprintf(stderr, "[Runtime] Fatal: memory reallocation of %lld bytes failed\n", (long long)new_size);
        abort();
    }
    return new_ptr;
}

int64_t mantiq_strlen(const char* s) {
    if (!s) return 0;
    return (int64_t)strlen(s);
}

// ── Chunked Arena Allocator ──────────────────────────────────────────
typedef struct MantiqArenaChunk {
    struct MantiqArenaChunk* next;
    size_t capacity;
    size_t used;
    char data[];
} MantiqArenaChunk;

typedef struct MantiqArena {
    MantiqArenaChunk* first;
    MantiqArenaChunk* current;
    size_t default_chunk_size;
} MantiqArena;

MantiqArena* mantiq_arena_create(size_t chunk_size) {
    if (chunk_size < 4096) chunk_size = 65536;
    MantiqArena* a = (MantiqArena*)mantiq_malloc(sizeof(MantiqArena));
    a->default_chunk_size = chunk_size;
    MantiqArenaChunk* initial = (MantiqArenaChunk*)malloc(sizeof(MantiqArenaChunk) + chunk_size);
    if (!initial) {
        fprintf(stderr, "[Runtime] Fatal: out of memory in mantiq_arena_create\n");
        abort();
    }
    initial->next = NULL;
    initial->capacity = chunk_size;
    initial->used = 0;
    a->first = initial;
    a->current = initial;
    return a;
}

void* mantiq_arena_alloc(MantiqArena* a, size_t size) {
    if (!a) return mantiq_malloc(size);
    size_t aligned_size = (size + 7) & ~((size_t)7);
    if (__builtin_expect(_mantiq_profile_active, 0)) {
        _alloc_count++;
        _alloc_bytes += aligned_size;
    }
    MantiqArenaChunk* c = a->current;
    if (c && c->used + aligned_size <= c->capacity) {
        void* ptr = c->data + c->used;
        c->used += aligned_size;
        return ptr;
    }
    if (c && c->next && c->next->capacity >= aligned_size) {
        a->current = c->next;
        c = a->current;
        c->used = aligned_size;
        return c->data;
    }
    size_t new_cap = a->default_chunk_size;
    if (aligned_size > new_cap) new_cap = aligned_size + 4096;
    MantiqArenaChunk* new_c = (MantiqArenaChunk*)malloc(sizeof(MantiqArenaChunk) + new_cap);
    if (!new_c) {
        fprintf(stderr, "[Runtime] Fatal: out of memory in mantiq_arena_alloc\n");
        abort();
    }
    new_c->next = NULL;
    new_c->capacity = new_cap;
    new_c->used = aligned_size;
    if (c) {
        c->next = new_c;
    } else {
        a->first = new_c;
    }
    a->current = new_c;
    return new_c->data;
}

void mantiq_arena_reset(MantiqArena* a) {
    if (!a) return;
    MantiqArenaChunk* c = a->first;
    while (c) {
        c->used = 0;
        c = c->next;
    }
    a->current = a->first;
}

void mantiq_arena_destroy(MantiqArena* a) {
    if (!a) return;
    MantiqArenaChunk* c = a->first;
    while (c) {
        MantiqArenaChunk* next = c->next;
        free(c);
        c = next;
    }
    mantiq_free(a);
}

// ── AST & Symbol Bump Arena ───────────────────────────────────────────
static MantiqArena* g_ast_arena = NULL;

void* mantiq_ast_alloc(size_t size) {
    if (!g_ast_arena) {
        g_ast_arena = mantiq_arena_create(262144); // 256 KB chunk size
    }
    void* ptr = mantiq_arena_alloc(g_ast_arena, size);
    if (ptr) {
        memset(ptr, 0, size);
    }
    return ptr;
}

void mantiq_ast_arena_reset(void) {
    if (g_ast_arena) {
        mantiq_arena_reset(g_ast_arena);
    }
}

void mantiq_ast_arena_destroy(void) {
    if (g_ast_arena) {
        mantiq_arena_destroy(g_ast_arena);
        g_ast_arena = NULL;
    }
}

// ── Global String & Identifier Interning Engine ───────────────────────
#define MANTIQ_INTERN_BUCKETS 16384
#define MANTIQ_INTERN_MASK (MANTIQ_INTERN_BUCKETS - 1)

typedef struct MantiqInternEntry {
    struct MantiqInternEntry* next;
    uint32_t hash;
    size_t len;
    char str[];
} MantiqInternEntry;

static MantiqArena* g_intern_arena = NULL;
static MantiqInternEntry* g_intern_table[MANTIQ_INTERN_BUCKETS];
static const char g_mantiq_empty_str[1] = {0};

uint32_t __mantiq_hash_bytes(const uint8_t* data, int64_t len);

const char* mantiq_intern_string(const char* s, size_t len) {
    if (!s || len == 0) return g_mantiq_empty_str;
    if (!g_intern_arena) {
        g_intern_arena = mantiq_arena_create(65536); // 64 KB chunk size
    }
    uint32_t hash = __mantiq_hash_bytes((const uint8_t*)s, (int64_t)len);
    uint32_t bucket = hash & MANTIQ_INTERN_MASK;

    MantiqInternEntry* entry = g_intern_table[bucket];
    while (entry) {
        if (entry->hash == hash && entry->len == len && memcmp(entry->str, s, len) == 0) {
            return entry->str;
        }
        entry = entry->next;
    }

    size_t entry_size = sizeof(MantiqInternEntry) + len + 1;
    MantiqInternEntry* new_entry = (MantiqInternEntry*)mantiq_arena_alloc(g_intern_arena, entry_size);
    if (!new_entry) {
        fprintf(stderr, "[Runtime] Fatal: out of memory in mantiq_intern_string\n");
        abort();
    }
    new_entry->hash = hash;
    new_entry->len = len;
    memcpy(new_entry->str, s, len);
    new_entry->str[len] = '\0';
    new_entry->next = g_intern_table[bucket];
    g_intern_table[bucket] = new_entry;

    return new_entry->str;
}

void mantiq_intern_reset(void) {
    if (g_intern_arena) {
        mantiq_arena_reset(g_intern_arena);
    }
    memset(g_intern_table, 0, sizeof(g_intern_table));
}

void mantiq_intern_destroy(void) {
    if (g_intern_arena) {
        mantiq_arena_destroy(g_intern_arena);
        g_intern_arena = NULL;
    }
    memset(g_intern_table, 0, sizeof(g_intern_table));
}

int mantiq_is_arena_ptr(void* ptr) {
    if (!ptr) return 0;
    if (g_ast_arena) {
        MantiqArenaChunk* c = g_ast_arena->first;
        while (c) {
            if ((char*)ptr >= c->data && (char*)ptr < c->data + c->capacity) return 1;
            c = c->next;
        }
    }
    if (g_intern_arena) {
        MantiqArenaChunk* c = g_intern_arena->first;
        while (c) {
            if ((char*)ptr >= c->data && (char*)ptr < c->data + c->capacity) return 1;
            c = c->next;
        }
    }
    return 0;
}


// ── Standalone SHA-256 Engine ─────────────────────────────────────────
typedef struct {
    uint32_t state[8];
    uint64_t count;
    uint8_t buffer[64];
} MantiqSha256;

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

#define MANTIQ_ROR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define MANTIQ_CH(x, y, z) (((x) & (y)) ^ (~(x) & (z)))
#define MANTIQ_MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define MANTIQ_EP0(x) (MANTIQ_ROR32(x, 2) ^ MANTIQ_ROR32(x, 13) ^ MANTIQ_ROR32(x, 22))
#define MANTIQ_EP1(x) (MANTIQ_ROR32(x, 6) ^ MANTIQ_ROR32(x, 11) ^ MANTIQ_ROR32(x, 25))
#define MANTIQ_SIG0(x) (MANTIQ_ROR32(x, 7) ^ MANTIQ_ROR32(x, 18) ^ ((x) >> 3))
#define MANTIQ_SIG1(x) (MANTIQ_ROR32(x, 17) ^ MANTIQ_ROR32(x, 19) ^ ((x) >> 10))

static void mantiq_sha256_transform(MantiqSha256* ctx, const uint8_t data[64]) {
    uint32_t a = ctx->state[0], b = ctx->state[1], c = ctx->state[2], d = ctx->state[3];
    uint32_t e = ctx->state[4], f = ctx->state[5], g = ctx->state[6], h = ctx->state[7];
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)data[i * 4] << 24) |
               ((uint32_t)data[i * 4 + 1] << 16) |
               ((uint32_t)data[i * 4 + 2] << 8) |
               ((uint32_t)data[i * 4 + 3]);
    }
    for (int i = 16; i < 64; i++) {
        w[i] = MANTIQ_SIG1(w[i - 2]) + w[i - 7] + MANTIQ_SIG0(w[i - 15]) + w[i - 16];
    }
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + MANTIQ_EP1(e) + MANTIQ_CH(e, f, g) + K256[i] + w[i];
        uint32_t t2 = MANTIQ_EP0(a) + MANTIQ_MAJ(a, b, c);
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }
    ctx->state[0] += a;
    ctx->state[1] += b;
    ctx->state[2] += c;
    ctx->state[3] += d;
    ctx->state[4] += e;
    ctx->state[5] += f;
    ctx->state[6] += g;
    ctx->state[7] += h;
}

static void mantiq_sha256_init(MantiqSha256* ctx) {
    ctx->state[0] = 0x6a09e667;
    ctx->state[1] = 0xbb67ae85;
    ctx->state[2] = 0x3c6ef372;
    ctx->state[3] = 0xa54ff53a;
    ctx->state[4] = 0x510e527f;
    ctx->state[5] = 0x9b05688c;
    ctx->state[6] = 0x1f83d9ab;
    ctx->state[7] = 0x5be0cd19;
    ctx->count = 0;
}

static void mantiq_sha256_update(MantiqSha256* ctx, const uint8_t* data, size_t len) {
    size_t buffer_used = (size_t)(ctx->count & 63);
    ctx->count += len;
    if (buffer_used > 0) {
        size_t to_fill = 64 - buffer_used;
        if (len < to_fill) {
            memcpy(ctx->buffer + buffer_used, data, len);
            return;
        }
        memcpy(ctx->buffer + buffer_used, data, to_fill);
        mantiq_sha256_transform(ctx, ctx->buffer);
        data += to_fill;
        len -= to_fill;
    }
    while (len >= 64) {
        mantiq_sha256_transform(ctx, data);
        data += 64;
        len -= 64;
    }
    if (len > 0) {
        memcpy(ctx->buffer, data, len);
    }
}

static void mantiq_sha256_final(MantiqSha256* ctx, uint8_t digest[32]) {
    uint8_t pad[64];
    pad[0] = 0x80;
    size_t buffer_used = (size_t)(ctx->count & 63);
    size_t pad_len = (buffer_used < 56) ? (56 - buffer_used) : (120 - buffer_used);
    memset(pad + 1, 0, pad_len - 1);
    uint64_t total_bits = ctx->count * 8;
    uint8_t len_bytes[8];
    for (int i = 0; i < 8; i++) {
        len_bytes[i] = (uint8_t)(total_bits >> (56 - i * 8));
    }
    mantiq_sha256_update(ctx, pad, pad_len);
    mantiq_sha256_update(ctx, len_bytes, 8);
    for (int i = 0; i < 8; i++) {
        digest[i * 4] = (uint8_t)(ctx->state[i] >> 24);
        digest[i * 4 + 1] = (uint8_t)(ctx->state[i] >> 16);
        digest[i * 4 + 2] = (uint8_t)(ctx->state[i] >> 8);
        digest[i * 4 + 3] = (uint8_t)(ctx->state[i]);
    }
}

void mantiq_sha256_hex(const char* data, size_t len, char* out_hex_64) {
    if (!out_hex_64) return;
    MantiqSha256 ctx;
    mantiq_sha256_init(&ctx);
    if (data && len > 0) {
        mantiq_sha256_update(&ctx, (const uint8_t*)data, len);
    }
    uint8_t digest[32];
    mantiq_sha256_final(&ctx, digest);
    static const char hex_digits[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        out_hex_64[i * 2] = hex_digits[(digest[i] >> 4) & 0x0F];
        out_hex_64[i * 2 + 1] = hex_digits[digest[i] & 0x0F];
    }
    out_hex_64[64] = '\0';
}

int mantiq_sha256_file_hex(const char* path, char* out_hex_64) {
    if (!path || !out_hex_64) return 0;
    FILE* f = fopen(path, "rb");
    if (!f) return 0;
    MantiqSha256 ctx;
    mantiq_sha256_init(&ctx);
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        mantiq_sha256_update(&ctx, buf, n);
    }
    fclose(f);
    uint8_t digest[32];
    mantiq_sha256_final(&ctx, digest);
    static const char hex_digits[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        out_hex_64[i * 2] = hex_digits[(digest[i] >> 4) & 0x0F];
        out_hex_64[i * 2 + 1] = hex_digits[digest[i] & 0x0F];
    }
    out_hex_64[64] = '\0';
    return 1;
}

// ── Cache File Utilities ──────────────────────────────────────────────
#include <errno.h>

int mantiq_mkdir_p(const char* dir_path) {
    if (!dir_path || !dir_path[0]) return 0;
    char tmp[4096];
    size_t len = strlen(dir_path);
    if (len >= sizeof(tmp)) return 0;
    memcpy(tmp, dir_path, len + 1);
    for (size_t i = 1; i < len; i++) {
        if (tmp[i] == '/') {
            tmp[i] = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
                return 0;
            }
            tmp[i] = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
        return 0;
    }
    return 1;
}

int mantiq_copy_file(const char* src_path, const char* dst_path) {
    if (!src_path || !dst_path) return 0;
    int src_fd = open(src_path, O_RDONLY);
    if (src_fd < 0) return 0;
    struct stat st;
    if (fstat(src_fd, &st) != 0) {
        close(src_fd);
        return 0;
    }
    char dst_dir[4096];
    size_t dlen = strlen(dst_path);
    if (dlen < sizeof(dst_dir)) {
        memcpy(dst_dir, dst_path, dlen + 1);
        char* last_slash = strrchr(dst_dir, '/');
        if (last_slash) {
            *last_slash = '\0';
            mantiq_mkdir_p(dst_dir);
        }
    }
    int dst_fd = open(dst_path, O_WRONLY | O_CREAT | O_TRUNC, (st.st_mode & 07777) ? (st.st_mode & 07777) : 0755);
    if (dst_fd < 0) {
        close(src_fd);
        return 0;
    }
    char buf[65536];
    ssize_t n;
    int ok = 1;
    while ((n = read(src_fd, buf, sizeof(buf))) > 0) {
        ssize_t written = 0;
        while (written < n) {
            ssize_t w = write(dst_fd, buf + written, n - written);
            if (w <= 0) {
                ok = 0;
                break;
            }
            written += w;
        }
        if (!ok) break;
    }
    close(src_fd);
    close(dst_fd);
#ifndef __wasi__
    if (ok) {
        chmod(dst_path, (st.st_mode & 07777) ? (st.st_mode & 07777) : 0755);
    }
#endif
    return ok;
}

#include <stdint.h>
int __mantiq_streq(const char* s1, int64_t l1, const char* s2, int64_t l2) {
    if (l1 != l2) return 0;
    return memcmp(s1, s2, l1) == 0;
}

uint32_t __mantiq_hash_bytes(const uint8_t* data, int64_t len) {
    uint32_t hash = 2166136261u;
    int64_t i = 0;
    while (i + 4 <= len) {
        hash = (hash ^ data[i]) * 16777619u;
        hash = (hash ^ data[i + 1]) * 16777619u;
        hash = (hash ^ data[i + 2]) * 16777619u;
        hash = (hash ^ data[i + 3]) * 16777619u;
        i += 4;
    }
    while (i < len) {
        hash = (hash ^ data[i]) * 16777619u;
        i++;
    }
    return hash;
}

uint32_t __mantiq_hash_string(const char* s, int64_t len) {
    return __mantiq_hash_bytes((const uint8_t*)s, len);
}

typedef struct {
    uint8_t* keys;
    uint8_t* values;
    uint32_t* hashes;
    uint8_t* occupied;
    int32_t capacity;
    int32_t count;
    int32_t key_size;
    int32_t val_size;
    int32_t is_string_key;
} MantiqDict;

void __mantiq_dict_set(MantiqDict* d, void* key, void* val, uint32_t hash);

MantiqDict* __mantiq_dict_create_with_capacity(int32_t key_size, int32_t val_size, int32_t is_string_key, int32_t initial_capacity) {
    MantiqDict* d = mantiq_malloc(sizeof(MantiqDict));
    int32_t cap = initial_capacity < 8 ? 8 : initial_capacity;
    int32_t p = 1;
    while (p < cap && p < 1073741824) {
        p <<= 1;
    }
    d->capacity = p;
    d->count = 0;
    d->key_size = key_size;
    d->val_size = val_size;
    d->is_string_key = is_string_key;
    d->keys = mantiq_malloc_raw(d->capacity * key_size);
    d->values = mantiq_malloc_raw(d->capacity * val_size);
    d->hashes = mantiq_malloc_raw(d->capacity * sizeof(uint32_t));
    d->occupied = mantiq_malloc(d->capacity);
    memset(d->occupied, 0, d->capacity);
    return d;
}

MantiqDict* __mantiq_dict_create(int32_t key_size, int32_t val_size, int32_t is_string_key) {
    return __mantiq_dict_create_with_capacity(key_size, val_size, is_string_key, 8);
}

void __mantiq_dict_resize(MantiqDict* d) {
    int32_t old_cap = d->capacity;
    uint8_t* old_keys = d->keys;
    uint8_t* old_vals = d->values;
    uint32_t* old_hashes = d->hashes;
    uint8_t* old_occ = d->occupied;

    d->capacity = old_cap * 2;
    d->keys = mantiq_malloc_raw(d->capacity * d->key_size);
    d->values = mantiq_malloc_raw(d->capacity * d->val_size);
    d->hashes = mantiq_malloc_raw(d->capacity * sizeof(uint32_t));
    d->occupied = mantiq_malloc(d->capacity);
    memset(d->occupied, 0, d->capacity);
    d->count = 0;

    int32_t mask = d->capacity - 1;
    for (int i = 0; i < old_cap; i++) {
        if (old_occ[i]) {
            uint32_t hash = old_hashes[i];
            int32_t idx = hash & mask;
            while (d->occupied[idx]) {
                idx = (idx + 1) & mask;
            }
            d->occupied[idx] = 1;
            d->hashes[idx] = hash;
            memcpy(d->keys + idx * d->key_size, old_keys + i * d->key_size, d->key_size);
            memcpy(d->values + idx * d->val_size, old_vals + i * d->val_size, d->val_size);
            d->count++;
        }
    }

    mantiq_free(old_keys);
    mantiq_free(old_vals);
    mantiq_free(old_hashes);
    mantiq_free(old_occ);
}

void __mantiq_dict_set(MantiqDict* d, void* key, void* val, uint32_t hash) {
    if (d->count * 2 >= d->capacity) {
        __mantiq_dict_resize(d);
    }
    
    int32_t mask = d->capacity - 1;
    int32_t idx = hash & mask;
    while (d->occupied[idx]) {
        if (d->hashes[idx] == hash) {
            int match = 0;
            if (d->is_string_key == 1) {
                struct MantiqStr { const char* ptr; size_t len; };
                struct MantiqStr* s1 = (struct MantiqStr*)(d->keys + idx * d->key_size);
                struct MantiqStr* s2 = (struct MantiqStr*)key;
                match = (s1->ptr == s2->ptr || (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0));
            } else if (d->is_string_key == 2) {
                struct MantiqHeapStr { const char* ptr; size_t len; size_t cap; };
                struct MantiqHeapStr* s1 = (struct MantiqHeapStr*)(d->keys + idx * d->key_size);
                struct MantiqHeapStr* s2 = (struct MantiqHeapStr*)key;
                match = (s1->ptr == s2->ptr || (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0));
            } else {
                match = memcmp(d->keys + idx * d->key_size, key, d->key_size) == 0;
            }
            if (match) {
                // Overwrite existing
                memcpy(d->values + idx * d->val_size, val, d->val_size);
                return;
            }
        }
        idx = (idx + 1) & mask;
    }

    d->occupied[idx] = 1;
    d->hashes[idx] = hash;
    memcpy(d->keys + idx * d->key_size, key, d->key_size);
    memcpy(d->values + idx * d->val_size, val, d->val_size);
    d->count++;
}

void* __mantiq_dict_get(MantiqDict* d, void* key, uint32_t hash) {
    int32_t mask = d->capacity - 1;
    int32_t idx = hash & mask;
    while (d->occupied[idx]) {
        if (d->hashes[idx] == hash) {
            int match = 0;
            if (d->is_string_key == 1) {
                struct MantiqStr { const char* ptr; size_t len; };
                struct MantiqStr* s1 = (struct MantiqStr*)(d->keys + idx * d->key_size);
                struct MantiqStr* s2 = (struct MantiqStr*)key;
                match = (s1->ptr == s2->ptr || (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0));
            } else if (d->is_string_key == 2) {
                struct MantiqHeapStr { const char* ptr; size_t len; size_t cap; };
                struct MantiqHeapStr* s1 = (struct MantiqHeapStr*)(d->keys + idx * d->key_size);
                struct MantiqHeapStr* s2 = (struct MantiqHeapStr*)key;
                match = (s1->ptr == s2->ptr || (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0));
            } else {
                match = memcmp(d->keys + idx * d->key_size, key, d->key_size) == 0;
            }
            if (match) {
                return d->values + idx * d->val_size;
            }
        }
        idx = (idx + 1) & mask;
    }
    return NULL;
}

int8_t __mantiq_dict_remove(MantiqDict* d, void* key, uint32_t hash) {
    int32_t mask = d->capacity - 1;
    int32_t idx = hash & mask;
    while (d->occupied[idx]) {
        if (d->hashes[idx] == hash) {
            int match = 0;
            if (d->is_string_key == 1) {
                struct MantiqStr { const char* ptr; size_t len; };
                struct MantiqStr* s1 = (struct MantiqStr*)(d->keys + idx * d->key_size);
                struct MantiqStr* s2 = (struct MantiqStr*)key;
                match = (s1->ptr == s2->ptr || (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0));
            } else if (d->is_string_key == 2) {
                struct MantiqHeapStr { const char* ptr; size_t len; size_t cap; };
                struct MantiqHeapStr* s1 = (struct MantiqHeapStr*)(d->keys + idx * d->key_size);
                struct MantiqHeapStr* s2 = (struct MantiqHeapStr*)key;
                match = (s1->ptr == s2->ptr || (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0));
            } else {
                match = memcmp(d->keys + idx * d->key_size, key, d->key_size) == 0;
            }
            if (match) {
                d->occupied[idx] = 0;
                d->count--;
                
                // Rehash the cluster to maintain contiguous probe sequences
                idx = (idx + 1) & mask;
                while (d->occupied[idx]) {
                    // Temporarily remove and re-insert
                    d->occupied[idx] = 0;
                    d->count--;
                    __mantiq_dict_set(d, d->keys + idx * d->key_size, d->values + idx * d->val_size, d->hashes[idx]);
                    idx = (idx + 1) & mask;
                }
                return 1;
            }
        }
        idx = (idx + 1) & mask;
    }
    return 0;
}

void* __mantiq_dict_get_or_insert(MantiqDict* d, void* key, uint32_t hash) {
    if (d->count * 2 >= d->capacity) {
        __mantiq_dict_resize(d);
    }
    int32_t mask = d->capacity - 1;
    int32_t idx = hash & mask;
    while (d->occupied[idx]) {
        if (d->hashes[idx] == hash) {
            int match = 0;
            if (d->is_string_key == 1) {
                struct MantiqStr { const char* ptr; size_t len; };
                struct MantiqStr* s1 = (struct MantiqStr*)(d->keys + idx * d->key_size);
                struct MantiqStr* s2 = (struct MantiqStr*)key;
                match = (s1->ptr == s2->ptr || (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0));
            } else if (d->is_string_key == 2) {
                struct MantiqHeapStr { const char* ptr; size_t len; size_t cap; };
                struct MantiqHeapStr* s1 = (struct MantiqHeapStr*)(d->keys + idx * d->key_size);
                struct MantiqHeapStr* s2 = (struct MantiqHeapStr*)key;
                match = (s1->ptr == s2->ptr || (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0));
            } else {
                match = memcmp(d->keys + idx * d->key_size, key, d->key_size) == 0;
            }
            if (match) {
                return d->values + idx * d->val_size;
            }
        }
        idx = (idx + 1) & mask;
    }
    d->occupied[idx] = 1;
    d->hashes[idx] = hash;
    memcpy(d->keys + idx * d->key_size, key, d->key_size);
    d->count++;
    return d->values + idx * d->val_size;
}

void __mantiq_list_append(void* list_addr, void* elem_addr, int64_t elem_size) {
    struct List {
        void* data;
        size_t len;
        size_t cap;
    }* l = (struct List*)list_addr;
    
    if (l->len >= l->cap) {
        size_t new_cap = l->cap == 0 ? 8 : l->cap * 2;
        l->data = mantiq_realloc(l->data, (int64_t)(new_cap * elem_size));
        l->cap = new_cap;
    }
    
    memcpy((char*)l->data + l->len * elem_size, elem_addr, (size_t)elem_size);
    l->len++;
}

void __mantiq_dict_keys(MantiqDict* d, void* list_addr, int32_t key_size) {
    if (!d || !list_addr) return;
    for (int32_t i = 0; i < d->capacity; i++) {
        if (d->occupied[i]) {
            void* key_ptr = d->keys + (i * d->key_size);
            __mantiq_list_append(list_addr, key_ptr, key_size);
        }
    }
}

void __mantiq_dict_clear(MantiqDict* d) {
    if (!d) return;
    d->count = 0;
    memset(d->occupied, 0, d->capacity);
}

void __mantiq_dict_merge(MantiqDict* dest, MantiqDict* src) {
    if (!dest || !src) return;
    for (int32_t i = 0; i < src->capacity; i++) {
        if (src->occupied[i]) {
            void* k = src->keys + i * src->key_size;
            void* v = src->values + i * src->val_size;
            uint32_t h = src->hashes[i];
            __mantiq_dict_set(dest, k, v, h);
        }
    }
}

void __mantiq_list_extend(void* list_addr, void* src_list_addr, int64_t elem_size) {
    if (!list_addr || !src_list_addr) return;
    struct MantiqRawList {
        uint8_t* data;
        size_t len;
        size_t cap;
    };
    struct MantiqRawList* dest = (struct MantiqRawList*)list_addr;
    struct MantiqRawList* src = (struct MantiqRawList*)src_list_addr;
    if (!src->data || src->len == 0) return;
    for (size_t i = 0; i < src->len; i++) {
        __mantiq_list_append(dest, src->data + i * elem_size, elem_size);
    }
}

// Print builtins
void mantiq_print_i32(int val) {
    printf("%d", val);
}

void mantiq_print_bool(int val) {
    if (val) {
        printf("True");
    } else {
        printf("False");
    }
}

void mantiq_print_float(float val) {
    printf("%f", val);
}

void mantiq_print_ptr(void* val) {
    printf("%p", val);
}

void mantiq_print_space() {
    printf(" ");
}

void mantiq_print_newline() {
    printf("\n");
}

void mantiq_print_dict_start() { printf("{"); }
void mantiq_print_dict_end() { printf("}"); }
void mantiq_print_list_start() { printf("["); }
void mantiq_print_list_end() { printf("]"); }
void mantiq_print_colon() { printf(": "); }
void mantiq_print_comma() { printf(", "); }

void mantiq_flush_stdout() {
    fflush(stdout);
}

void mantiq_print_str(const char* ptr, long long len) {
    if (ptr && len > 0) {
        fwrite(ptr, 1, len, stdout);
    }
}

void mantiq_print_cstr(const char* ptr) {
    if (ptr) {
        printf("%s", ptr);
    }
}

void mantiq_write(int fd, const char* ptr, long long len) {
    if (ptr && len > 0) {
#ifdef _WIN32
        FILE* stream = stdout;
        if (fd == 0) stream = stdin;
        else if (fd == 2) stream = stderr;
        fwrite(ptr, 1, len, stream);
        fflush(stream);
#else
        write(fd, ptr, len);
#endif
    }
}

void* mantiq_read(int fd, long long len, long long* out_len) {
    char* buf = mantiq_malloc(len + 1);
#ifdef _WIN32
    FILE* stream = stdin;
    if (fd == 1) stream = stdout;
    else if (fd == 2) stream = stderr;
    size_t bytes_read = fread(buf, 1, len, stream);
#else
    ssize_t bytes_read = read(fd, buf, len);
    if (bytes_read < 0) bytes_read = 0;
#endif
    buf[bytes_read] = '\0';
    if (out_len) *out_len = (long long)bytes_read;
    return buf;
}

int mantiq_fs_open(const char* path, long long path_len, const char* mode, long long mode_len) {
    char path_buf[1024];
    if (path_len >= 1024) path_len = 1023;
    memcpy(path_buf, path, path_len);
    path_buf[path_len] = '\0';

    char mode_buf[16];
    if (mode_len >= 16) mode_len = 15;
    memcpy(mode_buf, mode, mode_len);
    mode_buf[mode_len] = '\0';

    int flags = 0;
    if (strcmp(mode_buf, "r") == 0) {
        flags = O_RDONLY;
    } else if (strcmp(mode_buf, "w") == 0) {
        flags = O_WRONLY | O_CREAT | O_TRUNC;
    } else if (strcmp(mode_buf, "a") == 0) {
        flags = O_WRONLY | O_CREAT | O_APPEND;
    } else if (strcmp(mode_buf, "r+") == 0) {
        flags = O_RDWR;
    } else if (strcmp(mode_buf, "w+") == 0) {
        flags = O_RDWR | O_CREAT | O_TRUNC;
    } else if (strcmp(mode_buf, "a+") == 0) {
        flags = O_RDWR | O_CREAT | O_APPEND;
    } else {
        flags = O_RDONLY;
    }

#ifdef _WIN32
    // Windows compatibility
    return _open(path_buf, flags | _O_BINARY, 0666);
#else
    return open(path_buf, flags, 0666);
#endif
}

void mantiq_fs_close(int fd) {
#ifdef _WIN32
    _close(fd);
#else
    close(fd);
#endif
}

// ── WASI POSIX Shims ──────────────────────────────────────────────────
#if defined(__wasi__)
pid_t getpid(void) {
    return 1;
}

__attribute__((__import_module__("env"), __import_name__("host_system")))
extern int host_system(const char *command);

int system(const char *command) {
    return host_system(command);
}
#endif

static char g_lib_dir_override[PATH_MAX] = {0};
void set_compiler_lib_dir(const char* dir) {
    if (dir) {
        strncpy(g_lib_dir_override, dir, sizeof(g_lib_dir_override) - 1);
        g_lib_dir_override[sizeof(g_lib_dir_override) - 1] = '\0';
    }
}

const char* compiler_lib_dir(void) {
    if (g_lib_dir_override[0]) return g_lib_dir_override;
#if defined(__wasi__)
    if (access("mantiq/runtime.c", 0) == 0) return "mantiq";
    if (access("runtime.c", 0) == 0) return ".";
    if (access("../mantiq/runtime.c", 0) == 0) return "../mantiq";
    return ".";
#elif !defined(_WIN32)
    static char buf[PATH_MAX];
    char test[PATH_MAX];

    // 1. Check directory of executable (/proc/self/exe)
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n > 0) {
        buf[n] = '\0';
        char* slash = strrchr(buf, '/');
        if (slash != NULL) {
            if (slash == buf) {
                slash[1] = '\0';
            } else {
                *slash = '\0';
            }
            snprintf(test, sizeof(test), "%s/runtime.c", buf);
            if (access(test, R_OK) == 0) {
                snprintf(test, sizeof(test), "%s/tree_sitter_helper.c", buf);
                if (access(test, R_OK) == 0) {
                    snprintf(test, sizeof(test), "%s/libtree-sitter-mantiq.so", buf);
                    if (access(test, R_OK) == 0) return buf;
                }
            }
        }
    }

    // 2. Check user local library: ~/.local/lib/mantiq
    const char* home = getenv("HOME");
    if (home) {
        snprintf(buf, sizeof(buf), "%s/.local/lib/mantiq", home);
        snprintf(test, sizeof(test), "%s/runtime.c", buf);
        if (access(test, R_OK) == 0) {
            snprintf(test, sizeof(test), "%s/tree_sitter_helper.c", buf);
            if (access(test, R_OK) == 0) {
                snprintf(test, sizeof(test), "%s/libtree-sitter-mantiq.so", buf);
                if (access(test, R_OK) == 0) return buf;
            }
        }
    }

    // 3. Check system wide: /usr/local/lib/mantiq
    snprintf(buf, sizeof(buf), "/usr/local/lib/mantiq");
    snprintf(test, sizeof(test), "%s/runtime.c", buf);
    if (access(test, R_OK) == 0) {
        snprintf(test, sizeof(test), "%s/tree_sitter_helper.c", buf);
        if (access(test, R_OK) == 0) {
            snprintf(test, sizeof(test), "%s/libtree-sitter-mantiq.so", buf);
            if (access(test, R_OK) == 0) return buf;
        }
    }

    // 4. Check system wide: /usr/lib/mantiq
    snprintf(buf, sizeof(buf), "/usr/lib/mantiq");
    snprintf(test, sizeof(test), "%s/runtime.c", buf);
    if (access(test, R_OK) == 0) {
        snprintf(test, sizeof(test), "%s/tree_sitter_helper.c", buf);
        if (access(test, R_OK) == 0) {
            snprintf(test, sizeof(test), "%s/libtree-sitter-mantiq.so", buf);
            if (access(test, R_OK) == 0) return buf;
        }
    }

    return NULL;
#else
    static char buf[MAX_PATH];
    char test[MAX_PATH];
    DWORD n = GetModuleFileNameA(NULL, buf, sizeof(buf) - 1);
    if (n > 0) {
        buf[n] = '\0';
        char* slash = strrchr(buf, '\\');
        if (!slash) slash = strrchr(buf, '/');
        if (slash != NULL) {
            *slash = '\0';
            snprintf(test, sizeof(test), "%s\\runtime.c", buf);
            if (_access(test, 4) == 0) return buf;
        }
    }
    const char* localapp = getenv("LOCALAPPDATA");
    if (localapp) {
        snprintf(buf, sizeof(buf), "%s\\mantiq", localapp);
        snprintf(test, sizeof(test), "%s\\runtime.c", buf);
        if (_access(test, 4) == 0) return buf;
    }
    const char* progfiles = getenv("ProgramFiles");
    if (progfiles) {
        snprintf(buf, sizeof(buf), "%s\\mantiq", progfiles);
        snprintf(test, sizeof(test), "%s\\runtime.c", buf);
        if (_access(test, 4) == 0) return buf;
    }
    return NULL;
#endif
}

char mantiq_fs_exists(const char* path, long long path_len) {
    char path_buf[1024];
    if (path_len >= 1024) path_len = 1023;
    memcpy(path_buf, path, path_len);
    path_buf[path_len] = '\0';

#ifdef _WIN32
    DWORD attrib = GetFileAttributesA(path_buf);
    return (attrib != INVALID_FILE_ATTRIBUTES) ? 1 : 0;
#else
    struct stat st;
    return (stat(path_buf, &st) == 0) ? 1 : 0;
#endif
}

// F-String / Interpolation Utilities
void* mantiq_concat_str(const void* a_ptr, long long a_len, const void* b_ptr, long long b_len) {
    if (a_len <= 0 || !a_ptr) {
        if (b_len <= 0 || !b_ptr) {
            char* empty = (char*)mantiq_malloc_raw(1);
            empty[0] = '\0';
            return empty;
        }
        char* new_ptr = (char*)mantiq_malloc_raw(b_len + 1);
        memcpy(new_ptr, b_ptr, b_len);
        new_ptr[b_len] = '\0';
        return new_ptr;
    }
    if (b_len <= 0 || !b_ptr) {
        char* new_ptr = (char*)mantiq_malloc_raw(a_len + 1);
        memcpy(new_ptr, a_ptr, a_len);
        new_ptr[a_len] = '\0';
        return new_ptr;
    }
    long long total = a_len + b_len;
    char* new_ptr = (char*)mantiq_malloc_raw(total + 1);
    memcpy(new_ptr, a_ptr, a_len);
    memcpy(new_ptr + a_len, b_ptr, b_len);
    new_ptr[total] = '\0';
    return new_ptr;
}

void* mantiq_i32_to_str(int val, long long* out_len) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%d", val);
    char* new_ptr = (char*)mantiq_malloc_raw(len + 1);
    memcpy(new_ptr, buf, len + 1);
    if (out_len) *out_len = len;
    return new_ptr;
}

void* mantiq_float_to_str(float val, long long* out_len) {
    char buf[64];
    int len = snprintf(buf, sizeof(buf), "%f", val);
    char* new_ptr = (char*)mantiq_malloc_raw(len + 1);
    memcpy(new_ptr, buf, len + 1);
    if (out_len) *out_len = len;
    return new_ptr;
}

void* mantiq_i64_to_str(long long val, long long* out_len) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%lld", val);
    char* new_ptr = (char*)mantiq_malloc_raw(len + 1);
    memcpy(new_ptr, buf, len + 1);
    if (out_len) *out_len = len;
    return new_ptr;
}

void* mantiq_u64_to_str(unsigned long long val, long long* out_len) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%llu", val);
    char* new_ptr = (char*)mantiq_malloc_raw(len + 1);
    memcpy(new_ptr, buf, len + 1);
    if (out_len) *out_len = len;
    return new_ptr;
}

void* mantiq_f64_to_str(double val, long long* out_len) {
    char buf[64];
    int len = snprintf(buf, sizeof(buf), "%f", val);
    char* new_ptr = (char*)mantiq_malloc_raw(len + 1);
    memcpy(new_ptr, buf, len + 1);
    if (out_len) *out_len = len;
    return new_ptr;
}

void* mantiq_char_to_str(char val, long long* out_len) {
    char* new_ptr = (char*)mantiq_malloc_raw(2);
    new_ptr[0] = val;
    new_ptr[1] = '\0';
    if (out_len) *out_len = 1;
    return new_ptr;
}

void* mantiq_bool_to_str(int val, long long* out_len) {
    const char* str = val ? "True" : "False";
    long long len = val ? 4 : 5;
    char* new_ptr = (char*)mantiq_malloc_raw(len + 1);
    memcpy(new_ptr, str, len + 1);
    if (out_len) *out_len = len;
    return new_ptr;
}

typedef struct {
    void* data;
    void* vtable;
} MantiqAny;

MantiqAny make() {
    static int logged_allocator = 0;
    if (!logged_allocator) {
        printf("[Runtime] using allocator: %s\n", ALLOCATOR_NAME);
        logged_allocator = 1;
    }
    
    MantiqAny obj;
    obj.data = mantiq_malloc(32);
    obj.vtable = NULL;
    printf("[Runtime] make() created new Any object.\n");
    return obj;
}

// --- Async Runtime Executor ---

#ifdef _WIN32

typedef struct {
    HANDLE thread;
    void* (*func)(void*);
    void* env;
    void* result;
    int is_done;
    CRITICAL_SECTION mutex;
    CONDITION_VARIABLE cond;
} MantiqTask;

static unsigned __stdcall task_runner_win(void* arg) {
    MantiqTask* task = (MantiqTask*)arg;
    task->result = task->func(task->env);
    
    EnterCriticalSection(&task->mutex);
    task->is_done = 1;
    WakeConditionVariable(&task->cond);
    LeaveCriticalSection(&task->mutex);
    
    return 0;
}

MantiqTask* mantiq_spawn(void* (*func)(void*), void* env) {
    MantiqTask* task = (MantiqTask*)sys_malloc(sizeof(MantiqTask));
    task->func = func;
    task->env = env;
    task->result = NULL;
    task->is_done = 0;
    InitializeCriticalSection(&task->mutex);
    InitializeConditionVariable(&task->cond);
    
    printf("[Async] Spawning new actor task (Windows)...\n");
    task->thread = (HANDLE)_beginthreadex(NULL, 0, task_runner_win, task, 0, NULL);
    return task;
}

void* mantiq_await(MantiqTask* task) {
    if (!task) return NULL;
    
    EnterCriticalSection(&task->mutex);
    while (!task->is_done) {
        SleepConditionVariableCS(&task->cond, &task->mutex, INFINITE);
    }
    LeaveCriticalSection(&task->mutex);
    
    void* result = task->result;
    
    // Cleanup
    WaitForSingleObject(task->thread, INFINITE);
    CloseHandle(task->thread);
    DeleteCriticalSection(&task->mutex);
    sys_free(task);
    
    printf("[Async] Task awaited successfully.\n");
    return result;
}

// ── Channels (Windows) ──────────────────────────────────────────────────
typedef struct MantiqChannel {
    void** buffer;
    int64_t capacity;
    int64_t head;
    int64_t tail;
    int64_t count;
    int is_closed;
    CRITICAL_SECTION mutex;
    CONDITION_VARIABLE not_empty;
    CONDITION_VARIABLE not_full;
} MantiqChannel;

MantiqChannel* __mantiq_channel_new(int64_t capacity, int64_t elem_size) {
    (void)elem_size;
    if (capacity <= 0) capacity = 32;
    MantiqChannel* chan = (MantiqChannel*)sys_malloc(sizeof(MantiqChannel));
    chan->buffer = (void**)sys_malloc(sizeof(void*) * capacity);
    chan->capacity = capacity;
    chan->head = 0;
    chan->tail = 0;
    chan->count = 0;
    chan->is_closed = 0;
    InitializeCriticalSection(&chan->mutex);
    InitializeConditionVariable(&chan->not_empty);
    InitializeConditionVariable(&chan->not_full);
    return chan;
}

void __mantiq_channel_send(MantiqChannel* chan, void* val_ptr, int64_t elem_size) {
    if (!chan) return;
    EnterCriticalSection(&chan->mutex);
    while (chan->count == chan->capacity && !chan->is_closed) {
        SleepConditionVariableCS(&chan->not_full, &chan->mutex, INFINITE);
    }
    if (chan->is_closed) {
        LeaveCriticalSection(&chan->mutex);
        return;
    }
    int64_t sz = elem_size > 0 ? elem_size : 8;
    void* slot = sys_malloc(sz);
    if (val_ptr) memcpy(slot, val_ptr, sz);
    else memset(slot, 0, sz);
    chan->buffer[chan->tail] = slot;
    chan->tail = (chan->tail + 1) % chan->capacity;
    chan->count++;
    WakeConditionVariable(&chan->not_empty);
    LeaveCriticalSection(&chan->mutex);
}

void* __mantiq_channel_recv(MantiqChannel* chan, int64_t elem_size) {
    if (!chan) return NULL;
    EnterCriticalSection(&chan->mutex);
    while (chan->count == 0 && !chan->is_closed) {
        SleepConditionVariableCS(&chan->not_empty, &chan->mutex, INFINITE);
    }
    if (chan->count == 0 && chan->is_closed) {
        LeaveCriticalSection(&chan->mutex);
        int64_t sz = elem_size > 0 ? elem_size : 8;
        void* empty_slot = sys_malloc(sz);
        memset(empty_slot, 0, sz);
        return empty_slot;
    }
    void* slot = chan->buffer[chan->head];
    chan->head = (chan->head + 1) % chan->capacity;
    chan->count--;
    WakeConditionVariable(&chan->not_full);
    LeaveCriticalSection(&chan->mutex);
    return slot;
}

int __mantiq_channel_try_send(MantiqChannel* chan, void* val_ptr, int64_t elem_size) {
    if (!chan) return 0;
    EnterCriticalSection(&chan->mutex);
    if (chan->count == chan->capacity || chan->is_closed) {
        LeaveCriticalSection(&chan->mutex);
        return 0;
    }
    int64_t sz = elem_size > 0 ? elem_size : 8;
    void* slot = sys_malloc(sz);
    if (val_ptr) memcpy(slot, val_ptr, sz);
    else memset(slot, 0, sz);
    chan->buffer[chan->tail] = slot;
    chan->tail = (chan->tail + 1) % chan->capacity;
    chan->count++;
    WakeConditionVariable(&chan->not_empty);
    LeaveCriticalSection(&chan->mutex);
    return 1;
}

void* __mantiq_channel_try_recv(MantiqChannel* chan, int64_t elem_size, int* has_val) {
    if (!chan) {
        if (has_val) *has_val = 0;
        return NULL;
    }
    EnterCriticalSection(&chan->mutex);
    if (chan->count == 0) {
        if (has_val) *has_val = 0;
        LeaveCriticalSection(&chan->mutex);
        return NULL;
    }
    void* slot = chan->buffer[chan->head];
    chan->head = (chan->head + 1) % chan->capacity;
    chan->count--;
    if (has_val) *has_val = 1;
    WakeConditionVariable(&chan->not_full);
    LeaveCriticalSection(&chan->mutex);
    return slot;
}

void __mantiq_channel_close(MantiqChannel* chan) {
    if (!chan) return;
    EnterCriticalSection(&chan->mutex);
    chan->is_closed = 1;
    WakeAllConditionVariable(&chan->not_empty);
    WakeAllConditionVariable(&chan->not_full);
    LeaveCriticalSection(&chan->mutex);
}

int __mantiq_channel_is_closed(MantiqChannel* chan) {
    if (!chan) return 1;
    EnterCriticalSection(&chan->mutex);
    int res = chan->is_closed;
    LeaveCriticalSection(&chan->mutex);
    return res;
}

int64_t __mantiq_channel_len(MantiqChannel* chan) {
    if (!chan) return 0;
    EnterCriticalSection(&chan->mutex);
    int64_t cnt = chan->count;
    LeaveCriticalSection(&chan->mutex);
    return cnt;
}

int64_t __mantiq_channel_cap(MantiqChannel* chan) {
    return chan ? chan->capacity : 0;
}

void __mantiq_channel_free(MantiqChannel* chan) {
    if (!chan) return;
    __mantiq_channel_close(chan);
    EnterCriticalSection(&chan->mutex);
    for (int64_t i = 0; i < chan->count; i++) {
        int64_t idx = (chan->head + i) % chan->capacity;
        if (chan->buffer[idx]) sys_free(chan->buffer[idx]);
    }
    sys_free(chan->buffer);
    LeaveCriticalSection(&chan->mutex);
    DeleteCriticalSection(&chan->mutex);
    sys_free(chan);
}

#elif defined(__wasi__)

// ── Cooperative Task Scheduler (WASI / Single-Threaded) ───────────────────
typedef struct MantiqTask {
    void* (*func)(void*);
    void* env;
    void* result;
    int is_done;
    struct MantiqTask* next;
} MantiqTask;

static MantiqTask* g_wasi_ready_head = NULL;
static MantiqTask* g_wasi_ready_tail = NULL;

static void wasi_task_enqueue(MantiqTask* task) {
    task->next = NULL;
    if (!g_wasi_ready_tail) {
        g_wasi_ready_head = g_wasi_ready_tail = task;
    } else {
        g_wasi_ready_tail->next = task;
        g_wasi_ready_tail = task;
    }
}

static void wasi_run_ready_task(void) {
    if (!g_wasi_ready_head) return;
    MantiqTask* task = g_wasi_ready_head;
    g_wasi_ready_head = g_wasi_ready_head->next;
    if (!g_wasi_ready_head) g_wasi_ready_tail = NULL;
    if (!task->is_done) {
        task->result = task->func(task->env);
        task->is_done = 1;
    }
}

MantiqTask* mantiq_spawn(void* (*func)(void*), void* env) {
    MantiqTask* task = (MantiqTask*)mantiq_malloc(sizeof(MantiqTask));
    task->func = func;
    task->env = env;
    task->result = NULL;
    task->is_done = 0;
    task->next = NULL;
    wasi_task_enqueue(task);
    return task;
}

void* mantiq_await(MantiqTask* task) {
    if (!task) return NULL;
    while (!task->is_done) {
        if (g_wasi_ready_head) {
            wasi_run_ready_task();
        } else {
            task->result = task->func(task->env);
            task->is_done = 1;
            break;
        }
    }
    void* result = task->result;
    mantiq_free(task);
    return result;
}

// ── Channels (WASI Cooperative Mailbox) ───────────────────────────────────
typedef struct MantiqChannel {
    void** buffer;
    int64_t capacity;
    int64_t head;
    int64_t tail;
    int64_t count;
    int is_closed;
} MantiqChannel;

MantiqChannel* __mantiq_channel_new(int64_t capacity, int64_t elem_size) {
    (void)elem_size;
    if (capacity <= 0) capacity = 32;
    MantiqChannel* chan = (MantiqChannel*)mantiq_malloc(sizeof(MantiqChannel));
    chan->buffer = (void**)mantiq_malloc(sizeof(void*) * capacity);
    chan->capacity = capacity;
    chan->head = 0;
    chan->tail = 0;
    chan->count = 0;
    chan->is_closed = 0;
    return chan;
}

void __mantiq_channel_send(MantiqChannel* chan, void* val_ptr, int64_t elem_size) {
    if (!chan || chan->is_closed) return;
    int64_t sz = elem_size > 0 ? elem_size : 8;
    void* slot = mantiq_malloc(sz);
    if (val_ptr) memcpy(slot, val_ptr, sz);
    else memset(slot, 0, sz);
    chan->buffer[chan->tail] = slot;
    chan->tail = (chan->tail + 1) % chan->capacity;
    chan->count++;
}

void* __mantiq_channel_recv(MantiqChannel* chan, int64_t elem_size) {
    if (!chan) return NULL;
    int64_t sz = elem_size > 0 ? elem_size : 8;
    while (chan->count == 0 && !chan->is_closed) {
        if (g_wasi_ready_head) {
            wasi_run_ready_task();
        } else {
            break;
        }
    }
    if (chan->count == 0) {
        void* empty_slot = mantiq_malloc(sz);
        memset(empty_slot, 0, sz);
        return empty_slot;
    }
    void* slot = chan->buffer[chan->head];
    chan->head = (chan->head + 1) % chan->capacity;
    chan->count--;
    return slot;
}

int __mantiq_channel_try_send(MantiqChannel* chan, void* val_ptr, int64_t elem_size) {
    if (!chan || chan->count == chan->capacity || chan->is_closed) return 0;
    int64_t sz = elem_size > 0 ? elem_size : 8;
    void* slot = mantiq_malloc(sz);
    if (val_ptr) memcpy(slot, val_ptr, sz);
    else memset(slot, 0, sz);
    chan->buffer[chan->tail] = slot;
    chan->tail = (chan->tail + 1) % chan->capacity;
    chan->count++;
    return 1;
}

void* __mantiq_channel_try_recv(MantiqChannel* chan, int64_t elem_size, int* has_val) {
    if (!chan || chan->count == 0) {
        if (has_val) *has_val = 0;
        return NULL;
    }
    void* slot = chan->buffer[chan->head];
    chan->head = (chan->head + 1) % chan->capacity;
    chan->count--;
    if (has_val) *has_val = 1;
    return slot;
}

void __mantiq_channel_close(MantiqChannel* chan) {
    if (chan) chan->is_closed = 1;
}

int __mantiq_channel_is_closed(MantiqChannel* chan) {
    return !chan || chan->is_closed;
}

int64_t __mantiq_channel_len(MantiqChannel* chan) {
    return chan ? chan->count : 0;
}

int64_t __mantiq_channel_cap(MantiqChannel* chan) {
    return chan ? chan->capacity : 0;
}

void __mantiq_channel_free(MantiqChannel* chan) {
    if (!chan) return;
    for (int64_t i = 0; i < chan->count; i++) {
        int64_t idx = (chan->head + i) % chan->capacity;
        if (chan->buffer[idx]) mantiq_free(chan->buffer[idx]);
    }
    mantiq_free(chan->buffer);
    mantiq_free(chan);
}

#else

typedef struct {
    pthread_t thread;
    void* (*func)(void*);
    void* env;
    void* result;
    int is_done;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} MantiqTask;

static void* task_runner(void* arg) {
    MantiqTask* task = (MantiqTask*)arg;
    task->result = task->func(task->env);
    
    pthread_mutex_lock(&task->mutex);
    task->is_done = 1;
    pthread_cond_signal(&task->cond);
    pthread_mutex_unlock(&task->mutex);
    
    return NULL;
}

MantiqTask* mantiq_spawn(void* (*func)(void*), void* env) {
    MantiqTask* task = (MantiqTask*)mantiq_malloc(sizeof(MantiqTask));
    task->func = func;
    task->env = env;
    task->result = NULL;
    task->is_done = 0;
    pthread_mutex_init(&task->mutex, NULL);
    pthread_cond_init(&task->cond, NULL);
    
    pthread_create(&task->thread, NULL, task_runner, task);
    return task;
}

void* mantiq_await(MantiqTask* task) {
    if (!task) return NULL;
    
    pthread_mutex_lock(&task->mutex);
    while (!task->is_done) {
        pthread_cond_wait(&task->cond, &task->mutex);
    }
    pthread_mutex_unlock(&task->mutex);
    
    void* result = task->result;
    
    // Cleanup
    pthread_join(task->thread, NULL);
    pthread_mutex_destroy(&task->mutex);
    pthread_cond_destroy(&task->cond);
    mantiq_free(task);
    
    return result;
}

// ── Channels (POSIX) ───────────────────────────────────────────────────
typedef struct MantiqChannel {
    void** buffer;
    int64_t capacity;
    int64_t head;
    int64_t tail;
    int64_t count;
    int is_closed;
    pthread_mutex_t mutex;
    pthread_cond_t not_empty;
    pthread_cond_t not_full;
} MantiqChannel;

MantiqChannel* __mantiq_channel_new(int64_t capacity, int64_t elem_size) {
    (void)elem_size;
    if (capacity <= 0) capacity = 32;
    MantiqChannel* chan = (MantiqChannel*)mantiq_malloc(sizeof(MantiqChannel));
    chan->buffer = (void**)mantiq_malloc(sizeof(void*) * capacity);
    chan->capacity = capacity;
    chan->head = 0;
    chan->tail = 0;
    chan->count = 0;
    chan->is_closed = 0;
    pthread_mutex_init(&chan->mutex, NULL);
    pthread_cond_init(&chan->not_empty, NULL);
    pthread_cond_init(&chan->not_full, NULL);
    return chan;
}

void __mantiq_channel_send(MantiqChannel* chan, void* val_ptr, int64_t elem_size) {
    if (!chan) return;
    pthread_mutex_lock(&chan->mutex);
    while (chan->count == chan->capacity && !chan->is_closed) {
        pthread_cond_wait(&chan->not_full, &chan->mutex);
    }
    if (chan->is_closed) {
        pthread_mutex_unlock(&chan->mutex);
        return;
    }
    int64_t sz = elem_size > 0 ? elem_size : 8;
    void* slot = mantiq_malloc(sz);
    if (val_ptr) memcpy(slot, val_ptr, sz);
    else memset(slot, 0, sz);
    chan->buffer[chan->tail] = slot;
    chan->tail = (chan->tail + 1) % chan->capacity;
    chan->count++;
    pthread_cond_signal(&chan->not_empty);
    pthread_mutex_unlock(&chan->mutex);
}

void* __mantiq_channel_recv(MantiqChannel* chan, int64_t elem_size) {
    if (!chan) return NULL;
    pthread_mutex_lock(&chan->mutex);
    while (chan->count == 0 && !chan->is_closed) {
        pthread_cond_wait(&chan->not_empty, &chan->mutex);
    }
    if (chan->count == 0 && chan->is_closed) {
        pthread_mutex_unlock(&chan->mutex);
        int64_t sz = elem_size > 0 ? elem_size : 8;
        void* empty_slot = mantiq_malloc(sz);
        memset(empty_slot, 0, sz);
        return empty_slot;
    }
    void* slot = chan->buffer[chan->head];
    chan->head = (chan->head + 1) % chan->capacity;
    chan->count--;
    pthread_cond_signal(&chan->not_full);
    pthread_mutex_unlock(&chan->mutex);
    return slot;
}

int __mantiq_channel_try_send(MantiqChannel* chan, void* val_ptr, int64_t elem_size) {
    if (!chan) return 0;
    pthread_mutex_lock(&chan->mutex);
    if (chan->count == chan->capacity || chan->is_closed) {
        pthread_mutex_unlock(&chan->mutex);
        return 0;
    }
    int64_t sz = elem_size > 0 ? elem_size : 8;
    void* slot = mantiq_malloc(sz);
    if (val_ptr) memcpy(slot, val_ptr, sz);
    else memset(slot, 0, sz);
    chan->buffer[chan->tail] = slot;
    chan->tail = (chan->tail + 1) % chan->capacity;
    chan->count++;
    pthread_cond_signal(&chan->not_empty);
    pthread_mutex_unlock(&chan->mutex);
    return 1;
}

void* __mantiq_channel_try_recv(MantiqChannel* chan, int64_t elem_size, int* has_val) {
    if (!chan) {
        if (has_val) *has_val = 0;
        return NULL;
    }
    pthread_mutex_lock(&chan->mutex);
    if (chan->count == 0) {
        if (has_val) *has_val = 0;
        pthread_mutex_unlock(&chan->mutex);
        return NULL;
    }
    void* slot = chan->buffer[chan->head];
    chan->head = (chan->head + 1) % chan->capacity;
    chan->count--;
    if (has_val) *has_val = 1;
    pthread_cond_signal(&chan->not_full);
    pthread_mutex_unlock(&chan->mutex);
    return slot;
}

void __mantiq_channel_close(MantiqChannel* chan) {
    if (!chan) return;
    pthread_mutex_lock(&chan->mutex);
    chan->is_closed = 1;
    pthread_cond_broadcast(&chan->not_empty);
    pthread_cond_broadcast(&chan->not_full);
    pthread_mutex_unlock(&chan->mutex);
}

int __mantiq_channel_is_closed(MantiqChannel* chan) {
    if (!chan) return 1;
    pthread_mutex_lock(&chan->mutex);
    int res = chan->is_closed;
    pthread_mutex_unlock(&chan->mutex);
    return res;
}

int64_t __mantiq_channel_len(MantiqChannel* chan) {
    if (!chan) return 0;
    pthread_mutex_lock(&chan->mutex);
    int64_t cnt = chan->count;
    pthread_mutex_unlock(&chan->mutex);
    return cnt;
}

int64_t __mantiq_channel_cap(MantiqChannel* chan) {
    return chan ? chan->capacity : 0;
}

void __mantiq_channel_free(MantiqChannel* chan) {
    if (!chan) return;
    __mantiq_channel_close(chan);
    pthread_mutex_lock(&chan->mutex);
    for (int64_t i = 0; i < chan->count; i++) {
        int64_t idx = (chan->head + i) % chan->capacity;
        if (chan->buffer[idx]) mantiq_free(chan->buffer[idx]);
    }
    mantiq_free(chan->buffer);
    pthread_mutex_unlock(&chan->mutex);
    pthread_mutex_destroy(&chan->mutex);
    pthread_cond_destroy(&chan->not_empty);
    pthread_cond_destroy(&chan->not_full);
    mantiq_free(chan);
}

#endif

void mantiq_init(int argc, char** argv) {
    (void)argc;
    (void)argv;
}

void mantiq_process_exit(int code) {
    exit(code);
}

typedef struct {
    const char* ptr;
    long long len;
} MantiqAsciiStr;

typedef struct {
    MantiqAsciiStr* data;
    long long len;
    long long cap;
} MantiqListAsciiStr;

static int global_argc = -1;
static MantiqAsciiStr* global_argv_list = NULL;

static void mantiq_init_args_from_proc() {
    if (global_argc >= 0) return;
#ifdef _WIN32
    global_argc = 1;
    global_argv_list = (MantiqAsciiStr*)mantiq_malloc(sizeof(MantiqAsciiStr));
    global_argv_list[0].ptr = "mantiq-program";
    global_argv_list[0].len = 14;
#elif defined(__wasi__)
    int32_t c = 0, sz = 0;
    extern int32_t __imported_wasi_snapshot_preview1_args_sizes_get(int32_t*, int32_t*) __attribute__((__import_module__("wasi_snapshot_preview1"), __import_name__("args_sizes_get")));
    extern int32_t __imported_wasi_snapshot_preview1_args_get(int32_t*, int32_t*) __attribute__((__import_module__("wasi_snapshot_preview1"), __import_name__("args_get")));
    if (__imported_wasi_snapshot_preview1_args_sizes_get(&c, &sz) == 0 && c > 0) {
        char** argv_ptrs = (char**)mantiq_malloc(c * sizeof(char*));
        char* argv_buf = (char*)mantiq_malloc(sz);
        if (__imported_wasi_snapshot_preview1_args_get((int32_t*)argv_ptrs, (int32_t*)argv_buf) == 0) {
            global_argc = c;
            global_argv_list = (MantiqAsciiStr*)mantiq_malloc(c * sizeof(MantiqAsciiStr));
            for (int i = 0; i < c; i++) {
                size_t len = strlen(argv_ptrs[i]);
                global_argv_list[i].ptr = argv_ptrs[i];
                global_argv_list[i].len = (long long)len;
            }
            return;
        }
    }
    global_argc = 1;
    global_argv_list = (MantiqAsciiStr*)mantiq_malloc(sizeof(MantiqAsciiStr));
    global_argv_list[0].ptr = "nizam.wasm";
    global_argv_list[0].len = 10;
#else
    int fd = open("/proc/self/cmdline", O_RDONLY);
    if (fd < 0) {
        global_argc = 1;
        global_argv_list = (MantiqAsciiStr*)mantiq_malloc(sizeof(MantiqAsciiStr));
        global_argv_list[0].ptr = "mantiq-program";
        global_argv_list[0].len = 14;
        return;
    }
    static char buf[16384];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) {
        global_argc = 1;
        global_argv_list = (MantiqAsciiStr*)mantiq_malloc(sizeof(MantiqAsciiStr));
        global_argv_list[0].ptr = "mantiq-program";
        global_argv_list[0].len = 14;
        return;
    }
    buf[n] = '\0';
    int count = 0;
    for (ssize_t i = 0; i < n; i++) {
        if (buf[i] == '\0') {
            count++;
        }
    }
    if (count == 0) {
        global_argc = 1;
        global_argv_list = (MantiqAsciiStr*)mantiq_malloc(sizeof(MantiqAsciiStr));
        global_argv_list[0].ptr = "mantiq-program";
        global_argv_list[0].len = 14;
        return;
    }
    global_argc = count;
    global_argv_list = (MantiqAsciiStr*)mantiq_malloc(count * sizeof(MantiqAsciiStr));
    char* p = buf;
    for (int i = 0; i < count; i++) {
        size_t len = strlen(p);
        char* heap_str = (char*)mantiq_malloc(len + 1);
        memcpy(heap_str, p, len + 1);
        global_argv_list[i].ptr = heap_str;
        global_argv_list[i].len = (long long)len;
        p += len + 1;
    }
#endif
}

MantiqListAsciiStr* mantiq_process_args() {
    mantiq_init_args_from_proc();
    static MantiqListAsciiStr* cached_list = NULL;
    if (cached_list) return cached_list;
    
    cached_list = (MantiqListAsciiStr*)mantiq_malloc(sizeof(MantiqListAsciiStr));
    if (global_argc <= 0 || !global_argv_list) {
        cached_list->data = NULL;
        cached_list->len = 0;
        cached_list->cap = 0;
        return cached_list;
    }
    cached_list->data = (MantiqAsciiStr*)mantiq_malloc(global_argc * sizeof(MantiqAsciiStr));
    cached_list->len = global_argc;
    cached_list->cap = global_argc;
    for (int i = 0; i < global_argc; i++) {
        cached_list->data[i] = global_argv_list[i];
    }
    return cached_list;
}

void mantiq_panic(const char* message) {
    fprintf(stderr, "Runtime Panic: %s\n", message);
    exit(1);
}

void mantiq_panic_at(const char* message, const char* file, int line, int col) {
    fprintf(stderr, "Runtime Panic: %s at %s:%d:%d\n", message, file, line, col);
    exit(1);
}

long long mantiq_time_now() {
    return (long long)time(NULL);
}

long long mantiq_perf_now_ns() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec;
}

long long mantiq_perf_rss_bytes() {
#ifdef __linux__
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return (long long)ru.ru_maxrss * 1024LL;
#else
    return 0;
#endif
}

void mantiq_time_sleep(int seconds) {
#ifdef _WIN32
    Sleep(seconds * 1000);
#else
    sleep(seconds);
#endif
}

MantiqAsciiStr* mantiq_sys_os() {
    static MantiqAsciiStr os_str;
#if defined(_WIN32)
    os_str.ptr = "windows";
    os_str.len = 7;
#elif defined(__wasi__)
    os_str.ptr = "wasi";
    os_str.len = 4;
#elif defined(__APPLE__)
    os_str.ptr = "macos";
    os_str.len = 5;
#elif defined(__linux__)
    os_str.ptr = "linux";
    os_str.len = 5;
#else
    os_str.ptr = "unknown";
    os_str.len = 7;
#endif
    return &os_str;
}

MantiqAsciiStr* mantiq_sys_arch() {
    static MantiqAsciiStr arch_str;
#if defined(__wasm32__) || defined(__wasm__)
    arch_str.ptr = "wasm32";
    arch_str.len = 6;
#elif defined(__x86_64__) || defined(_M_X64)
    arch_str.ptr = "x86_64";
    arch_str.len = 6;
#elif defined(__aarch64__) || defined(_M_ARM64)
    arch_str.ptr = "aarch64";
    arch_str.len = 7;
#else
    arch_str.ptr = "unknown";
    arch_str.len = 7;
#endif
    return &arch_str;
}

MantiqAsciiStr* mantiq_sys_getenv(const char* name_ptr, long long name_len) {
    char* name = (char*)mantiq_malloc(name_len + 1);
    memcpy(name, name_ptr, name_len);
    name[name_len] = '\0';
    
    const char* val = getenv(name);
    mantiq_free(name);
    
    static MantiqAsciiStr val_str;
    if (val == NULL) {
        val_str.ptr = "";
        val_str.len = 0;
    } else {
        val_str.ptr = val;
        val_str.len = strlen(val);
    }
    return &val_str;
}

void mantiq_sys_setenv(const char* name_ptr, long long name_len, const char* val_ptr, long long val_len) {
    char* name = (char*)mantiq_malloc(name_len + 1);
    memcpy(name, name_ptr, name_len);
    name[name_len] = '\0';
    
    char* val = (char*)mantiq_malloc(val_len + 1);
    memcpy(val, val_ptr, val_len);
    val[val_len] = '\0';
    
#ifdef _WIN32
    SetEnvironmentVariableA(name, val);
#elif defined(__wasi__)
    (void)name; (void)val;
#else
    setenv(name, val, 1);
#endif
    mantiq_free(name);
    mantiq_free(val);
}

void mantiq_sys_unsetenv(const char* name_ptr, long long name_len) {
    char* name = (char*)mantiq_malloc(name_len + 1);
    memcpy(name, name_ptr, name_len);
    name[name_len] = '\0';
    
#ifdef _WIN32
    SetEnvironmentVariableA(name, NULL);
#elif defined(__wasi__)
    (void)name;
#else
    unsetenv(name);
#endif
    mantiq_free(name);
}

void format_llvm_float(double val, int is_f32, char* out_buf) {
    if (val == 0.0) {
        strcpy(out_buf, "0.000000e+00");
        return;
    }
    uint64_t u = 0;
    if (is_f32) {
        float f = (float)val;
        double d = (double)f;
        memcpy(&u, &d, sizeof(uint64_t));
    } else {
        memcpy(&u, &val, sizeof(uint64_t));
    }
    sprintf(out_buf, "0x%016llX", (unsigned long long)u);
}

// ── BFloat16 ABI Conversion Lowering ───────────────────────────────────────
#ifdef __x86_64__
__attribute__((naked)) void __truncsfbf2(void) {
    __asm__ volatile (
        "movd %xmm0, %eax\n\t"
        "movl %eax, %edx\n\t"
        "andl $0x7f800000, %edx\n\t"
        "cmpl $0x7f800000, %edx\n\t"
        "jne 1f\n\t"
        "movl %eax, %edx\n\t"
        "andl $0x007fffff, %edx\n\t"
        "jz 2f\n\t"
        "shrl $16, %eax\n\t"
        "orl $0x0040, %eax\n\t"
        "jmp 3f\n\t"
        "1:\n\t"
        "movl %eax, %edx\n\t"
        "shrl $16, %edx\n\t"
        "andl $1, %edx\n\t"
        "addl $0x7fff, %edx\n\t"
        "addl %edx, %eax\n\t"
        "2:\n\t"
        "shrl $16, %eax\n\t"
        "3:\n\t"
        "movd %eax, %xmm0\n\t"
        "ret\n\t"
    );
}

__attribute__((naked)) void __extendbfsf2(void) {
    __asm__ volatile (
        "movd %xmm0, %eax\n\t"
        "shll $16, %eax\n\t"
        "movd %eax, %xmm0\n\t"
        "ret\n\t"
    );
}

__attribute__((naked)) void __truncdfbf2(void) {
    __asm__ volatile (
        "cvtsd2ss %xmm0, %xmm0\n\t"
        "jmp __truncsfbf2\n\t"
    );
}

__attribute__((naked)) void __extendbfdf2(void) {
    __asm__ volatile (
        "movd %xmm0, %eax\n\t"
        "shll $16, %eax\n\t"
        "movd %eax, %xmm0\n\t"
        "cvtss2sd %xmm0, %xmm0\n\t"
        "ret\n\t"
    );
}
#endif

// ── RTTI / Dynamic Type Checking ─────────────────────────────────────
typedef struct MantiqTypeDescriptor {
    int32_t type_id;
    const char* type_name;
    int32_t parent_type_id;
    int32_t num_interfaces;
    const int32_t* interface_ids;
} MantiqTypeDescriptor;

int32_t mantiq_isa(const void* rtti_ptr, int32_t target_type_id) {
    if (!rtti_ptr) return 0;
    const MantiqTypeDescriptor* desc = (const MantiqTypeDescriptor*)rtti_ptr;
    if (desc->type_id == target_type_id) return 1;
    if (desc->parent_type_id == target_type_id && target_type_id != 0) return 1;
    for (int32_t i = 0; i < desc->num_interfaces; i++) {
        if (desc->interface_ids && desc->interface_ids[i] == target_type_id) {
            return 1;
        }
    }
    return 0;
}

// ── Quantum Simulator ────────────────────────────────────────────────────────
static int32_t s_mantiq_qubits[64] = {0};

int32_t mantiq_quantum_qbit(int32_t id) {
    s_mantiq_qubits[id & 63] = (id != 0) ? 1 : 0;
    return id & 63;
}

int32_t mantiq_quantum_h(int32_t q) {
    return q & 63;
}

int32_t mantiq_quantum_measure(int32_t q) {
    return s_mantiq_qubits[q & 63];
}

void mantiq_quantum_cnot(int32_t control, int32_t target) {
    if (s_mantiq_qubits[control & 63]) {
        s_mantiq_qubits[target & 63] ^= 1;
    }
}

int32_t mantiq_quantum_x(int32_t q) {
    s_mantiq_qubits[q & 63] ^= 1;
    return q & 63;
}

int32_t mantiq_quantum_y(int32_t q) {
    s_mantiq_qubits[q & 63] ^= 1;
    return q & 63;
}

int32_t mantiq_quantum_z(int32_t q) {
    return q & 63;
}

// ── Terminal Width Helper ─────────────────────────────────────────────
int32_t nizam_get_terminal_width(void) {
    const char *env_cols = getenv("COLUMNS");
    if (env_cols) {
        int parsed_w = atoi(env_cols);
        if (parsed_w > 20) {
            int w = parsed_w - 4;
            if (w < 70) return 70;
            if (w > 120) return 120;
            return w;
        }
    }
#if !defined(_WIN32) && !defined(__wasi__)
    struct winsize ws;
    if (ioctl(1, 21523 /* TIOCGWINSZ */, &ws) == 0 && ws.ws_col > 20) {
        int w = (int)ws.ws_col - 4;
        if (w < 70) return 70;
        if (w > 120) return 120;
        return w;
    }
#endif
    return 84;
}

// ── Python FFI Buffer Protocol & Shared Ownership ─────────────────────

typedef struct MantiqBufferOwner {
    int32_t ref_count;              // Shared atomic reference count
    void* data_ptr;                 // Raw contiguous element buffer
    size_t element_count;           // Number of elements
    uint32_t element_size;          // Element size in bytes
    char format_code[8];            // Format code (e.g. "d", "f", "q", "i")
    void (*destructor)(void* data); // Optional destructor callback
    int64_t shape[1];               // 1D shape storage for Py_buffer
    int64_t strides[1];             // 1D strides storage for Py_buffer
} MantiqBufferOwner;

typedef struct MantiqPyBuffer {
    void *buf;
    void *obj;                      // Owning PyObject* reference
    int64_t len;
    int64_t itemsize;
    int32_t readonly;
    int32_t ndim;
    char *format;
    int64_t *shape;
    int64_t *strides;
    int64_t *suboffsets;
    void *internal;
} MantiqPyBuffer;

typedef struct MantiqPyWrapper {
    int64_t ob_refcnt;
    void *ob_type;
    MantiqBufferOwner *owner;
    uint8_t is_owned;
    uint8_t pad[7];
} MantiqPyWrapper;

#if !defined(__wasi__) && (defined(__GNUC__) || defined(__clang__))
// Forward declarations for CPython C-API functions (weak symbols to prevent undefined references in standalone non-Python binaries)
extern void Py_Initialize(void) __attribute__((weak));
extern int Py_IsInitialized(void) __attribute__((weak));
extern void* PyImport_ImportModule(const char*) __attribute__((weak));
extern void* PyObject_GetAttrString(void*, const char*) __attribute__((weak));
extern void* PyObject_CallObject(void*, void*) __attribute__((weak));
extern void* PyTuple_New(int64_t) __attribute__((weak));
extern int PyTuple_SetItem(void*, int64_t, void*) __attribute__((weak));
extern void Py_IncRef(void*) __attribute__((weak));
extern void Py_DecRef(void*) __attribute__((weak));
extern void* PyFloat_FromDouble(double) __attribute__((weak));
extern void* PyLong_FromLongLong(long long) __attribute__((weak));
extern void* PyBool_FromLong(long) __attribute__((weak));
extern void* PyUnicode_FromString(const char*) __attribute__((weak));
extern void* PyUnicode_FromStringAndSize(const char*, int64_t) __attribute__((weak));
extern double PyFloat_AsDouble(void*) __attribute__((weak));
extern long long PyLong_AsLongLong(void*) __attribute__((weak));
extern int PyObject_IsTrue(void*) __attribute__((weak));
extern const char* PyUnicode_AsUTF8AndSize(void*, int64_t*) __attribute__((weak));
extern void* PyList_New(int64_t) __attribute__((weak));
extern int PyList_SetItem(void*, int64_t, void*) __attribute__((weak));
extern void PyErr_Print(void) __attribute__((weak));
extern void PyObject_Free(void*) __attribute__((weak));
extern void* PyType_GenericNew(void*, void*, void*) __attribute__((weak));
extern void* PyExc_BufferError __attribute__((weak));
extern void* PyExc_TypeError __attribute__((weak));
extern void PyErr_SetString(void*, const char*) __attribute__((weak));
extern int PyObject_GetBuffer(void*, void*, int) __attribute__((weak));
extern void PyBuffer_Release(void*) __attribute__((weak));
#endif

MantiqBufferOwner* mantiq_buffer_owner_create(void* data, size_t count, uint32_t elem_sz, const char* fmt) {
    MantiqBufferOwner* owner = (MantiqBufferOwner*)mantiq_malloc((int64_t)sizeof(MantiqBufferOwner));
    if (!owner) return NULL;
    owner->ref_count = 1;
    owner->data_ptr = data;
    owner->element_count = count;
    owner->element_size = elem_sz;
    memset(owner->format_code, 0, sizeof(owner->format_code));
    if (fmt) {
        strncpy(owner->format_code, fmt, sizeof(owner->format_code) - 1);
    } else {
        owner->format_code[0] = 'B';
    }
    owner->destructor = NULL;
    owner->shape[0] = (int64_t)count;
    owner->strides[0] = (int64_t)elem_sz;
    return owner;
}

void mantiq_buffer_owner_retain(MantiqBufferOwner* owner) {
    if (!owner) return;
    __atomic_add_fetch(&owner->ref_count, 1, __ATOMIC_SEQ_CST);
}

void mantiq_buffer_owner_release(MantiqBufferOwner* owner) {
    if (!owner) return;
    int32_t rc = __atomic_sub_fetch(&owner->ref_count, 1, __ATOMIC_SEQ_CST);
    if (rc <= 0) {
        if (owner->destructor) {
            owner->destructor(owner->data_ptr);
        } else if (owner->data_ptr) {
            mantiq_free(owner->data_ptr);
        }
        mantiq_free(owner);
    }
}

int __mantiq_py_bf_getbuffer(void* exporter, void* view_ptr, int flags) {
#if !defined(__wasi__)
    if (!exporter || !view_ptr) {
        if (&PyExc_BufferError && PyExc_BufferError && PyErr_SetString) {
            PyErr_SetString(PyExc_BufferError, "exporter or view is null");
        }
        return -1;
    }
    MantiqPyWrapper* wrap = (MantiqPyWrapper*)exporter;
    MantiqBufferOwner* owner = wrap->owner;
    if (!owner || !owner->data_ptr) {
        if (&PyExc_BufferError && PyExc_BufferError && PyErr_SetString) {
            PyErr_SetString(PyExc_BufferError, "Buffer is null or uninitialized");
        }
        return -1;
    }

    MantiqPyBuffer* view = (MantiqPyBuffer*)view_ptr;
    view->buf = owner->data_ptr;
    view->obj = exporter;
    if (Py_IncRef) {
        Py_IncRef(exporter);
    }

    view->len = (int64_t)(owner->element_count * owner->element_size);
    view->itemsize = (int64_t)owner->element_size;
    view->readonly = 0;
    view->ndim = 1;
    view->format = (flags & 0x0004 /* PyBUF_FORMAT */) ? owner->format_code : NULL;
    view->shape = (flags & (0x0010 | 0x0008) /* PyBUF_ND | PyBUF_STRIDES */) ? &owner->shape[0] : NULL;
    view->strides = (flags & 0x0010 /* PyBUF_STRIDES */) ? &owner->strides[0] : NULL;
    view->suboffsets = NULL;
    view->internal = (void*)owner;

    mantiq_buffer_owner_retain(owner);
    return 0;
#else
    return -1;
#endif
}

void __mantiq_py_bf_releasebuffer(void* exporter, void* view_ptr) {
    (void)view_ptr;
    if (!exporter) return;
    MantiqPyWrapper* wrap = (MantiqPyWrapper*)exporter;
    if (wrap->owner) {
        mantiq_buffer_owner_release(wrap->owner);
    }
}

void __mantiq_py_tp_dealloc_buffer(void* self) {
#if !defined(__wasi__)
    if (!self) return;
    MantiqPyWrapper* wrap = (MantiqPyWrapper*)self;
    if (wrap->owner) {
        mantiq_buffer_owner_release(wrap->owner);
        wrap->owner = NULL;
    }
    if (PyObject_Free) {
        PyObject_Free(self);
    }
#endif
}

void* __mantiq_py_wrap_buffer(void* data, size_t count, uint32_t elem_sz, const char* fmt, void* type_obj) {
#if !defined(__wasi__)
    if (!type_obj || !PyType_GenericNew) return NULL;
    MantiqPyWrapper* obj = (MantiqPyWrapper*)PyType_GenericNew(type_obj, NULL, NULL);
    if (!obj) return NULL;

    MantiqBufferOwner* owner = mantiq_buffer_owner_create(data, count, elem_sz, fmt);
    obj->owner = owner;
    obj->is_owned = 1;
    return (void*)obj;
#else
    return NULL;
#endif
}

int __mantiq_py_extract_buffer(void* obj, void* py_buf_out, void** out_data, int64_t* out_len, uint32_t expected_elem_sz, const char* expected_fmt) {
#if !defined(__wasi__)
    (void)expected_fmt;
    if (!obj || !py_buf_out || !out_data || !out_len || !PyObject_GetBuffer) {
        if (&PyExc_TypeError && PyExc_TypeError && PyErr_SetString) {
            PyErr_SetString(PyExc_TypeError, "Null argument passed to buffer extractor");
        }
        return -1;
    }

    MantiqPyBuffer* view = (MantiqPyBuffer*)py_buf_out;
    int ret = PyObject_GetBuffer(obj, (void*)view, 0x001c /* PyBUF_STRIDES | PyBUF_FORMAT */);
    if (ret != 0) {
        return -1;
    }

    if (expected_elem_sz > 0 && view->itemsize != (int64_t)expected_elem_sz) {
        if (PyBuffer_Release) {
            PyBuffer_Release((void*)view);
        }
        if (&PyExc_TypeError && PyExc_TypeError && PyErr_SetString) {
            PyErr_SetString(PyExc_TypeError, "Buffer element size mismatch");
        }
        return -1;
    }

    *out_data = view->buf;
    if (view->itemsize > 0) {
        *out_len = view->len / view->itemsize;
    } else {
        *out_len = view->len;
    }
    return 0;
#else
    return -1;
#endif
}

// ── Python FFI Phase 5: Embedded Python Runtime Support ─────────────────
void mantiq_py_init(void) {
#if !defined(__wasi__)
    if (!Py_IsInitialized) {
        fprintf(stderr, "Error: CPython runtime symbols not linked (-lpython3.12 missing)\n");
        exit(1);
    }
    if (!Py_IsInitialized()) {
        Py_Initialize();
    }
#endif
}

void* mantiq_py_import(const char* name) {
#if !defined(__wasi__)
    mantiq_py_init();
    if (!PyImport_ImportModule) return NULL;
    void* mod = PyImport_ImportModule(name);
    if (!mod && PyErr_Print) {
        PyErr_Print();
    }
    return mod;
#else
    return NULL;
#endif
}

void* mantiq_py_getattr(void* obj, const char* name) {
#if !defined(__wasi__)
    if (!obj || !PyObject_GetAttrString) return NULL;
    void* attr = PyObject_GetAttrString(obj, name);
    if (!attr && PyErr_Print) {
        PyErr_Print();
    }
    return attr;
#else
    return NULL;
#endif
}

void* mantiq_py_call(void* callable, void* tuple_args) {
#if !defined(__wasi__)
    if (!callable || !PyObject_CallObject) {
        if (tuple_args && Py_DecRef) Py_DecRef(tuple_args);
        return NULL;
    }
    void* res = PyObject_CallObject(callable, tuple_args);
    if (!res && PyErr_Print) {
        PyErr_Print();
    }
    if (callable && Py_DecRef) Py_DecRef(callable);
    if (tuple_args && Py_DecRef) Py_DecRef(tuple_args);
    return res;
#else
    return NULL;
#endif
}

void mantiq_py_decref(void* obj) {
#if !defined(__wasi__)
    if (obj && Py_DecRef) {
        Py_DecRef(obj);
    }
#endif
}

void mantiq_py_incref(void* obj) {
#if !defined(__wasi__)
    if (obj && Py_IncRef) {
        Py_IncRef(obj);
    }
#endif
}

double mantiq_py_to_f64(void* obj) {
#if !defined(__wasi__)
    if (!obj || !PyFloat_AsDouble) return 0.0;
    return PyFloat_AsDouble(obj);
#else
    return 0.0;
#endif
}

int64_t mantiq_py_to_i64(void* obj) {
#if !defined(__wasi__)
    if (!obj || !PyLong_AsLongLong) return 0;
    return (int64_t)PyLong_AsLongLong(obj);
#else
    return 0;
#endif
}

int32_t mantiq_py_to_i32(void* obj) {
#if !defined(__wasi__)
    if (!obj || !PyLong_AsLongLong) return 0;
    return (int32_t)PyLong_AsLongLong(obj);
#else
    return 0;
#endif
}

bool mantiq_py_to_bool(void* obj) {
#if !defined(__wasi__)
    if (!obj || !PyObject_IsTrue) return false;
    return PyObject_IsTrue(obj) != 0;
#else
    return false;
#endif
}

const char* mantiq_py_to_cstr(void* obj) {
#if !defined(__wasi__)
    if (!obj || !PyUnicode_AsUTF8AndSize) return "";
    int64_t size = 0;
    const char* utf8 = PyUnicode_AsUTF8AndSize(obj, &size);
    if (!utf8 || size < 0) return "";
    return utf8;
#else
    return "";
#endif
}

void* mantiq_py_box_list_f64(double* items, int64_t count) {
#if !defined(__wasi__)
    if (!PyList_New) return NULL;
    void* list = PyList_New(count > 0 ? count : 0);
    if (!list) return NULL;
    if (items && count > 0 && PyFloat_FromDouble && PyList_SetItem) {
        for (int64_t i = 0; i < count; i++) {
            void* f_obj = PyFloat_FromDouble(items[i]);
            PyList_SetItem(list, i, f_obj);
        }
    }
    return list;
#else
    return NULL;
#endif
}

void* mantiq_py_box_list_i64(int64_t* items, int64_t count) {
#if !defined(__wasi__)
    if (!PyList_New) return NULL;
    void* list = PyList_New(count > 0 ? count : 0);
    if (!list) return NULL;
    if (items && count > 0 && PyLong_FromLongLong && PyList_SetItem) {
        for (int64_t i = 0; i < count; i++) {
            void* i_obj = PyLong_FromLongLong((long long)items[i]);
            PyList_SetItem(list, i, i_obj);
        }
    }
    return list;
#else
    return NULL;
#endif
}

// ── Webview Desktop Shell ───────────────────────────────────────────────
typedef struct NizamWebview NizamWebview;
typedef void (*NizamWebviewCallback)(NizamWebview *wv, const char *arg, void *userdata);

struct NizamWebview {
    void *window_handle;
    void *webview_handle;
    char *title;
    int width;
    int height;
    int resizable;
    int debug;
    int is_running;
    int is_headless;
    char *last_html;
    char *last_eval_result;
};

static char* nizam_wv_dup(const char *src) {
    if (!src) return NULL;
    size_t len = strlen(src);
    char *dest = (char*)malloc(len + 1);
    if (dest) {
        memcpy(dest, src, len + 1);
    }
    return dest;
}

NizamWebview* nizam_webview_create(const char *title, int width, int height, int resizable, int debug) {
    NizamWebview *wv = (NizamWebview*)malloc(sizeof(NizamWebview));
    if (!wv) return NULL;

    wv->window_handle = NULL;
    wv->webview_handle = NULL;
    wv->title = nizam_wv_dup(title ? title : "Nizam App");
    wv->width = width > 0 ? width : 800;
    wv->height = height > 0 ? height : 600;
    wv->resizable = resizable;
    wv->debug = debug;
    wv->is_running = 0;
    wv->is_headless = 1;
    wv->last_html = NULL;
    wv->last_eval_result = NULL;

    return wv;
}

void nizam_webview_set_title(NizamWebview *wv, const char *title) {
    if (!wv || !title) return;
    if (wv->title) {
        free(wv->title);
    }
    wv->title = nizam_wv_dup(title);
}

void nizam_webview_set_size(NizamWebview *wv, int width, int height) {
    if (!wv) return;
    if (width > 0) wv->width = width;
    if (height > 0) wv->height = height;
}

void nizam_webview_navigate(NizamWebview *wv, const char *url) {
    if (!wv || !url) return;
    if (wv->debug) {
        printf("[nizam_webview] Navigate: %s\n", url);
    }
}

void nizam_webview_set_html(NizamWebview *wv, const char *html) {
    if (!wv || !html) return;
    if (wv->last_html) {
        free(wv->last_html);
    }
    wv->last_html = nizam_wv_dup(html);
}

void nizam_webview_eval(NizamWebview *wv, const char *js) {
    if (!wv || !js) return;
    if (wv->last_eval_result) {
        free(wv->last_eval_result);
    }
    wv->last_eval_result = nizam_wv_dup(js);
}

void nizam_webview_dispatch_patches(NizamWebview *wv, const char *json_patches) {
    if (!wv || !json_patches) return;
    char buffer[512];
    snprintf(buffer, sizeof(buffer), "window.__nizam_apply_patches && window.__nizam_apply_patches(%s);", json_patches);
    nizam_webview_eval(wv, buffer);
}

void nizam_webview_step(NizamWebview *wv) {
    if (!wv) return;
    if (wv->debug) {
        printf("[nizam_webview] Step\n");
    }
}

void nizam_webview_run(NizamWebview *wv) {
    if (!wv) return;
    wv->is_running = 1;
    nizam_webview_step(wv);
    wv->is_running = 0;
}

void nizam_webview_terminate(NizamWebview *wv) {
    if (!wv) return;
    wv->is_running = 0;
}

void nizam_webview_destroy(NizamWebview *wv) {
    if (!wv) return;
    if (wv->title) {
        free(wv->title);
        wv->title = NULL;
    }
    if (wv->last_html) {
        free(wv->last_html);
        wv->last_html = NULL;
    }
    if (wv->last_eval_result) {
        free(wv->last_eval_result);
        wv->last_eval_result = NULL;
    }
    free(wv);
}

// ── Direct Process Execution (no /bin/sh overhead) ───────────────────
int32_t mantiq_run_command_direct(const char* const* argv) {
    if (!argv || !argv[0]) return -1;
#if defined(__unix__) || defined(__APPLE__)
    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        execvp(argv[0], (char* const*)argv);
        _exit(127);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return -1;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return -1;
#else
    return -1;
#endif
}
