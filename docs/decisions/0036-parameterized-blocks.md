# Decision 0036: Parameterized Blocks

## Context

Parameterized blocks (`block(x as i32, y as i32) as i32:`) are a Mantiq/Nizam feature for defining inline, scope-bounded computations with typed parameters and named return values. They behave like anonymous functions that execute immediately in the current scope, with `return` storing values into pre-allocated return variables rather than performing a function return.

---

## Language Specification

### Feature: `block` Expressions

```nizam
// Plain block (scope only)
block:
    let x = 10
    print(x)

// Parameterized block with return values
let result as i32 = block(a as i32, b as i32) as i32:
    return a + b

// Multiple return values
let x, y as (i32, i32) = block(val as i32) as (i32, i32):
    return val, val * 2
```

### Grammar

```js
block_stmt: $ => seq(
    'block',
    optional($.identifier),                    // optional label (parsed, unused)
    optional(seq('(', optional($.typed_params), ')')),  // typed parameters
    optional($.return_annotation),              // optional return type annotation
    ':',
    choice($.block_body, $.statement)
)
```

### AST

```zig
// ast.zig:230-237
ParamBlockStmt: struct {
    params: []const *Node,              // parameter identifier nodes
    param_types: []TypeAnnotation,       // type annotations per param
    return_names: [][]const u8,         // named return variables
    return_types: []TypeAnnotation,      // types per return value
    body: *Node,                         // inner BlockStmt
    auto_drops: ?[]*symbols.Symbol = null,
},
```

---

## Scoping Rules

**Decision: Return variables are declared in the parent scope; parameters in the inner scope.**

```zig
// sema.zig:649-684
.ParamBlockStmt => |*p| {
    // Step 1: Inject return variables into PARENT scope
    for (p.return_names) |name| {
        try self.current_scope.define(sym);  // parent scope
    }

    // Step 2: Create INNER scope for block body
    const block_scope = try symbols.Scope.create(self.allocator, self.current_scope);
    block_scope.closure_node = node;  // mark for capture analysis
    self.current_scope = block_scope;

    // Step 3: Define parameters inside the inner scope
    for (p.params) |param| {
        try self.current_scope.define(p_sym);
    }

    try self.resolvePass2(p.body);
    self.current_scope = self.current_scope.parent.?;  // restore
},
```

This means:
- **Return variables** are visible **after** the block exits (in the enclosing scope)
- **Parameters** are scoped to the block body only
- The inner scope is marked with `closure_node` for closure capture analysis

---

## Type Checking

**Decision: Parameters are typed from annotations; body is checked; block type is `Any`.**

```zig
// typecheck.zig:2375-2385
.ParamBlockStmt => |*p| {
    for (p.params, 0..) |param, i| {
        if (param.node_type == .Identifier) {
            param.inferred_type = try self.validateType(p.param_types[i]);
        }
    }
    try self.checkNode(p.body);
    node.inferred_type = .{ .kind = .Any };
},
```

The return type annotations exist in the AST but are not enforced by the type checker — validation against actual return values is a future enhancement.

---

## Code Generation: LLVM IR

**Decision: Pre-allocate return variables; return inside block stores and branches to exit.**

```zig
// codegen.zig:1451-1481
.ParamBlockStmt => |*p| {
    // 1. Allocate return variables
    for (p.return_names, 0..) |name, i| {
        const t = annotToLLVM(p.return_types[i].name);
        try writer.print("  %{s} = alloca {s}\n", .{ name, t });
    }

    // 2. Create block exit label
    const exit_label = try std.fmt.allocPrint("block_exit_{d}", .{block_id});

    // 3. Save/restore active block context
    const prev_block = self.active_param_block;
    const prev_exit = self.active_block_exit;
    self.active_param_block = node;
    self.active_block_exit = exit_label;

    // 4. Emit body
    try self.genNode(p.body);

    // 5. Branch to exit label
    try writer.print("  br label %{s}\n", .{exit_label});
    try writer.print("{s}:\n", .{exit_label});

    // 6. Auto-drops + restore context
    if (p.auto_drops) |drops| { try self.genAutoDrops(drops); }
    self.active_param_block = prev_block;
    self.active_block_exit = prev_exit;
},
```

### Return inside parameterized block

**Decision: `return` stores into return allocas and branches to exit (not a function return).**

```zig
// codegen.zig:1828-1851
.ReturnStmt => |*r| {
    if (self.active_param_block) |p_node| {
        const p = &p_node.data.ParamBlockStmt;
        if (r.values) |values| {
            for (values, 0..) |val, i| {
                if (i < p.return_names.len) {
                    const ret_name = p.return_names[i];
                    // Coerce value to return type
                    const coerced = try self.coerceType(ret_val, source_t, t);
                    try writer.print("  store {s} {s}, ptr %{s}\n", .{ t, coerced, ret_name });
                }
            }
        }
        try writer.print("  br label %{s}\n", .{self.active_block_exit});
    } else {
        // Normal function return
    }
},
```

```llvm
; block(a as i32, b as i32) as i32:
;   return a + b

%result = alloca i32              ; return variable (allocated in parent entry)
%a = alloca i32
%b = alloca i32
store i32 %arg0, ptr %a
store i32 %arg1, ptr %b

; body
%t.0 = load i32, ptr %a
%t.1 = load i32, ptr %b
%sum = add i32 %t.0, %t.1
store i32 %sum, ptr %result        ; store to return alloca
br label %block_exit_0

block_exit_0:
; execution continues here after block
```

### State tracking

```zig
// codegen.zig:69-70
active_param_block: ?*ast.Node = null,    // current param block (for return interception)
active_block_exit: []const u8 = "",       // target label for block exit branches
```

These fields are saved/restored on the codegen state, allowing nesting:

```nizam
block(x as i32) as i32:
    block(y as i32) as i32:
        return x + y   // inner block's return, not outer
```

---

## Borrow Checking

**Decision: Same scope-based auto-drop collection as BlockStmt, with return-scope walking.**

```zig
// borrowck.zig:69-109
.ParamBlockStmt => |*p| {
    // Push scope, check body, pop scope, collect owned variables for drop
    const new_scope = std.ArrayList(*symbols.Symbol).init(self.allocator);
    try self.scopes.append(new_scope);
    try self.checkNode(p.body);
    const popped = self.scopes.pop();
    // Collect .Owned move-type variables
    p.auto_drops = try drops.toOwnedSlice();
},
```

Variable ownership states are managed through the same `Owned → Moved → Dropped` state machine as regular blocks.

---

## Examples

### Basic Parameterized Block

```nizam
let result as i32 = block(a as i32, b as i32) as i32:
    return a + b

// Equivalent to:
fn add(a as i32, b as i32) as i32:
    return a + b
```

### Multi-Return Block

```nizam
let sum, product as (i32, i32) = block(x as i32, y as i32) as (i32, i32):
    return x + y, x * y
// sum = x + y, product = x * y
```

### Nested Blocks

```nizam
let outer as i32 = block(x as i32) as i32:
    let inner as i32 = block(y as i32) as i32:
        return x + y   // inner return → stores, branches to inner exit
    return inner       // outer return → stores, branches to outer exit
```

### Scoped Computation with Auto-Drop

```nizam
block:
    let s as String = String.make("temp")
    process(s)
    // s auto-dropped at block exit
```

### Labeled Block (Label Parsed but Not Used)

```nizam
block my_label:
    // label is parsed and discarded during lowering
```

---

## Limitations

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| Label ignored | `block name:` label parsed but not wired | Implement labeled break/continue |
| Return type not enforced | Return annotation exists but no validation | Add check against actual return values |
| No expression value | Block always returns Void or uses Any type | Infer return type from return statements |
| No early-exit without return | No `break` from block | Add label-based break |

---

## Relevant Files

| File | Lines | Role |
|------|-------|------|
| `grammar.js` | 274-281 | `block_stmt` grammar (label, params, return_annotation) |
| `ast.zig` | 84, 230-237 | `ParamBlockStmt` node definition |
| `lower.zig` | 2105-2207 | CST→AST lowering for parameterized blocks |
| `sema.zig` | 649-684 | Scoping: return vars in parent, params in inner scope |
| `typecheck.zig` | 2375-2385 | Parameter type checking, body checking |
| `borrowck.zig` | 69-109 | Scope-based auto-drop collection |
| `codegen.zig` | 69-70, 1451-1481, 1828-1851 | LLVM IR: allocas, exit label, return interception |
