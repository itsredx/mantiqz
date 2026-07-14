# Decision 0030: Import System and Module Resolution

## Context

Mantiq and Nizam need an import system that supports:
1. **Module organisation** — splitting code across files and directories
2. **Namespace management** — qualified names (`std.string`) and selective imports
3. **Built-in injection** — certain modules inject symbols into the importer's scope directly (no filesystem lookup)
4. **Cross-language FFI** — importing C libraries and linking to native code
5. **Nizam strict-mode gating** — heap types require explicit imports in Nizam

The design avoids a package manager in favour of a simple filesystem-based resolution with vendor directories.

---

## Language Specification

### Feature: Import Syntax

Three syntactic forms, all lowered to the same `ImportDecl` AST node:

```nizam
import std.quantum                       // entire module as namespace
from std.quantum import H, CNOT          // selective symbols
import H from std.quantum                // single symbol (alternative form)
```

Tagged imports for non-default resolution:

```nizam
import[vendor] lib.strings               // search vendor paths only
import[c] lib.zlib                       // C library import (FFI, no parsing)
import[path] /absolute/path/my_module    // exact filesystem path
import[pkg] my_package                   // future: package manager integration
```

Optional alias:

```nizam
import std.collections as coll
from std.io import write as wr
```

### AST Representation

```zig
// ast.zig:126-132
ImportDecl: struct {
    kind: ImportKind = .normal,      // normal | path | vendor | c | pkg
    target: []const u8,              // dotted module path (e.g. "std.quantum")
    imported_symbols: [][]const u8,  // selective import list (empty = import all)
    alias: ?[]const u8,              // optional namespace alias
    module_ast: ?*Node = null,       // populated after recursive analysis
},
```

`kind` comes from the tag in `import[...]`:

| Tag | `ImportKind` | Behaviour |
|-----|-------------|-----------|
| *(none)* | `normal` | Search relative path first, then project root |
| `[vendor]` | `vendor` | Search `vendor/` directories only |
| `[c]` | `c` | C library — register as link dependency, no parsing |
| `[path]` | `path` | Exact filesystem path (no search) |
| `[pkg]` | `pkg` | Future package manager |

---

## Module Resolution Algorithm

### Project Root Detection

**Decision: Walk up from CWD looking for sentinel files.**

```zig
// sema.zig:29-71
fn findProjectRoot(allocator: std.mem.Allocator) ![]const u8 {
    // Walk up directory tree checking for:
    //   nmproject.toml, mantiq.toml, nizam.toml,
    //   project.toml, mantiq-compiler/, std/
    // Fallback to "." if not found
}
```

Order of sentinel checks, in each directory:
1. `nmproject.toml`
2. `mantiq.toml`
3. `nizam.toml`
4. `project.toml`
5. `mantiq-compiler/` (directory exists)
6. `std/` (directory exists — detected as compiler source tree)

### Search Order

**Decision: Different search strategies by import kind.**

**`normal` imports** (e.g. `import mylib.parser`):
1. Convert dots to path separators: `mylib.parser` → `mylib/parser`
2. Search `./mylib/parser.nz`, then `./mylib/parser.mq` (relative to CWD)
3. If path starts with `std.`, also search the project root (`<root>/std/strings.nz`)

**`path` imports**:
1. Try `<path>.nz` directly
2. Try `<path>.mq` directly
3. No search traversal

**`vendor` imports** (e.g. `import[vendor] lib.strings`):
1. `<project_root>/vendor/lib/strings.nz`
2. `<project_root>/vendor/lib/strings.mq`
3. `$MANTIQ_VENDOR_PATH/lib/strings.nz` / `.mq`
4. `~/.mantiq/vendor/lib/strings.nz` / `.mq`
5. `/usr/lib/mantiq/vendor/lib/strings.nz` / `.mq`
6. Also try `<base>/main.nz` / `<base>/main.mq` for directory-as-module

```zig
// sema.zig:90-159
fn resolveModulePath(self, module_path, kind) !struct { filename, mode } {
    if (kind == .path) { /* direct file lookup */ }
    
    var search_roots = ArrayList.init();
    if (kind == .vendor) {
        search_roots.append("<project_root>/vendor/");
        if (env $MANTIQ_VENDOR_PATH) search_roots.append(it);
        search_roots.append("~/.mantiq/vendor/");
        search_roots.append("/usr/lib/mantiq/vendor/");
    } else {
        search_roots.append("./");
        if (module_path starts with "std.")
            search_roots.append(project_root);
    }
    
    for (search_roots) |root| {
        try <root>/<path>.nz, then .mq
        if (vendor) also try <root>/<path>/main.nz, then .mq
    }
}
```

### Language Mode Detection

When a module file is found, its extension determines the `LanguageMode`:

| Extension | Mode |
|-----------|------|
| `.nz` | `Nizam` (strict subset) |
| `.mq` | `Mantiq` (full) |

The module is analysed in its own mode, independent of the importer's mode.

---

## Recursive Module Loading

**Decision: Each module is analysed in a fresh semantic analyser, sharing the `loaded_modules` cache.**

When `declarePass1` encounters an `ImportDecl` with a non-built-in target (`sema.zig:364-468`):

1. **Check `loaded_modules` cache** — if already loaded, reuse the global scope
2. **Open file** and read source
3. **Parse** with tree-sitter
4. **Lower** CST to AST
5. **Inject** `module_name` (LLVM-mangled namespace) on all declarations in the module AST
6. **Analyse** with a fresh `SemanticAnalyzer` (shares `loaded_modules` to prevent cycles)
7. **Typecheck** with a fresh `TypeChecker`
8. **Store** the module's global scope into `loaded_modules`
9. **Define** the module symbol in the importer's current scope
10. **Selective import**: if `imported_symbols` is non-empty, resolve each name from the module scope and define it directly in the importer's scope

```zig
// sema.zig:383-455 (simplified)
if (self.loaded_modules.get(target)) |scope| {
    target_scope = scope;  // cache hit — skip load
} else {
    // Parse, lower, set module_name on declarations
    var sa = try SemanticAnalyzer.init(...);
    sa.loaded_modules = self.loaded_modules;  // share cache
    sa.analyze(ast_root);                     // recursive sema
    self.loaded_modules = sa.loaded_modules;
    self.loaded_modules.put(target, sa.global_scope);
    // Typecheck the module
    var tc = TypeChecker.init(...);
    tc.checkProgram(ast_root);
    i.module_ast = ast_root;                  // store for codegen
}
// Define module symbol in importer scope
```

### Module Name Mangling

**Decision: `mantiq_` prefix, `/` → `__`, `.` → `_`.**

```zig
// sema.zig:73-88
fn mangleModuleName(target: []const u8) ![]const u8 {
    // "std.collections" → "mantiq_std_collections"
    // "my/module" → "mantiq_my__module"
}
```

This mangled name is set as `module_name` on every declaration in the module's AST before semantic analysis:

```zig
// sema.zig:404-419
for (ast_root.data.Program.declarations) |sub_decl| {
    sub_decl.module_name = llvm_ns_name;
    // Also set on methods of structs, unions, classes
}
```

In codegen, `module_name` prefixes the LLVM symbol:

```zig
// codegen.zig — various locations
if (decl.module_name) |mod_name| {
    try writer.print("@{s}_{s} ", .{ mod_name, func_name });
}
```

---

## Built-in Module Injection

**Decision: Certain `std.*` modules inject symbols directly into the importer's scope without filesystem lookup.**

Instead of opening a file, the semantic analyser recognises these modules by name and injects their symbols as built-in declarations:

| Module | Injected Symbols |
|--------|-----------------|
| `std.quantum` | `qbit`, `qreg`, `H`, `measure`, `CNOT`, `X`, `Y`, `Z` |
| `std.mem` | `make`, `drop`, `resize` |
| `std.io` | `print`, `println`, `stdin`, `stdout`, `stderr`, `write`, `read` |
| `std.fs` | `open`, `close`, `read`, `write`, `exists` |
| `std.process` | `exit`, `args` |
| `std.time` | `now`, `sleep` |
| `std.sys` | `os`, `arch`, `getenv`, `setenv`, `unsetenv` |
| `std.option` | `Option`, `Some`, `Empty` |
| `std.result` | `Result`, `Ok`, `Err` |

The `isSymbolImported` helper gates injection to only the symbols the user actually asked for:

```zig
// sema.zig:276-363
if (std.mem.eql(u8, i.target, "std.quantum")) {
    const builtins = [_][]const u8{ "qbit", "qreg", "H", "measure", "CNOT", "X", "Y", "Z" };
    for (builtins) |b| {
        if (!isSymbolImported(i.imported_symbols, b)) continue;
        // define sym in current scope
    }
}
```

One exception: `std.collections` is loaded as a real file, but with pre-injected symbols:

```zig
// sema.zig:425-434
if (std.mem.eql(u8, i.target, "std.collections")) {
    // Inject into the module's global scope before analysis
    const builtins = [_][]const u8{ "List", "Dict", "String" };
    for (builtins) |b| {
        sa.global_scope.define(sym);  // injected BEFORE sema runs on the module
    }
}
```

### Global Built-ins (No Import Required)

Some symbols are always available in the global scope, regardless of imports:

```zig
// sema.zig:169-174
const builtins = [_][]const u8{ "make", "drop", "range", "print", "Some", "Empty", "None", "Ok", "Err" };
```

In **Mantiq** mode, additional types are globally available:

```zig
// sema.zig:176-186 (Mantiq mode only)
const mantiq_builtins = [_][]const u8{ "String", "List", "Any", "webstr", "utf16str", "rangestr", "utf32str" };
```

---

## Nizam Strict-Mode Gating

**Decision: In Nizam mode, heap types require explicit imports tracked by typechecker flags.**

```zig
// typecheck.zig
is_string_imported: bool = false,
is_list_imported: bool = false,
is_dict_imported: bool = false,
is_option_imported: bool = false,
is_result_imported: bool = false,
```

When any of these heap types is used without the corresponding `import`, the typechecker raises `ImplicitAllocationNotAllowed`. This ensures Nizam code is explicit about heap usage.

---

## `link` Declaration

**Decision: `link` statements register native library dependencies for the linker.**

```nizam
link "zlib"
link[c] "ssl"
link "m"
```

Represented as `LinkDecl` in the AST:

```zig
// ast.zig:133-136
LinkDecl: struct {
    kind: ImportKind = .normal,
    target: []const u8,
},
```

`link` statements pass through the semantic analyser (`sema.zig:471-473`) and are skipped during codegen (`codegen.zig:1960-1961`) — they are collected during the AOT compilation pipeline and forwarded as `-l` flags to `zig cc`.

---

## C FFI (`import[c]`)

**Decision: C imports register the library but skip parsing.**

```zig
// sema.zig:271-274
if (i.kind == .c) {
    // Do not parse or load C files. They are just for codegen.
    return;
}
```

The `import[c]` declaration makes the compiler aware that C library symbols will be available at link time. The programmer must still declare `extern fn` signatures for the specific C functions they want to call.

---

## Examples

### Full Module Import

```nizam
import std.quantum                   // import all as std.quantum namespace

fn main():
    let q = std.quantum.qreg[2]      // qualified access
    std.quantum.H(q[0])
```

### Selective Import

```nizam
from std.quantum import H, CNOT     // import only H and CNOT

fn main():
    let q = qreg[2]                  // qreg not imported — error
    H(q[0])                          // OK: H is imported
```

### Alias Import

```nizam
import std.collections as coll
let items = coll.List[i32]()
```

### Vendor Import

```nizam
import[vendor] lib.strings           // searched in vendor paths only
```

### C Library Import

```nizam
import[c] lib.zlib
extern fn compress(data as ptr[u8], len as i64) -> i64
```

### Link Declaration

```nizam
link "m"                             // link libm for math
```

### Nizam Strict-mode

```nizam
// Nizam — errors without import
// let s = String.make("hello")     // ERROR: ImplicitAllocationNotAllowed

from std.string import String       // explicit import required
let s = String.make("hello")        // OK
```

---

## Current Limitations

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| No package manager | No dependency versioning or registry | Implement `import[pkg]` with a lockfile |
| No circular dependency detection | Infinite recursion on mutual imports | Add cycle detection with visited set |
| `std.collections` hardcoded | Special-cased module with pre-injected symbols | Generalise to a module-level manifest |
| No test coverage | Import resolution untested | Add integration tests for module loading |
| `import[c]` skips sema entirely | No validation of C symbol existence | Generate bindings from C headers |
| Vendor paths hardcoded to 4 locations | Limited flexibility | Add project config file for custom paths |

---

## Relevant Files

| File | Role |
|------|------|
| `grammar.js:66-80` | `import_decl` and `link_decl` CST grammar rules |
| `grammar.js:291-297` | `import_stmt` secondary form (`import X from Y`) |
| `ast.zig:53-59` | `ImportKind` enum (normal/path/vendor/c/pkg) |
| `ast.zig:126-136` | `ImportDecl` and `LinkDecl` AST nodes |
| `lower.zig:322-431` | CST→AST lowering for import/link |
| `sema.zig:29-71` | `findProjectRoot` sentinel-file walk |
| `sema.zig:73-88` | `mangleModuleName` scheme |
| `sema.zig:90-159` | `resolveModulePath` search order |
| `sema.zig:165-193` | Global built-in registration |
| `sema.zig:270-475` | ImportDecl handler (built-in injection + file loading) |
| `sema.zig:383-455` | Recursive module loading with cache |
| `sema.zig:457-468` | Selective symbol import from module scope |
| `typecheck.zig:17-21` | Nizam import gate flags |
| `codegen.zig:468,1080,1121,...` | `module_name` prefixing in LLVM symbol emission |
| `codegen.zig:1960-1961` | ImportDecl/LinkDecl skipped in codegen |
