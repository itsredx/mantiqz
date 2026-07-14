# Mantiq & Nizam (mantiqz)

A clean, self-contained compiler and parser suite for the **Mantiq** and **Nizam** programming languages. The compiler is written in Zig and generates native executables via LLVM.

## Languages Overview

Both **Mantiq** and **Nizam** leverage a compile-time **ownership and borrow checking model** to ensure memory safety without runtime overhead (no garbage collection). Additionally, both languages support **manual memory management** (using `make` / `drop` builtins) when direct, low-level allocation control is required.

- **Nizam**: A strict, static, safe systems programming language designed for predictability and performance. Nizam files traditionally end with the `.nz` extension.
- **Mantiq**: A gradual, dynamically-typed script counterpart that prioritizes ease-of-use and quick iterations. Mantiq files traditionally end with the `.mq` extension.

---

## Repository Structure

The project is structured into self-contained components:

- [mantiq-compiler/](file:/mantiqz/mantiq-compiler) — The compiler codebase written in Zig. Handles AST lowering, semantic analysis, control flow analysis, type checking, borrow checking, DCE optimization, and codegen (LLVM IR). Includes JIT and AOT runners.
- [tree-sitter-mantiq/](file:/mantiqz/tree-sitter-mantiq) — The formal Tree-sitter syntax parser definition, queries, and generated C parsers.
- [std/](file:/mantiqz/std) — The standard library code for Mantiq and Nizam (collections, math, path, string, text, etc.).
- [docs/](file:/mantiqz/docs) — Extensive documentation including language specifications (`docs/specification/`) and architectural decision records (ADRs in `docs/decisions/`).

---

## Building the Compilers

To build the compilers, make sure you have the [Zig compiler toolchain](https://ziglang.org) installed on your system.

Navigate to the compiler directory and run the build command:

```bash
cd mantiq-compiler
zig build
```

This will produce two separate compiled binary executables inside the `zig-out/bin/` folder:
- `mantiq` — The Mantiq compiler and JIT/AOT runner.
- `nizam` — The Nizam compiler and JIT/AOT runner.

---

## CLI Usage

Running the compiler binary with no arguments starts the interactive REPL in the respective language mode:

```bash
$ ./mantiq
Welcome to the Mantiq REPL.
mantiq>

$ ./nizam
Welcome to the Nizam (Persistent) REPL.
nizam>
```

### Ahead-of-Time (AOT) Compilation
Compile a source file into a native binary:

```bash
# Compiles hello.nz into a standalone hello executable
$ ./nizam build hello.nz -o hello
$ ./hello
```

### JIT Execution
Directly execute a program using the JIT compiler:

```bash
$ ./nizam run hello.nz
```

### Running Test Suite
Execute the compiler's internal test batteries:

```bash
$ ./mantiq test
```

---

## Portability & Dependencies

The compiler binaries are fully portable and self-contained:
- The runtime code (`runtime.c`) is embedded directly into the compiler executables at compile-time.
- The binaries can be moved to any directory or another Linux machine, provided that:
  1. `zig` is installed and available in the system `PATH` (for C backend invocation).
  2. `libmimalloc` is installed on the host system (for dynamic memory allocation).
