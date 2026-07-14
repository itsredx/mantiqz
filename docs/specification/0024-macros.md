# Language Specification: Macros

## Overview

Macros are compile-time code transformations that operate on AST nodes. A macro definition stores its parameter list and body AST. On invocation (`name!(args)`), the body AST is deep-cloned with parameter identifiers replaced by the argument ASTs. Expansion happens during lowering (CST → AST), before semantic analysis.

---

## 1. Macro Declaration

### 1.1 Grammar

```js
macro_decl: $ => seq(
    'macro', $.identifier, '(', optional($.typed_params), ')', ':',
    choice($.block_body, $.statement)
)
```

### 1.2 Syntax

```nizam
macro log_info(msg as cstr):
    print(f"[INFO]: {msg}")

macro assert_eq(a, b):
    if a != b:
        print(f"Assertion failed: {a} != {b}")

macro twice(expr):
    expr * 2
```

### 1.3 AST

```zig
// ast.zig:329-335
MacroDecl: struct {
    name: []const u8,
    params: []const *Node,
    param_names: []const []const u8,
    param_types: []?TypeAnnotation,
    body: *Node,
},
```

---

## 2. Macro Invocation

### 2.1 Grammar

```js
macro_invocation: $ => prec(10, seq($.identifier, '!', '(', optional($.arguments), ')'))
```

The `!` suffix before `(` unambiguously signals a macro call (since `!` is not a postfix operator in the language).

### 2.2 Syntax

```nizam
log_info!("System started")
assert_eq!(x, 42)
let result = twice!(21)
```

### 2.3 AST

```zig
// ast.zig:336-339
MacroInvocation: struct {
    name: []const u8,
    arguments: []*Node,
},
```

---

## 3. MacroDef Storage

**File:** `lower.zig:29-32`

```zig
pub const MacroDef = struct {
    param_names: [][]const u8,
    body_ast: *ast.Node,
};
```

The `Lowerer` carries:

```zig
// Shared across compilation — lives in persistent arena (REPL) or per-module
macros: *std.StringHashMap(MacroDef),

// Temporary per-invocation parameter bindings
macro_args: std.StringHashMap(*ast.Node),
```

---

## 4. Expansion Mechanism

**Decision: Clone-and-substitute at lowering time.**

### 4.1 Steps

1. **Look up** macro by name in `self.macros` — error if undefined
2. **Lower** invocation arguments to AST nodes
3. **Validate** argument count matches parameter count — error if mismatch
4. **Bind** each argument to its parameter name in `self.macro_args`
5. **Deep-clone** the macro's body AST via `cloneNode`
6. During clone, any `Identifier` matching a parameter name is **replaced** by the bound argument (cloned recursively)
7. **Clean up** bindings from `macro_args`
8. **Return** the expanded AST in place of the invocation node

```zig
fn lowerMacroInvocation(self: *Lowerer, ts_node: c.TSNode) !*ast.Node {
    const macro_def = self.macros.get(name) orelse {
        return error.InvalidSyntax;  // "macro 'x' is undefined"
    };

    // Lower arguments
    var args = std.ArrayList(*ast.Node).init(self.allocator);
    for (arg_count) |i| {
        try args.append(try self.lowerNode(arg_child));
    }

    // Arity check
    if (args.items.len != macro_def.param_names.len) {
        return error.InvalidSyntax;  // "macro 'x' expects N arguments, got M"
    }

    // Bind arguments to parameter names
    for (macro_def.param_names, 0..) |p_name, idx| {
        try self.macro_args.put(p_name, args.items[idx]);
    }

    // Clone with substitution
    const expanded_ast = try self.cloneNode(macro_def.body_ast);

    // Clean up bindings
    for (macro_def.param_names) |p_name| {
        _ = self.macro_args.remove(p_name);
    }

    return expanded_ast;
}
```

### 4.2 Substitution in cloneNode

**File:** `lower.zig:3060-3067`

```zig
.Identifier => |id| {
    if (self.macro_args.get(id.name)) |arg_node| {
        return try self.cloneNode(arg_node);  // replace param with argument
    }
    // Normal identifier clone
    cloned.data = .{ .Identifier = .{
        .name = id.name,
        .resolved_symbol = id.resolved_symbol,
    } };
},
```

### 4.3 Deep Clone

`cloneNode` recursively deep-copies every AST node type. The expanded AST is completely independent of the macro body — modifications after expansion do not affect the original definition.

```zig
// lower.zig:2769-3119 — cloneNode handles every NodeType variant
```

---

## 5. Pipeline Position

**Decision: Expansion at lowering time, before all semantic passes.**

```
Source → Parse → Lower (expand macros) → Sema → CFG → Typecheck → Borrowck → DCE → MergeImports → Codegen → JIT/AOT
```

- Macros are expanded **before** semantic analysis
- The expanded AST goes through the full pipeline
- Macro bodies are type-checked in the context of the call site (caller's types, namespaces, and variables are visible)
- `MacroDecl` nodes remain in the AST but are **no-ops** in all later passes

| Pass | MacroDecl | MacroInvocation |
|------|-----------|-----------------|
| `sema.zig` | Skipped (line 868) | Skipped (should not exist) |
| `typecheck.zig` | `→ Void` (line 2386) | `→ Void` (line 2389) |
| `codegen.zig` | No-op `{}` (line 1485) | No-op `{}` (line 1486) |

---

## 6. Macro Table Lifetime

### 6.1 Per-Module

Each imported module gets its own macro table:

```zig
// sema.zig:416-418 — during module loading
var macros = std.StringHashMap(lower.MacroDef).init(self.allocator);
var lowerer = lower.Lowerer.init(self.allocator, module_info.mode, source_code, &macros);
```

### 6.2 REPL Persistence

In the REPL, the macro table persists across evaluations:

```zig
// main.zig:1410
var macros = std.StringHashMap(lower.MacroDef).init(arena.allocator());
// Passed to every Lowerer instance across all snippets
```

Macros defined in one snippet are available in later snippets.

---

## 7. Hygiene

**Decision: Unhygienic (caller-scope identifiers are visible).**

```nizam
let x = 10
macro add_x(y):
    y + x

let result = add_x!(5)  // 15 — refers to caller's x
```

The expanded AST inherits the call site's scope during semantic analysis. There is no automatic renaming of identifiers inside the macro body.

---

## 8. Error Handling

| Error | When | Message |
|-------|------|---------|
| Undefined macro | Invocation of undeclared name | `"macro '{name}' is undefined"` |
| Argument count mismatch | Invocation with wrong arity | `"macro '{name}' expects {N} arguments, got {M}"` |

Errors are reported at **lowering time** (before sema/typecheck).

---

## 9. Examples

### Expression Macro

```nizam
macro twice(expr):
    expr * 2

let x = twice!(5)   // expands to: 5 * 2  → 10
```

### Statement Macro

```nizam
macro log(level, msg):
    print(f"[{level}]: {msg}")

log!("INFO", "System started")
```

### Block Macro

```nizam
macro assert_eq(a, b):
    if a != b:
        print(f"{a} != {b}")

fn main():
    assert_eq!(1 + 1, 2)
```

### Multi-Expression Body

```nizam
macro measure_twice(qb):
    measure(qb)
    measure(qb)

measure_twice!(0)
// expands to:
//   measure(0)
//   measure(0)
```

### Macro Returning Expression

```nizam
macro min(a, b):
    if a < b: a else: b

let m = min!(x, y)   // expands to if-expression
```

### Module-Level Marker

```nizam
macro _mac(): pass   // parsed as MacroDecl, stored in macros map
```

---

## 10. Limitations

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| Unhygienic | Macro body identifiers can clash with caller scope | Add `gensym` or `$crate` hygiene |
| No procedural macros | `@`-decorator-style AST transformation not supported | Implement `@macro` dunder protocol |
| No recursive macros | Macros cannot invoke themselves | Add recursion depth guard |
| No token-level macros | No `$`-based pattern matching | Keep AST-level (simpler, safer) |
| No macro export | Macros defined in one module not visible in another | Add `#[macro_export]` attribute |
| No type-checked params | Parameter type annotations exist but are not enforced | Validate against call-site types |

---

## 11. Relevant Files

| File | Lines | Role |
|------|-------|------|
| `grammar.js` | 56, 134-137, 497, 518 | `macro_decl` and `macro_invocation` grammar |
| `ast.zig` | 109-110, 329-339 | `MacroDecl`, `MacroInvocation` AST nodes |
| `lower.zig` | 29-32, 38-39, 41-49 | `MacroDef` struct, `Lowerer` fields |
| `lower.zig` | 2637-2716 | `lowerMacroDecl` — definition processing |
| `lower.zig` | 2718-2767 | `lowerMacroInvocation` — expansion |
| `lower.zig` | 2769-3119 | `cloneNode` with parameter substitution |
| `sema.zig` | 416-418, 868 | Per-module macro table; MacroDecl no-op |
| `typecheck.zig` | 2386-2391 | MacroDecl/MacroInvocation → Void |
| `typecheck.zig` | 2790-2811 | Clone support for macro nodes |
| `codegen.zig` | 1485-1486 | MacroDecl/MacroInvocation no-op |
| `main.zig` | 1284-1285, 1410, 1469, 1484 | Pipeline and REPL integration |
| `macros_report.md` | 1-109 | Full macro design document |
| `docs/decisions/0034-macro-system.md` | Full | Decision record for macro system |
