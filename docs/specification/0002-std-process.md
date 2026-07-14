# Specification 0002: std.process Module

- Feature: Standard Process Management
- Syntax:
  ```python
  import std.process
  
  # Retrieve command line arguments
  let arguments = args()
  
  # Terminate process with exit code
  exit(code)
  ```
- Semantics:
  - `import std.process` exposes the builtin functions `args()` and `exit(code)` in the current scope.
  - `args()` takes no arguments and returns a value of type `List[AsciiStr]` containing the command-line arguments passed to the program, starting with the program name at index 0.
  - `exit(code)` takes an `i32` argument, terminates the calling process, and returns status code `code` to the parent process or shell environment. It does not return control to the caller.
- Examples:
  ```python
  import std.process
  import std.io
  
  fn main():
      let argv = args()
      if argv[0] == "help":
          print("Help printed.\n")
          exit(0)
      exit(1)
  ```
- Errors:
  - Calling `exit` with a non-`i32` value results in a type check mismatch error.
  - Calling `args` with any arguments results in a type check mismatch error.
