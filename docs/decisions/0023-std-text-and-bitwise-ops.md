# Decision 0023: std.text Module and Compiler Bitwise/Shift Support

## Context
Implementing lexical analysis and UTF-8 processing (decoding, encoding, validating, and counting codepoints) requires bitwise operators (`&`, `|`, `^`, `~`) and shift operators (`<<`, `>>`). Prior to this decision, the Nizam/Mantiq compiler did not support code generation or lowering for these operators. Implementing them enables the standard text processing module (`std/text.nz`) to be written entirely in Nizam. Furthermore, tests requiring char properties need a way to pass string literals/slices to functions expecting character types without triggering JIT type mismatch errors.

## Decision
We extend the compiler with full support for bitwise and shift operators in both Nizam and Mantiq modes, implement the `std.text` standard library module under `std/text.nz`, and introduce robust JIT type casting logic.

### Implementation Details:
- **Logical and Bitwise Negation**:
  - We map logical negation `!` to `"not"` in `lowerUnaryExpr` (`lower.zig`).
  - We map bitwise negation `~` to a unary expression with operator `"~"` in `lowerUnaryExpr` (`lower.zig`).
  - In `codegen.zig`, we compile `~` by performing an `xor` operation between the operand and `-1`.
- **Binary Bitwise and Shift Operators**:
  - We implement lowering and code generation for `&`, `|`, `^`, `<<`, and `>>` in `codegen.zig`.
  - For right shifts (`>>`), the compiler automatically selects between logical right shift (`lshr` for unsigned types: `u8`, `u16`, `u32`, `u64`, `u128`, `usize`) and arithmetic right shift (`ashr` for signed types).
- **std.text Standard Library Module**:
  - We create `std/text.nz` containing Lexer helpers (`is_digit`, `is_alpha`, `is_alphanumeric`, `is_whitespace`, `is_hex_digit`, `is_octal_digit`).
  - We implement UTF-8 decoding (`utf8_decode`), encoding (`utf8_encode`), validation (`utf8_validate`), and length helper (`utf8_char_length`) using manual pointer manipulation and bitwise operations.
- **Robust Type Casting**:
  - We update `CastExpr` codegen to support casting string types (`{ ptr, i64 }` or `%struct.String`) and raw `ptr` to `char`/`i8` integer types. This extracts the pointer element at index 0 and performs an LLVM load.
  - We update `CastExpr` codegen to delegate integer-to-integer casting (e.g. `i32` to `i8`) to `coerceType`, emitting `trunc` for down-sizing and `zext`/`sext` for up-sizing, ensuring compliance with LLVM type layout constraints.
