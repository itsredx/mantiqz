# Language Specification: Complete Type Reference

## Overview

Mantiq and Nizam share a unified type system. Nizam is a strict subset that disallows implicit heap allocations and requires explicit imports for heap types (`String`, `List`, `Dict`, `Option`, `Result`). Mantiq enables these types globally.

Types are classified as **Copy** (freely duplicatable by bitwise copy) or **Move** (affine — ownership must be transferred). This classification is determined recursively for composite types.

---

## 1. Primitive Types

### 1.1 Signed Integers

| Type | Alias | Size | Alignment | LLVM IR | Copy/Move |
|------|-------|------|-----------|---------|-----------|
| `I8` | — | 1 byte | 1 | `i8` | Copy |
| `I16` | — | 2 bytes | 2 | `i16` | Copy |
| `I32` | — | 4 bytes | 4 | `i32` | Copy |
| `I64` | — | 8 bytes | 8 | `i64` | Copy |
| `I128` | — | 16 bytes | 16 | `i128` | Copy |
| `ISize` | — | 8 bytes (x86_64) | 8 | `i64` | Copy |

### 1.2 Unsigned Integers

| Type | Aliases | Size | Alignment | LLVM IR | Copy/Move |
|------|---------|------|-----------|---------|-----------|
| `U8` | `byte` | 1 byte | 1 | `i8` | Copy |
| `U16` | — | 2 bytes | 2 | `i16` | Copy |
| `U32` | — | 4 bytes | 4 | `i32` | Copy |
| `U64` | — | 8 bytes | 8 | `i64` | Copy |
| `U128` | — | 16 bytes | 16 | `i128` | Copy |
| `USize` | — | 8 bytes (x86_64) | 8 | `i64` | Copy |

### 1.3 Floating Point

| Type | Aliases | Size | Alignment | LLVM IR | Copy/Move |
|------|---------|------|-----------|---------|-----------|
| `F16` | — | 2 bytes | 2 | `half` | Copy |
| `BFloat16` | `bf16` | 2 bytes | 2 | `bfloat` | Copy |
| `F32` | — | 4 bytes | 4 | `float` | Copy |
| `F64` | — | 8 bytes | 8 | `double` | Copy |
| `F128` | — | 16 bytes | 16 | `fp128` | Copy |

### 1.4 Boolean

| Type | Size | Alignment | LLVM IR | Copy/Move |
|------|------|-----------|---------|-----------|
| `Boolean` | 1 byte | 1 | `i8` | Copy |

Represented as `i8` (0 = false, 1 = true). Aliases: `bool`.

### 1.5 Character

| Type | Size | Alignment | LLVM IR | Copy/Move |
|------|------|-----------|---------|-----------|
| `Char` | 1 byte | 1 | `i8` | Copy |

A single Unicode code point stored as a byte. On x86_64, this is a single ASCII/UTF-8 byte. Multi-byte characters span multiple `Char` values.

---

## 2. String Types

Mantiq supports a multi-tiered string representation to decouple immutable slice views from owned dynamic buffers.

### 2.1 `Utf8Str` (alias `str`, `ustr`, `u8str`)

- **Layout**: `{ ptr, i64 }` (fat pointer: data pointer + byte length) — 16 bytes on x86_64
- **Mutability**: Immutable
- **Semantics**: Zero-cost slice view into `.rodata`, stack arrays, or heap buffers. Slicing returns a new `str` pointing to the same buffer.
- **Encoding**: Guaranteed UTF-8
- **LLVM IR**: `{ ptr, i64 }`
- **Copy/Move**: Move (owned pointer to buffer)
- **`hasDestructor`**: Yes

### 2.2 `String`

- **Layout**: `{ ptr, i64, i64 }` (data pointer + length + capacity) — 24 bytes on x86_64
- **Mutability**: Mutable
- **Semantics**: Uniquely owned, growable heap-allocated buffer.
- **Encoding**: Guaranteed UTF-8
- **LLVM IR**: `{ ptr, i64, i64 }`
- **Copy/Move**: Move
- **`hasDestructor`**: Yes

### 2.3 `AsciiStr` (alias `asciistr`, `astr`)

- **Layout**: `{ ptr, i64 }` — 16 bytes
- **Encoding**: Guaranteed 7-bit ASCII
- **Copy/Move**: Move
- **`hasDestructor`**: Yes

### 2.4 `WebStr` (alias `webstr`, `utf16str`, `u16str`, `wstr`)

- **Layout**: `{ ptr, i64 }` — 16 bytes
- **Encoding**: Guaranteed UTF-16
- **Copy/Move**: Move
- **`hasDestructor`**: Yes

### 2.5 `RangeStr` (alias `rangestr`, `rstr`, `utf32str`, `u32str`)

- **Layout**: `{ ptr, i64 }` — 16 bytes
- **Encoding**: Guaranteed UTF-32
- **Copy/Move**: Move
- **`hasDestructor`**: Yes

### 2.6 `CStr` (alias `cstr`)

- **Layout**: `ptr` (thin pointer) — 8 bytes
- **Mutability**: Immutable (typically)
- **Semantics**: Null-terminated C-compatible string. No encoding guarantees.
- **LLVM IR**: `ptr`
- **Copy/Move**: Move
- **`hasDestructor`**: Yes

### String Literal Syntax

| Syntax | Inferred Type |
|--------|---------------|
| `"hello"` | `Utf8Str` (`str`) |
| `c"hello"` | `CStr` |

### String Conversions

| Conversion | Mechanism | Description |
|------------|-----------|-------------|
| `str` → `String` | `to String` or `.to_string()` | Heap-allocates a copy with capacity = length + 1 |
| `String` → `str` | Implicit coercion | Drops capacity field, yields `{ ptr, len }` |
| `str`/`String` → `cstr` | Implicit coercion | Extracts data pointer only |
| Any string variant → another | Implicit assignment | Allowed between `String`, `AsciiStr`, `Utf8Str`, `WebStr`, `RangeStr`, `CStr` |

---

## 3. Collection Types

### 3.1 `List[T, N]` / `List[T]`

- **Fixed-size** (`List[T, N]`): `[N x T]` inline array — size is `N * sizeof(T)`
- **Dynamic** (`List[T]`): `{ ptr, i64, i64 }` — 24 bytes (buffer pointer, length, capacity)
- **LLVM IR**: `[N x T]` or `{ ptr, i64, i64 }`
- **Copy/Move**: Move
- **`hasDestructor`**: Yes (dynamic only)

### 3.2 `Dict[K, V]`

- **Layout**: `{ ptr, i64, i64 }` — 24 bytes (hash table pointer, length, capacity)
- **LLVM IR**: `{ ptr, i64, i64 }`
- **Copy/Move**: Move

### 3.3 `Tuple[A, B, ...]`

- **Layout**: Sequentially packed fields with alignment padding
- **LLVM IR**: `{ type_A, type_B, ... }`
- **Copy/Move**: Copy if all element types are Copy
- **`hasDestructor`**: Yes if any element has a destructor

### 3.4 `Slice`

- **Layout**: `ptr` (data pointer, no length — primarily for C interop)
- **LLVM IR**: `ptr`
- **Copy/Move**: Move

---

## 4. Control Flow Types

### 4.1 `Option[T]`

- **Layout**: `{ i8, ptr }` — 16 bytes (discriminant byte + payload pointer)
- **LLVM IR**: `{ i8, ptr }`
- **Copy/Move**: Copy if T is Copy
- **Constructors**: `Some(value)`, `None` / `Empty`

### 4.2 `Result[T, E]`

- **Layout**: `{ i8, ptr, ptr }` — 24 bytes (discriminant + ok pointer + err pointer)
- **LLVM IR**: `{ i8, ptr, ptr }`
- **Copy/Move**: Copy only if T is Copy
- **Constructors**: `Ok(value)`, `Err(error)`

### 4.3 `Task`

- **Layout**: `ptr` — 8 bytes (handle to a spawned concurrent task)
- **LLVM IR**: `ptr`
- **Copy/Move**: Move

---

## 5. Quantum Types

### 5.1 `QBit`

- **Layout**: `i32` — 4 bytes (qubit index)
- **LLVM IR**: `i32`
- **Copy/Move**: Copy

### 5.2 `QReg`

- **Layout**: `{ ptr, i32 }` — 12 bytes (state vector pointer + qubit count)
- **LLVM IR**: `{ ptr, i32 }`
- **Copy/Move**: Copy

---

## 6. OOP / Aggregate Types

### 6.1 `Struct`

- **Layout**: Sequentially packed fields with alignment padding (C-compatible)
- **LLVM IR**: `%StructName` (named struct type)
- **Copy/Move**: Copy if all field types are Copy
- **`hasDestructor`**: Yes if any field has a destructor

### 6.2 `Union`

- **Plain union**: Size = max field size (padded to alignment)
- **Tagged union**: Size = tag + padding + max field size
- **LLVM IR**: `%UnionName`
- **Copy/Move**: Copy if all field types are Copy
- **Tag type**: Optional `i32` discriminator

### 6.3 `Enum`

- **Plain enum**: Stored as `i32` tag
- **Payload-bearing enum**: `{ i32, [4 x i64] }` — 40 bytes (tag + aligned payload union)
- **LLVM IR**: `%EnumName`
- **Copy/Move**: Copy only if all payload types are Copy

### 6.4 `Class`

- **Layout**: `ptr` — 8 bytes (pointer to heap-allocated instance)
- **LLVM IR**: `ptr`
- **Copy/Move**: Move

### 6.5 `Interface`

- **Layout**: `ptr` — 8 bytes
- **LLVM IR**: `ptr`
- **Copy/Move**: Move

---

## 7. Function Types

### 7.1 `Function`

- **Layout**: `{ ptr, ptr }` — 16 bytes (function pointer + context pointer)
- **LLVM IR**: `{ ptr, ptr }`
- **Copy/Move**: Copy

### 7.2 `Closure`

- **Layout**: `{ ptr, ptr }` — 16 bytes (function pointer + environment pointer)
- **LLVM IR**: `{ ptr, ptr }`
- **Copy/Move**: Copy
- **Internal**: Each closure is assigned a unique `closure_id`. The environment is heap-allocated as a packed struct of captured variables.

---

## 8. Pointer Types

### 8.1 `RawPointer` (alias `ptr`)

- **Layout**: `ptr` — 8 bytes
- **LLVM IR**: `ptr`
- **Copy/Move**: Copy
- **Usage**: Low-level memory access, unsafe blocks, C interop.

### 8.2 Reference (`ref`) / `deref`

```nizam
let r as ref mut T = ref x    // mutable reference to x
let val as T = deref r         // dereference
```

References are syntactic sugar over `RawPointer` with borrow-checking semantics. The `ref` operator produces a pointer; `deref` reads through it.

### 8.3 Lifetime Annotations (`life[a]`)

```nizam
let reference as life[a] mut String = source
```

Lifetime annotations are parsed and stored but **not yet enforced** by the borrow checker. They serve as a foundation for future lifetime elision.

---

## 9. Dynamic / Special Types

### 9.1 `Any`

- **Layout**: `{ ptr, ptr }` — 16 bytes (heap-allocated data pointer + type tag pointer)
- **LLVM IR**: `{ ptr, ptr }`
- **Copy/Move**: Move
- **Semantics**: Universal container. Any value assigned to `Any` is heap-allocated and boxed. The type tag pointer is reserved for future runtime type information.

### 9.2 `Void`

- **Size**: 0 bytes
- **LLVM IR**: `void`
- **Usage**: Return type for functions that produce no value.

### 9.3 `Unknown`

- **Size**: 8 bytes (fallback)
- **Usage**: Placeholder for unresolved types during compilation. Emitting code with `Unknown` indicates a compiler error.

### 9.4 `Error`

- **Size**: 8 bytes (fallback)
- **Usage**: Internal sentinel to prevent cascading type errors in the checker.

### 9.5 `Module`

- **Size**: 8 bytes
- **Usage**: Represents a module scope as a type value.

---

## 10. LLVM Type Mapping Reference

The `typeToLLVM` function in `codegen.zig` maps each `TypeKind` to its LLVM IR type string:

| TypeKind | LLVM IR Type | Size (x86_64) |
|----------|-------------|---------------|
| `Void` | `void` | 0 |
| `I8` / `U8` / `Char` / `Boolean` | `i8` | 1 |
| `I16` / `U16` | `i16` | 2 |
| `I32` / `U32` | `i32` | 4 |
| `I64` / `U64` / `ISize` / `USize` | `i64` | 8 |
| `I128` / `U128` | `i128` | 16 |
| `F16` | `half` | 2 |
| `BFloat16` | `bfloat` | 2 |
| `F32` | `float` | 4 |
| `F64` | `double` | 8 |
| `F128` | `fp128` | 16 |
| `String` | `{ ptr, i64, i64 }` | 24 |
| `CStr` | `ptr` | 8 |
| `AsciiStr` / `Utf8Str` / `WebStr` / `RangeStr` | `{ ptr, i64 }` | 16 |
| `List` (dynamic) | `{ ptr, i64, i64 }` | 24 |
| `List` (fixed) | `[N x T]` | `N * sizeof(T)` |
| `Dict` | `{ ptr, i64, i64 }` | 24 |
| `Any` | `{ ptr, ptr }` | 16 |
| `Option` | `{ i8, ptr }` | 16 |
| `Result` | `{ i8, ptr, ptr }` | 24 |
| `QBit` | `i32` | 4 |
| `QReg` | `{ ptr, i32 }` | 12 |
| `Function` | `{ ptr, ptr }` | 16 |
| `Closure` | `{ ptr, ptr }` | 16 |
| `RawPointer` / `Slice` / `Class` / `Interface` / `Task` | `ptr` | 8 |
| `Struct` | `%StructName` | Computed |
| `Union` | `%UnionName` | Computed |
| `Enum` | `%EnumName` | Computed |
| `Tuple` | `{ T1, T2, ... }` | Computed |

---

## 11. Size and Alignment Rules

Type sizes and alignments are computed by `layout.zig` for the `x86_64_linux` target.

### Simple Types

- 1-byte types (`I8`, `U8`, `Boolean`, `Char`): size 1, align 1
- 2-byte types (`I16`, `U16`, `F16`, `BFloat16`): size 2, align 2
- 4-byte types (`I32`, `U32`, `F32`, `QBit`): size 4, align 4
- 8-byte types (`I64`, `U64`, `F64`, `ISize`, `USize`): size 8, align 8
- 16-byte types (`I128`, `U128`, `F128`): size 16, align 16

### Composite Types

- **Structs**: Fields are laid out sequentially with alignment padding between fields (C-compatible struct layout). The struct alignment is the maximum alignment of its fields. Final padding ensures the total size is a multiple of the alignment.
- **Tuples**: Same layout rules as structs (sequential with padding).
- **Unions**: Size is the maximum field size (padded to alignment). Tagged unions prepend the tag before the payload union.
- **Enums**: 40 bytes (`{ i32, [4 x i64] }`) — a 4-byte tag followed by a 32-byte payload aligned to 8 bytes for storing any variant's payload.
- **Option**: 16 bytes (`{ i8, ptr }` — 1 byte discriminant + 7 bytes padding + 8 byte payload pointer).
- **Result**: 24 bytes (`{ i8, ptr, ptr }` — 1 byte discriminant + 7 bytes padding + 2 × 8 byte pointers).
- **Any**: 16 bytes (`{ ptr, ptr }`).

### Pointer-Sized Types

All types with `ptr` components use `target.pointer_size` (8 bytes on x86_64).

---

## 12. Copy/Move Classification

### Copy Types (freely duplicatable)

| Category | Types |
|----------|-------|
| All primitives | `I8`–`I128`, `U8`–`U128`, `ISize`, `USize`, `F16`–`F128`, `Boolean`, `Char` |
| Quantum | `QBit`, `QReg` |
| Pointers | `RawPointer` |
| Functions | `Function`, `Closure` |
| String views | `CStr`, `AsciiStr`, `Utf8Str`, `WebStr`, `RangeStr` |
| Enums | All variants — **unless** any payload type is Move |
| Tuples | All elements — **unless** any element is Move |
| Structs | All fields — **unless** any field is Move |
| Unions | All fields — **unless** any field is Move |
| `Option[T]` | **If and only if** T is Copy |
| `Result[T, E]` | **If and only if** T is Copy |

### Move Types (affine — ownership transfers)

| Category | Types |
|----------|-------|
| Owned strings | `String` |
| Collections | `List` (dynamic), `Dict`, `Slice` |
| Classes | Any `Class` instance |
| `Option[T]` | If T is Move |
| `Result[T, E]` | If T is Move |
| `Any` | Always Move (heap-allocated payload) |
| `Task` | Always Move |

### `hasDestructor` (types needing cleanup on scope exit)

- `String`, `Utf8Str`, `AsciiStr`, `WebStr`, `RangeStr` — yes (own heap buffers)
- `List` (dynamic, no fixed length) — yes
- `Struct` — yes if any field has a destructor
- `Union` — yes if any field has a destructor
- `Tuple` — yes if any element has a destructor
- All others — no

---

## 13. Implicit Type Conversions

The `isImplicitlyConvertible` function in `types.zig` defines which type pairs can be silently coerced:

1. **Identity**: Same kind, same structure → always convertible.
2. **Function/Closure interop**: `Function` ↔ `Closure` with compatible signatures.
3. **`Any` box/unbox**: Any type ↔ `Any` (always allowed).
4. **Error sentinel**: `Error` ↔ anything (prevents cascading).
5. **String family**: `String` / `AsciiStr` ↔ any string variant (`CStr`, `AsciiStr`, `Utf8Str`, `WebStr`, `RangeStr`, `String`).
6. **Numeric literal conversion**: Any integer ↔ any integer, any float ↔ any float, integer ↔ float.
7. **Tuples**: Element-wise convertible check.
8. **Pointers**: `RawPointer` with matching payload types.

### Nizam-Specific Allocation Rules

In Nizam mode, the following types require an explicit `import` before they can be used:

| Type | Required Import |
|------|----------------|
| `String` | `from std.collections import String` |
| `List[T]` (dynamic) | `from std.collections import List` |
| `Dict[K,V]` | `from std.collections import Dict` |
| `Option[T]` | `from std.option import Option` |
| `Result[T,E]` | `from std.result import Result` |

Fixed-size `List[T, N]` does not require an import (no heap allocation).

---

## 14. Explicit Type Casts (`to`)

The `to` keyword performs explicit type conversion:

```nizam
<expr> to <type>
```

| Source → Target | Behavior |
|----------------|----------|
| `str` → `String` | Heap-allocates with `mantiq_malloc`, copies data, stores length and capacity |
| Any → `Any` | Heap-allocates payload, boxes into `{ ptr, ptr }` fat pointer |
| String/slice → integer | Extracts first byte, zero-extends to target width |
| Integer → Integer | `zext` (widen) or `trunc` (narrow) |
| Integer → `ptr` | `inttoptr` |
| `ptr` → Integer | `ptrtoint` |
| `float` ↔ `bfloat` | `fptrunc` / `fpext` |
| Integer → `float`/`double` | `sitofp` |
| Any unsupported pair | `bitcast` fallback |

---

## 15. Type Annotation Syntax

Type annotations use the `as` keyword in variable declarations and function signatures:

```nizam
// Variable with type annotation
let x as i32 = 42
var name as str = "hello"

// Function parameter and return types
fn add(a as i32, b as i32) -> i32:
    return a + b

// Generic type annotation
let list as List[i32] = List[i32]()

// Reference with lifetime
let r as life[a] mut String = ref source
```

### `TypeAnnotation` AST Structure

```
TypeAnnotation {
    name:        []const u8       // "i32", "String", "List", "fn", etc.
    is_ref:      bool             // true for `ref` types
    is_mut:      bool             // true for `mut` types
    lifetime:    ?[]const u8      // "a", "b", etc. for `life[a]`
    generics:    ?[]TypeAnnotation  // [i32] in List[i32]
    params:      ?[]TypeAnnotation  // parameter tuple for fn types
    return_type: ?*TypeAnnotation   // return type for fn types
}
```

### Function Type Annotation

```nizam
fn(param1: Type1, param2: Type2) -> ReturnType
```

Represented in the AST as a `TypeAnnotation` with `name = "fn"`, `params` containing the parameter types, and `return_type` containing the return type.

---

## 16. Name Mangling for Monomorphized Types

Generic type instantiations produce mangled names to avoid symbol collisions:

```
<BaseName>_<TypeArg1>_<TypeArg2>_...
```

Examples:
- `GenericPoint[i32]` → `GenericPoint_i32`
- `GenericPoint[f64]` → `GenericPoint_f64`
- `calc[i32]` → `calc_i32`

The `formatType` function in `types.zig` returns the human-readable name for each `TypeKind`, used during mangling:

| TypeKind | Mangled String |
|----------|---------------|
| `I32` | `i32` |
| `F64` | `f64` |
| `Struct` | (`struct_type.name`) |
| `Closure` | `Closure_<id>` |
| Others | Lowercase kind name |

---

## 17. Type Parsing (String → TypeKind)

The `parseTypeString` function maps type name strings to their `TypeKind`:

| Input Strings | Result |
|---------------|--------|
| `"i8"`–`"i128"`, `"isize"` | `I8`–`I128`, `ISize` |
| `"u8"`, `"byte"`–`"u128"`, `"usize"` | `U8`–`U128`, `USize` |
| `"f16"`–`"f128"`, `"bf16"` | `F16`–`F128`, `BFloat16` |
| `"char"` | `Char` |
| `"bool"` | `Boolean` |
| `"cstr"` | `CStr` |
| `"asciistr"`, `"astr"`, `"AsciiStr"` | `AsciiStr` |
| `"utf8str"`, `"str"`, `"u8str"`, `"ustr"`, `"Utf8Str"` | `Utf8Str` |
| `"webstr"`, `"utf16str"`, `"u16str"`, `"wstr"`, `"WebStr"` | `WebStr` |
| `"rangestr"`, `"rstr"`, `"utf32str"`, `"u32str"`, `"RangeStr"` | `RangeStr` |
| `"String"` | `String` |
| `"slice"`... | `Slice` |
| `"List"`... | `List` |
| `"Dict"`... | `Dict` |
| `"Result"`... | `Result` |
| `"Option"`... | `Option` |
| `"ptr"`... | `RawPointer` |
| `"qbit"` | `QBit` |
| `"qreg"`... | `QReg` |
| `"Any"` | `Any` |
| `"void"` | `Void` |
| Everything else | `Unknown` |

Note: Collection types (`List`, `Dict`, `Result`, `Option`) use `startsWith` matching to handle generic suffixes like `List[i32]`.
