# Decision 0033: `Any` Type and Fat Pointer Boxing

## Context

Mantiq (superset mode) supports a dynamic `Any` type that can hold a value of any other type. This enables:

- Heterogeneous collections (`List[Any]`)
- Dynamic dispatch fallbacks
- OOP patterns where a method accepts "anything"
- Gradual typing — opting out of static type precision

The design must balance ergonomics (implicit boxing/unboxing) with the affine type system (heap allocations are explicit in Nizam).

---

## Language Specification

### Feature: `Any` Type

`Any` is a special type that can represent any value. In Mantiq mode it is a global built-in; in Nizam mode it requires `import` (since it implies heap allocation).

### Runtime Representation

**Decision: Fat pointer `{ ptr, ptr }` — boxed data pointer + type info pointer.**

```llvm
%Any = type { ptr, ptr }
```

| Field | Type | Contents |
|-------|------|----------|
| `.0`  | `ptr` | Heap-allocated copy of the boxed value |
| `.1`  | `ptr` | Type information tag (currently **always `null`**) |

**Size**: 16 bytes on x86_64 (two pointers).
**Alignment**: 8 bytes on x86_64.

### Boxing (Value → `Any`)

**Decision: Heap allocation of the value + store into fat pointer.**

When a value of type `T` is assigned to an `Any` slot, the compiler:

1. Allocates `sizeof(T)` bytes on the heap via `mantiq_malloc`
2. Stores the value into the allocation
3. Creates a `{ ptr, ptr }` fat pointer with the data pointer and null type tag

```llvm
; Boxing an i32 value 42 into Any
%box = call ptr @mantiq_malloc(i64 4)        ; sizeof(i32) = 4
store i32 42, ptr %box
%t.1 = insertvalue { ptr, ptr } undef, ptr %box, 0
%any = insertvalue { ptr, ptr } %t.1, ptr null, 1
```

The boxing happens in `coerceType` (codegen.zig:212-221) when the target type is `{ ptr, ptr }` and the source is any other type.

Currently, all boxing allocates 32 bytes (`i64 32`) regardless of the actual value size — this is a known simplification.

### Unboxing (`Any` → `T`)

**Decision: Extract the data pointer from the fat pointer and load.**

```llvm
; Unboxing an Any to i32
%box = extractvalue { ptr, ptr } %any, 0
%val = load i32, ptr %box
```

No runtime type check is performed — the second pointer (type info) is null. Attempting to unbox to the wrong type will load incorrect bytes (undefined behaviour).

### Implicit Conversion

**Decision: `Any` is implicitly convertible to/from every type.**

```zig
// types.zig:212
if (to.kind == .Any or from.kind == .Any) return true; // Anything can be cast to Any, and Any can cast to anything
```

This means:
- Any value can be assigned to an `Any` variable (implicit boxing)
- An `Any` value can be used where a concrete type is expected (implicit unboxing)
- No explicit `as Any` cast is required in Mantiq mode

In Nizam mode, implicit boxing triggers `ImplicitAllocationNotAllowed` unless inside an `unsafe` block.

### Type Classification

**Decision: `Any` is a Copy type.**

`Any` is 16 bytes (two pointers), fitting the Copy classification (size ≤ 16 bytes and trivially copyable). This means:

- `Any` values can be freely duplicated
- No move semantics on `Any` assignments
- No destructor — the heap-allocated box is **not freed** automatically (memory leak)

```zig
// types.zig: isCopyType — .Any is not explicitly listed,
// falls through to the default `return true` for non-move types.
// hasDestructor — .Any is not listed, default false.
```

**This means all boxed `Any` values currently leak memory** — there is no auto-drop for the heap-allocated box payload.

### ABI

**Decision: `Any` falls through to size-based classification (Coerce `{ i64, i64 }`).**

`Any` is not in the primitive list in `getArgABI`/`getRetABI`, so it falls through to the size check:
- Size = 16 → `Coerce` as `{ i64, i64 }` — passed in two registers (rax, rdx)

### LLVM Type Mapping

```zig
// codegen.zig:892
.Any => "{ ptr, ptr }",
```

The same `{ ptr, ptr }` layout is also used for `Function` and `Closure` types (codegen.zig:897-900), creating a natural union between dynamic values and callable values.

---

## Nizam / Mantiq Mode Differences

| Aspect | Mantiq | Nizam |
|--------|--------|-------|
| `Any` availability | Global built-in | Requires explicit `import` |
| Boxing to `Any` | Implicit | `unsafe` block required |
| Typical use | Dynamic dispatch, OOP | Avoided — explicit types preferred |

```zig
// sema.zig:176-186 — Mantiq mode
const mantiq_builtins = [_][]const u8{ "String", "List", "Any", ... };
```

---

## Codegen Integration

### Boxing Paths

There are two boxing code paths in codegen.zig:

1. **`coerceType`** (line 212): When a value is coerced to `{ ptr, ptr }` during type conversion (e.g. assignment to `Any` variable, function argument passing)

2. **`genUnaryExpr` / cast** (line 2914): When an explicit `CastExpr` or unary conversion targets `{ ptr, ptr }`

Both paths allocate 32 bytes via `mantiq_malloc` and construct the fat pointer.

### Unboxing Path

Unboxing happens in `coerceType` (line 224) when the source type is `{ ptr, ptr }` and the target is a concrete type. It extracts `.0` and loads the value.

### Preamble Declaration

```llvm
; codegen.zig:379-386
%Any = type { ptr, ptr }
declare ptr @mantiq_malloc(i64)
```

### Printing

Printing `Any` values (e.g. via `print(any_val)`) does not have special handling — the current print helpers would print the address or require manual extraction.

### Method Calls on `Any`

Method calls on `Any`-typed expressions resolve via `MemberExpr` / `MethodCallExpr` — the type checker allows method dispatch because `isImplicitlyConvertible` treats `Any` as compatible with everything.

---

## Current Limitations

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| All box allocations are 32 bytes | Wasted memory for small types, overflow for types > 32 bytes | Compute `sizeof(T)` dynamically for boxing |
| No runtime type info | Unboxing to wrong type is silent UB | Store a type-ID or vtable pointer in field `.1` |
| Boxed values are never freed | Memory leak on every boxing operation | Add auto-drop for `Any` that frees the heap box |
| `getSize(.Any)` returns 8 (should be 16) | Layout calculations may underestimate size | Fix `layout.zig:92` to return `ptr_size * 2` |
| `getAlign(.Any)` returns 16 (correct) | — | — |
| No downcasting | No `if x is T: unbox(x)` pattern | Add runtime type-checked downcasting |
| No Any-specific tests in `tests.zig` | Boxing/unboxing untested | Add unit tests for all boxing paths |

---

## Examples

### Implicit Boxing

```mantiq
let x as i32 = 42
let y as Any = x              // implicit box
let z as i32 = y              // implicit unbox
```

```llvm
%x = alloca i32
store i32 42, ptr %x
%box = call ptr @mantiq_malloc(i64 32)
%val = load i32, ptr %x
store i32 %val, ptr %box
%t.1 = insertvalue { ptr, ptr } undef, ptr %box, 0
%y = insertvalue { ptr, ptr } %t.1, ptr null, 1
; unbox
%data = extractvalue { ptr, ptr } %y, 0
%z = load i32, ptr %data
```

### Heterogeneous List (via `Any`)

```mantiq
let items as List[Any] = [42, "hello", 3.14]
```

### Nizam Unsafe Boxing

```nizam
from std.mem import Any
let x as i32 = 42
unsafe:
    let y as Any = x          // explicit unsafe block required
```

### Function Arguments

```mantiq
fn print_any(val as Any):
    print(val)

fn main():
    print_any(42)             // implicit box
    print_any("hello")        // implicit box
```

---

## Relevant Files

| File | Role |
|------|------|
| `types.zig:25` | `TypeKind.Any` enum variant |
| `types.zig:179` | `parseTypeString("Any")` → `.Any` |
| `types.zig:212` | `isImplicitlyConvertible` — Any compatible with everything |
| `types.zig:326` | `formatType` → `"Any"` |
| `layout.zig:92` | `getSize(.Any)` = 8 (likely bug, should be 16) |
| `layout.zig:187` | `getAlign(.Any)` = 16 |
| `codegen.zig:212-221` | Boxing: `coerceType` to `{ ptr, ptr }` |
| `codegen.zig:224-230` | Unboxing: `coerceType` from `{ ptr, ptr }` |
| `codegen.zig:379-386` | LLVM preamble: `%Any = type { ptr, ptr }` |
| `codegen.zig:892` | `typeToLLVM(.Any)` → `"{ ptr, ptr }"` |
| `codegen.zig:2914-2924` | Boxing in cast expression codegen |
| `codegen.zig:383,433` | `mantiq_malloc` declaration |
| `typecheck.zig` (various) | `Any` as inference default, method dispatch fallback |
| `sema.zig:178` | `"Any"` in Mantiq builtins list |
| `abi.zig:26-30` | Any falls through to size-based Coerce classification |
| `runtime.c:613` | `make()` returns Any with printf |
| `MANTIQ.mq:34` | Example: `let dynamic_content as Any = #000000 if is_dark_mode else "Black"` |
