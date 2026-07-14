# Language Specification: Strings

## Feature: String Types and Conversions

### String Type Hierarchy

| Type | Kind | Layout | Encoding | Mutability |
|------|------|--------|----------|------------|
| `str` / `asciistr` | `AsciiStr` | `{ptr, i64}` (16 B) | 7-bit ASCII | Immutable |
| `ustr` / `utf8str` | `Utf8Str` | `{ptr, i64}` (16 B) | UTF-8 | Immutable |
| `webstr` / `utf16str` | `WebStr` | `{ptr, i64}` (16 B) | UTF-16 | Immutable |
| `rangestr` / `utf32str` | `RangeStr` | `{ptr, i64}` (16 B) | UTF-32 | Immutable |
| `String` | `String` | `{ptr, i64, i64}` (24 B) | UTF-8 | Mutable |
| `cstr` | `CStr` | `ptr` (8 B) | C string | N/A |

All immutable string types are fat pointers `{ data: ptr[u8], len: i64 }`. The `String` type adds `capacity: i64`. The `cstr` type is a thin null-terminated pointer.

String decoding aliases are registered in `types.parseTypeString` (`types.zig:162-175`).

### Syntax

| Expression | Result Type | Notes |
|-----------|-------------|-------|
| `"hello"` | `str` (AsciiStr) | Inferred as static string literal |
| `f"x = {val}"` | `String` | Interpolated — concatenated at runtime |
| `"hello" to String` | `String` | Explicit conversion from literal |
| `"hello".to_string()` | `String` | Method call variant |
| `cstr"hello"` | `cstr` | **Not yet implemented** — use `"hello" to cstr` |
| `my_str[i]` | `i8` (char) | Single-byte indexing; bounds-checked |

### Conversion Rules

- `str` → `String`: explicit via `to String` or `.to_string()` — allocates heap buffer and copies bytes (`codegen.zig:2891-2912`)
- `String` → `str`: implicit via borrow — zero-cost fat pointer extraction
- `String` → `cstr`: explicit via `.cstr()` method — returns `data` pointer (null-terminated for String)
- `str` → `cstr`: explicit via `to cstr` — panics if string contains null bytes
- Between encoding types: cast via `to <type>` — no encoding conversion performed

### String Slicing

`my_string[start..end]` is **specified** (produces a zero-copy `str` sub-slice) but **not yet implemented** in the compiler. The `..` range operator currently only works in for-loops (`0..10`) and match patterns.

### Layout and ABI

| Type | Size | Alignment | ABI |
|------|------|-----------|-----|
| `str` / encoding types | 16 | 8 | Coerced to `{i64, i64}` in registers (`abi.zig:48-50`) |
| `String` | 24 | 8 | Passed by value (or coerced) for ≤ 16 B; by-val for return (`abi.zig:48-54`) |
| `cstr` | 8 | 8 | Direct (`abi.zig:39`) |

### Interpolation

`f"..."` strings lower to concatenation calls using runtime helpers:

| Helper | Signature |
|--------|-----------|
| `@mantiq_concat_str` | `fn (String, String) -> String` |
| `@mantiq_i32_to_str` | `fn (i32) -> String` |
| `@mantiq_float_to_str` | `fn (f64) -> String` |
| `@mantiq_bool_to_str` | `fn (bool) -> String` |

`codegen.zig:2723-2792` accumulates parts with `concat_str`.

### String Comparison and Hashing

| Operation | Runtime Function |
|-----------|-----------------|
| Equality | `__mantiq_streq` (`runtime.c:178`) |
| Hashing (Dict keys) | `__mantiq_hash_string` (`runtime.c:192`) |

Declared in `codegen.zig` preamble (`codegen.zig:417-419`).

### Examples

```mantiq
// Immutable static string
let name as str = "Alice"

// Mutable dynamic string (explicit conversion)
let greeting as String = "Hello, " to String
greeting.append(name)
print(greeting)

// Single-character indexing
let ch as i8 = greeting[0]

// C string (via cast)
let path as cstr = "/etc/passwd" to cstr
open(path)

// Interpolation
let msg = f"Hello, {name}! You are {age} years old."
```

### Encoding Aliases

All refer to the same underlying types:

| Canonical | Aliases |
|-----------|---------|
| `asciistr` | `str` |
| `utf8str` | `ustr` |
| `utf16str` | `webstr` |
| `utf32str` | `rangestr` |

### Errors

| Error | Condition | When |
|-------|-----------|------|
| MismatchedTypes | Assigning `String` where `str` expected | Typecheck |
| UndefinedType | Using encoded string types without import in Nizam mode | Typecheck (`typecheck.zig:249-256`) |
| IndexOutOfBounds | String index at runtime | Runtime panic |
| NullByteInCString | `str` to `cstr` conversion with embedded null | Runtime panic |

### Not Yet Implemented

- `c"..."` C-string literal syntax — grammar prefix regex must be extended beyond `[bBrRuU]*` (`grammar.js:669-670`)
- `str[start..end]` slicing — requires `RangeSlice` AST node, typecheck, and codegen support
