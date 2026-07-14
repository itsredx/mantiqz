# Decision 0025: Nizam std.path Module and Dual Signature Support

## Context
A Nizam standard library module for path manipulation (`std/path.nz`) is needed to support basic path functions like `join`, `dirname`, `basename`, `isabs`, and `exists`. Because Nizam implements move semantics for complex types like `String`, passing a `String` by value transfers ownership of the string, which moves/drops the variable in the caller's scope. If the caller needs to reuse the path variable, they must either clone the string or pass it by pointer. To support both use cases cleanly, the library needs a mechanism to allow both pass-by-value and pass-by-reference.

Furthermore, the module must work across Linux, macOS, and Windows dynamically, handling native separators and path prefixes (like drive letters and UNC shares).

## Decision
We implement the `std.path` standard library module under `std/path.nz` with:
1. **Dual Signature Support**:
   - **By-Value Functions**: e.g., `join(p1, p2)`, `dirname(path)`, `basename(path)`, `isabs(path)`, `exists(path)`. These take `String` by value, transferring ownership. They are syntactically clean but consume their arguments.
   - **By-Reference/Pointer Functions**: e.g., `join_ref(ref p1, ref p2)`, `dirname_ref(ref path)`, `basename_ref(ref path)`, `isabs_ref(ref path)`, `exists_ref(ref path)`. These take `ptr[String]`, avoiding ownership transfers and allowing the caller to reuse the variables.
2. **Cross-Platform Path Parsing**:
   - The host operating system is detected dynamically using `std.sys.os()`.
   - On Windows, separators can be both forward slash `/` and backslash `\`. Absolute paths include drive letters (e.g. `C:\`, `D:/`) and UNC shares (e.g. `\\server\share`).
   - On POSIX (Linux/macOS), the forward slash `/` is the sole separator and absolute paths start with `/`.

Under the hood, all by-value functions are thin wrappers that pass their parameters by reference (via `ref`) to the pointer-based implementation, preventing duplicate logic and minimizing code size.

### Implementation Details:
- **std.path Standard Library Module**:
  - We create `std/path.nz` containing the path logic.
  - Platform helpers `is_windows()`, `is_sep(c)`, and `sep()` handle separator differences dynamically.
  - Slices are constructed using a helper `make_from_slice(bytes as ptr[u8], len as usize) as String` to perform safe allocations and null-termination.
  - `exists` is imported from `std.fs` as the by-value version, and `exists_ref` is implemented by passing a temporary `String` struct layout to the `exists` builtin.
- **StdPath Integration Tests**:
  - We add `test_nizam_path` to `mantiq-compiler/src/main.zig` under the `"StdPath_Operations"` test case to verify both value and pointer-based implementations.
  - Windows path verification is run conditionally if `is_windows()` is True.
