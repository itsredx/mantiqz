# Decision 0028: Closure Capture

## Context

Mantiq and Nizam support closures (anonymous functions that capture variables from their enclosing scope). The design must answer:

1. **What** gets captured — which variables and how they're identified
2. **How** they're captured — by value, by reference, or by move
3. **How** the closure is represented at runtime — the calling convention and environment layout
4. **How** the borrow checker interacts with captures

The C++ interop requirement drives the choice toward a simple, predictable capture model.

---

## Language Specification

### Feature: Closure Expressions

A closure is a `fn` expression without a name that can reference variables from its enclosing scope:

```nizam
let multiply = (y as i32) => x * y    // captures 'x'
```

Closures can be full `fn` blocks or expression-body lambdas (`=>`).

### Capture Detection

**Decision: Scope-walking name resolution.**

When the semantic analyser resolves an identifier and finds it belongs to a parent scope, it walks the scope chain from the current scope toward the defining scope. Any scope with a `closure_node` anchor gets the variable name added to its `captured_vars` array.

```zig
// sema.zig — Identifier handler (lines 664–690)
if (resolved.sym.kind == .Variable and resolved.scope.parent != null) {
    var s: ?*symbols.Scope = self.current_scope;
    while (s != null and s != resolved.scope) : (s = s.?.parent) {
        if (s.?.closure_node) |cl_node| {
            // add variable name to captured_vars if not already present
        }
    }
}
```

This handles nested closures correctly — a variable may be captured by multiple nesting levels by walking through each intermediate `closure_node` scope.

**Not considered**: Free-variable analysis on the AST. The scope-walking approach is simpler and reuses existing symbol infrastructure.

### Capture Mode

**Decision: All captures are by-value (copy).**

The closure snapshots the current value of each captured variable at the point of closure creation. The value is loaded from the stack alloca and packed into a heap-allocated environment block.

**Not implemented (future):**
- `move` captures (move ownership into the closure)
- `ref` captures (borrow a reference into the closure)
- Mutable (`&mut`) captures

### Runtime Representation

**Decision: Fat pointer `{ ptr, ptr }` — function pointer + environment pointer.**

```
%Closure = type { ptr, ptr }
```

| Field | Type | Contents |
|-------|------|----------|
| `.0` | `ptr` | Pointer to the outlined closure function |
| `.1` | `ptr` | Pointer to the heap-allocated environment (or `null` if no captures) |

**Layout**: `layout.zig` gives it size 16 and alignment 8 (two pointers on x86_64).

### Calling Convention

**Decision: Trampoline — environment pointer as first argument.**

The outlined function receives `ptr %env` as its first parameter, followed by the closure's explicit parameters:

```llvm
define i32 @__mantiq_closure_0(ptr %env, i32 %y.param) {
  ; unpack captures from %env
  ; execute body
}
```

At the call site, the fat pointer is decomposed:

```llvm
%func_ptr = extractvalue { ptr, ptr } %closure, 0
%env_ptr  = extractvalue { ptr, ptr } %closure, 1
%result   = call i32 %func_ptr(ptr %env_ptr, i32 %arg)
```

This is the standard C-compatible closure ABI (also used by LLVM's `trampoline` intrinsics and Go's goroutine closures).

### Environment Layout

**Decision: Heap-allocated contiguous block, one i32 slot per captured variable.**

```llvm
%env = call ptr @mantiq_malloc(i64 4)     ; for one captured variable
%slot = getelementptr inbounds i8, ptr %env, i64 0
store i32 %captured_value, ptr %slot
```

**Current limitation**: All captures are hardcoded to `i32` (4 bytes). Non-i32 captures will produce incorrect LLVM IR. Future work should use the actual type size.

If a closure has zero captures, the environment pointer is `null`.

### Type System Integration

Closures are classified as **Copy** types (`isCopyType` returns `true`). This means:

- Closures can be freely duplicated without move semantics
- They can be passed as `fn()` type parameters via implicit conversion
- The borrow checker does **not** track captured variables

```zig
// typecheck.zig — ClosureExpr handling (lines 2148–2180)
node.inferred_type = .{ .kind = .Closure, .closure_id = cid, .function = fn_type };
```

Each closure gets a unique sequential ID. The `FunctionType` is built from parameter types and body return type, enabling signature compatibility checking with regular function types.

### Code Generation Strategy

**Decision: Outlining — each closure is compiled as a separate LLVM function.**

The pipeline:

1. **Save** the current IR output buffer and variable state
2. **Emit** a new LLVM function `define i32 @__mantiq_closure_<id>(ptr %env, ...)` into a fresh buffer
3. **Unpack** captures from the environment pointer into local allocas
4. **Generate** the closure body in the new function
5. **Append** the function to `outlined_out` (accumulated outlined functions)
6. **Restore** the previous state
7. **Emit** the environment packing at the closure-creation site: `malloc` → store captures → `insertvalue { ptr, ptr }`

Special case — **parallel loops** (`for@par`): The loop body is outlined as `__mantiq_par_closure_<id>(ptr %env, i32 %iterator)` with return type `void`.

### Borrow Checker Interaction

**Decision: The borrow checker does not walk into closures.**

`borrowck.zig` has no `ClosureExpr` handler; it falls through to `else => {}`. This means:

- Captured variables remain `.Owned` after capture — no ownership transfer
- Use-after-move inside a closure body is not detected
- Multiple closures can capture the same variable without interference

This is acceptable because:
- Captures are by-value (copy), so ownership is not transferred
- Closures are Copy types (the `{ ptr, ptr }` fat pointer is freely duplicable)
- The original variable continues to exist independently

---

## Examples

### Basic Capture

```nizam
fn make_multiplier(x as i32) -> fn(i32) -> i32:
    let multiply = (y as i32) => x * y
    return multiply

fn main() -> i32:
    let times3 = make_multiplier(3)
    let result = times3(5)
    return result     // 15
```

### No Captures

```nizam
let add = (a as i32, b as i32) => a + b
// env_ptr = null, only fn_ptr needed
```

### Nested Closures

```nizam
fn outer(x as i32) -> fn() -> i32:
    let mid = fn() -> fn() -> i32:
        let inner = () => x + 1
        return inner
    return mid()

// Both mid and inner capture 'x'
```

---

## Current Limitations

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| All captures are `i32` | Non-i32 types produce incorrect IR | Use `typeToLLVM` + `layout.getSize` per capture |
| Outlined function always returns `i32` | Return type mismatch for non-i32 closures | Use the actual return type from `FunctionType` |
| No mutable / `ref` captures | Cannot modify captured variables | Add `ref` capture mode with borrow checker integration |
| Borrow checker ignores closures | Use-after-move inside closure not caught | Walk closure body in borrow checker |
| No `move` semantics | Captures always copy; large structs are duplicated | Add `move` keyword for ownership transfer |

---

## Relevant Files

| File | Role |
|------|------|
| `ast.zig` | `ClosureExpr` node with `captured_vars` field |
| `sema.zig:664-690` | Capture detection via scope walking |
| `sema.zig:778-792` | Closure scope creation with `closure_node` anchor |
| `symbols.zig:25-29` | `Scope.closure_node` back-pointer |
| `typecheck.zig:2148-2180` | Closure type checking and `closure_id` assignment |
| `typecheck.zig:235-246` | `Closure_<id>` type annotation parsing |
| `codegen.zig:2999-3097` | Closure outlining, environment packing, fat pointer |
| `codegen.zig:3116-3224` | Closure invocation (extract + call via fn ptr) |
| `codegen.zig:1524-1551` | `for@par` closure outlining |
| `layout.zig` | Size=16, Align=8 for closure type |
| `lower.zig:1871-1986` | CST→AST lowering of closure syntax |
