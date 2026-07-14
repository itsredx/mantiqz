# Language Specification: Error Handling

## Overview

Error handling uses a **tagged union** approach with two built-in types: `Option[T]` (nullable value) and `Result[T, E]` (fallible operation). The `try` expression unwraps these types with a mandatory `catch` handler, and `raise` synthesizes an `Err` return value. A separate **panic** mechanism handles unrecoverable runtime errors (bounds checks, division by zero).

---

## 1. Error Types

### 1.1 Option[T]

```nizam
from std.option import Option, Some, Empty
```

Represents an optional value:

| Variant | Discriminant | Payload | Meaning |
|---------|-------------|---------|---------|
| `Empty` | 0 | (none) | No value |
| `Some(x)` | 1 | `x` | Value present |

**LLVM type**: `{ i8, ptr }` — tag byte + heap-allocated payload pointer.

```llvm
; Empty
%t.1 = insertvalue { i8, ptr } undef, i8 0, 0
%t.2 = insertvalue { i8, ptr } %t.1, ptr null, 1

; Some(42)
%box = call ptr @mantiq_malloc(i64 32)
store i32 42, ptr %box
%t.1 = insertvalue { i8, ptr } undef, i8 1, 0
%t.2 = insertvalue { i8, ptr } %t.1, ptr %box, 1
```

### 1.2 Result[T, E]

```nizam
from std.result import Result, Ok, Err
```

Represents a fallible operation:

| Variant | Discriminant | Payload | Meaning |
|---------|-------------|---------|---------|
| `Ok(x)` | 0 | `x` (slot 1) | Success |
| `Err(e)` | 1 | `e` (slot 2) | Failure |

**LLVM type**: `{ i8, ptr, ptr }` — tag byte + Ok payload pointer + Err payload pointer.

```llvm
; Ok(42)
%box = call ptr @mantiq_malloc(i64 32)
store i32 42, ptr %box
%t.1 = insertvalue { i8, ptr, ptr } undef, i8 0, 0
%t.2 = insertvalue { i8, ptr, ptr } %t.1, ptr %box, 1
%t.3 = insertvalue { i8, ptr, ptr } %t.2, ptr null, 2

; Err(404)
%box = call ptr @mantiq_malloc(i64 32)
store i32 404, ptr %box
%t.1 = insertvalue { i8, ptr, ptr } undef, i8 1, 0
%t.2 = insertvalue { i8, ptr, ptr } %t.1, ptr null, 1
%t.3 = insertvalue { i8, ptr, ptr } %t.2, ptr %box, 2
```

Both payloads are heap-allocated via `@mantiq_malloc(i64 32)`.

---

## 2. The `try` Expression

### 2.1 Grammar

```js
try_expr: $ => prec.right(15, seq(
    $.kw_try, $._postfix,
    optional(seq(
        'catch',
        optional(field('catch_binding', $.identifier)),
        ':', field('catch_body', choice($.block_body, $.statement))
    ))
)),
```

### 2.2 AST

```zig
// ast.zig:241-246
TryStmt: struct {
    body: *Node,
    catch_binding: ?[]const u8,
    catch_body: ?*Node,
    unwrapped_type: ?types.Type = null,   // populated during typecheck
},
```

### 2.3 Syntax

```nizam
// Full form with catch binding
let val as T = try fallible_fn() catch err:
    // handle error
    default_value

// Expression form (value used in expression)
let val as T = try fallible_fn() catch err: 0
```

### 2.4 Semantics

1. Evaluate `body` — must produce `Option[T]` or `Result[T, E]`
2. Check the **discriminant** (tag byte)
3. If **Ok/Some** (tag = 0): extract the payload value as type `T`
4. If **Err/Empty** (tag = 1): bind the error to `catch_binding` variable and execute `catch_body`
5. The overall expression type is the unwrapped payload type `T`

```zig
// typecheck.zig:2338-2355
check body_type is .Result or .Option
unwrapped_type = body_type.payload
node.inferred_type = unwrapped_type
```

### 2.5 LLVM IR

```llvm
; try expr catch err: handler
%result = call { i8, ptr } @fallible_fn()
%tag = extractvalue { i8, ptr } %result, 0
%is_ok = icmp eq i8 %tag, 0
br i1 %is_ok, label %ok_block, label %err_block

ok_block:
  %val_ptr = extractvalue { i8, ptr } %result, 1
  %val = load T, ptr %val_ptr
  store T %val, ptr %unwrapped_alloca
  br label %end

err_block:
  %err_ptr = extractvalue { i8, ptr } %result, 1
  %err_val = load T_err, ptr %err_ptr
  store T_err %err_val, ptr %err_var  ; catch_binding
  ; catch_body code here
  br label %end

end:
  %final = load T, ptr %unwrapped_alloca
```

For `Result[T, E]` — the error is extracted from slot 2:

```llvm
%err_ptr = extractvalue { i8, ptr, ptr } %result, 2
```

### 2.6 Catch Binding Type

The `catch_binding` variable is typed as the error payload type:

- For `Result[T, E]`: type is `E` (currently validated as `I32` or `Any`)
- For `Option[T]`: type is the payload type (since `Empty` carries no data, the tag error path stores the same payload pointer)

---

## 3. The `raise` Statement

### 3.1 Grammar

```js
jump_stmt: $ => seq(
    choice(
        seq(choice('return', 'break', 'continue'), optional(commaSep1($.expression))),
        seq('raise', $.expression)
    ),
    optional($._newline)
),
```

### 3.2 AST

```zig
// ast.zig:247-249
ThrowStmt: struct {
    value: *Node,
},
```

### 3.3 Syntax

```nizam
fn fallible() -> Result[i32, i32]:
    if bad_condition:
        raise 404
    return Ok(0)
```

### 3.4 Semantics

1. The enclosing function must return `Result[T, E]`
2. The `raise` expression is heap-allocated and wrapped in the `Err` variant
3. `raise` is a **definitive return** — code after it is unreachable

```zig
// typecheck.zig:2356-2373
// Validate: enclosing function returns Result type
throw_stmt: check enclosing fn return type is Result
raise value type must be compatible with E
```

### 3.5 LLVM IR

```llvm
; raise 404
%box = call ptr @mantiq_malloc(i64 32)
store i32 404, ptr %box
%t.1 = insertvalue { i8, ptr, ptr } undef, i8 1, 0
%t.2 = insertvalue { i8, ptr, ptr } %t.1, ptr null, 1
%t.3 = insertvalue { i8, ptr, ptr } %t.2, ptr %box, 2
ret { i8, ptr, ptr } %t.3
```

---

## 4. Control Flow Graph

**File:** `cfg.zig:70-72`

```zig
.ThrowStmt => {
    try self.collectReferencedNodes(node.data.ThrowStmt.value);
    cur_block.returns_always = true;   // no fallthrough
},
```

`ThrowStmt` is treated as a definitive return:

- Any statement following `raise` in the same block is detected as **unreachable code**
- Functions that use `raise` on all paths satisfy the **return on all paths** requirement

---

## 5. Unused Result Warning

**File:** `typecheck.zig:655`

When a function call returning `Result` or `Option` is used as a statement (not assigned or consumed by `try`), the type checker emits a warning:

```text
Type Error: Ignored 'Result[i32, i32]' value from function call.
Must be handled with 'try' or explicitly assigned.
```

This enforces that all fallible operations are explicitly handled.

---

## 6. Panics (Unrecoverable Errors)

### 6.1 Runtime Functions

```c
// runtime.c:837-843
void mantiq_panic(const char* message) {
    fprintf(stderr, "PANIC: %s\n", message);
    abort();
}

void mantiq_panic_at(const char* message, const char* file, int line, int col) {
    fprintf(stderr, "PANIC at %s:%d:%d: %s\n", file, line, col, message);
    abort();
}
```

### 6.2 LLVM Declarations

```zig
// codegen.zig:384-385
declare void @mantiq_panic(ptr)
declare void @mantiq_panic_at(ptr, ptr, i32, i32)
```

### 6.3 Panic Sites

| Check | File | Codegen |
|-------|------|---------|
| Array bounds | `codegen.zig:3862-3868` | `call void @mantiq_panic_at(...)` |
| Division by zero | `codegen.zig:5077-5100` | `call void @mantiq_panic_at(...)` |

```llvm
@.panic_str_bounds = private unnamed_addr constant [19 x i8] c"index out of bounds\00"

; before load from array
%in_bounds = icmp ult i64 %idx, %len
br i1 %in_bounds, label %ok, label %panic

panic:
  call void @mantiq_panic_at(ptr @.panic_str_bounds, ptr @.file_str, i32 %line, i32 %col)
  unreachable
ok:
  %val = load T, ptr %ptr
```

Panics are **not recoverable** — they abort the process. Unlike Result errors, panics represent programming bugs (out-of-bounds access, division by zero).

---

## 7. Nizam Mode Gating

### 7.1 Required Imports

In Nizam (safe) mode, `Option` and `Result` require explicit imports:

```nizam
from std.option import Option, Some, Empty
from std.result import Result, Ok, Err
```

### 7.2 Error on Missing Import

```zig
// typecheck.zig:490-495
if (self.mode == .nizam and !self.is_option_imported) {
    return error.ImplicitAllocationNotAllowed;
}
```

Mantiq (unsafe) mode provides `Option`, `Result`, `Some`, `Empty`, `Ok`, `Err` as built-in globals without import.

### 7.3 Flag Tracking

```zig
// typecheck.zig:40-41
is_option_imported: bool = false,
is_result_imported: bool = false,
```

Flags are set during import scanning in `checkProgram`:

| Module | Flag | Condition |
|--------|------|-----------|
| `std.option` | `is_option_imported` | All symbols or `Option`/`Some`/`Empty` imported |
| `std.result` | `is_result_imported` | All symbols or `Result`/`Ok`/`Err` imported |

---

## 8. Built-in Registration

**File:** `sema.zig:165-194`

All error-related constructors are registered as built-ins in `SemanticAnalyzer.init`:

```zig
const builtins = [_][]const u8{
    "make", "drop", "range", "print",
    "Some", "Empty", "None",
    "Ok", "Err",
};
```

These are available after `std.option` or `std.result` is imported (Nizam) or globally (Mantiq).

---

## 9. Type Classification

### 9.1 Option and Result Type Kinds

```zig
// types.zig:46
Option, Result, Task,
```

### 9.2 Copy / Move

| Type | Classification | Reason |
|------|---------------|--------|
| `Option[T]` | Move always | Contains heap-allocated payload |
| `Result[T, E]` | Move always | Contains heap-allocated payloads |

### 9.3 ABI

Option and Result use fat-pointer-style ABI (Direct mode) — the `{ i8, ptr }` or `{ i8, ptr, ptr }` struct is passed directly in registers.

---

## 10. Full Error Handling Workflow

```
Source code: try fallible_fn() catch err: handler_value
                         |
                         v
    grammar.js:417-426 — try_expr CST node
                         |
                         v
    lower.zig:627-685 — lowerTryStmt → TryStmt AST node
                         |
                         v
    sema.zig:833-847 — resolve TryStmt, push scope for catch binding
                         |
                         v
    typecheck.zig:2338-2355 — type-check body (must be Option/Result),
                              extract unwrapped_type → Ok/Some payload type
                         |
                         v
    codegen.zig:5168-5253 — LLVM IR: discriminant check, branch,
                            extractvalue payload, execute handler on error
                         |
                         v
    JIT/AOT execution
```

```
Source code: raise 404
                         |
                         v
    grammar.js:283-289 — jump_stmt (raise) CST node
                         |
                         v
    lower.zig:603-621 — lowerJumpStmt → ThrowStmt AST node
                         |
                         v
    sema.zig:848-850 — resolve ThrowStmt value
                         |
                         v
    typecheck.zig:2356-2373 — validate enclosing fn returns Result,
                              check raise value type
                         |
                         v
    codegen.zig:1920-1953 — heap-allocate, construct Err fat struct,
                            ret value
                         |
                         v
    JIT/AOT execution
```

---

## 11. Examples

### Result with try/catch

```nizam
from std.result import Result, Ok, Err

fn parse_age(age as i32) as Result[i32, i32]:
    if age == 20:
        return Ok(20)
    else:
        raise 404

fn main():
    let res as i32 = try parse_age(20) catch err:
        print(err)
        return 0
    print(res)
```

### Option with try/catch

```nizam
from std.option import Option, Some, Empty

fn find_user(id as i32) as Option[str]:
    if id == 1:
        return Some("Alice")
    else:
        return Empty

fn main():
    let name as str = try find_user(1) catch:
        "unknown"
    print(name)
```

### Nizam Mode — Import Required

```nizam
// Type error: 'Option' requires 'from std.option import Option'
fn bad() as Option[i32]:
    return Some(1)
```

### Unused Result Warning

```nizam
fn compute() as Result[i32, i32]:
    return Ok(42)

fn main():
    compute()  // Warning: unused Result value
    let _ = compute()  // OK: explicitly ignored
    let x = try compute() catch err: 0  // OK: handled
```

### Panic

```nizam
fn main():
    let arr as [3]i32 = [1, 2, 3]
    let x as i32 = arr[10]  // Panic: index out of bounds
```

---

## 12. Related Decision Records

| Document | Content |
|----------|---------|
| `docs/decisions/0017-std-option-result.md` | Module-based Option/Result via std.option / std.result |
| `docs/decisions/0029-async-actor-model.md` | Task type for concurrent error handling |

---

## 13. Relevant Files

| File | Lines | Role |
|------|-------|------|
| `grammar.js` | 259-266, 283-289, 417-426, 661 | try_expr, try_stmt, raise grammar |
| `ast.zig` | 86-87, 241-249 | TryStmt, ThrowStmt AST nodes |
| `lower.zig` | 6-11, 272, 603-621, 627-685 | CST→AST lowering |
| `sema.zig` | 17-21, 165-194, 345-359, 833-850 | Builtin registration, import handling, resolution |
| `types.zig` | 23-59, 324 | Option/Result TypeKind, formatType |
| `typecheck.zig` | 27-31, 37-41, 151-162, 490-495, 507-508, 655, 791-835, 2338-2373 | Type checking — imports, constructors, try/raise |
| `cfg.zig` | 70-72 | ThrowStmt as definitive return |
| `codegen.zig` | 168, 384-385, 584-591, 1920-1953, 2817-2824, 3515-3563, 3862-3868, 5077-5100, 5168-5253 | LLVM IR emission |
| `runtime.c` | 837-843 | mantiq_panic, mantiq_panic_at |
| `main.zig` | 642-661, 974-999, 1244-1368 | Pipeline, Option/Result tests |
| `docs/specification/0006-std-option-result.md` | All | Stdlib spec for Option/Result |
| `docs/decisions/0017-std-option-result.md` | All | Decision record for Option/Result |
