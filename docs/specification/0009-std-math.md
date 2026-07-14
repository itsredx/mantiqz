# Specification 0009: Nizam std.math Module

- Feature: Standard Mathematical Constants and Functions
- Syntax:
  ```python
  from std.math import PI, E
  from std.math import min, max, abs
  from std.math import sqrt, sin, cos, tan, ceil, floor, pow, log, exp

  // Usage
  let pi_val = PI
  let minimum = min(10, 20)
  let root = sqrt(144.0 to f64)
  ```
- Semantics:
  - `PI` and `E` are predefined `f64` constants representing Archimedes' constant (3.141592653589793) and Euler's number (2.718281828459045), respectively.
  - `min[T](a as T, b as T) as T` returns the smaller of two values of any comparable type `T`.
  - `max[T](a as T, b as T) as T` returns the larger of two values of any comparable type `T`.
  - `abs[T](a as T) as T` returns the absolute value of `a`.
  - transcendental functions (`sqrt`, `sin`, `cos`, `tan`, `ceil`, `floor`, `pow`, `log`, `exp`) map directly to their standard C mathematical library equivalents from `libm`.
- Examples:
  ```python
  from std.math import min, abs, sqrt

  fn main():
      let minimum = min(3.14, 2.71) // 2.71
      let absolute = abs(-10) // 10
      let root = sqrt(9.0) // 3.0
  ```
- Errors:
  - Calling generic mathematical functions (`min`, `max`, `abs`) with mismatched argument types (e.g. `min(10, 2.71)`) results in a typechecker error unless explicit casting is used.
  - Passing a non-floating-point value to transcendental functions expecting `f64` (such as `sqrt`) without explicit casting to `f64` results in a typecheck failure.
