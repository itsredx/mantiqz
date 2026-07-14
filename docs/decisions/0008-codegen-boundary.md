# 0008 - Codegen Boundary (Compiler vs Runtime)

## Context
Defining a clear boundary between inline LLVM IR generation and runtime library calls keeps the compiler maintainable. Implementing complex behaviors (like string formatting, dictionary lookups, or async scheduling) directly in LLVM IR leads to bloated, hard-to-debug code generators.

## Decision
Mantiq enforces a strict division of labor between compiler-generated LLVM IR, LLVM intrinsics, and the Mantiq C Runtime Library (`runtime.c`).

### 1. Compiler-Generated LLVM IR (Direct Code Generation)
The compiler directly emits LLVM IR for primitive and low-level control operations.
- **Arithmetic**:
  - Signed integer addition (`add`), subtraction (`sub`), multiplication (`mul`).
  - Integer division (`sdiv`) and modulo (`srem`) (guarded by runtime zero checks).
  - Floating-point operations (`fadd`, `fsub`, `fmul`, `fdiv`, `frem`).
- **Bitwise & Shifts**: Bitwise operations (`and`, `or`, `xor`, `shl`, `lshr`, `ashr`).
- **Control Flow**: Conditional and unconditional branches (`br i1`, `br label`), phi nodes, and local block terminators.
- **Memory Operations**: Stack allocation (`alloca`), memory accesses (`load`, `store`), and address calculation (`getelementptr`).
- **Data Layout Structures**: Tuple and struct representation extraction/insertion (`extractvalue`, `insertvalue`).

### 2. LLVM Intrinsics
The compiler uses standardized LLVM compiler intrinsics for performance-critical structural operations.
- **Bulk Memory Copy**: `@llvm.memcpy.p0.p0.i64` is declared and emitted for struct/value copying.

### 3. Mantiq C Runtime Library (`runtime.c`)
Higher-level behaviors, I/O, dynamic typing, and collections are delegated to the runtime library.
- **Memory Allocation**:
  - `mantiq_malloc` and `mantiq_free` (backed by the thread-safe `mimalloc` library).
- **I/O & String Formatting**:
  - `mantiq_print_i32`, `mantiq_print_bool`, `mantiq_print_float`, `mantiq_print_str`, `mantiq_print_newline`, etc.
  - `mantiq_concat_str` (string concatenation).
  - `mantiq_i32_to_str`, `mantiq_float_to_str`, `mantiq_bool_to_str` (type conversion formatting).
  - `__mantiq_streq` (string equality comparisons).
- **Dynamic Collections (Dictionaries)**:
  - `__mantiq_dict_create`, `__mantiq_dict_set`, `__mantiq_dict_get`, `__mantiq_dict_get_or_insert`.
  - Hash functions: `__mantiq_hash_string`, `__mantiq_hash_bytes`.
- **Task Scheduling & Concurrency**:
  - `mantiq_spawn` (spawns tasks into the runtime thread pool).
  - `mantiq_await` (suspends current worker thread until task completion).
  - `__mantiq_parallel_for` (parallel iterations).
- **Panic Handler**:
  - `mantiq_panic` (terminates execution with status code 1 and writes the panic reason to stderr).
- **Quantum Mechanics Simulation**:
  - `quantum_measure`, `quantum_H`, `quantum_CNOT`, `quantum_qreg`.

## Implementation Implications
- The code generator (`codegen.zig`) remains highly readable, only handling value lowering, branching, and layout calculation.
- The C runtime can be easily debugged, profiled, or swapped with specialized backends (e.g. WASM or embedded environments).
