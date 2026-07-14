# Specification 0006: std.option and std.result Modules

- Feature: Standard Option and Result Types
- Syntax:
  ```python
  from std.option import Option, Some, Empty
  from std.result import Result, Ok, Err
  
  # Option usage
  let opt as Option[i32] = Some(42)
  let empty_opt as Option[i32] = Empty
  
  # Result usage
  let res as Result[i32, i32] = Ok(100)
  let err_res as Result[i32, i32] = Err(1)
  ```
- Semantics:
  - `Option[T]` represents an optional value containing either a value of type `T` (via `Some(value)`) or no value (via `Empty`).
  - `Result[T, E]` represents the outcome of an operation that can succeed with a value of type `T` (via `Ok(value)`) or fail with an error code/payload of type `E` (via `Err(error)`).
- Examples:
  ```python
  from std.option import Option, Some, Empty
  from std.result import Result, Ok, Err
  import std.io
  
  fn get_value(x as i32) -> Option[i32]:
      if x > 0:
          return Some(x)
      return Empty

  fn check_value(x as i32) -> Result[i32, i32]:
      if x == 42:
          return Ok(x)
      return Err(1)
  ```
- Errors:
  - Using `Option`, `Some`, or `Empty` in Nizam mode without importing them from `std.option` causes a compile-time error.
  - Using `Result`, `Ok`, or `Err` in Nizam mode without importing them from `std.result` causes a compile-time error.
  - Using these types with mismatching generic parameters or constructor payload types generates compile-time type mismatch errors.
