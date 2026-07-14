# Language Specification: Variables

## Overview

Variables are named storage locations with an associated type. They are declared with `let`, `var`, or `const` keywords, support type inference, optional type annotations, destructuring, mutability control, and automatic lifetime management via borrow checking.

---

## 1. Declaration Syntax

### 1.1 Grammar

```js
var_decl: $ => seq(
    choice(
        // Form 1: let/var
        seq(
            optional($.access_modifier),
            optional($.var_modifier),
            choice('let', 'var'),
            optional('mut'),
            commaSep1(choice($.identifier, $.typed_var)),
            optional($.type_annotation),
            optional(seq('=', commaSep1($.expression)))
        ),
        // Form 2: const
        seq(
            optional($.access_modifier),
            'const',
            commaSep1(choice($.identifier, $.typed_var)),
            optional($.type_annotation),
            '=', commaSep1($.expression)
        )
    )
),

typed_var: $ => seq($.identifier, $.type_annotation),
```

### 1.2 Syntax Examples

```nizam
// Immutable (let)
let x = 42
let y as i32 = 10
let a, b = (1, 2)              // destructuring

// Mutable (var + mut, or var in Nizam)
var mut counter = 0
var mut name as String = String.make("hello")

// Const (compile-time known)
const PI = 3.14159
const MAX_SIZE as i32 = 1024

// Typed variable (identifier + type annotation)
let val as f64 = 3.14
```

### 1.3 Keyword Semantics

| Keyword | Mutability | Initializer Required | Notes |
|---------|-----------|---------------------|-------|
| `let` | Immutable | Required | Rebind not allowed |
| `var` + `mut` | Mutable | Required | Value can be reassigned |
| `const` | Immutable | Required | Compile-time constant |

---

## 2. AST

```zig
// ast.zig:152-158
VarDecl: struct {
    names: [][]const u8,              // one or more variable names
    type_annots: []?TypeAnnotation,   // optional type annotations (per name)
    initializers: ?[]*Node,           // optional initializer expressions
    is_mut: bool,                     // true if var mut
    resolved_symbols: ?[]*symbols.Symbol = null,  // populated by sema
},
```

`VarDecl` handles single declarations (`let x = 1`) and multi-destructuring (`let a, b = (1, 2)`) through the array fields.

---

## 3. Semantic Analysis

### 3.1 Symbol Registration — Pass 1

**File:** `sema.zig:247-251`

```zig
.VarDecl => |*v| {
    for (v.names) |name| {
        _ = try self.declareSymbol(name, .Variable, node);
    }
},
```

Each variable name is registered in the current scope as a `.Variable` symbol.

### 3.2 Symbol Resolution — Pass 2

**File:** `sema.zig:493-522`

```zig
.VarDecl => |*v| {
    if (self.current_scope != self.global_scope) {
        // Local scope
        for (v.names) |name| {
            if (self.current_scope.resolveLocal(name) != null) {
                // Error: Redeclaration of local variable
                return error.Redeclaration;
            }
            sym = .{ .name = name, .kind = .Variable, .decl_node = node };
            try self.current_scope.define(sym);
        }
    } else {
        // Global scope — reuse global symbol
    }
},
```

### 3.3 Scoping Rules

- **Local variables**: declared in the innermost `BlockStmt` scope
- **Global variables**: declared at module level (function scope root)
- **Shadowing**: local variables shadow globals; redeclaration in same scope is an error
- **Symbol**: stored in `symbols.zig` as `Symbol{ .kind = .Variable }`

---

## 4. Type Checking

**File:** `typecheck.zig:517-546`

### 4.1 Type Inference

```nizam
let x = 42             // inferred: i32
let y as f64 = 10      // explicit: f64, coercion applied
let z as i32           // ERROR: must have initializer
```

### 4.2 Rules

1. If a type annotation is provided, validate it and use it
2. If no annotation but an initializer is present, infer from the initializer
3. If neither, **error** — every variable must have an initializer
4. If both annotation and initializer are present, the initializer is coerced to the annotated type

### 4.3 Coercion

```zig
const coerced_val = try self.coerceType(init_val, source_type, target_type);
```

Coercion follows the hierarchy: `F64 > F32 > I64 > I32 > I16 > I8`.

### 4.4 Mutation Checking

Assignments to non-mut variables are rejected:

```zig
// typecheck.zig — assignment validation
if (operator == "=" and left.node_type == .MemberExpr) {
    // Check struct field is_mutable flag
}
// Mutation of a let-bound variable: error
```

---

## 5. Borrow Checking — Ownership States

**File:** `borrowck.zig:48-68`

### 5.1 Variable States

```zig
pub const ObjectState = enum {
    Owned,     // variable has valid data
    Moved,     // value moved to another variable
    Dropped,   // value has been freed
};
```

### 5.2 VarDecl Handling

```zig
.VarDecl => |*v| {
    if (v.initializers) |inits| {
        for (inits) |init_expr| {
            if (init_expr.node_type == .Identifier) {
                try self.handleMove(init_expr);  // move source value
            }
        }
    }
    if (v.resolved_symbols) |syms| {
        for (syms) |sym| {
            try self.states.put(sym, .{ .state = .Owned });
            // Add to current scope for auto-drop tracking
            try self.scopes.items[last].append(sym);
        }
    }
},
```

### 5.3 State Transitions

```
Declaration:          Unknown → Owned
Move to another var:  Owned → Moved
Scope exit (drop):    Owned → Dropped  (auto-drop emitted)
Use after move:       Moved → ERROR
```

### 5.4 Auto-Drop on Scope Exit

Variables still `.Owned` at scope exit with move types (or context managers) are collected:

```zig
if (state == .Owned and (isMoveType(t) or is_context_manager)) {
    drops.append(sym);
    state = .Dropped;
}
```

---

## 6. Code Generation

**File:** `codegen.zig:1391-1450`

### 6.1 Local Variables

```llvm
; let x = 42
%x_0_0 = alloca i32
store i32 42, ptr %x_0_0

; let y as f64 = 10
%y_0_1 = alloca f64
store f64 10.0, ptr %y_0_1

; var mut counter = 0
%counter_0_2 = alloca i32
store i32 0, ptr %counter_0_2
```

Each variable gets a unique scoped name: `{name}_{scopeDepth}_{counter}`.

### 6.2 Global Variables

```llvm
; global scope: let MAX = 100
@MAX = global i32 100

; with module prefix
@mantiq_mymodule_MAX = global i32 100
```

### 6.3 Scoped Name Registration

```zig
fn registerVarName(self, name) {
    const scoped_name = try std.fmt.allocPrint("{s}_{d}_{d}",
        .{ name, self.scope_depth, counter });
    // Save previous name for restore on popScope
    return scoped_name;
}
```

### 6.4 Destructuring Initialization

Multi-name declarations with a single tuple initializer use `extractvalue`:

```llvm
; let a, b = (1, 2)
%a_0 = alloca i32
%b_0 = alloca i32
%t.0 = extractvalue { i32, i32 } %tuple, 0
store i32 %t.0, ptr %a_0
%t.1 = extractvalue { i32, i32 } %tuple, 1
store i32 %t.1, ptr %b_0
```

### 6.5 Variable Access (Load)

```llvm
%t.N = load i32, ptr %x_0_0
```

Access resolves through `var_name_map` which tracks the current scoped name for each variable.

### 6.6 Variable Assignment (Store)

```llvm
store i32 20, ptr %counter_0_2
```

### 6.7 Auto-Drop

```llvm
; scope exit for variable s: String
%t.N = load { ptr, i64, i64 }, ptr %s_0_3
%heap_ptr = extractvalue { ptr, i64, i64 } %t.N, 0
call void @mantiq_free(ptr %heap_ptr)
```

---

## 7. Mutability

### 7.1 Declaration

```nizam
let x = 42              // immutable
var mut y = 10          // mutable
```

### 7.2 Rules

| Declaration | Can Reassign | Can Mutate Fields |
|-------------|-------------|-------------------|
| `let x` | No | No |
| `var mut x` | Yes | Yes |
| `var mut x` with `ref` | — | Yes (via pointer) |

### 7.3 Mutation Semantics

Assignment to a `let` variable is a compile-time error. Only `var mut` variables can appear on the left side of `=`.

---

## 8. Constants

```nizam
const PI = 3.14159
const MAX_SIZE as i32 = 1024
```

Constants are:
- Declared with `const` keyword
- Require an initializer (`= expr` is mandatory)
- Compile-time evaluable
- Emitted as LLVM `global` constants
- Immutable at runtime

---

## 9. Variable Lifecycle

```
           ┌─────────────────────────────┐
           │    Declaration (VarDecl)     │
           │  - Create alloca / global    │
           │  - Store initial value       │
           │  - State: Owned              │
           └─────────────┬───────────────┘
                         │
              ┌──────────┴──────────┐
              │                     │
              ▼                     ▼
      ┌──────────────┐     ┌──────────────┐
      │  Mutation     │     │    Move      │
      │  (store)      │     │  (use by     │
      │  State: Owned │     │   value)     │
      └──────────────┘     │  State: Moved │
                           └──────┬───────┘
                                  │
                                  ▼
                         ┌────────────────┐
                         │  Use after     │
                         │  move → ERROR  │
                         └────────────────┘

           ┌─────────────────────────────┐
           │     Scope Exit / Return      │
           │  - If State: Owned + MoveType│
           │  - Emit auto-drop (free)     │
           │  - State: Dropped            │
           └─────────────────────────────┘
```

---

## 10. Examples

### Basic Declarations

```nizam
let x = 42
let y as i32 = 10
var mut counter = 0
```

### Destructuring

```nizam
let a, b = (1, 2)           // a=1, b=2
let x, y = get_coords()
```

### Global Variables

```nizam
let MAX_SIZE as i32 = 1024

fn main():
    print(MAX_SIZE)
```

### Shadowing

```nizam
let x = 1
block:
    let x = 2               // shadows outer x
    print(x)                // 2
print(x)                    // 1
```

### Mutability

```nizam
var mut val = 10
val = 20                    // OK

let imm = 10
imm = 20                    // Error: cannot assign to immutable
```

### Move Semantics

```nizam
let s1 = String.make("hello")
let s2 = s1                 // s1 moved → s1 unusable
print(s1)                   // Error: use after move
```

### Auto-Drop

```nizam
block:
    let s = String.make("temp")
    // s freed here automatically
```

---

## 11. Relevant Files

| File | Lines | Role |
|------|-------|------|
| `grammar.js` | 159-180 | var_decl, typed_var grammar |
| `ast.zig` | 67, 152-158 | VarDecl AST node (names, type_annots, initializers, is_mut) |
| `lower.zig` | (VarDecl lowering) | CST→AST lowering for variable declarations |
| `sema.zig` | 247-251, 493-522 | Symbol registration (pass 1) and resolution (pass 2) |
| `symbols.zig` | 5-23, 25-63 | Symbol (Variable kind), Scope with define/resolve |
| `typecheck.zig` | 517-546 | Type inference, annotation validation, coercion |
| `borrowck.zig` | 48-68, 111-146, 371-385 | Ownership states (Owned/Moved/Dropped), handleMove |
| `codegen.zig` | 1391-1450 | alloca/global emission, store, destructuring |
| `codegen.zig` | 126-163 | pushScope/popScope, registerVarName (scoped names) |
| `codegen.zig` | 985-1044 | genAutoDrops for move types |
| `codegen.zig` | 552, 2494 | Variable type collection, last-statement check |
| `types.zig` | 240-306 | isCopyType / isMoveType for variable classification |
