# Decision 0031: ABI Calling Convention

## Context

Mantiq/Nizam compiles to LLVM IR, which is then compiled by `zig cc` (AOT) or JIT'd via `dlopen`. The generated IR must follow a consistent calling convention that is compatible with the SysV x86_64 ABI for C interop.

The key question is: **how are composite types (structs, unions, tuples, fat pointers) passed and returned?** LLVM's default `ret` and `call` semantics do not always match the C ABI — a `{ i64, i64 }` struct returned in registers requires explicit coercion to prevent LLVM from passing it via hidden sret.

---

## Language Specification

### Feature: Argument Passing Modes

**Decision: Three-passing-mode classification (`abi.zig`).**

Every argument type is classified into one of three `PassMode` values:

```zig
pub const PassMode = enum {
    Direct,   // Passed using its natural LLVM type
    ByVal,    // Passed as `ptr byval(T)` — caller heap-copies
    Coerce,   // Bitcast to `i64` or `{ i64, i64 }` for register passing
};
```

### Classification Algorithm

```zig
pub fn getArgABI(t: Type, target: Target) ABISignature {
    const size = layout.getSize(t, target);

    // Primitives and pointer-like types: Direct
    switch (t.kind) {
        .Void, .I8, .U8, .Char, .Boolean, .I16, .U16,
        .F16, .BFloat16, .I32, .U32, .F32,
        .I64, .U64, .F64, .ISize, .USize,
        .I128, .U128, .F128, .Enum,
        .RawPointer, .CStr, .QBit => return Direct;
    }

    if (size <= 8)   return Coerce(i64);
    if (size <= 16)  return Coerce({ i64, i64 });
    else             return ByVal(ptr);
}
```

| Size Range | Mode | LLVM Representation |
|------------|------|---------------------|
| ≤ 8 bytes | `Coerce` → `i64` | Forced into a single register (rax) |
| 9–16 bytes | `Coerce` → `{ i64, i64 }` | Split across rax and rdx |
| > 16 bytes | `ByVal` → `ptr byval(T)` | Hidden pointer — caller allocates and copies |

This matches SysV x86_64 behaviour where:
- INTEGER class (≤ 64 bits) → one register
- Two INTEGER class (≤ 128 bits) → two registers (rax, rdx)
- MEMORY class (> 128 bits, or > 64 bits without a second register) → stack / hidden pointer

### Classification Algorithm for Return Values

```zig
pub fn getRetABI(t: Type, target: Target) ABISignature {
    const size = layout.getSize(t, target);

    // Primitives: Direct
    switch (t.kind) {
        /* same as getArgABI primitives */ => return Direct;
    }

    if (size <= 8)   return Coerce(i64);
    if (size <= 16)  return Coerce({ i64, i64 });
    else             return Direct;  // Deferred sret — let LLVM handle it
}
```

**Difference from arguments**: For returns > 16 bytes, the current implementation returns `Direct` (let LLVM choose), rather than `ByVal`. This is a known simplification — a proper sret (hidden struct return pointer) implementation is planned.

### Codegen for Function Definitions

When emitting a function definition, the ABI classification affects both the function signature and the parameter entry block:

```llvm
; Example: struct Big { i64, i64, i64 }  (24 bytes → ByVal)
define void @foo(ptr byval(%Big) %s.param) {
entry:
  %s = alloca %Big, align 8
  %t.1 = load %Big, ptr %s.param, align 8
  store %Big %t.1, ptr %s, align 8
  ...
}
```

```llvm
; Example: struct Pair { i64, i64 }  (16 bytes → Coerce)
define void @bar({ i64, i64 } %p.param) {
entry:
  %p = alloca { i64, i64 }, align 8
  store { i64, i64 } %p.param, ptr %p, align 8
  ...
}
```

### Codegen for Call Sites

At call sites, the argument is first stored to an alloca, then loaded with the coerced type:

```llvm
; Passing a struct ≤ 16 bytes → Coerce
%t.1 = alloca %Pair, align 8
store %Pair %val, ptr %t.1, align 8
%t.2 = load { i64, i64 }, ptr %t.1, align 8
call void @bar({ i64, i64 } %t.2)
```

For `ByVal` arguments:
```llvm
%t.1 = alloca %Big, align 8
store %Big %val, ptr %t.1, align 8
call void @foo(ptr byval(%Big) %t.1)
```

For return values using `Coerce`:
```llvm
%t.1 = call { i64, i64 } @get_pair()
%t.2 = alloca %Pair, align 8
store { i64, i64 } %t.1, ptr %t.2, align 8
%t.3 = load %Pair, ptr %t.2, align 8
```

---

## Type Sizes and Alignment

### Target: x86_64 Linux

```zig
pub const Target = .{
    .arch = "x86_64",
    .os = "linux",
    .pointer_size = 8,
    .endianness = .Little,
    .triple = "x86_64-unknown-linux-gnu",
};
```

### `getSize` / `getAlign` Rules

| Type | Size | Align | Notes |
|------|------|-------|-------|
| `I8`–`U128` | 1–16 | 1–16 | Native integer sizes |
| `Enum` | 40 | 8 | Fixed-size — max 40 bytes (tag + payload) |
| `String` | 24 | 8 | `{ ptr, i64, i64 }` fat pointer |
| `Utf8Str` / `str` | 16 | 8 | `{ ptr, i64 }` fat pointer |
| `CStr` | 8 | 8 | Single pointer |
| `List` (dynamic) | 24 | 8 | `{ ptr, i64, i64 }` |
| `List` (fixed array) | `elem_size × len` | elem align | Inline array |
| `Tuple` | Sum of padded fields | Max field align | C-compatible struct layout |
| `Struct` | Sum of padded fields | Max field align | C-compatible struct layout |
| `Union` (plain) | Max field size (+tag) | Max field align | Tagged union variant |
| `Option` | 16 | 8 | `{ i8, ptr }` |
| `Result` | 24 | 8 | `{ i8, ptr, ptr }` |
| `Any` | 16 | 8 | `{ ptr, ptr }` |
| `Function` / `Closure` | 16 | 8 | `{ ptr, ptr }` |
| `Task` | 8 | 8 | Single pointer to `MantiqTask` |

**Struct/Tuple padding**: Fields are laid out with padding to satisfy each field's alignment requirement, and trailing padding rounds up to the struct's max alignment (C-compatible).

**Union layout**:
- Plain (untagged): size = max field size, padded to max field align
- Tagged: size = tag + padding + max field size, aligned to max(tag_align, field_align)

---

## LLVM Type Mappings

| Zig `TypeKind` | LLVM IR Type | Size | Rationale |
|----------------|--------------|------|-----------|
| `I8` / `U8` / `Char` / `Boolean` | `i8` | 1 | Native byte |
| `I16` / `U16` | `i16` | 2 | |
| `I32` / `U32` | `i32` | 4 | |
| `I64` / `U64` / `ISize` / `USize` | `i64` | 8 | |
| `I128` / `U128` | `i128` | 16 | |
| `F16` | `half` | 2 | |
| `BFloat16` | `bfloat` | 2 | |
| `F32` | `float` | 4 | |
| `F64` | `double` | 8 | |
| `F128` | `fp128` | 16 | |
| `String` | `{ ptr, i64, i64 }` | 24 | Capacity-aware fat pointer |
| `Utf8Str` / `AsciiStr` / `WebStr` / `RangeStr` | `{ ptr, i64 }` | 16 | Pointer + length |
| `CStr` | `ptr` | 8 | Null-terminated pointer |
| `List` (dynamic) | `{ ptr, i64, i64 }` | 24 | Buffer ptr + len + cap |
| `List` (fixed) | `[N x T]` | `N * sizeof(T)` | Inline array |
| `Dict` | `{ ptr, i64, i64 }` | 24 | Hash table ptr + len + cap |
| `Option` | `{ i8, ptr }` | 16 | Tag + payload pointer |
| `Result` | `{ i8, ptr, ptr }` | 24 | Tag + ok ptr + err ptr |
| `Any` | `{ ptr, ptr }` | 16 | Type info + boxed data |
| `QBit` | `i32` | 4 | Qubit index |
| `QReg` | `{ ptr, i32 }` | 12 | State vector ptr + size |
| `Function` | `{ ptr, ptr }` | 16 | Fn pointer + env pointer |
| `Closure` | `{ ptr, ptr }` | 16 | Fn pointer + env pointer |
| `RawPointer` | `ptr` | 8 | |
| `Enum` | (opaque) | ≤ 40 | Fixed-size tag+payload union |
| `Task` | `ptr` | 8 | Pointer to `MantiqTask` |
| `Class` | `ptr` | 8 | Heap-allocated class instance |
| `Interface` | `ptr` | 8 | Vtable pointer |
| `Slice` | `ptr` | 8 | View into array |

---

## Extern Function ABI

`extern fn` declarations use the same ABI classification but **omit the environment pointer** from the parameter list:

```zig
// codegen.zig:835-837
if (!f.is_extern) {
    try param_str.appendSlice("ptr");  // %env for closures
}
```

The environment pointer is the first parameter for non-extern functions (needed for closure trampolines and module dispatch). For `extern` functions, it is omitted entirely — the parameter list matches the source-level signature exactly, enabling direct C interop.

Example extern declaration in LLVM IR:

```llvm
; extern fn compress(data as ptr[u8], len as i64) -> i64
declare i64 @compress(ptr, i64)
```

---

## Current Limitations

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| sret not implemented | Structs > 16 bytes returned via LLVM default (may mismatch C ABI) | Add sret handling with hidden `ptr` parameter |
| Coerce store/load pattern | Generates extra allocas for register-sized arguments | Use direct bitcast or `ptrtoint`/`inttoptr` |
| Only x86_64 target defined | No ARM, WASM, or RISC-V support | Add target triples + per-target ABI tables |
| Alignment hardcoded in many codegen paths | May not match actual target alignment | Use `layout.getAlign` consistently |
| Union ABI not fully tested | Tagged union layout may not match C interop expectations | Verify against SysV union ABI rules |

---

## Examples

### Direct (Primitive)

```llvm
define i64 @add(i64 %a.param, i64 %b.param) {
entry:
  %a = alloca i64, align 8
  store i64 %a.param, ptr %a, align 8
  %b = alloca i64, align 8
  store i64 %b.param, ptr %b, align 8
```

### Coerce (Struct ≤ 16 bytes)

```llvm
; struct Pair { x: f64, y: f64 }  → size 16
define { i64, i64 } @make_pair({ i64, i64 } %p.param) {
entry:
  %p = alloca { i64, i64 }, align 8
  store { i64, i64 } %p.param, ptr %p, align 8
```

### ByVal (Struct > 16 bytes)

```llvm
; struct Big { a: i64, b: i64, c: i64 }  → size 24
define void @process_big(ptr byval({ i64, i64, i64 }) %b.param) {
entry:
  %b = alloca { i64, i64, i64 }, align 8
  %t.1 = load { i64, i64, i64 }, ptr %b.param, align 8
  store { i64, i64, i64 } %t.1, ptr %b, align 8
```

---

## Relevant Files

| File | Role |
|------|------|
| `abi.zig` | `PassMode` enum, `ABISignature` struct, `getArgABI`, `getRetABI` |
| `layout.zig` | `Target` struct (x86_64_linux), `getSize`, `getAlign` for all types |
| `codegen.zig:789-796` | Arg ABI in function declaration (extern) |
| `codegen.zig:842-849` | Arg ABI in function declaration (non-extern) |
| `codegen.zig:806-807` | Ret ABI in function declaration |
| `codegen.zig:1166-1173` | Arg ABI in function definition |
| `codegen.zig:1183-1184` | Ret ABI in function definition |
| `codegen.zig:1210-1224` | Arg ABI in parameter entry alloca/store |
| `codegen.zig:3174-3191` | Arg ABI in call site (variable call) |
| `codegen.zig:3201-3219` | Ret ABI coercion at call site |
| `codegen.zig:3779-3807` | Arg/Ret ABI in method call sites |
| `codegen.zig:4507-4514` | Arg ABI in `self` parameter passing |
| `codegen.zig:4884-4906` | Arg/Ret ABI in built-in call sites |
| `codegen.zig:1928-1951` | Ret ABI in throw-stmt return path |
| `codegen.zig:865-899` | `typeToLLVM` — type name mappings |
