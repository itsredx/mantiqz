# Decision 0017: std.option and std.result Modules

## Context
Nizam's core design values memory safety and explicit resource management. Option and Result types (`Option[T]` and `Result[T, E]`) are generic container structures commonly used to represent optional values and operation outcomes. While Mantiq exposes these globally as built-in types to support rapid, dynamic development, Nizam requires explicit imports for standard library types that control memory representation and potential allocation overhead.

## Decision
We introduce standard library modules `std.option` and `std.result` to manage `Option[T]` and `Result[T, E]` types respectively.

### Implementation Details:
- **Type Whitelisting & Injection**:
  - We whitelist standard library paths `std.option` and `std.result` in semantic analysis.
  - Importing `std.option` injects `Option`, `Some`, and `Empty` into the importing scope.
  - Importing `std.result` injects `Result`, `Ok`, and `Err` into the importing scope.
- **Nizam Rules & Verification**:
  - Direct use of type annotations `Option` or `Result` in Nizam mode without an explicit import (e.g., `from std.option import Option`) raises a compile-time error (`error.ImplicitAllocationNotAllowed`).
  - Calls to Option/Result constructors (`Some(...)`, `Ok(...)`, `Err(...)`, `Empty`) also check for these module imports in Nizam mode.
- **Mantiq Compatibility**:
  - In Mantiq mode, these types and constructors remain globally accessible without explicit imports to prioritize ease-of-use and developer ergonomics.
