# Decision 0039: CLI Compilation and Execution Modes

## Context

To prepare for compiler self-hosting, the Mantiq/Nizam compiler needs a robust CLI capable of compiling source files directly into standalone native executables (AOT) and running them directly via JIT execution.

Currently, the compiler's CLI only supports:
1. `repl` mode (`mantiq repl [nizam]`)
2. `test-suite` mode (runs inline integration tests when no arguments are provided)
3. Direct file invocation, which runs both JIT and AOT compilation under `testPipeline` and prints verbose test diagnostics to `stdout`.

We need dedicated `build` and `run` commands that compile and run programs cleanly, support custom output names (`-o`), pass arguments through to the target program, and suppress test-suite diagnostics.

---

## Proposed CLI Design

The command-line syntax supports dual compiler executables (`mantiq` and `nizam`):

```bash
# Default (runs interactive REPL in the respective mode)
$ mantiq
$ nizam

# Compilation (AOT)
$ mantiq build <input_file> [-o <output_file>] [-target <target>] [--show-ir] [--debug]
$ nizam build <input_file> [-o <output_file>] [-target <target>] [--show-ir] [--debug]

# Execution (JIT)
$ mantiq run <input_file> [--show-ir] [--debug] [program_arguments...]
$ nizam run <input_file> [--show-ir] [--debug] [program_arguments...]

# Interactive REPL (explicitly choosing mode)
$ mantiq repl [nizam|mantiq] [--show-ir] [--debug]
$ nizam repl [nizam|mantiq] [--show-ir] [--debug]

# Run Integration Tests
$ mantiq test
$ nizam test
```

### Semantics

1. **Default Mode Selection (by binary name):**
   - If the compiler binary name (`args[0]`) contains `nizam`, it defaults the language mode to **Nizam**.
   - Otherwise, it defaults the language mode to **Mantiq**.

2. **Language Mode Inference (by file extension):**
   - File extension `.nz` compiles in strict **Nizam** mode.
   - File extension `.mq` compiles in dynamic **Mantiq** mode.
   - Files with no extension or unknown extensions default to the binary-defined mode.

3. **Portability and Self-Containment:**
   - The compiler runtime helper (`runtime.c`) is embedded directly into the compiler executables (`mantiq` and `nizam`) using `@embedFile`.
   - The executables can be moved to any directory (e.g. `$HOME` or a different Linux system) and will compile/run program code without requiring source directory paths.
   - Dependencies: The host machine must have `zig` (for C compilation toolchain) and `libmimalloc` (development package) installed.

4. **Diagnostics Suppression:**
   - Direct execution via `build` and `run` will suppress all parser/compilation status output on `stdout` (e.g. `=== Test: ... ===`, `LOWERTYPE: ...`, `Compilation pipeline successful!`).
   - Compiler errors (syntax errors, type mismatches, etc.) are printed to `stderr` and the compiler exits with code `1`.

5. **Output File Naming (`build`):**
   - If `-o <output_file>` is specified, the native binary is written to that path.
   - Otherwise, the output filename defaults to the input filename with the extension removed.

---

## Implementation Details

### Pipeline Extraction
The compiler pipeline steps in `main.zig` will be refactored into a reusable function:
```zig
fn runPipeline(
    allocator: std.mem.Allocator,
    p: *parser.Parser,
    source_code: []const u8,
    mode: ast.LanguageMode,
    file_path: []const u8,
) ![]const u8 // returns LLVM IR
```

### Build command
`build` invokes `runPipeline`, passes the LLVM IR to `AOTCompiler.compile()`, and exits. JIT execution is skipped.

### Run command
`run` invokes `runPipeline`, evaluates the LLVM IR using `JITCompiler.evaluate()`, and exits. AOT compilation is skipped.

---

## Examples

### Compilation
```bash
$ mantiq build hello.nz -o hello
$ ./hello
Hello, World!
```

### Direct JIT Execution
```bash
$ mantiq run hello.nz
Hello, World!
```
