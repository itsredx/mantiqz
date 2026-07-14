# Specification 0008: std.text Module & Bitwise/Shift Support

- Feature: Standard Text Processing (Lexer/UTF-8 helpers) and Bitwise/Shift Operators
- Syntax:
  ```python
  // Bitwise / Shift Operators
  let a = b & c
  let d = e | f
  let g = h ^ i
  let j = ~k
  let l = m << 2
  let n = o >> 3

  // Import std.text
  from std.text import Codepoint
  from std.text import is_digit, is_alpha, is_alphanumeric, is_whitespace, is_hex_digit, is_octal_digit
  from std.text import utf8_char_length, utf8_decode, utf8_encode, utf8_validate, utf8_count_codepoints

  // Explicit type casting
  let c_char = 'A' to char
  let byte_val = c_char to u8
  ```
- Semantics:
  - `&`, `|`, `^`, `<<`, `>>` perform standard bitwise AND, OR, XOR, SHL, and SHR operations. For signed integers, `>>` is an arithmetic right shift; for unsigned integers, it is a logical right shift.
  - `~` performs a bitwise NOT (negation) operation, returning the bitwise complement.
  - `!` / `not` performs a logical negation.
  - `Codepoint` represents a decoded Unicode codepoint: `value as u32` and `length as usize`.
  - Lexer helpers check character properties based on ASCII/Unicode ranges.
  - UTF-8 helpers encode/decode codepoints and validate byte arrays.
  - Casting string representation (`asciistr`, `%struct.String`, etc.) or raw pointer to `char` (`i8`) compiles to extracting the base pointer (index 0) and performing a `load i8` operation from it.
  - Casting between different integer sizes (e.g. `i32` to `i8`) compiles to LLVM `trunc` for down-sizing, and `zext`/`sext` for up-sizing, ensuring correct type size compliance.
- Examples:
  ```python
  from std.text import is_digit, utf8_char_length

  fn main():
      let digit = is_digit('7' to char) // true
      let len = utf8_char_length(240 to u8) // 4 bytes (for F0...)
  ```
- Errors:
  - Attempting to perform bitwise operations on non-integer types results in a compile-time typechecker error.
  - Trying to pass a single-character literal (which defaults to `asciistr`) to a function expecting `char` without casting results in: `"Type Error: Argument expects type 'char', but got 'asciistr'"`.
