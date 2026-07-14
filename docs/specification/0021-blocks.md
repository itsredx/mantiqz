# Language Specification: Blocks

## Overview

Blocks are indentation-delimited statement groups that introduce lexical scopes. They appear in control flow constructs, function bodies, unsafe blocks, with-statements, and as standalone `block` expressions with optional parameters and return values.

---

## 1. Block Grammar

### 1.1 block_body

The fundamental indentation-delimited body:

```js
block_body: $ => seq(
    $._newline,
    $._indent,
    repeat(choice($._declaration, $._newline)),
    $._dedent
),
```

Used by: `if`, `for`, `while`, `try`, `with`, `unsafe`, function bodies, `class`, `struct`, `enum`, `union`, `interface`, `match` cases.

### 1.2 block_stmt — Parameterized Block

```js
block_stmt: $ => seq(
    'block', 
    optional($.identifier),                // optional label
    optional(seq('(', optional($.typed_params), ')')),  // typed parameters
    optional($.return_annotation),          // optional return type
    ':',
    choice($.block_body, $.statement)
),
```

### 1.3 Syntax

```nizam
// Plain block (scope only)
block:
    let x as i32 = 10
    print(x)

// Parameterized block (with return value)
block(x as i32, y as i32) as i32:
    let z = x + y
    return z

// Block as expression
let result = block:
    let a = 1
    let b = 2
    a + b    // last expression is block value

// Unsafe block
unsafe:
    let ptr = ref val
    deref ptr = 42
```

---

## 2. AST

```zig
// ast.zig:226-237
BlockStmt: struct {
    statements: []const *Node,
    auto_drops: ?[]*symbols.Symbol = null,    // set by borrowck
},

ParamBlockStmt: struct {
    params: []const *Node,
    param_types: []TypeAnnotation,
    return_names: [][]const u8,
    return_types: []TypeAnnotation,
    body: *Node,                              // inner BlockStmt
    auto_drops: ?[]*symbols.Symbol = null,
},
```

`UnsafeBlock` wraps a `BlockStmt` body:

```zig
UnsafeBlock: struct {
    body: *Node,
},
```

---

## 3. Scoping

### 3.1 Lexical Scopes

Every `BlockStmt` creates a new lexical scope:

```zig
// sema.zig:624-630
.BlockStmt => |*b| {
    try self.pushScope();
    for (b.statements) |stmt| {
        try self.resolvePass2(stmt);
    }
    self.popScope();
},
```

### 3.2 ParamBlockStmt Scoping

Parameters are injected into the **parent** scope, body variables into an **inner** scope:

```zig
// sema.zig:632-662
// Step 1: Inject return vars into parent scope
// Step 2: Create inner scope for params + body
// Step 3: Mark inner scope as closure boundary
```

### 3.3 LLVM Scope

**File:** `codegen.zig:126-147`

```zig
fn pushScope(self: *LLVMCodegen) !void {
    self.scope_depth += 1;
    try self.scope_var_stack.append(std.StringHashMap([]const u8).init(self.allocator));
}

fn popScope(self: *LLVMCodegen) void {
    // Restore previous variable name mappings
    // Remove or restore shadowed names
    self.scope_depth -= 1;
}
```

Variable names are mangled with scope depth:

```zig
fn registerVarName(self: *LLVMCodegen, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint("{s}_{d}_{d}", .{ name, self.scope_depth, counter });
}
```

### 3.4 Shadowing

Inner scopes can shadow outer names. On `popScope`, the previous mapping is restored.

---

## 4. Block as Expression

### 4.1 Type Inference

A `BlockStmt` infers its type from the **last statement**:

```zig
// typecheck.zig:646-666
for (b.statements, 0..) |stmt, i| {
    try self.checkNode(stmt);
    if (i == b.statements.len - 1) {
        last_type = stmt.inferred_type orelse .{ .kind = .Unknown };
    }
}
node.inferred_type = last_type;
```

### 4.2 Codegen

**File:** `codegen.zig:2487-2509`

```zig
.BlockStmt => |*b| {
    try self.pushScope();
    defer self.popScope();
    var last_val: []const u8 = "null";
    for (b.statements, 0..) |stmt, i| {
        if (i == b.statements.len - 1) {
            // Last statement: use genExpr for value
            last_val = try self.genExpr(stmt);
        } else {
            try self.genNode(stmt);  // Statement: no value
        }
    }
    if (b.auto_drops) |drops| {
        try self.genAutoDrops(drops);
    }
    return last_val;
},
```

Declarations (`VarDecl`, `FunDecl`, `StructDecl`, etc.) as the last statement produce no value (treated as statements, not expressions).

---

## 5. Parameterized Blocks

### 5.1 Semantics

A `block(x as i32, y as i32) as i32:` defines:
- **Input parameters**: `x`, `y` scoped to the block body
- **Return variables**: implicitly declared in the **parent** scope, set by `return` inside the block

### 5.2 Codegen

**File:** `codegen.zig:1451-1481`

1. **Allocate** return variables in the current function scope (`%ret_x = alloca T`)
2. **Create** an exit label (`block_exit_N:`)
3. **Set** `active_param_block` context on the codegen state
4. **Emit** block body (statements inside)
5. **Branch** to exit label at end of body
6. **Emit** exit label (execution continues after the block)

```llvm
; block(x as i32, y as i32) as i32:
;   return x + y
;
%res = alloca i32           ; return variable
%x = alloca i32
%y = alloca i32
store i32 %arg0, ptr %x
store i32 %arg1, ptr %y
; body
%tmp = load i32, ptr %x
%tmp2 = load i32, ptr %y
%sum = add i32 %tmp, %tmp2
store i32 %sum, ptr %res
br label %block_exit_0

block_exit_0:
```

### 5.3 Return Inside Parameterized Block

`return` inside a `ParamBlockStmt` **stores** into the block's return allocas and branches to the exit label (not a function return):

```zig
// codegen.zig:1828-1851
.ReturnStmt => |*r| {
    if (self.active_param_block) |p_node| {
        // Store into return allocas, branch to block_exit
        for (values, 0..) |val, i| {
            store rtype %rval, ptr %ret_name
        }
        br label %block_exit_label
    } else {
        // Normal function return
    }
},
```

---

## 6. Auto-Drop at Scope Exit

### 6.1 Borrow Checker Scope Tracking

**File:** `borrowck.zig:215-246`

The borrow checker maintains a parallel scope stack. On block exit, variables that are still `.Owned` and are move types or context managers are collected:

```zig
// For each scope-exit:
for (popped_scope.items) |sym| {
    if (state == .Owned and (isMoveType(t) or is_context_manager)) {
        drops.append(sym);
        state = .Dropped;
    }
}
// Store on AST node
b.auto_drops = try drops.toOwnedSlice();
```

### 6.2 Codegen for Auto-Drops

**File:** `codegen.zig:985-1044`

```llvm
; auto-drop for variable x of type String
%t.N = load { ptr, i64, i64 }, ptr %x_s
%t.M = extractvalue { ptr, i64, i64 } %t.N, 0
call void @mantiq_free(ptr %t.M)

; auto-drop for context manager
%t.N = load { ptr, i64 }, ptr %cm_s
call void @ContextManager___exit__(ptr %t.N)
```

### 6.3 Auto-Drops on Function Return

**File:** `borrowck.zig:303-350`

On `ReturnStmt`, the borrow checker walks **all** scopes from innermost to outermost, collecting owned variables not being returned:

```zig
for (scope in scopes reversed) {
    for (sym in scope) {
        if (state == .Owned and !is_returned(sym)) {
            drops.append(sym);
        }
    }
}
```

---

## 7. Unsafe Block

### 7.1 Type Checking

**File:** `typecheck.zig:1687-1693`

```zig
.UnsafeBlock => |*u| {
    const prev_unsafe = self.in_unsafe_block;
    self.in_unsafe_block = true;
    try self.checkNode(u.body);
    node.inferred_type = u.body.inferred_type orelse .{ .kind = .Void };
    self.in_unsafe_block = prev_unsafe;
},
```

Inside an unsafe block, plain union field access and raw pointer dereference are permitted.

### 7.2 Codegen

```zig
.UnsafeBlock => |*u| {
    try self.genNode(u.body);
},
```

Body is emitted directly with no wrapping.

---

## 8. With Statement (Context Manager)

### 8.1 Grammar

```js
with_stmt: $ => seq(
    $.kw_with, $.expression, optional(seq('as', $.identifier)), ':', $.block_body
),
```

### 8.2 Lifecycle

1. Evaluate expression (must be a context manager)
2. Optionally bind to `as name`
3. Execute body
4. Auto-call `__exit__` on scope exit (even via return/break)

### 8.3 AST

```zig
WithStmt: struct {
    expr: *Node,
    var_name: ?[]const u8,
    body: *Node,
    resolved_symbol: ?*symbols.Symbol = null,
    auto_drops: ?[]*symbols.Symbol = null,
},
```

### 8.4 Codegen

```llvm
; with resource as r: body
%r = alloca %ResourceType
%res = call %ResourceType @expr()
store %ResourceType %res, ptr %r
; body
...
; exit: auto-drop calls __exit__
%loaded = load %ResourceType, ptr %r
call void @ResourceType___exit__(ptr %loaded)
```

---

## 9. CFG Analysis

**File:** `cfg.zig:39-53`

```zig
.BlockStmt => |b| {
    var always_returns = false;
    for (b.statements) |stmt| {
        if (always_returns) {
            // Unreachable code detected
            return error.UnreachableCode;
        }
        if (try self.checkNode(stmt)) {
            always_returns = true;
        }
    }
    return always_returns;
},
```

Blocks that end in `return`, `raise`, or `break` on all paths are treated as definitive returns.

---

## 10. Statement Temporaries

**File:** `codegen.zig:110-124`

Temporary heap allocations within a block are tracked and freed:

```zig
fn flushStatementTemps(self: *LLVMCodegen) !void {
    for (self.statement_temporaries) |heap_ptr| {
        try writer.print("  call void @mantiq_free(ptr {s})\n", .{heap_ptr});
    }
    self.statement_temporaries.clearRetainingCapacity();
}
```

Temps are flushed between statements and at block exit.

---

## 11. Examples

### Plain Block

```nizam
block:
    let a as i32 = 1
    let b as i32 = 2
    print(a + b)
```

### Block as Expression

```nizam
let x as i32 = block:
    let a = 10
    a * 2               // x = 20
```

### Parameterized Block

```nizam
let result as i32 = block(a as i32, b as i32) as i32:
    return a + b

// Equivalent to:
fn add(a as i32, b as i32) as i32:
    return a + b
```

### Unsafe Block

```nizam
var x as i32 = 10
unsafe:
    let p = ref x
    deref p = 20         // allowed inside unsafe
```

### With Statement

```nizam
with open("file.txt") as f:
    print(f.read())
// __exit__ called automatically
```

### Nested Scopes with Shadowing

```nizam
let x as i32 = 1
block:
    let x as i32 = 2     // shadows outer x
    print(x)              // 2
print(x)                  // 1
```

### Auto-Drop

```nizam
block:
    let s as String = String.make("hello")
    print(s)
    // s auto-dropped at scope exit: mantiq_free called
```

---

## 12. Relevant Files

| File | Lines | Role |
|------|-------|------|
| `grammar.js` | 274-281, 299-304 | block_stmt, block_body grammar |
| `ast.zig` | 83-84, 108, 111, 226-237, 326-328, 340-346 | BlockStmt, ParamBlockStmt, UnsafeBlock, WithStmt |
| `lower.zig` | 532-554, 1616-1664, 2067-2207 | Block lowering (if-branch, unsafe, block_stmt, with) |
| `symbols.zig` | 25-63 | Scope type (parent, symbols, closure_node) |
| `sema.zig` | 196-204, 624-662, 713-725 | pushScope/popScope, block scope resolution |
| `typecheck.zig` | 646-666, 1334-1341, 1687-1693, 2375-2424 | Block type checking (last-expr = value), unsafe, findReturnType |
| `borrowck.zig` | 69-109, 215-350 | Auto-drop collection on scope/return exit |
| `codegen.zig` | 69-82, 110-163, 985-1044, 1228-1266, 1451-1549, 1828-1851, 2487-2509, 2547-2588 | LLVM IR: scoping, temps, drops, param blocks, unsafes, with |
| `cfg.zig` | 39-53 | Unreachable code detection in blocks |
| `dce.zig` | 77-83, 147-174 | Mark/sweep for blocks |
