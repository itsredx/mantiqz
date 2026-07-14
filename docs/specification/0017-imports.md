# Language Specification: Imports and Modules

## Overview

The import system provides cross-file code reuse through module resolution, selective symbol import, optional namespace aliasing, and built-in module injection. All modules are recursively parsed, analyzed, and type-checked, then merged into a single AST for code generation.

---

## 1. Import Syntax

### 1.1 Grammar

Three syntactic forms (two style variants) are supported:

```js
// Form 1 — import with optional tag, alias
import_decl: $ => seq(
    'import',
    optional(seq('[', field('tag', $.identifier), ']')),
    choice($.module_path, $.string),
    optional(seq('as', $.identifier)),
    $._newline
)

// Form 2 — from ... import ...
import_decl: $ => seq(
    'from', $.module_path, 'import', commaSep1($.identifier),
    $._newline
)

// Form 3 — import symbol from ...
import_decl: $ => seq(
    'import', $.identifier, 'from', $.module_path,
    $._newline
)
```

### 1.2 Syntax Examples

```nizam
// Form 1: basic import with optional alias
import math                              // import module as "math"
import math as m                         // import module as "m"
import[vendor] json                      // vendor-tagged import
import[path] "/home/lib/mylib.nz"        // exact path import
import[c] "sqlite3"                      // C library link import
import[pkg] libcurl                      // system package import

// Form 2: selective import
from math import pi, sin, cos            // import specific symbols

// Form 3: import-symbol-from
import sin from math                     // import single symbol
```

### 1.3 Import Tags

| Tag | Semantics |
|-----|-----------|
| *(no tag)* | Standard module search in language search paths |
| `[vendor]` | Search `vendor/` directory in project root |
| `[path]` | Exact file path — no search path resolution |
| `[c]` | C library — link declaration, no parsing (LLVM `-l`) |
| `[pkg]` | System package — link declaration only |

### 1.4 Link Declaration

```js
link_decl: $ => seq(
    'link', optional(seq('[', field('tag', $.identifier), ']')), $.string,
    $._newline
)
```

```nizam
link[c] "m"
link[pkg] "ssl"
```

---

## 2. AST

### 2.1 ImportKind

```zig
// ast.zig:53-59
pub const ImportKind = enum {
    normal,
    path,
    vendor,
    c,
    pkg,
};
```

### 2.2 ImportDecl

```zig
// ast.zig:126-132
ImportDecl: struct {
    kind: ImportKind = .normal,
    target: []const u8,                // module path or filename
    imported_symbols: [][]const u8,    // selective import list
    alias: ?[]const u8,               // optional namespace alias
    module_ast: ?*Node = null,        // populated after recursive analysis
},
```

### 2.3 LinkDecl

```zig
// ast.zig:133-136
LinkDecl: struct {
    kind: ImportKind = .normal,
    target: []const u8,
},
```

### 2.4 module_name on every Node

```zig
// ast.zig:119
pub const Node = struct {
    // ...
    module_name: ?[]const u8 = null,   // LLVM-mangled namespace prefix
};
```

---

## 3. Lowering (CST → AST)

**File:** `lower.zig:322-391` / `lower.zig:393-431`

For each `import_decl` CST node, `lowerImportDecl`:

1. Extracts the `tag` field → determines `ImportKind`
2. Extracts the `module_path` (dotted) or `string` literal → `target`
3. Extracts comma-separated `identifier` nodes → `imported_symbols`
4. Extracts `alias` if `as` keyword is present
5. Creates an `ImportDecl` node with `.module_ast = null` (filled later)

```zig
return self.createNode(.ImportDecl, span, .{
    .ImportDecl = .{
        .kind = kind,
        .target = try target_path.toOwnedSlice(),
        .imported_symbols = try imported_symbols.toOwnedSlice(),
        .alias = alias,
    },
});
```

---

## 4. Module Resolution

### 4.1 Project Root

**File:** `sema.zig:29-71`

The project root is found by walking up from CWD until one of these markers is found:

- `nmproject.toml`, `mantiq.toml`, `nizam.toml`, `project.toml`
- `mantiq-compiler/` directory
- `std/` directory

Falls back to `"."`.

### 4.2 Name Mangling

**File:** `sema.zig:73-88`

```zig
// "std.collections" → "mantiq_std_collections"
// "my/module"       → "mantiq_my__module"
```

Prefix `mantiq_`, replace `.` with `_`, replace `/` with `__`.

### 4.3 Search Paths

**File:** `sema.zig:90-160`

Resolution depends on `ImportKind`:

| Kind | Search Roots |
|------|-------------|
| `normal` | `./` (CWD); if target starts with `std.`, also project root |
| `vendor` | `<project_root>/vendor/`, `$MANTIQ_VENDOR_PATH`, `~/.mantiq/vendor/`, `/usr/lib/mantiq/vendor/` |
| `path` | Direct file — no search |
| `c` | Not a file — link declaration |
| `pkg` | Not a file — link declaration |

For each root, tries `<root>/<path>.nz` then `<root>/<path>.mq`. If `<path>/` is a directory, tries `<path>/main.nz` then `<path>/main.mq`.

### 4.4 File Lookup Algorithm

```zig
for (search_roots.items) |root| {
    // Try:
    //   <root>/<path>.nz
    //   <root>/<path>.mq
    //   <root>/<path>/main.nz  (directory-as-module)
    //   <root>/<path>/main.mq
    for (extensions) |ext| {
        for (paths) |p| {
            if (std.fs.cwd().access(path, .{})) return path;
        }
    }
}
return error.FileNotFound;
```

---

## 5. Semantic Analysis — Module Loading

**File:** `sema.zig:270-469`

### 5.1 C Imports

`.kind == .c` → skipped entirely. No parsing, no analysis. Used later by codegen/AOT for linker flags.

### 5.2 Built-in Module Injection

Certain `std.*` targets are recognized as built-in and their symbols are injected directly into the importer's scope **without** file loading:

| Module | Injected Symbols |
|--------|------------------|
| `std.quantum` | `qbit`, `qreg`, `H`, `measure`, `CNOT`, `X`, `Y`, `Z` |
| `std.mem` | `make`, `drop`, `resize` |
| `std.io` | `print`, `println`, `stdin`, `stdout`, `stderr`, `write`, `read` |
| `std.fs` | `open`, `close`, `read`, `write`, `exists` |
| `std.process` | `exit`, `args` |
| `std.time` | `now`, `sleep` |
| `std.sys` | `os`, `arch`, `getenv`, `setenv`, `unsetenv` |
| `std.option` | `Option`, `Some`, `Empty` |
| `std.result` | `Result`, `Ok`, `Err` |

Injection is gated by `imported_symbols` — only requested symbols are injected. If `imported_symbols` is empty, all are injected.

### 5.3 File-Based Module Loading

For non-built-in imports:

1. **Resolve** the module file path via `resolveModulePath`
2. **Determine namespace name** — last path component, or alias if provided
3. **Mangle LLVM namespace** via `mangleModuleName`
4. **Check cache** in `loaded_modules` (skip re-parsing if already loaded)
5. **Parse and lower** the module file into its own AST
6. **Set `module_name`** on all declarations in the module AST
7. **Recurse** — analyze the module with a fresh `SemanticAnalyzer` (sharing `loaded_modules` for cycle avoidance)
8. **Type-check** the module with a fresh `TypeChecker`
9. **Cache** module scope in `loaded_modules`
10. **Define** a `Module`-type symbol in the importer's current scope
11. **Selective import** — if `imported_symbols` is non-empty, re-define requested symbols directly

```zig
// Module symbol definition
const mod_sym = try self.allocator.create(symbols.Symbol);
mod_sym.* = .{
    .name = mod_ns_name,
    .kind = .Module,
    .decl_node = node,
    .module_scope = target_scope,
};
try self.current_scope.define(mod_sym);
```

### 5.4 Recursive Loading and Cycle Avoidance

**File:** `sema.zig`

`loaded_modules: std.StringHashMap(*symbols.Scope)` acts as a cache and cycle breaker:

```zig
if (self.loaded_modules.get(i.target)) |scope| {
    // Already loaded — reuse cached scope, skip re-parsing
    target_scope = scope;
} else {
    // Fresh parse, analyze, type-check
    // ... store in loaded_modules ...
    try self.loaded_modules.put(i.target, sa.global_scope);
}
```

If module A imports module B which imports module A, the second encounter returns the cached (possibly incomplete) scope.

---

## 6. Type Checking — Cross-Module Integration

**File:** `typecheck.zig:100-213`

### 6.1 Nizam Gate Flags

```zig
is_string_imported: bool = false,
is_list_imported: bool = false,
is_dict_imported: bool = false,
is_option_imported: bool = false,
is_result_imported: bool = false,
```

In Nizam mode, `String`, `List`, `Dict`, `Option`, and `Result` are only valid type annotations if the corresponding import flag is set. Mantiq mode has no such restriction.

### 6.2 Import Flag Detection (Phase 1-2)

**Phase 1** (line 105-127): If the current module itself defines `String`/`List`/`Dict`/`Option`/`Result` structs or unions, auto-set the flag (self-contained module).

**Phase 2** (line 130-166): Scan `ImportDecl` nodes for built-in targets (`std.collections`, `std.option`, `std.result`) and check `imported_symbols` for the relevant names.

**Phase 3** (line 169-213): For modules with `.module_ast`:
- Set flags based on what the imported module exports
- Recursively type-check sub-modules (with cycle prevention via `typechecked_modules`)
- Register mangled type names (e.g. `mantiq_std_collections_List`) into the importer's type registries under short name aliases (e.g. `List`)

### 6.3 Module Type Inference

```zig
// typecheck.zig:504-505
if (sym.kind == .Module) {
    node.inferred_type = .{ .kind = .Module, .module_scope = sym.module_scope };
}
```

### 6.4 Type Name Registration Across Modules

**File:** `typecheck.zig:1476-1488`

```zig
if (node.module_name) |mod_name| {
    struct_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, s.name });
}
// Register short name for selective imports
if (node.module_name) |_| {
    try self.struct_types.put(s.name, struct_name);
}
```

---

## 7. AST Merging

**File:** `main.zig:1522-1542`

After type-checking, all imported module declarations are merged into a single flattened AST:

```zig
fn mergeImportedDeclarations(allocator, program, merged_modules) {
    for (program declarations) |decl| {
        if (decl is ImportDecl with module_ast) {
            // Recursively merge sub-module
            // Inline all sub-module declarations into parent
            for (sub_ast.declarations) |sub_decl| {
                new_decls.append(sub_decl);
            }
        }
        new_decls.append(decl);  // keep non-ImportDecls
    }
    program.declarations = new_decls.toOwnedSlice();
}
```

This is invoked in the pipeline after type-checking and DCE, before code generation.

---

## 8. Code Generation

**File:** `codegen.zig`

### 8.1 ImportDecl / LinkDecl — Skipped

```zig
// codegen.zig:1961-1963
.ImportDecl, .LinkDecl => {
    // Dependencies/metadata handled during compilation pipeline
},
```

Import nodes are no-ops in codegen. Their declarations have been inlined during AST merging.

### 8.2 Module Name Prefixing

All global symbols from imported modules are prefixed with the mangled module name:

```zig
// Global variables:   @mantiq_std_math_pi
// Functions:          @mantiq_std_math_sin
// Struct types:       %mantiq_std_math_Vector
```

### 8.3 Module Member Access

**File:** `codegen.zig:4308-4336`

When a `MemberExpr` has a `.Module`-typed object:

```zig
if (obj_inferred.kind == .Module) {
    if (obj_inferred.module_scope) |scope_ptr| {
        const mod_scope = @as(*symbols.Scope, @ptrCast(@alignCast(scope_ptr)));
        if (mod_scope.resolveLocal(m.property)) |sym| {
            // Use sym.decl_node.module_name as namespace prefix
            return try std.fmt.allocPrint(self.allocator, "@{s}_{s}",
                .{ llvm_ns_name, m.property });
        }
    }
}
```

### 8.4 Module Function Calls

**File:** `codegen.zig:3106-3114`

```zig
if (me_obj_type.kind == .Module) {
    module_func_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}",
        .{ me.object.data.Identifier.name, me.property });
}
```

### 8.5 LinkDecl — Linker Flags

`LinkDecl` nodes are collected during compilation (`main.zig:1353-1358`) and passed to the AOT linker as `-l` flags.

---

## 9. Pipeline Order

```
Parse → Lower → Sema → CFG → Typecheck → Borrowck → DCE → MergeImports → Codegen → JIT/AOT
```

| Stage | Module Handling |
|-------|----------------|
| Parse | Source file → CST |
| Lower | CST → AST (ImportDecl nodes with module_ast = null) |
| Sema | Module resolution, parsing, analysis, caching |
| CFG | (unchanged for imports) |
| Typecheck | Cross-module type registration, Nizam gate flags |
| Borrowck | (unchanged for imports) |
| DCE | Dead code elimination |
| MergeImports | Flatten imported ASTs into parent |
| Codegen | LLVM IR with mangled names |
| JIT/AOT | Link with LinkDecl libraries |

---

## 10. Nizam Mode Gating

In Nizam (safe) mode, these types require `import` before use:

| Type | Required Import |
|------|-----------------|
| `String` | `from std.collections import String` |
| `List[T]` | `from std.collections import List` |
| `Dict[K, V]` | `from std.collections import Dict` |
| `Option[T]` | `from std.option import Option` |
| `Result[T, E]` | `from std.result import Result` |

```zig
// typecheck.zig:249-275
if (self.mode == .nizam and !self.is_string_imported and
    std.mem.eql(u8, name, "String")) {
    std.debug.print("Type Error: 'String' requires 'from std.collections import String'\n", .{});
    return error.ImplicitAllocationNotAllowed;
}
```

Mantiq (unsafe) mode allows these types without imports.

---

## 11. Standard Library Module Index

| Module Path | File | Contents |
|-------------|------|----------|
| `std.collections` | `std/collections.nz` | `Set[T]` |
| `std.string` | `std/string.nz` | `String`, `StringBuilder` |
| `std.math` | `std/math.nz` | Math functions |
| `std.path` | `std/path.nz` | Path utilities |
| `std.text` | `std/text.nz` | Text/unicode handling |
| `std.option` | *(built-in)* | `Option`, `Some`, `Empty` |
| `std.result` | *(built-in)* | `Result`, `Ok`, `Err` |
| `std.mem` | *(built-in)* | `make`, `drop`, `resize` |
| `std.io` | *(built-in)* | `print`, `println`, `stdin`, `stdout`, `stderr` |
| `std.fs` | *(built-in)* | `open`, `close`, `read`, `write`, `exists` |
| `std.process` | *(built-in)* | `exit`, `args` |
| `std.time` | *(built-in)* | `now`, `sleep` |
| `std.sys` | *(built-in)* | `os`, `arch`, `getenv`, `setenv` |
| `std.quantum` | *(built-in)* | `qbit`, `qreg`, `H`, `measure`, `CNOT`, `X`, `Y`, `Z` |

---

## 12. Examples

### Basic Module Import

```nizam
// math.mq
fn add(a as i32, b as i32) as i32:
    return a + b

// main.nz
import math

fn main():
    print(math.add(1, 2))
```

### Selective Import

```nizam
// utils.nz
fn multiply(a as i32, b as i32) as i32:
    return a * b

fn divide(a as i32, b as i32) as i32:
    return a / b

// main.nz
from utils import multiply

fn main():
    print(multiply(3, 4))
    // divide() is not accessible
```

### Aliased Import

```nizam
from std.math import sin, cos as cosine

fn main():
    print(sin(3.14))
    print(cosine(0.0))
```

### Import with Namespace Alias

```nizam
import math as m

fn main():
    print(m.pi)
```

### Vendor Import

```nizam
import[vendor] json

fn main():
    print(json.parse("{}"))
```

### C Library Import

```nizam
import[c] "sqlite3"

fn main():
    // sqlite3 functions available via FFI
```

---

## 13. Relevant Files

| File | Lines | Role |
|------|-------|------|
| `grammar.js` | 48-49, 66-80, 291-297 | Import/link/module_path grammar |
| `ast.zig` | 53-59, 64-65, 119, 126-136 | ImportKind, ImportDecl, LinkDecl |
| `lower.zig` | 180-181, 322-431 | CST→AST lowering for imports |
| `sema.zig` | 29-71 | `findProjectRoot` |
| `sema.zig` | 73-88 | `mangleModuleName` |
| `sema.zig` | 90-160 | `resolveModulePath` |
| `sema.zig` | 165-193 | Built-in initialization |
| `sema.zig` | 270-469 | ImportDecl semantic analysis |
| `symbols.zig` | 5-63 | `Symbol`, `Scope` with Module support |
| `types.zig` | 52, 122-135 | `TypeKind.Module`, module scope |
| `typecheck.zig` | 37-41 | Nizam gate flags |
| `typecheck.zig` | 69-98, 100-213 | Import type checking, flag detection |
| `typecheck.zig` | 249-275 | Nizam type validation gating |
| `typecheck.zig` | 504-505 | Module type inference |
| `typecheck.zig` | 1476-1488 | Module name prefixing on types |
| `codegen.zig` | 1961-1963 | ImportDecl/LinkDecl skip |
| `codegen.zig` | 3106-3114 | Module function call |
| `codegen.zig` | 4308-4336 | Module member access |
| `codegen.zig` | (many lines) | Module name prefixing |
| `main.zig` | 1316-1320, 1522-1542 | AST merging pipeline |
| `docs/decisions/0030-import-module-resolution.md` | Full | Decision record for imports |
| `docs/decisions/0011-package-level-modules.md` | Full | Package-level module design |
