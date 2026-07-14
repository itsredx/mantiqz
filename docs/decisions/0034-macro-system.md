# Decision 0034: Macro System (AST-Level Compile-Time Expansion)

## Context

Mantiq/Nizam need a metaprogramming facility for code generation, boilerplate reduction, and DSL embedding. The design is modeled on Rust's `macro_rules!` — AST-level macros expanded at lowering time, before semantic analysis.

The implementation must integrate with:
- The existing lowering pipeline (CST → AST)
- The AST cloning infrastructure (for parameter substitution)
- The compilation pipeline (expansion before sema/typecheck/codegen)

---

## Language Specification

### Feature: `macro` Declarations

```nizam
macro log_info(msg as cstr):
    print(f"[INFO]: {msg}")

macro assert_eq(a, b):
    if a != b:
        print(f"Assertion failed: {a} != {b}")
```

**Grammar** (`grammar.js:134-137`):

```js
macro_decl: $ => seq(
    'macro', $.identifier, '(', optional($.typed_params), ')', ':',
    choice($.block_body, $.statement)
)
```

**AST** (`ast.zig:329-335`):

```zig
MacroDecl: struct {
    name: []const u8,
    params: []const *Node,
    param_names: []const []const u8,
    param_types: []?TypeAnnotation,
    body: *Node,
},
```

**Semantics**: A `macro` declaration stores its parameter list and body AST in a shared `MacroDef` map. The macro definition itself appears in the AST but is a no-op for all later passes.

### Feature: Macro Invocation

```nizam
log_info!("System started")
assert_eq!(x, 42)
```

**Grammar** (`grammar.js:518`):

```js
macro_invocation: $ => prec(10, seq($.identifier, '!', '(', optional($.arguments), ')'))
```

**AST** (`ast.zig:336-339`):

```zig
MacroInvocation: struct {
    name: []const u8,
    arguments: []*Node,
},
```

### Feature: `MacroDef` Storage

```zig
// lower.zig:29-32
pub const MacroDef = struct {
    param_names: [][]const u8,
    body_ast: *ast.Node,
};
```

The `Lowerer` carries two fields:

```zig
// lower.zig:38-39
macros: *std.StringHashMap(MacroDef),    // shared across compilation
macro_args: std.StringHashMap(*ast.Node), // temporary per-invocation bindings
```

---

## Expansion Mechanism

**Decision: Clone-and-substitute at lowering time.** When a macro invocation is encountered:

1. **Look up** the macro by name in `self.macros`
2. **Lower** the invocation arguments to AST
3. **Validate** argument count matches parameter count
4. **Bind** each argument to its parameter name in `self.macro_args`
5. **Deep-clone** the macro's body AST via `cloneNode`
6. During clone, any `Identifier` node matching a parameter name is **replaced** by the bound argument (cloned recursively)
7. **Clean up** bindings from `macro_args`
8. **Return** the expanded AST in place of the invocation node

```zig
fn lowerMacroInvocation(self: *Lowerer, ts_node: c.TSNode) !*ast.Node {
    // Look up macro definition
    const macro_def = self.macros.get(name) orelse {
        return error.InvalidSyntax;  // "macro 'x' is undefined"
    };

    // Lower and bind arguments
    for (macro_def.param_names, 0..) |p_name, idx| {
        try self.macro_args.put(p_name, args.items[idx]);
    }

    // Deep-clone with substitution
    const expanded_ast = try self.cloneNode(macro_def.body_ast);

    // Clean up
    for (macro_def.param_names) |p_name| {
        _ = self.macro_args.remove(p_name);
    }

    return expanded_ast;
}
```

### Substitution in `cloneNode`

**File:** `lower.zig:3060-3067`

```zig
.Identifier => |id| {
    if (self.macro_args.get(id.name)) |arg_node| {
        return try self.cloneNode(arg_node);  // replace with argument
    }
    // normal identifier clone
},
```

This is equivalent to Rust's `$param` token replacement, but achieved via AST cloning rather than textual substitution. The expanded AST is fully independent of the macro body.

---

## Pipeline Position

**Decision: Macro expansion happens during lowering (CST → AST), before all semantic passes.**

```
Source → Parse → Lower (expand macros) → Sema → CFG → Typecheck → Borrowck → DCE → MergeImports → Codegen → JIT/AOT
```

This means:
- Macros are expanded **before** semantic analysis
- The expanded AST goes through the full pipeline (name resolution, type checking, borrow checking, codegen)
- Macro bodies are type-checked **in the context of the call site** (caller's types and namespaces are visible)
- Macro definitions are a no-op in all later passes (`sema.zig:868`, `typecheck.zig:2386-2391`, `codegen.zig:1485-1486`)

---

## Macro Table Lifetime

**Decision: Per-module macro table, persistent across REPL evaluations.**

```zig
// main.zig:1284-1285 (test pipeline)
var macros = std.StringHashMap(lower.MacroDef).init(arena.allocator());
var lowerer = lower.Lowerer.init(arena.allocator(), mode, source_code, &macros);

// main.zig:1410 (REPL)
var macros = std.StringHashMap(lower.MacroDef).init(arena.allocator());
```

In the REPL, the macro table persists across evaluations — macros defined in one snippet are available in later snippets.

During module loading (`sema.zig:416-418`), each imported module gets its own fresh macro table:

```zig
var macros = std.StringHashMap(lower.MacroDef).init(self.allocator);
var lowerer = lower.Lowerer.init(self.allocator, module_info.mode, source_code, &macros);
```

---

## Hygiene

**Decision: Unhygienic (caller-scope identifiers are visible).** The expanded AST inherits the call site's scope during semantic analysis:

```nizam
let x = 10
macro add_x(y):
    y + x     // refers to caller's x

let result = add_x!(5)  // 15
```

There is no automatic renaming of identifiers inside the macro body. Full hygiene (where macro-internal identifiers are isolated from the caller's scope) is a future enhancement.

---

## Limitations

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| Unhygienic | Macro body identifiers can clash with caller scope | Add `gensym` or `$crate` hygiene |
| No procedural macros | `@`-decorator-style AST transformation not supported | Implement `@macro` dunder protocol |
| No recursive macros | Macros cannot invoke themselves | Add recursion depth guard |
| No token-level macros | No `$` token-based pattern matching (C/CPP style) | Keep as-is (AST-level is simpler) |
| No macro export | Macros defined in one module not visible in another | Add `#[macro_export]` attribute |

---

## Examples

### Basic Macro

```nizam
macro twice(expr):
    expr * 2

let x = twice!(5)   // expands to: 5 * 2  → 10
```

### Multi-Statement Macro

```nizam
macro assert_eq(a, b):
    if a != b:
        print(f"Assertion failed: {a} != {b}")

fn main():
    assert_eq!(1 + 1, 2)
```

### Macro with Expression Body

```nizam
macro log(level, msg):
    print(f"[{level}]: {msg}")

log!("INFO", "System started")
```

### Macro Expanding to Expression

```nizam
macro min(a, b):
    if a < b: a else: b

let m = min!(x, y)   // expands to if-expression
```

### Module-Level Macro

```nizam
macro _mac(): pass  // module-level marker/hook
```

---

## Relevant Files

| File | Lines | Role |
|------|-------|------|
| `grammar.js` | 56, 134-137, 497, 518 | `macro_decl` and `macro_invocation` grammar |
| `ast.zig` | 109-110, 329-339 | `MacroDecl`, `MacroInvocation` AST nodes |
| `lower.zig` | 29-32, 38-39, 41-49, 210-215, 300-303 | `MacroDef` struct, `Lowerer` fields |
| `lower.zig` | 2637-2716 | `lowerMacroDecl` — macro definition processing |
| `lower.zig` | 2718-2767 | `lowerMacroInvocation` — expansion with clone+substitute |
| `lower.zig` | 2769-3119 | `cloneNode` with parameter substitution |
| `sema.zig` | 416-418, 868 | Module macro table creation; no-op in resolve |
| `typecheck.zig` | 2386-2391 | MacroDecl/MacroInvocation → Void type |
| `typecheck.zig` | 2790-2811 | Clone support for MacroDecl/MacroInvocation |
| `codegen.zig` | 1485-1486 | MacroDecl/MacroInvocation → no-op |
| `main.zig` | 1284-1285, 1410, 1469, 1484 | Pipeline and REPL macro map integration |
| `macros_report.md` | 1-109 | Full macro design specification document |
| `docs/compiler-architecture.md` | 118 | Macro expansion in architecture overview |
