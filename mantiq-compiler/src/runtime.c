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

#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
    #include <windows.h>
    #include <process.h>
#else
    #include <pthread.h>
    #include <unistd.h>
    #include <fcntl.h>
    #include <sys/stat.h>
    #include <sys/types.h>
#endif
#include <pthread.h>
#include <time.h>

#define sys_malloc malloc
#define sys_free free
#define sys_realloc realloc
#define ALLOCATOR_NAME "libc-malloc"

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

// Memory Management for Closures and Objects
void* mantiq_malloc(size_t size) {
    void* ptr = calloc(1, size ? size : 1);
    if (!ptr) {
        fprintf(stderr, "[Runtime] Fatal: memory allocation of %zu bytes failed\n", size);
        abort();
    }
    return ptr;
}

void mantiq_free(void* ptr) {
    sys_free(ptr);
}

void* mantiq_realloc(void* ptr, size_t new_size) {
    void* new_ptr = sys_realloc(ptr, new_size);
    if (!new_ptr && new_size > 0) {
        fprintf(stderr, "[Runtime] Fatal: memory reallocation of %zu bytes failed\n", new_size);
        abort();
    }
    return new_ptr;
}

#include <stdint.h>
int __mantiq_streq(const char* s1, int64_t l1, const char* s2, int64_t l2) {
    if (l1 != l2) return 0;
    return memcmp(s1, s2, l1) == 0;
}

uint32_t __mantiq_hash_bytes(const uint8_t* data, int64_t len) {
    uint32_t hash = 2166136261u;
    for (int64_t i = 0; i < len; i++) {
        hash ^= data[i];
        hash *= 16777619u;
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

MantiqDict* __mantiq_dict_create(int32_t key_size, int32_t val_size, int32_t is_string_key) {
    MantiqDict* d = mantiq_malloc(sizeof(MantiqDict));
    d->capacity = 8;
    d->count = 0;
    d->key_size = key_size;
    d->val_size = val_size;
    d->is_string_key = is_string_key;
    d->keys = mantiq_malloc(d->capacity * key_size);
    d->values = mantiq_malloc(d->capacity * val_size);
    d->hashes = mantiq_malloc(d->capacity * sizeof(uint32_t));
    d->occupied = mantiq_malloc(d->capacity);
    memset(d->occupied, 0, d->capacity);
    return d;
}

void __mantiq_dict_resize(MantiqDict* d) {
    int32_t old_cap = d->capacity;
    uint8_t* old_keys = d->keys;
    uint8_t* old_vals = d->values;
    uint32_t* old_hashes = d->hashes;
    uint8_t* old_occ = d->occupied;

    d->capacity = old_cap * 2;
    d->keys = mantiq_malloc(d->capacity * d->key_size);
    d->values = mantiq_malloc(d->capacity * d->val_size);
    d->hashes = mantiq_malloc(d->capacity * sizeof(uint32_t));
    d->occupied = mantiq_malloc(d->capacity);
    memset(d->occupied, 0, d->capacity);
    d->count = 0;

    for (int i = 0; i < old_cap; i++) {
        if (old_occ[i]) {
            void* k = old_keys + i * d->key_size;
            void* v = old_vals + i * d->val_size;
            __mantiq_dict_set(d, k, v, old_hashes[i]);
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
    
    int32_t idx = hash % d->capacity;
    while (d->occupied[idx]) {
        if (d->hashes[idx] == hash) {
            int match = 0;
            if (d->is_string_key == 1) {
                struct MantiqStr { const char* ptr; int64_t len; };
                struct MantiqStr* s1 = (struct MantiqStr*)(d->keys + idx * d->key_size);
                struct MantiqStr* s2 = (struct MantiqStr*)key;
                match = (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0);
            } else if (d->is_string_key == 2) {
                struct MantiqHeapStr { const char* ptr; int64_t len; int64_t cap; };
                struct MantiqHeapStr* s1 = (struct MantiqHeapStr*)(d->keys + idx * d->key_size);
                struct MantiqHeapStr* s2 = (struct MantiqHeapStr*)key;
                match = (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0);
            } else {
                match = memcmp(d->keys + idx * d->key_size, key, d->key_size) == 0;
            }
            if (match) {
                // Overwrite existing
                memcpy(d->values + idx * d->val_size, val, d->val_size);
                return;
            }
        }
        idx = (idx + 1) % d->capacity;
    }

    d->occupied[idx] = 1;
    d->hashes[idx] = hash;
    memcpy(d->keys + idx * d->key_size, key, d->key_size);
    memcpy(d->values + idx * d->val_size, val, d->val_size);
    d->count++;
}

void* __mantiq_dict_get(MantiqDict* d, void* key, uint32_t hash) {
    int32_t idx = hash % d->capacity;
    while (d->occupied[idx]) {
        if (d->hashes[idx] == hash) {
            int match = 0;
            if (d->is_string_key == 1) {
                struct MantiqStr { const char* ptr; int64_t len; };
                struct MantiqStr* s1 = (struct MantiqStr*)(d->keys + idx * d->key_size);
                struct MantiqStr* s2 = (struct MantiqStr*)key;
                match = (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0);
            } else if (d->is_string_key == 2) {
                struct MantiqHeapStr { const char* ptr; int64_t len; int64_t cap; };
                struct MantiqHeapStr* s1 = (struct MantiqHeapStr*)(d->keys + idx * d->key_size);
                struct MantiqHeapStr* s2 = (struct MantiqHeapStr*)key;
                match = (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0);
            } else {
                match = memcmp(d->keys + idx * d->key_size, key, d->key_size) == 0;
            }
            if (match) {
                return d->values + idx * d->val_size;
            }
        }
        idx = (idx + 1) % d->capacity;
    }
    return NULL;
}

int8_t __mantiq_dict_remove(MantiqDict* d, void* key, uint32_t hash) {
    int32_t idx = hash % d->capacity;
    while (d->occupied[idx]) {
        if (d->hashes[idx] == hash) {
            int match = 0;
            if (d->is_string_key == 1) {
                struct MantiqStr { const char* ptr; int64_t len; };
                struct MantiqStr* s1 = (struct MantiqStr*)(d->keys + idx * d->key_size);
                struct MantiqStr* s2 = (struct MantiqStr*)key;
                match = (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0);
            } else if (d->is_string_key == 2) {
                struct MantiqHeapStr { const char* ptr; int64_t len; int64_t cap; };
                struct MantiqHeapStr* s1 = (struct MantiqHeapStr*)(d->keys + idx * d->key_size);
                struct MantiqHeapStr* s2 = (struct MantiqHeapStr*)key;
                match = (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0);
            } else {
                match = memcmp(d->keys + idx * d->key_size, key, d->key_size) == 0;
            }
            if (match) {
                d->occupied[idx] = 0;
                d->count--;
                
                // Rehash the cluster to maintain contiguous probe sequences
                idx = (idx + 1) % d->capacity;
                while (d->occupied[idx]) {
                    // Temporarily remove and re-insert
                    d->occupied[idx] = 0;
                    d->count--;
                    __mantiq_dict_set(d, d->keys + idx * d->key_size, d->values + idx * d->val_size, d->hashes[idx]);
                    idx = (idx + 1) % d->capacity;
                }
                return 1;
            }
        }
        idx = (idx + 1) % d->capacity;
    }
    return 0;
}

void* __mantiq_dict_get_or_insert(MantiqDict* d, void* key, uint32_t hash) {
    if (d->count * 2 >= d->capacity) {
        __mantiq_dict_resize(d);
    }
    int32_t idx = hash % d->capacity;
    while (d->occupied[idx]) {
        if (d->hashes[idx] == hash) {
            int match = 0;
            if (d->is_string_key == 1) {
                struct MantiqStr { const char* ptr; int64_t len; };
                struct MantiqStr* s1 = (struct MantiqStr*)(d->keys + idx * d->key_size);
                struct MantiqStr* s2 = (struct MantiqStr*)key;
                match = (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0);
            } else if (d->is_string_key == 2) {
                struct MantiqHeapStr { const char* ptr; int64_t len; int64_t cap; };
                struct MantiqHeapStr* s1 = (struct MantiqHeapStr*)(d->keys + idx * d->key_size);
                struct MantiqHeapStr* s2 = (struct MantiqHeapStr*)key;
                match = (s1->len == s2->len && memcmp(s1->ptr, s2->ptr, s1->len) == 0);
            } else {
                match = memcmp(d->keys + idx * d->key_size, key, d->key_size) == 0;
            }
            if (match) {
                return d->values + idx * d->val_size;
            }
        }
        idx = (idx + 1) % d->capacity;
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
        int64_t len;
        int64_t cap;
    }* l = (struct List*)list_addr;
    
    if (l->len >= l->cap) {
        int64_t new_cap = l->cap == 0 ? 8 : l->cap * 2;
        l->data = mantiq_realloc(l->data, new_cap * elem_size);
        l->cap = new_cap;
    }
    
    memcpy((char*)l->data + l->len * elem_size, elem_addr, elem_size);
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

const char* compiler_lib_dir(void) {
#ifndef _WIN32
    static char buf[PATH_MAX];
    char test[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n <= 0) {
        return NULL;
    }
    buf[n] = '\0';
    char* slash = strrchr(buf, '/');
    if (slash == NULL) {
        return NULL;
    }
    if (slash == buf) {
        slash[1] = '\0';
    } else {
        *slash = '\0';
    }
    snprintf(test, sizeof(test), "%s/runtime.c", buf);
    if (access(test, R_OK) != 0) return NULL;
    snprintf(test, sizeof(test), "%s/tree_sitter_helper.c", buf);
    if (access(test, R_OK) != 0) return NULL;
    snprintf(test, sizeof(test), "%s/libtree-sitter-mantiq.so", buf);
    if (access(test, R_OK) != 0) return NULL;
    return buf;
#else
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
    long long total = a_len + b_len;
    char* new_ptr = (char*)mantiq_malloc(total + 1);
    if (a_len > 0 && a_ptr) memcpy(new_ptr, a_ptr, a_len);
    if (b_len > 0 && b_ptr) memcpy(new_ptr + a_len, b_ptr, b_len);
    new_ptr[total] = '\0';
    return new_ptr;
}

void* mantiq_i32_to_str(int val, long long* out_len) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%d", val);
    char* new_ptr = (char*)mantiq_malloc(len + 1);
    memcpy(new_ptr, buf, len + 1);
    if (out_len) *out_len = len;
    return new_ptr;
}

void* mantiq_float_to_str(float val, long long* out_len) {
    char buf[64];
    int len = snprintf(buf, sizeof(buf), "%f", val);
    char* new_ptr = (char*)mantiq_malloc(len + 1);
    memcpy(new_ptr, buf, len + 1);
    if (out_len) *out_len = len;
    return new_ptr;
}

void* mantiq_bool_to_str(int val, long long* out_len) {
    const char* str = val ? "True" : "False";
    long long len = val ? 4 : 5;
    char* new_ptr = (char*)mantiq_malloc(len + 1);
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
    
    printf("[Async] Spawning new actor task...\n");
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
    sys_free(task);
    
    printf("[Async] Task awaited successfully.\n");
    return result;
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
#if defined(__x86_64__) || defined(_M_X64)
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
