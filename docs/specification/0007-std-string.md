# Specification 0007: std.string Module

## Feature: Standard String Library (`std/string.nz`)

### Import

```mantiq
from std.string import String, StringBuilder
```

In Nizam mode, using `String` without importing it from `std.string` (or `std.collections`) raises a compile-time error (`typecheck.zig:249-256`).

> **Note:** `String` is both a built-in type kind (`.String` in `types.zig`) — used for type annotations like `let s as String` — and a struct type defined in `std/string.nz`. The built-in kind is returned by `parseTypeString("String")` and is used by the compiler internally (layout, codegen). The struct provides methods and fields. When `from std.string import String` is used, both paths resolve to the same type.

---

### `String` Struct

```mantiq
pub struct String:
    data as ptr[u8]
    len as usize
    capacity as usize
```

| Method | Signature | Description |
|--------|-----------|-------------|
| `make` | `(s as cstr) as String` | Allocate and copy a C string into a new `String` |
| `deinit` | `(self as ptr[String])` | Free the internal buffer |
| `append` | `(self as ptr[String], other as ptr[String])` | Concatenate `other` onto `self` |
| `len` | `(self as ptr[String]) as usize` | Return string length |
| `cstr` | `(self as ptr[String]) as cstr` | Return null-terminated pointer |

#### Low-Level Free Functions

For use in contexts where method syntax is unavailable:

| Function | Signature | Description |
|----------|-----------|-------------|
| `make` | `(s as cstr) as String` | Same as `String.make` |
| `deinit` | `(s as ptr[String])` | Same as `String.deinit` |
| `append` | `(s as ptr[String], other as ptr[String])` | Same as `String.append` |

---

### `StringBuilder` Struct

```mantiq
pub struct StringBuilder:
    buffer as ptr[u8]
    len as usize
    capacity as usize
```

| Method | Signature | Description |
|--------|-----------|-------------|
| `make_builder` | `() as StringBuilder` | Create a new empty builder |
| `deinit_builder` | `(self as ptr[StringBuilder])` | Free the builder buffer |
| `append_builder` | `(self as ptr[StringBuilder], s as cstr)` | Append a C string |
| `builder_to_string` | `(self as ptr[StringBuilder]) as String` | Finalize into a `String` |

#### Low-Level Free Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `make_builder` | `() as StringBuilder` | Same as `StringBuilder.make_builder` |
| `deinit_builder` | `(self as ptr[StringBuilder])` | Same as `StringBuilder.deinit_builder` |
| `append_builder` | `(self as ptr[StringBuilder], s as cstr)` | Same as `StringBuilder.append_builder` |
| `builder_to_string` | `(self as ptr[StringBuilder]) as String` | Same as `StringBuilder.builder_to_string` |

---

### Example

```mantiq
from std.string import String, StringBuilder, make, deinit, append
from std.string import make_builder, deinit_builder, append_builder, builder_to_string

fn main():
    // String via method syntax
    let mut s1 = String.make("Hello ")
    let s2 = String.make("World")
    s1.append(ref s2)
    print(s1)  // Hello World
    s1.deinit()
    s2.deinit()

    // StringBuilder
    let mut builder = StringBuilder.make_builder()
    builder.append_builder(ref builder, "Hello ")
    builder.append_builder(ref builder, "World")
    let s3 = builder.builder_to_string()
    print(s3)  // Hello World
    s3.deinit()
    builder.deinit_builder(ref builder)

    // Low-level free function style
    let s4 = make("Hello World" to cstr)
    print(s4)
    deinit(ref s4)
```

### Related Modules

| Module | File | Contents |
|--------|------|----------|
| `std.text` | `std/text.nz` | UTF-8/16/32 encoding, validation, codepoint classification |
| `std.path` | `std/path.nz` | Path manipulation (`join`, `dirname`, `basename`, `exists`) |
| `std.collections` | `sem.zig:445` | Injects `String` as a builtin on import |

### Errors

| Error | Condition | When |
|-------|-----------|------|
| UndefinedType | Using `String` in Nizam without import | Typecheck (`typecheck.zig:249-256`) |
| NullByteInCString | Passing string with embedded null to C FFI | Runtime |
