# Compiler Architecture

## Overview

The Mantiq/Nizam compiler is written in **Zig** and compiles source code through a multi-stage pipeline:

```
Source text
  │
  ▼
┌─────────────────────────────────────────────────────┐
│ 1. Parser (tree-sitter C FFI)                       │
│    Source → tree-sitter CST (Concrete Syntax Tree)  │
└─────────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────────┐
│ 2. Lower (CST → AST)                                │
│    Tree-sitter CST → Mantiq AST (ast.zig: Node)     │
│    Macro expansion, Nizam strict mode enforcement   │
└─────────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────────┐
│ 3. Semantic Analysis (sema.zig)                     │
│    Two-pass: declare → resolve                      │
│    Symbol table construction, scope resolution,     │
│    module loading, closure capture analysis         │
└─────────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────────┐
│ 4. CFG Analysis (cfg.zig)                           │
│    Control flow graph checks:                       │
│    - Return path completeness                       │
│    - Unreachable code detection                     │
└─────────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────────┐
│ 5. Type Checking (typecheck.zig)                    │
│    Type inference, unification, validation          │
│    Generic monomorphization (struct + function)     │
│    Nizam allocation rules enforcement               │
│    Built-in function type resolution                │
└─────────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────────┐
│ 6. Borrow Checking (borrowck.zig)                   │
│    Ownership state machine: Owned → Moved | Dropped │
│    Auto-drop injection at scope exit                │
│    Context manager (with stmt) integration          │
└─────────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────────┐
│ 7. Dead Code Elimination (dce.zig)                  │
│    Mark-and-sweep two-phase design                  │
│    Quantum-specific tree shaking (std.quantum)      │
│    Constant-folding boolean branches                │
└─────────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────────┐
│ 8. AST Merging (mergeImportedDeclarations)          │
│    Inline imported module ASTs into the root AST    │
└─────────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────────┐
│ 9. Code Generation (codegen.zig)                    │
│    AST → LLVM IR string                             │
│    - Type mapping (fat pointers, Option, Any, etc.) │
│    - Auto-drop cleanup generation                   │
│    - Temporary lifetime management                  │
│    - Closure outlining + trampoline patterns        │
│    - Parallel loop codegen (for@par)                │
└─────────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────────┐
│ 10. JIT (jit.zig)                                   │
│     LLVM IR → zig cc -shared → .so → dlopen → exec │
│     Incremental: previous .so linked into new ones  │
└─────────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────────┐
│ OR AOT (aot.zig)                                    │
│     LLVM IR → zig cc → native binary (.o / elf)    │
│     WASM cross-compilation path                     │
└─────────────────────────────────────────────────────┘
```

---

## Stage Details

### 1. Parser — `parser.zig` (37 lines)

A thin Zig wrapper around the tree-sitter C library. It:
- Initialises a `TSParser` with the external `tree_sitter_mantiq()` language (compiled from `tree-sitter-mantiq/`)
- Exposes `parseString(source) → TSTree`
- The resulting `TSTree` is a **Concrete Syntax Tree** (CST) — a full-fidelity parse tree with whitespace and comments

**Key files:** `parser.zig`, `tree-sitter-mantiq/src/parser.c`

---

### 2. Lower — `lower.zig` (~2870 lines, largest lowering pass)

Converts the tree-sitter CST into the Mantiq **AST** (`ast.zig:Node`). This is the most substantial transformation pass:

| Responsibility | Details |
|---|---|
| CST→AST conversion | Walks tree-sitter nodes, constructs `ast.Node` tagged union variants |
| Macro expansion | `MacroDef` struct stores param names + body AST; invocation performs text substitution |
| Nizam strict mode | `StrictNizamViolation` error for Mantiq-only features in Nizam mode (e.g., classes) |
| Ternary lowering | `X if cond else Y` → AST `IfStmt` |
| Type annotation parsing | Recursive `lowerTypeAnnotation` for generics, tuples, function signatures |

**Entry point:** `Lowerer.lowerProgram(root_node) → *ast.Node`

---

### 3. Semantic Analysis — `sema.zig` (~850 lines)

Two-pass symbol resolution:

- **Pass 1 (declare):** Walks the AST to register all declarations (functions, variables, structs, classes, interfaces, enums, unions, imports) into symbol tables (`symbols.Scope`)
- **Pass 2 (resolve):** Resolves identifier references to their declarations, links `resolved_symbol` pointers on `Identifier` nodes

Additional responsibilities:
- **Module loading:** `resolveModulePath` searches `cwd → project root → $MANTIQ_VENDOR_PATH → ~/.mantiq/vendor/ → /usr/lib/mantiq/vendor/`
- **Circular dependency prevention:** via `loaded_modules` HashMap
- **Project root discovery:** `findProjectRoot` walks up directories looking for `nmproject.toml`, `mantiq.toml`, `nizam.toml`, `project.toml`, `mantiq-compiler/`, `std/`
- **Name mangling:** `mangleModuleName` — `mantiq_` prefix, `/ → __`, `. → _`
- **Built-in symbol injection:** Language-appropriate builtins injected for each `std.*` module
- **Closure capture analysis** (lines 662-684): Detects upvalues — variables accessed from an outer scope within a closure

**Entry point:** `SemanticAnalyzer.analyze(ast_root)`

---

### 4. CFG Analysis — `cfg.zig` (~90 lines)

Control flow graph analysis on the AST:

- **Return path completeness:** Verifies all execution paths in non-void functions end with `return`
- **Unreachable code detection:** Flags statements after guaranteed returns
- `WhileStmt` is treated as not guaranteeing a return (the condition could be false)

**Entry point:** `CFGAnalyzer.analyzeProgram(ast_root)`

---

### 5. Type Checking — `typecheck.zig` (~2530 lines, second largest)

Type inference, validation, and monomorphization:

| Component | Details |
|---|---|
| Type resolution | `validateType` converts `TypeAnnotation → Type` structs via `parseTypeString` |
| Generic monomorphization | `instantiateStruct` clones generic AST, substitutes type params, re-runs analysis |
| Generic function instantiation | Lines 770-870: `inferGenericBindings` algorithm |
| Nizam allocation rules | `ImplicitAllocationNotAllowed` fires for heap-allocating expressions in Nizam mode |
| Built-in functions | Lines 525-750: type inference for ~100+ built-in functions (math, string, IO, quantum, etc.) |
| Closure types | Tracked via `closure_types` AutoHashMap keyed by closure counter |

**Entry point:** `TypeChecker.checkProgram(ast_root)`

---

### 6. Borrow Checking — `borrowck.zig` (~386 lines)

Ownership tracking via a simple state machine:

- **ObjectState:** `Owned → Moved | Dropped`
- On assignment of a complex type, the source is **moved** (marked Moved)
- Subsequent uses of a Moved or Dropped variable trigger `UseAfterMoveError` / `UseAfterDropError`
- `VariableState` tracks `shared_borrows` / `mutable_borrows` (reserved for future reference-counting borrows)
- **Auto-drop injection:** `auto_drops` fields on `FunDecl`, `BlockStmt`, `ParamBlockStmt` are populated at scope exit
- **Context manager integration:** `is_context_manager` flag on symbols enables `with` statement semantics

**Entry point:** `BorrowChecker.checkProgram(ast_root)`

---

### 7. Dead Code Elimination — `dce.zig` (~192 lines)

Two-phase mark-and-sweep:

- **Phase 1 (Mark):** Walks the AST marking reachable nodes. Constant-folds boolean branch conditions (`if True` / `if False`) to prune unreachable arms
- **Phase 2 (Sweep):** Removes unmarked declarations and prunes dead branches
- **Quantum tree shaking:** If `std.quantum` is imported but no qbit/qreg types are used, the entire quantum import is pruned (zero-cost abstraction)

**Entry point:** `DeadCodeEliminator.optimizeProgram(ast_root)`

---

### 8. AST Merging — `mergeImportedDeclarations` (inline in `main.zig`)

Flattens the AST by inlining imported module ASTs into the root `Program.declarations` array. Uses a `merged_modules` set to prevent duplicate inlining (circular import guard).

**Entry point:** `mergeImportedDeclarations(allocator, ast_root, &merged_modules)`

---

### 9. Code Generation — `codegen.zig` (~4855 lines, largest file)

Converts the analyzed AST to an LLVM IR string:

| Component | Details |
|---|---|
| Type mapping | Primitives → LLVM native types; fat pointers (`{ptr, i64}`) for strings; `{ptr, ptr}` for `Any`; `{i1, ptr}` for `Option`; `{i8, ptr}` for `Result` |
| Auto-drops | `genAutoDrops` generates cleanup code at scope boundaries |
| Temporary lifetime | `statement_temporaries` / `registerTemp` / `consumeTemp` / `flushStatementTemps` — managed per-statement |
| Global variable handling | In script mode (no `main()`), an implicit `main` is generated wrapping global code |
| Parallel loops | `for@par` → closure outlining + trampoline function pattern |
| Struct/Union/Enum layouts | Emitted as LLVM struct types with computed padding |
| ABI | `byval` vs `coerce` vs `direct` based on type size (SysV x86_64) |

The `LLVMCodegen` struct maintains **four output buffers**:
- `out` — main function/global IR
- `outlined_out` — outlined closures and parallel loop trampolines
- `type_out` — type definitions
- `metadata_out` — debug metadata

**Entry point:** `LLVMCodegen.generate(ast_root) → []const u8` (LLVM IR string)

---

### 10. JIT — `jit.zig` (~116 lines)

Just-In-Time compilation via a **compile-link-load-execute** strategy:

1. Write LLVM IR to `{name}_jit.ll`
2. Run `zig cc -shared -fPIC {name}_jit.ll src/runtime.c -O3 -o lib{name}_jit.so -lmimalloc -lpthread`
3. `dlopen` the `.so` and call the `main()` entry point
4. Keep the `.so` loaded and linked into subsequent snippets (incremental REPL)

**Incremental linking:** Each new snippet is linked against all previous `.so` files, enabling cross-snippet symbol resolution.

**Cleanup:** `.ll` files deleted immediately; `.so` files kept until `deinit`.

---

### 11. AOT — `aot.zig` (~101 lines)

Ahead-Of-Time compilation to native binaries:

1. Write LLVM IR to `{name}.ll`
2. Run `zig cc {name}.ll src/runtime.c -O3 -o {name} -lmimalloc`
3. Supports WASM cross-compilation (`-target wasm32-wasi`, `--no-entry`, `-nostdlib`)
4. If no `main()` entry point is found → compiles to a `.o` object file instead
5. `link` statements in source map to `-l` flags

**Entry point:** `AOTCompiler.compile(ir, name, target, as_object, link_targets)`

---

## Key Data Structures

### AST (ast.zig)

```
Node
├── node_type: NodeType   (46 variants: Program, FunDecl, VarDecl, IfStmt, etc.)
├── span: Span            (source location)
├── data: NodeData         (tagged union matching node_type)
├── inferred_type: ?Type   (set by typecheck)
└── module_name: ?[]const u8
```

### Type System (types.zig)

```
Type
├── kind: TypeKind         (40+ variants: I32, String, Struct, Function, QBit, etc.)
├── payload: ?*Type        (generic/collection element type)
├── tuple_types: ?[]Type
├── function: ?*FunctionType
├── struct_type: ?*StructType
├── enum_type: ?*EnumType
├── union_type: ?*UnionType
├── closure_id: ?u32
├── array_len: ?usize
└── module_scope: ?*anyopaque
```

### Symbol Table (symbols.zig)

```
Symbol
├── name: []const u8
├── kind: SymbolType      (Variable, Function, Class, Struct, Interface, Enum, Union, Module)
├── decl_node: ?*Node
├── sym_type: ?TypeKind
├── module_scope: ?*Scope
└── is_context_manager: bool

Scope (linked list)
├── parent: ?*Scope
├── symbols: HashMap(name → *Symbol)
└── closure_node: ?*Node
```

---

## Operating Modes

### 1. Test-Suite Mode (default)

`main.zig` runs a battery of ~50 inline integration tests in `runTests()`. Each test:
1. Parses a hardcoded source string
2. Runs the full pipeline (parse → lower → sema → cfg → typecheck → borrowck → dce → merge → codegen → JIT → AOT)
3. Prints pass/fail for each stage

This is the primary development workflow — tests are embedded in `main.zig` rather than a separate test framework.

### 2. REPL Mode

`./mantiq repl [nizam]` — interactive read-eval-print loop:
- Maintains persistent state across snippets (`SemanticAnalyzer`, `TypeChecker`, `JITCompiler`)
- Each snippet is compiled and JIT-evaluated incrementally
- Previous `.so` files are linked into new snippets (cross-snippet symbol resolution)
- Supports both Mantiq and Nizam language modes

### 3. File Compilation Mode

**Not yet implemented.** The CLI currently only supports test-suite and REPL modes. The intended flow would be:
- `mantiq build file.mq` → parse → pipeline → AOT output binary
- `mantiq run file.mq` → parse → pipeline → JIT execute

Flags supported today:
- `--show-ir` — prints generated LLVM IR
- `--debug` — enables debug logging

---

## Runtime Library — `runtime.c` (~877 lines)

The C runtime provides:
- **SIMD/parallel execution:** `__mantiq_parallel_for` — thread pool dispatcher for `for@par`
- **Quantum simulation:** State-vector simulator with 16-qubit limit (`Complex global_state[65536]`), Hadamard, CNOT, measure operations
- **Concurrency:** `MantiqTask` / `mantiq_spawn` / `mantiq_await` — actor-based model using pthreads
- **Hash table:** `MantiqDict` — open-addressing hash table
- **Process args:** `mantiq_process_args` — parses `/proc/self/cmdline`
- **Memory:** Optional mimalloc integration (falls back to libc malloc)

The runtime is compiled and linked in at both JIT and AOT stages via `zig cc src/runtime.c`.

---

## Build System — `build.zig`

The compiler is built with Zig's build system:
- `zig build` — builds the compiler executable
- Links against the tree-sitter C library
- Statically links mimalloc
- Generates the final binary at `zig-out/bin/mantiq`
