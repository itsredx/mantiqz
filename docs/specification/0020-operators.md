# Language Specification: Operators

## Overview

All operators are compiled to LLVM IR instructions directly. There is **no operator overloading** — operator meaning is fixed per type class. The precedence chain has 17 levels.

---

## 1. Precedence Table

| Level | Assoc | Category | Operators | Grammar Rule |
|-------|-------|----------|-----------|-------------|
| 1 | right | Assignment | `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `**=`, `<<=`, `>>=`, `&=`, `|=`, `^=` | `assignment` |
| 2 | left | Null coalescing | `??` | `_bin_expr_2` |
| 3 | left | Logical OR | `or` | `_bin_expr_3` |
| 4 | left | Logical AND | `and` | `_bin_expr_4` |
| 5 | left | Bitwise OR | `\|` | `_bin_expr_5` |
| 6 | left | Bitwise XOR | `^` | `_bin_expr_6` |
| 7 | left | Bitwise AND | `&` | `_bin_expr_7` |
| 8 | left | Equality | `==`, `!=` | `_bin_expr_8` |
| 9 | left | Comparison | `>`, `>=`, `<`, `<=`, `is`, `is not`, `in`, `not in` | `_bin_expr_9` |
| 10 | left | Range | `..` | `_bin_expr_10` |
| 11 | left | Shift | `<<`, `>>` | `_bin_expr_11` |
| 12 | left | Term | `-`, `+` | `_bin_expr_12` |
| 14 | left | Factor | `*`, `/`, `%` | `_bin_expr_14` |
| 15 | right | Unary | `not`/`!`, `-`, `+`, `~`, `deref`, `size`, `type`, `ref`/`ref mut`, `await`, `spawn`, `try` | `unary_expression` |
| 16 | right | Power | `**` | `_bin_expr_16_r` |
| 17 | left | Postfix | `f()`, `a[i]`, `a.b`, `++`, `--` | `call_expression`, `index_expression`, `member_expression`, `update_expression` |

---

## 2. AST Representation

### 2.1 BinaryExpr

```zig
// ast.zig:250-254
BinaryExpr: struct {
    left: *Node,
    right: *Node,
    operator: []const u8,
},
```

Operator strings: `"+"`, `"-"`, `"*"`, `"/"`, `"%"`, `"=="`, `"!="`, `"<"`, `">"`, `"<="`, `">="`, `"and"`, `"or"`, `"&"`, `"|"`, `"^"`, `"<<"`, `">>"`, `".."`, `"??"`, `"="`, `"**"`, `"is"`, `"is not"`, `"in"`, `"not in"`.

Assignment (`=`) uses `BinaryExpr` — there is no separate `AssignExpr` node.

### 2.2 UnaryExpr

```zig
// ast.zig:255-258
UnaryExpr: struct {
    operand: *Node,
    operator: []const u8,
},
```

Operator strings: `"not"`, `"-"`, `"+"`, `"~"`, `"ref"`, `"ref mut"`, `"deref"`.

`await`, `spawn`, `try` are separate AST nodes (`AwaitExpr`, `SpawnStmt`, `TryStmt`), not `UnaryExpr`.

---

## 3. Type Checking

### 3.1 BinaryExpr

**File:** `typecheck.zig:1396-1441`

```
1. Type-check left and right operands
2. For "=" with MemberExpr left: validate field mutability
3. Common type coercion: F64 > F32 > ... (coerce both to wider type)
4. Result type:
   - ==, !=, <, >, <=, >=, and, or → Boolean
   - everything else → common type of operands
```

### 3.2 UnaryExpr

**File:** `typecheck.zig:1442-1468`

| Operator | Result Type |
|----------|-------------|
| `not` | Boolean (operand must be Boolean) |
| `ref` / `ref mut` | `RawPointer` with operand as payload |
| `deref` | Payload type of pointer (error if not pointer) |
| `-`, `+`, `~` | Operand's inferred type |

---

## 4. Codegen — LLVM IR

**File:** `codegen.zig:5009-5168` (BinaryExpr), `codegen.zig:5255-5296` (UnaryExpr)

### 4.1 Arithmetic

| Operator | Int | Float |
|----------|-----|-------|
| `+` | `add` | `fadd` |
| `-` | `sub` | `fsub` |
| `*` | `mul` | `fmul` |
| `/` | `sdiv` (with div-by-zero panic) | `fdiv` |
| `%` | `srem` (with div-by-zero panic) | `frem` |

```llvm
; a + b
%sum = add i64 %a, %b

; Division with zero check
%is_zero = icmp eq i64 %b, 0
br i1 %is_zero, label %panic, label %ok
panic:
  call void @mantiq_panic_at(ptr @.div_zero_str, ptr @.file, i32 %line, i32 %col)
  unreachable
ok:
  %quot = sdiv i64 %a, %b
```

### 4.2 Comparison

| Operator | Int | Float | String |
|----------|-----|-------|--------|
| `==` | `icmp eq` | `fcmp oeq` | `call @__mantiq_streq` |
| `!=` | `icmp ne` | `fcmp one` | `call @__mantiq_streq` + `xor` |
| `<` | `icmp slt` | `fcmp olt` | — |
| `>` | `icmp sgt` | `fcmp ogt` | — |
| `<=` | `icmp sle` | `fcmp ole` | — |
| `>=` | `icmp sge` | `fcmp oge` | — |

All comparison results are `i8` (`zext i1 to i8`).

### 4.3 Logical

| Operator | LLVM IR | Notes |
|----------|---------|-------|
| `and` | `and` | Same as bitwise AND |
| `or` | `or` | Same as bitwise OR |

### 4.4 Bitwise

| Operator | LLVM IR |
|----------|---------|
| `&` | `and` |
| `\|` | `or` |
| `^` | `xor` |
| `<<` | `shl` |
| `>>` | `lshr` (unsigned types) / `ashr` (signed types) |
| `~` | `xor %val, -1` |

### 4.5 Unary

| Operator | LLVM IR | Notes |
|----------|---------|-------|
| `ref` / `ref mut` | returns LValue pointer | `genLValue` |
| `deref` | `load T, ptr %val` | — |
| `not` | `xor %val, 1` | Flip boolean |
| `-` (negate) | `fneg` (float) / `sub 0, %val` (int) | — |
| `+` (identity) | passthrough | Returns operand unchanged |
| `~` (bitwise not) | `xor %val, -1` | — |

### 4.6 Assignment

Only `=` is handled (compound assignments parsed but silently return `"null"` in codegen):

```llvm
; a = 42
store i32 42, ptr %a
```

LValue resolution for the left-hand side dispatches on node type:

| LHS Node Type | Method |
|---------------|--------|
| `Identifier` | Global or stack alloca lookup |
| `MemberExpr` | GEP into struct/union |
| `UnaryExpr(deref)` | Pointer dereference |
| `IndexExpr` | GEP into array |

### 4.7 Compound Assignments

Parsed by the grammar (`+=`, `-=`, `*=`, `/=`, `%=`, `**=`, `<<=`, `>>=`, `&=`, `|=`, `^=`) but **not implemented** in codegen — fall through to `return "null"`.

---

## 5. Compound Assignment Expansion

Compound assignments are syntactic sugar that **should** expand to:

```
a += b   →   a = a + b
a *= b   →   a = a * b
```

The LHS is evaluated once. Currently parsed but **not code-generated**.

---

## 6. Type Coercion in Binary Operations

**File:** `typecheck.zig` — common type resolution:

```
coercion hierarchy:
  F64 > F32 > I64 > I32 > I16 > I8 > ... Unknown

When operands differ, both are coerced to the wider type.
Unknown coerces to the known operand's type.
```

---

## 7. Pre/Post Increment/Decrement

```js
// grammar.js:443 — inside _postfix
update_expression: $ => choice(
    seq($._postfix, '++'),
    seq($._postfix, '--'),
    seq('++', $._postfix),
    seq('--', $._postfix),
)
```

| Form | Meaning |
|------|---------|
| `x++` | Post-increment |
| `x--` | Post-decrement |
| `++x` | Pre-increment |
| `--x` | Pre-decrement |

---

## 8. Operator Summary

### 8.1 Arithmetic

| Op | Name | Int | Float | Bool | String |
|----|------|-----|-------|------|--------|
| `+` | Add | ✓ | ✓ | — | — |
| `-` | Subtract | ✓ | ✓ | — | — |
| `*` | Multiply | ✓ | ✓ | — | — |
| `/` | Divide | ✓ (panic on zero) | ✓ | — | — |
| `%` | Modulo | ✓ (panic on zero) | ✓ | — | — |
| `**` | Power | ✓ | ✓ | — | — |
| `-` | Negate | ✓ | ✓ | — | — |
| `+` | Identity | ✓ | ✓ | — | — |

### 8.2 Bitwise

| Op | Name | Int | Bool |
|----|------|-----|------|
| `&` | AND | ✓ | ✓ |
| `\|` | OR | ✓ | ✓ |
| `^` | XOR | ✓ | ✓ |
| `~` | NOT | ✓ | — |
| `<<` | Shift left | ✓ | — |
| `>>` | Shift right | ✓ | — |

### 8.3 Comparison

| Op | Name | Int | Float | Bool | String | Pointer |
|----|------|-----|-------|------|--------|---------|
| `==` | Equal | ✓ | ✓ | ✓ | ✓ | ✓ |
| `!=` | Not equal | ✓ | ✓ | ✓ | ✓ | ✓ |
| `<` | Less | ✓ | ✓ | — | — | — |
| `>` | Greater | ✓ | ✓ | — | — | — |
| `<=` | LE | ✓ | ✓ | — | — | — |
| `>=` | GE | ✓ | ✓ | — | — | — |

### 8.4 Logical

| Op | Name | Bool |
|----|------|------|
| `and` | AND | ✓ |
| `or` | OR | ✓ |
| `not` / `!` | NOT | ✓ |

### 8.5 Reference

| Op | Name | Any |
|----|------|-----|
| `ref` | Take reference | ✓ |
| `ref mut` | Take mutable reference | ✓ |
| `deref` | Dereference | ✓ (pointer only) |

### 8.6 Other

| Op | Name | Notes |
|----|------|-------|
| `=` | Assignment | Simple store |
| `+=` etc. | Compound | Parsed only, not code-genned |
| `..` | Range | Creates range iterator |
| `??` | Null coalescing | (defined in grammar, codegen TBD) |
| `is` / `is not` | Type check | Runtime type tag comparison |
| `in` / `not in` | Containment | Collection membership |

---

## 9. Examples

```nizam
// Arithmetic
let sum = a + b
let diff = a - b
let product = a * b
let quot = a / b
let rem = a % b

// Comparison
if a == b: print("equal")
if a != b: print("not equal")
if a < b: print("less")

// Logical
if a > 0 and b > 0: print("both positive")
if not found: print("not found")

// Bitwise
let flags = READ | WRITE
let masked = value & 0xFF
let shifted = value << 2

// Reference
let p = ref x
let val = deref p

// Assignment
let mut x as i32 = 10
x = 20

// Range
for i in 0..10:
    print(i)
```

---

## 10. Relevant Files

| File | Lines | Role |
|------|-------|------|
| `grammar.js` | 332-340, 410-415, 443, 760-772 | All operator grammar rules and precedence |
| `ast.zig` | 89-90, 250-258 | BinaryExpr, UnaryExpr node definitions |
| `lower.zig` | 249, 293-295, 1136-1167, 2024-2065, 2395-2526 | CST→AST operator lowering |
| `typecheck.zig` | 1396-1441, 1442-1468 | Operator type checking |
| `codegen.zig` | 5009-5168, 5255-5296 | LLVM IR emission for all operators |
| `codegen.zig` | 2026-2034 | LValue gen for deref |
| `codegen.zig` | 593-599 | Operator type collection |
| `types.zig` | 23-59 | TypeKind variants |
