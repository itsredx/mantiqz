# Decision 0018: std.string Module and Raw Pointer Indexing

## Context
Standard string representation (`String`) and string building (`StringBuilder`) are essential for real-world application development. In Mantiq mode, dynamic strings are primitive, built-in, and garbage-collected. However, Nizam mode requires strict memory safety, zero implicit allocation, and manual memory management. Implementing string utilities using Nizam language primitives requires systems-level routines (e.g. `malloc`, `realloc`, `free`, `memcpy`) and unsafe operations like raw pointer indexing (`ptr[i]`).

## Decision
We implement `String` and `StringBuilder` directly in Nizam language in a new standard library file `std/string.nz` instead of hardcoding them in the compiler. To support this implementation, we extend Nizam with safe and unsafe systems-level capabilities.

### Implementation Details:
- **Project Root Resolve**:
  - We update module resolution (`resolveModulePath` in `sema.zig`) to look inside the project root directory when importing modules starting with `"std."`.
- **Raw Pointer Indexing**:
  - We extend the typechecker (`typecheck.zig`) to infer the dereferenced element type when indexing `RawPointer` (`ptr` or `ptr[T]`).
  - We extend the code generator (`codegen.zig`) to compile pointer indexing using LLVM `getelementptr` instructions (and `load` when used as an rvalue).
- **String and StringBuilder Implementation**:
  - We define `String` and `StringBuilder` as value-type structs in `std/string.nz`.
  - We define explicit namespace functions (`make`, `deinit`, `append`, etc.) for managing allocation, resizing, and freeing of string buffers using `std.mem` routines (`alloc`, `realloc`, `free`) and `extern` functions (`strlen`, `memcpy`).
- **Nizam Rules & Verification**:
  - Direct use of `String` in Nizam mode without an explicit import (e.g., `from std.string import String`) raises a compile-time error.
