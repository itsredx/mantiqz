# Decision 0039: CLI Driver Compilation, Target Architecture, and Execution Modes

## Context

To support standalone systems programming, cross-compilation, in-browser WebAssembly execution, and Python C-extension packaging, the self-hosted Mantiq/Nizam compiler requires a robust CLI driver.

Historically, the compiler's CLI began as an interactive REPL and test runner inside the bootstrap compiler. As the self-hosted compiler (`src/main.nz`) converged, the CLI transitioned to an AOT compiler and multi-target runner capable of compiling source files directly into standalone native executables, WebAssembly modules, and CPython C-extension shared libraries without test-suite noise.

---

## CLI Design & Command Reference

The command-line driver supports dual compiler executables (`nizam` for strict mode default and `mantiq` for dynamic mode default):

```bash
# Compilation (AOT)
$ nizam build <input_file> [-o <output_file>] [--target <triple>] [--lib-dir <dir>] [--profile]
$ mantiq build <input_file> [-o <output_file>] [--target <triple>] [--lib-dir <dir>] [--profile]

# Execution (Compile & Run)
$ nizam run <input_file> [--target <triple>] [--lib-dir <dir>] [--profile]
$ mantiq run <input_file> [--target <triple>] [--lib-dir <dir>] [--profile]

# Version Information
$ nizam version
$ nizam --version
```

---

## Supported Targets (`--target`)

The compiler abstracts code generation and data layouts via `src/layout.nz` and `src/codegen.nz`, targeting three primary environments:

| Target Triple | Output Artifact | Default Name | Linker / Runtime Engine | Execution Model (`run`) |
| :--- | :--- | :--- | :--- | :--- |
| `x86_64-unknown-linux-gnu` *(default)* | Native ELF 64-bit Executable | `a.out` | `clang` / `zig cc` (`-no-pie`, `-lm`) | Direct OS execution via `/tmp/mantiq_run_tmp_<pid>` |
| `wasm32-wasi` / `wasm` | WebAssembly 1.0 Linear Module | `a.wasm` | `zig cc` (`-target wasm32-wasi`, `-O2`) | Node.js WASI Preview 1 runner |
| `python-ext` | PEP 384 Limited API Shared Library | `<module>.abi3.so` | `clang` / `zig cc` (`-shared`, `-fPIC`) | Dynamic CPython 3 test loader inspecting module exports |

---

## Options & Flags

1. **`-o <output_file>`**:
   - Specifies the destination output path.
   - If omitted:
     - Native target defaults to `a.out`.
     - `wasm32-wasi` target defaults to `a.wasm`.
     - `python-ext` target extracts the module name from the input path and defaults to `<module>.abi3.so`.

2. **`--target <triple>`**:
   - Configures the backend architecture, calling convention, and struct layout (e.g. 32-bit linear memory vs 64-bit SysV x86_64 vs PEP 384 abi3).

3. **`--lib-dir <dir>`**:
   - Explicitly configures the search path for standard library modules (`std/`) and dynamic helper libraries (`libtree-sitter-mantiq.so`).

4. **`--profile`**:
   - Enables compiler micro-profiling ([perf_init](file:///mantiq/src/main.nz), [perf_print](file:///mantiq/src/main.nz)) measuring nanosecond latency across each compiler pipeline stage:
     - Lexical parsing & Tree-Sitter CST generation
     - CST lowering & macro expansion
     - Semantic analysis & symbol table resolution
     - Type checking & monomorphization
     - SSA LLVM IR code generation
     - Native linker invocation (`clang` / `zig cc`)

---

## Language Mode Detection

The compiler automatically infers language mode using the following hierarchy:

1. **File Extension**:
   - `.nz` files compile in strict **Nizam** mode (manual memory ownership, borrow checking, no implicit heap allocations, `class` disallowed).
   - `.mq` files compile in dynamic **Mantiq** mode (gradual typing, closures, classes, runtime polymorphism).
2. **Binary Invocation Name**:
   - If the compiler binary name (`argv[0]`) contains `nizam`, unrecognized extensions default to **Nizam**.
   - Otherwise, unrecognized extensions default to **Mantiq**.

---

## Examples

### 1. Compiling & Running Native Executables
```bash
# Compile to custom binary
$ nizam build src/app.nz -o my_app
$ ./my_app

# Compile and immediately run
$ nizam run src/app.nz
```

### 2. Compiling for WebAssembly
```bash
$ nizam build app.nz --target wasm32-wasi -o app.wasm --lib-dir mantiq
$ node --experimental-wasi-unstable-preview1 -e '
  const { WASI } = require("wasi");
  const fs = require("fs");
  const wasi = new WASI({ version: "preview1", args: ["app.wasm"] });
  const wasm = new WebAssembly.Module(fs.readFileSync("app.wasm"));
  const inst = new WebAssembly.Instance(wasm, wasi.getImportObject());
  wasi.start(inst);'
```

### 3. Compiling CPython C-Extensions
```bash
$ nizam build math_ops.nz --target python-ext
# Produces math_ops.abi3.so

$ python3 -c "import math_ops; print(math_ops.add(10, 20))"
```

### 4. Profiling Compilation Performance
```bash
$ nizam build app.nz --profile
# Outputs:
# [perf] parse: 4.2ms
# [perf] lower: 2.1ms
# [perf] sema:  3.5ms
# [perf] type:  5.1ms
# [perf] codegen: 12.3ms
# [perf] link:  45.8ms
# Successfully compiled app.nz -> a.out
```
