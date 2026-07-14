# Language Specification: Control Flow

## Overview

Mantiq/Nizam provides imperative control flow constructs: conditional branching (`if`/`elif`/`else`), pattern matching (`match`), definite loops (`for`), conditional loops (`while`), and jump statements (`break`, `continue`, `pass`, `return`, `raise`). Ternary expressions (`X if cond else Y`) exist as syntactic sugar over `if` expressions.

---

## 1. Conditional Branching

### 1.1 `if` / `elif` / `else`

```nizam
if condition:
    body
elif other_condition:
    other_body
else:
    fallback_body
```

**Grammar**:

```js
if_stmt: $ => seq(
    'if', $.expression, ':', $._suite,
    repeat(seq('elif', $.expression, ':', $._suite)),
    optional(seq('else', ':', $._suite))
)
```

**Semantics**:
- `condition` is evaluated; must be Boolean-coercible
- First truthy condition's body is executed; remaining branches are skipped
- `elif` chains are desugared to nested `if` in the `else_branch` of the previous `if`
- The entire `if`/`elif`/`else` expression has a result type: the unification of then-type and else-type (or `Void` if they don't unify)

**Type inference** (`typecheck.zig:1309-1332`):

```zig
// If branches return different types, default to Void
const then_t = ...;
const else_t = ...;
if (types.isImplicitlyConvertible(then_t, else_t)) {
    node.inferred_type = else_t;
} else if (types.isImplicitlyConvertible(else_t, then_t)) {
    node.inferred_type = then_t;
} else {
    node.inferred_type = .{ .kind = .Void };
}
```

**Codegen** (`codegen.zig:2589-2642`): Generates LLVM IR with a phi-node pattern via alloca:

```llvm
%cond_val = ... ; evaluate condition
%cond_i1 = icmp ne i32 %cond_val, 0
br i1 %cond_i1, label %if.then, label %if.else
if.then:
  %then_val = ...
  store i32 %then_val, ptr %result
  br label %if.end
if.else:
  %else_val = ...
  store i32 %else_val, ptr %result
  br label %if.end
if.end:
  %merged = load i32, ptr %result
```

### 1.2 Ternary Expression

```nizam
let max_val = a if a > b else b
```

**Lowering** (`lower.zig:508-530`): Desugared during CST→AST lowering to an `IfStmt`. Equivalent to:

```nizam
let max_val as i32 = if a > b: a else: b
```

---

## 2. Pattern Matching

### 2.1 `match` Statement

```nizam
match subject:
    case pattern_1 [if guard_1]:
        body_1
    case pattern_2:
        body_2
    case _:
        fallback_body
```

**Grammar**:

```js
match_stmt: $ => seq(
    'match', field('subject', $.expression), ':', $._newline,
    $._indent,
    repeat1(seq(
        'case', field('pattern', choice(
            $.identifier, $.number, $.string, $.boolean,
            $.binary_expression  // for range patterns
        )),
        optional(seq('if', field('guard', $.expression))),
        ':', $._suite
    )),
    $._dedent
)
```

**Pattern types**:

| Pattern | Example | Semantics |
|---------|---------|-----------|
| Variable binding | `case x:` | Bind subject to name `x`, always matches |
| Wildcard | `case _:` | Ignores subject, always matches (last resort) |
| Literal | `case 42:` | `icmp eq` comparison |
| Range | `case 10..20:` | `icmp sge` && `icmp sle` |
| Guard | `case x if x < 50:` | Guard expression evaluated after pattern match |

**Codegen** (`codegen.zig:1732-1826`):

```llvm
  br label %match.case.0
match.case.0:
  %cmp.0 = icmp eq i32 %subject, 42
  br i1 %cmp.0, label %match.body.0, label %match.case.1
match.body.0:
  ... body ...
  br label %match.end
match.case.1:
  %cmp.1 = icmp sge i32 %subject, 10
  %cmp.2 = icmp sle i32 %subject, 20
  %cmp.3 = and i1 %cmp.1, %cmp.2
  br i1 %cmp.3, label %match.body.1, label %match.case.2
match.body.1:
  ... body ...
  br label %match.end
match.case.2:
  ; wildcard _ always matches
  br label %match.body.2
match.body.2:
  ... body ...
  br label %match.end
match.end:
```

---

## 3. Loops

### 3.1 `while` Loop

```nizam
while condition:
    body
```

**Grammar**:

```js
while_stmt: $ => seq(
    optional($.loop_modifier),
    'while', $.expression, ':', $._suite
)
```

**CFG analysis** (`cfg.zig:73-77`): A `while` loop never guarantees return (body may not execute).

**Codegen** (`codegen.zig:2509-2544`):

```llvm
  br label %while.cond
while.cond:
  %cond = ...
  %cmp = icmp ne i32 %cond, 0
  br i1 %cmp, label %while.body, label %while.end
while.body:
  ... body ...
  br label %while.cond
while.end:
```

### 3.2 `for` Loop

```nizam
for iterator as Type in iterable:
    body

for@par i in 0..CPU_CORES:      // parallel
    thread_work(i)

for@vec i in 0..1024:            // auto-vectorize
    data[i] *= 2.0
```

**Grammar**:

```js
for_stmt: $ => seq(
    'for',
    optional(field('modifier', $.loop_modifier)),
    field('iterator', $.identifier),
    optional($.type_annotation),
    'in',
    field('iterable', $.expression),
    ':', $._suite
)

loop_modifier: $ => choice('@par', '@vec')
```

**Three codegen modes** (`codegen.zig:1496-1729`):

| Mode | When | Codegen |
|------|------|---------|
| **Parallel** (`is_parallel`) | `for@par` | Outlines body as `__mantiq_par_closure<id>` function, calls `__mantiq_parallel_for(start, end, closure_ptr, null)` |
| **Vectorized** (`is_vectorized`) | `for@vec` | Same as sequential with `!llvm.loop.vectorize.enable` metadata |
| **Sequential** | default | Numeric iteration over `range()` or `start..end`, or buffer iteration over `List`/`Tuple` (GEP + load pattern) |

**Sequential codegen**:

```llvm
  %start = ... ; evaluate iterable
  %end = ...
  ; %i = alloca i32
  store i32 %start, ptr %i
  br label %for.cond
for.cond:
  %i_val = load i32, ptr %i
  %cmp = icmp slt i32 %i_val, %end
  br i1 %cmp, label %for.body, label %for.end
for.body:
  ... body using %i_val ...
  %next = add i32 %i_val, 1
  store i32 %next, ptr %i
  br label %for.cond
for.end:
```

**List/tuple iteration**: Extracts buffer pointer from `{ ptr, i64, i64 }`, indexes via GEP:

```llvm
%buf = extractvalue { ptr, i64, i64 } %list, 0
%len = extractvalue { ptr, i64, i64 } %list, 1
; for each index i:
%elem = getelementptr inbounds T, ptr %buf, i64 %i
%val = load T, ptr %elem
```

### 3.3 `break` / `continue`

```nizam
while condition:
    if something:
        break        // exit loop
    else:
        continue     // restart at condition check
    pass             // (only reached if neither break nor continue)
```

**Codegen** (`codegen.zig:2546-2566`):

```llvm
break:
  br label %while.end
  ; dead block to keep IR valid
  br label %dead

continue:
  br label %while.cond
  ; dead block
  br label %dead
```

Uses `active_loop_cond` / `active_loop_exit` tracking to know which labels to jump to. These are saved/restored around nested loop entry.

### 3.4 `pass` (No-op)

```nizam
if condition:
    pass               // do nothing
```

**Codegen**: Returns `"null"`, emits no LLVM instructions.

---

## 4. Jump Statements

### 4.1 `return`

```nizam
fn add(a as i32, b as i32) as i32:
    return a + b
```

Single and multi-value returns are supported. Auto-drops are emitted before the `ret` instruction.

### 4.2 `raise` / `throw`

```nizam
fn divide(a as i32, b as i32) as Result[i32, str]:
    if b == 0:
        raise "division by zero"
    return Ok(a / b)
```

`raise` (or `throw`) evaluates the value and generates a `Result` with the error variant, then returns it. Requires the enclosing function to have a `Result` or `Option` return type.

---

## 5. Special Blocks

### 5.1 `unsafe` Block

```nizam
unsafe:
    body
```

Disables certain safety checks (plain union field access). Body is generated transparently.

### 5.2 `with` Block (Context Manager)

```nizam
with resource as res:
    use(res)
```

The resource expression is evaluated, the variable `res` is bound, the body runs, and the resource's context manager exit is called on scope exit. Auto-drops are injected by the borrow checker.

### 5.3 `block` (Parameterized Block)

```nizam
block (x as i32, y as i32) as (res_x as i64, res_y as i64):
    res_x = x * 2
    res_y = y * 3
```

Parameterized blocks create a scope with parameters and return variables. They can be compiled as closures (IIFE pattern) via the `closure_node` anchor in the scope.

---

## 6. CFG Analysis

### 6.1 Return Path Completeness

**Decision**: `cfg.zig` performs a guaranteed-return analysis for non-void functions. A function that has any path without `return` (or `raise`) gets a compile error.

```zig
// cfg.zig:73-77
.WhileStmt => {
    return false;  // while may not execute
},
.ForStmt => {
    return false;  // for may not execute
},
.IfStmt => {
    return then_ret and else_ret;  // both branches must return
},
```

### 6.2 Unreachable Code Detection

After a guaranteed-return block (if+else both return, or `return` statement), subsequent code is flagged:

```zig
// cfg.zig:39-53
if (always_returns) {
    std.debug.print("CFG Warning: Unreachable code after guaranteed return\n", .{});
}
```

---

## 7. Borrow Checker Integration

| Construct | Borrow Checker Behaviour |
|-----------|-------------------------|
| `if` | Condition, then, else all walked for moves |
| `while` | Condition and body walked |
| `for` | Iterable and body walked |
| `with` | Context manager variable tracked through scope, auto_drop emitted |
| `return` | Moves processed, auto_drops collected across all scopes |
| `match` | Subject and each case's body walked |

Auto-drops are injected at scope exit for `BlockStmt`, `WithStmt`, and `ReturnStmt`.

---

## 8. Examples

### If/Elif/Else

```nizam
fn classify(score as i32) as str:
    if score >= 90:
        return "A"
    elif score >= 80:
        return "B"
    elif score >= 70:
        return "C"
    else:
        return "F"
```

### Match

```nizam
fn describe(num as i32) as str:
    match num:
        case 0:
            return "zero"
        case 1..9:
            return "small"
        case 10..99:
            return "medium"
        case _ if num < 0:
            return "negative"
        case _:
            return "large"
```

### For Loop with Range

```nizam
fn sum(n as i32) as i32:
    let total as i32 = 0
    for i in 0..n:
        total = total + i
    return total
```

### While Loop

```nizam
fn gcd(a as i32, b as i32) as i32:
    var x as i32 = a
    var y as i32 = b
    while y != 0:
        let tmp as i32 = y
        y = x % y
        x = tmp
    return x
```

### Parallel Loop

```nizam
for@par i in 0..num_cores:
    process_chunk(i)
```

---

## 9. Pipeline Summary

| Stage | File | Handling |
|-------|------|----------|
| **Parsing** | `grammar.js` | CST rules for all control flow syntax |
| **Lowering** | `lower.zig` | CST→AST: `lowerIfStmt`, `lowerForStmt`, `lowerWhileStmt`, `lowerMatchStmt`, `lowerJumpStmt`, `lowerPassStmt`, `lowerTernary`, etc. |
| **Semantic analysis** | `sema.zig` | Name resolution, scope push/pop for `for`, `match`, `with` |
| **Type checking** | `typecheck.zig` | Type inference, branch type unification, match pattern typing |
| **Borrow checking** | `borrowck.zig` | Move tracking, context manager tracking, auto_drop injection |
| **CFG analysis** | `cfg.zig` | Return path completeness, unreachable code detection |
| **Codegen** | `codegen.zig` | LLVM IR: branches, phi via alloca, loop headers/feet, break/continue targets |
