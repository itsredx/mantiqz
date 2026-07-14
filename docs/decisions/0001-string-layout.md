# Design Decision: String Layout and Representation

## 1. Problem
Mantiq requires a robust string representation that supports high-performance static strings, C interoperability, and dynamic heap-allocated buffers without ambiguous performance penalties. The lack of formalized string semantics could break FFI, slicing, and memory safety assumptions.

## 2. Decision
We have established a multi-tiered string layout to decouple immutable slice views from owned dynamic buffers:

### 2.1 Types and Layouts
- **`str` (and aliases `utf8str`, `ustr`)**:
  - **Layout**: `{ ptr, i64 }` (Fat pointer: Data Pointer + Byte Length).
  - **Mutability**: Immutable.
  - **Semantics**: A zero-cost slice view pointing to `.rodata`, stack arrays, or heap arrays. Slicing returns a new `str` pointing to the same buffer (zero-copy).
  - **Encoding**: Guaranteed UTF-8.

- **`String`**:
  - **Layout**: `{ ptr, i64, i64 }` (Fat pointer: Data Pointer + Length + Capacity).
  - **Mutability**: Mutable.
  - **Semantics**: A uniquely owned, growable heap-allocated buffer. 
  - **Encoding**: Guaranteed UTF-8.

- **`cstr`**:
  - **Layout**: `ptr` (Thin pointer).
  - **Mutability**: Immutable (typically).
  - **Semantics**: Null-terminated C-compatible string. No encoding guarantees.

- **`webstr` (`utf16str`)**: `{ ptr, i64 }`, guaranteed UTF-16.
- **`asciistr`**: `{ ptr, i64 }`, guaranteed 7-bit ASCII.
- **`rangestr` (`utf32str`)**: `{ ptr, i64 }`, guaranteed UTF-32.

### 2.2 Operations and Conversions
- **Slicing**: Operations like `my_string[0..5]` are zero-copy and always yield an immutable `str` slice.
- **Conversion**: Static strings (`str`) must be explicitly converted to dynamic buffers when mutation is required, using the explicit `to String` keyword syntax (e.g., `"hello" to String`) or via `.to_string()`. Implicit allocation for basic strings is forbidden to adhere to Nizam's performance constraints.

## 3. Rationale
- Splitting `str` and `String` matches the Rust/Zig philosophy of zero-cost abstractions, avoiding the performance hit of hidden heap allocations.
- Guaranteeing UTF-8 by default prevents encoding chaos in the standard library while offering strict types (`asciistr`, `webstr`) for specialized interop.

## 4. Consequences
- `codegen.zig` string literals must be refactored to emit direct `.rodata` pointers instead of automatically invoking `mantiq_malloc` and `memcpy`.
- The ABI module (`abi.zig`) must properly pack/coerce `{ ptr, i64 }` and `{ ptr, i64, i64 }` structs to comply with the SysV calling conventions.
