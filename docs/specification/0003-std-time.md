# Specification 0003: std.time Module

- Feature: Standard Time and Thread Suspension
- Syntax:
  ```python
  import std.time
  
  # Get Unix epoch timestamp
  let timestamp = now()
  
  # Suspend thread
  sleep(seconds)
  ```
- Semantics:
  - `import std.time` whitelists the module and introduces the functions `now` and `sleep` into the module's scope.
  - `now()` takes 0 arguments and returns an `i64` representing the current epoch timestamp in seconds.
  - `sleep(seconds)` takes a single `i32` argument, suspends calling thread execution for the specified number of seconds, and returns `Void`.
- Examples:
  ```python
  import std.time
  import std.io
  
  fn main():
      let start = now()
      sleep(2)
      let end = now()
      let elapsed = end - start
      print("Elapsed: ")
      print(elapsed)
  ```
- Errors:
  - Calling `now` with one or more arguments results in a compile-time type mismatch error.
  - Calling `sleep` with a non-`i32` type or with an incorrect number of arguments results in a compile-time type mismatch error.
