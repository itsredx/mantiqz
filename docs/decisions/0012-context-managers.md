# 0012 - Python-like Context Managers and the `with` Statement

## Context
Nizam and Mantiq code needs a structured way to handle resource cleanups (such as closing file descriptors, releasing locks, or cleaning up heap resources) automatically when exiting a lexical block. Manually writing cleanup code at every possible exit point (early returns, breaks, continues, throws) is error-prone and leads to resource leaks. We need a Python-like `with` statement that automatically cleans up resources upon block exit by leveraging the compiler's existing `auto_drops` lifetime analysis.

## Decision
We implement a `with` statement syntax and map it to the compiler's lexical scope cleanup system. The compiler automatically binds the context manager resource to a unique, local scope-tracked symbol and appends it to the scope's `auto_drops` list during the borrow checking phase. At code generation, the compiler generates calls to cleanup procedures (such as `mantiq_fs_close` for file descriptors or `__exit__` methods for struct instances) when dropping the context manager symbol.

## Specification

- **Feature**: Context Managers and `with` Statements
- **Syntax**:
  ```python
  with <expr> as <var_name>:
      <body>
  ```
  Where `<expr>` evaluates to a resource (e.g. a file descriptor returned by `open`) and `<var_name>` is an optional identifier binding the resource inside the block.
- **Semantics**:
  1. The resource expression `<expr>` is evaluated.
  2. A new lexical scope is pushed, and the resource is bound to `<var_name>` (or a unique internal temporary if `as <var_name>` is omitted).
  3. The compiler's borrow checker registers the context manager symbol as `is_context_manager = true`.
  4. Upon block exit (including normal completion, early returns, breaks, continues, or throws), the borrow checker registers the symbol to be automatically dropped.
  5. During LLVM IR generation, if a dropped symbol has `is_context_manager = true`, the compiler:
     - Generates a call to `@mantiq_fs_close` if the resource is an integer file descriptor (`i32`).
     - Generates a call to the resource's `__exit__` method (`@{struct_name}___exit__`) if the resource is a struct instance with an `__exit__` method.
- **Examples**:
  Using `with` to manage a file resource:
  ```python
  import std.fs
  import std.io

  fn main():
      with open("temp.txt", "w") as f:
          write(f, "Hello Nizam Filesystem!\n")
  ```
- **Errors**:
  - `Type Error`: If the compiler is unable to resolve the type of the context manager expression.
  - `Semantic Error`: If the context manager variable name collides with another variable name in the same scope.

## Implementation Details
1. **AST Representation**: We add `WithStmt` to the compiler's AST definition containing `expr`, `var_name`, `body`, `resolved_symbol`, and `auto_drops`.
2. **Lexical Scopes**: During semantic analysis, we push a scope and define the context manager variable prior to resolving the body statements.
3. **Borrow Checking & Lifetime Analysis**: We extend `borrowck.zig` to check `WithStmt`, pushing a new scope containing the context manager symbol, checking the body block, and appending the context manager symbol to `auto_drops` if it is still active/owned upon exit.
4. **Code Generation**: We update the `genExpr` handler for `WithStmt` in `codegen.zig` to allocate stack space, store the resource value, run the body, and emit cleanups via `genAutoDrops` before returning.
