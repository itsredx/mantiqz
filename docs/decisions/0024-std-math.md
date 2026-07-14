# Decision 0024: Nizam std.math Module and Codegen Global State Fix

## Context
A Nizam standard library module for mathematical functions (`std/math.nz`) is needed to support basic arithmetic operations (`min`, `max`, `abs`) and common transcendental functions (`sqrt`, `sin`, `cos`, `tan`, `ceil`, `floor`, `pow`, `log`, `exp`). Additionally, when compiling standard library modules that declare both external JIT functions (`extern fn`) and global variables (such as constants `PI` and `E`), the code generator was returning early in `.FunDecl` handler without restoring the `is_global` state variable to `true`. This caused subsequent module scope declarations to be compiled as local variable stack allocations (`alloca`) instead of global variable declarations, breaking JIT compilation with `expected 'type' after name` errors.

## Decision
We implement the `std.math` standard library module under `std/math.nz`, add comprehensive mathematical operation integration tests, and fix the compiler's code generator state-tracking bug by ensuring the `is_global` flag is reset to `true` on the `FunDecl` external function early return path.

### Implementation Details:
- **std.math Standard Library Module**:
  - We create `std/math.nz` containing:
    - Constants `PI` and `E` represented as `f64`.
    - Generic functions `min[T](a as T, b as T) as T`, `max[T](a as T, b as T) as T`, and `abs[T](a as T) as T`.
    - External declarations for standard math library (`libm`) C-compatibility functions: `sqrt`, `sin`, `cos`, `tan`, `ceil`, `floor`, `pow`, `log`, `exp`.
    - Link directive `link "m"` to ensure JIT links against the standard C math library.
- **Codegen Global State Fix**:
  - In `mantiq-compiler/src/codegen.zig`, inside `.FunDecl` handler:
    - We update the early return path for external functions (`if (f.is_extern) { ... }`) to reset `self.is_global = true;` before returning.
    - This guarantees that subsequent global variables (like `PI` and `E`) are generated as global variable declarations (e.g. `@std_math_PI = global double ...`) rather than stack allocations (`%PI = alloca double`), resolving LLVM assembler failures.
- **StdMath Integration Tests**:
  - We add `test_nizam_math` to `mantiq-compiler/src/main.zig` under the `"StdMath_Operations"` test case to verify constants, generic math functions, and libm functions.
