# 0005 - Zero-Cost Error Handling

## Context
In Nizam and Mantiq, error handling must be both expressive and highly performant. Traditional exception handling (using setjmp/longjmp or landing pads) introduces runtime overhead, increases binary size, and is difficult to compile to web targets like WASM. A "zero-cost" error handling mechanism is needed, where errors are returned as values, but structured using clean `try` and `catch` syntax.

## Decision
Mantiq and Nizam adopt **Zero-Cost Typed Error Handling** using a `Result[T, E]` type. This mechanism compiles down to value-based status flags and pointer payloads, incurring zero runtime exception-handling overhead.

### 1. The `Result` Type
A function that can fail returns a `Result[T, E]`.
- Under the hood, this is represented as a 24-byte struct `{ i8, ptr, ptr }` in LLVM:
  - `i8` tag: `0` for `Ok`, `1` for `Err`.
  - `ptr` Ok: A pointer to the heap-allocated success value of type `T` (or null).
  - `ptr` Err: A pointer to the heap-allocated error value of type `E` (or null).

### 2. Syntax and Semantics
- **Raising Errors**: The `raise <expr>` statement halts the current block, wraps the expression in the error variant of the function's return type, and returns it.
- **Returning Success**: The `return Ok(<expr>)` or simply returning a value when the function's return type is a `Result` wraps the value in the success variant.
- **Handling Errors (`try-catch`)**:
  - The `try <expr> catch <binding>: <block_body>` syntax allows propagating or handling errors.
  - If the expression evaluated under `try` succeeds, the result is unwrapped to the success payload.
  - If the expression fails (returns an `Err` variant), the error payload is extracted and bound to `<binding>`, and the catch `<block_body>` is executed.

## Implementation Implications
In `codegen.zig`, the `Result[T, E]` layout is compiled as a `{ i8, ptr, ptr }` struct. Since it exceeds 16 bytes, it is returned in memory under SysV AMD64 ABI convention. The `TryStmt` code generator extracts the tag at index 0, branches to success and failure blocks, and guarantees that any catch binding `alloca` is executed in the active block prior to branching to prevent undefined behavior/crashes.
