# Decision 0022: Backend Implicit Type Coercion at Codegen Boundaries

## Context
In Nizam, string literals compile to the 2-field slice type `{ ptr, i64 }` (representing `.AsciiStr` or `.Utf8Str`), whereas the `String` type from the standard library compiles to the 3-field type `{ ptr, i64, i64 }` (or `%mantiq_std_string_String = type { ptr, i64, i64 }`, containing pointer, length, and capacity). 

Although the typechecker (`typecheck.zig`) correctly marks these types as implicitly convertible (since a string literal can initialize a `String`), the LLVM IR generator previously output direct variable assignments and function arguments without any conversion. This mismatch between `{ ptr, i64 }` and `%mantiq_std_string_String` caused LLVM IR verification errors (such as `%t.1 defined with type ... but expected ...`).

To resolve this without complicating semantic analysis or polluting the AST with explicit casting nodes, we implement a backend-level implicit type coercion mechanism.

---

## Language Specification

- Feature: Backend-Level Implicit Type Coercion
- Syntax: Implicitly triggered at variable declarations, assignments, function calls, returns, and struct initializations when the typechecker has approved an implicit conversion.
- Semantics:
  - When converting from a string literal type (`{ ptr, i64 }`) to a `String` layout (`{ ptr, i64, i64 }` or `%mantiq_std_string_String`), the compiler extracts the pointer and length fields, and duplicates the length to fill the capacity field, inserting all three values into the target `String` struct.
  - When converting from `String` layout to `{ ptr, i64 }`, the compiler extracts the pointer and length and packages them into a `{ ptr, i64 }` slice.
  - When converting a string representation (`{ ptr, i64 }`, `{ ptr, i64, i64 }`, or `%mantiq_std_string_String`) to `ptr` (representing `cstr`), the compiler extracts the first element (the raw pointer to bytes) and returns it.
  - When converting a value to `Any` (`{ ptr, ptr }`), the compiler boxes the value by allocating heap memory using `mantiq_malloc`, storing the value, and returning a fat pointer.
  - When assigning or passing integers of different sizes, the compiler inserts `zext` (zero-extend) or `trunc` (truncate) instructions.
  - When passing an integer to a pointer (or vice versa), the compiler inserts `inttoptr` or `ptrtoint` cast instructions.
- Examples:
  ```nizam
  import std.collections
  let s1 as String = "Mantiq" // Coerced from { ptr, i64 } to %mantiq_std_string_String
  let s2 as String = s1
  ```
- Errors:
  None. Type mismatch errors are caught at compile-time by `typecheck.zig`. Type coercion at codegen ensures no LLVM IR errors occur for valid conversions.
