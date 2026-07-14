# Decision 0035: REPL Architecture

## Context

The Mantiq/Nizam REPL enables interactive code exploration and rapid prototyping. Unlike file-based compilation (which runs once and exits), the REPL must maintain persistent state across evaluations: global scope, type definitions, function declarations, variable bindings, and macro definitions. It uses a **compile-link-load JIT** backend.

---

## Language Interface

### Usage

```
mantiq-compiler repl              # Mantiq mode (dynamic)
mantiq-compiler repl nizam        # Nizam mode (strict)
```

### Prompt

```
mantiq> 1 + 1
2
mantiq> let x = 42
mantiq> print(x)
42
mantiq> macro assert_eq(a, b):
...     if a != b:
...         print(f"{a} != {b}")
...
mantiq> assert_eq!(1, 2)
1 != 2
```

---

## Architecture Overview

### Entry Point

**File:** `main.zig:31-59`

```zig
if (args.len > 1 and std.mem.eql(u8, args[1], "repl")) {
    var mode: ast.LanguageMode = .Mantiq;
    if (args.len > 2 and std.mem.eql(u8, args[2], "nizam")) {
        mode = .Nizam;
    }
    try startRepl(allocator, stdout, mode);
    return;
}
```

### Pipeline per Snippet

Each REPL snippet goes through the full compilation pipeline:

```
Input → Parse → Lower → Sema → CFG → Typecheck → Borrowck → DCE → MergeImports → Codegen → JIT
```

---

## Persistent State

**Decision: Reuse compiler state across evaluations.** The REPL holds these persistent objects:

| State | Type | Purpose |
|-------|------|---------|
| **Arena allocator** | `std.heap.ArenaAllocator` | Lives until REPL exit — all AST/IR data allocated here |
| **Semantic analyzer** | `sema.SemanticAnalyzer` | Holds `global_scope` — each snippet adds declarations |
| **Type checker** | `typecheck.TypeChecker` | Reused across snippets |
| **Global variables** | `std.StringHashMap([]const u8)` | Maps global names to LLVM type strings |
| **Macros** | `std.StringHashMap(lower.MacroDef)` | Macro definitions persist across snippets |
| **JIT compiler** | `jit.JITCompiler` | Holds loaded `.so` handles and file paths |
| **Snippet counter** | `u32` | Unique names: `repl_snippet_N` |

```zig
// main.zig:1395-1412
var arena = std.heap.ArenaAllocator.init(allocator);
var analyzer = sema.SemanticAnalyzer.init(arena.allocator(), mode);
var tc = typecheck.TypeChecker.init(arena.allocator(), mode);
var jit_compiler = jit.JITCompiler.init(allocator);
var global_vars = std.StringHashMap([]const u8).init(arena.allocator());
var macros = std.StringHashMap(lower.MacroDef).init(arena.allocator());
var snippet_count: u32 = 1;
```

---

## JIT Backend: Compile-Link-Load

**Decision: Not an ORC JIT.** Each snippet is compiled via `zig cc` to a shared library, then loaded with `dlopen`.

**File:** `jit.zig`

### Per-Snippet Steps

1. **Write LLVM IR** to `repl_snippet_N_jit.ll`
2. **Compile**: `zig cc -shared -fPIC {.ll} src/runtime.c {prev .so files...} -O3 -o librepl_snippet_N_jit.so`
3. **Load**: `dlopen("librepl_snippet_N_jit.so")`
4. **Execute**: `dlsym("main")` → call `main()`
5. **Keep open**: library handle stays in `loaded_libs`
6. **Clean up**: delete `.ll` file, keep `.so`

### Cross-Snippet Visibility

Previous `.so` files are passed as linker inputs to each new compilation:

```zig
// jit.zig:70-72
for (self.previous_so_files.items) |prev_so| {
    try args.append(prev_so);
}
```

This means globals, functions, and types defined in earlier snippets are link-resolved in later snippets.

---

## Synthetic `main` Generation

**Decision: Snippets without `main` are wrapped in a synthetic entry point.**

**File:** `codegen.zig:1052-1144`

When no `main` function is defined:

1. **Emit `external global`** declarations for all previously-compiled globals
2. **Emit new globals** as `@name = global type zeroinitializer`
3. **Emit functions and type definitions**
4. **Wrap in `define i32 @main()`** that initializes globals and executes statements

```llvm
@x = external global i32          ; from previous snippet
@y = global i32 zeroinitializer   ; from this snippet

define i32 @main() {
entry:
  store i32 42, ptr @y
  %t.0 = load i32, ptr @y
  call void @mantiq_print_i32(i32 %t.0)
  call void @mantiq_print_newline()
  ret i32 0
}
```

---

## Statement-Level Expression Printing

**Decision: Non-void statement-level expressions auto-print with newline.**

**File:** `codegen.zig:1964-1973`

```zig
else => {
    // Evaluate expression and print value
    const val = try self.genExpr(node);
    const ty = node.inferred_type orelse .{ .kind = .Any };
    if (ty.kind != .Void and !std.mem.eql(u8, val, "null")) {
        try self.printValue(writer, val, ty);
        try writer.print("  call void @mantiq_print_newline()\n", .{});
    }
},
```

```
mantiq> 42 + 1
43
mantiq> "hello" ++ " world"
hello world
```

---

## Error Recovery

**Decision: Errors print and return; REPL loop continues.**

Each pipeline stage in `replEvaluate` has its own `catch`:

```zig
analyzer.analyze(ast_root) catch |err| {
    try stdout.print("Semantic Error: {}\n", .{err});
    return;  // return from replEvaluate, not from REPL loop
};
```

The REPL loop itself catches errors from the evaluate function:

```zig
replEvaluate(...) catch |err| {
    try stdout.print("REPL Error: {}\n", .{err});
};
snippet_count += 1;  // always increments
```

This contrasts with file compilation where `try` propagates errors up.

---

## CLI Options

| Flag | Effect |
|------|--------|
| `--show-ir` | Print generated LLVM IR for each snippet |
| `--debug` | Enable verbose debug output |

```zig
// ast.zig:20-27
pub var show_ir: bool = false;
pub var show_debug: bool = false;
```

---

## REPL Loop

**File:** `main.zig:1387-1456`

```
while True:
    Print "mantiq> " or "nizam> " prompt
    Read line from stdin
    Trim input
    If "exit" / "quit": break
    If empty: continue
    Append '\n' (tree-sitter requirement)
    replEvaluate(snippet)    // runs full pipeline with persistent state
    snippet_count += 1
    Print newline
```

---

## Macro Persistence

**Decision: Macro definitions persist across REPL evaluations.**

The `macros` HashMap is allocated from the persistent arena and passed to every `Lowerer` instance. Macros defined in one snippet are available for invocation in later snippets:

```zig
// Snippet 1
mantiq> macro twice(x):
...     x * 2
...

// Snippet 2
mantiq> twice!(21)
42
```

---

## Example Session

```
$ mantiq-compiler repl nizam
Welcome to the Nizam (Persistent) REPL.
Type your code and press Enter. (Persistent snippet evaluation mode)
Type 'exit' or press Ctrl+C to quit.

nizam> fn add(a as i32, b as i32) as i32:
...     return a + b
...
nizam> add(1, 2)
3
nizam> let x = 10
nizam> add(x, 5)
15
nizam> exit
```

---

## Limitations

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| High per-snippet latency | Each eval compiles via `zig cc` (~seconds) | Implement ORC JIT for incremental compilation |
| No state reset | No way to clear global scope without restarting REPL | Add `reset` command |
| No multi-line editing | No readline/linenoise support | Integrate a TUI library |
| No history | Previous commands not recallable | Add line history |
| No tab completion | No symbol completion | Implement completion via scope walk |
| No `--show-ast` flag | Can't inspect AST structure | Add flag to dump AST |

---

## Relevant Files

| File | Lines | Role |
|------|-------|------|
| `main.zig` | 31-59 | CLI dispatch (repl vs test) |
| `main.zig` | 1387-1456 | `startRepl` — REPL loop with prompt, read, dispatch |
| `main.zig` | 1458-1536 | `replEvaluate` — per-snippet pipeline with persistent state |
| `jit.zig` | 1-128 | `JITCompiler`: write .ll, zig cc, dlopen, dlsym, call |
| `codegen.zig` | 1052-1144 | Script mode: external globals + synthetic main |
| `codegen.zig` | 1964-1973 | Statement-level expression auto-print |
| `lower.zig` | 29-32, 38-39 | MacroDef storage, persistent macros map |
| `sema.zig` | 1402 | Reused SemanticAnalyzer with persistent global_scope |
| `ast.zig` | 20-27 | `show_ir` / `show_debug` flags |
| `runtime.c` | 472-500 | Runtime read/write for stdout/stdin |
