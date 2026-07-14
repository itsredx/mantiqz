# Mantiq Language Specification

Mantiq is a multi-paradigm language designed for building dynamic toolkits, UIs, and complex applications. **Mantiq is a strict superset of Nizam**, meaning all Nizam systems-level features, strict types, and memory models are available, but Mantiq implicitly elevates dynamic capabilities, object-oriented programming, and high-level abstractions to the language core.

## 1. Core Principles
- **Superset of Nizam:** Any valid Nizam code is valid Mantiq code.
- **Built-in Dynamic Structures:** Unlike Nizam, Mantiq natively supports dynamically-sized collections and strings.
- **Toolkit Focused:** First-class support for declarative UI structures, dynamic dispatch, and actor-based concurrency.

## 2. Advanced Toolkit Types
In addition to Nizam's primitive types (like `i32`, `bf16`, `f128`, `qbit`), Mantiq elevates the following to primitive status:
- **Strings:** `String` (growable, heap-allocated buffer), `webstr` / `utf16str` (for browser/JVM/CLR interop), `rangestr` / `utf32str` (fast, full Unicode support).
- **Collections:** `List[T]` (dynamically-sized, growable list).
- **Dynamic Typing:** `Any` (for dynamic typing, UI state reflection, and polymorphism).

## 3. Object-Oriented Programming (OOP)
Mantiq introduces classical OOP concepts to build robust toolkit APIs.
- **Interfaces (Traits):** Defines a contract (e.g., `interface Drawable: abstract fn draw(ref self) as void`).
- **Classes:** Reference types, heap-allocated, supporting single/multiple inheritance and access modifiers (`public`, `private`, `protected`).
- **Method Overriding:** Uses the `@override` decorator.
- **Dynamic Dispatch:** Using the `Any` type and `match item: case s is Resizable:` for reflection-based behavior.

## 4. Declarative Collections (UI Layer)
Mantiq features a declarative syntax for quickly assembling complex structures like UIs.
- Supports inline conditionals: `#000 if is_dark_mode else #FFF`
- Supports inline loops: `for tag as str in tags: f"Tag: {tag}"`
- Spread operators: `...base_config`

## 5. Async / Await and Actor Abstractions
Mantiq simplifies concurrency for I/O and UI rendering.
- `async fn` and `await` keywords.
- `spawn async fn():` for creating lightweight tasks or actors.
- Channels for inter-task communication: `let chan = channel[String]()`

## 6. Execution and Memory
While Mantiq provides high-level abstractions, it still strictly enforces ownership and manual memory management beneath the surface. Using classes implicitly manages memory in standard ways, but manual instantiation (`make[UIContext]()`) and destruction (`drop(ui_state)`) are supported and required for lower-level bindings.

## 7. Zero-Cost Error Handling
Mantiq implements a zero-cost exception handling model where errors are treated as first-class returned values, avoiding runtime unwinding and setjmp/longjmp costs.

- **Feature**: Zero-Cost Typed Error Handling
- **Syntax**: 
  - Function signature: `fn name(...) -> Result[T, E]`
  - Success return: `return Ok(val)`
  - Error raise: `raise err_val`
  - Try-Catch block: `let result = try fallible_call() catch err: handler_block`
- **Semantics**:
  - The return type is lowered to a status tag and double pointers.
  - `raise` terminates the current function execution, allocating the error payload and returning the result with error tag.
  - `try-catch` extracts the tag. If success (`0`), it unwraps and returns the success value. If failure (`1`), it binds the error payload to the catch variable and transfers control to the error handling block.
- **Examples**:
  ```mq
  fn divide(a as f32, b as f32) -> Result[f32, String]:
      if b == 0.0:
          raise "Division by zero"
      return Ok(a / b)

  fn main():
      let quotient = try divide(10.0, 0.0) catch err:
          print(err)
          return
  ```
- **Errors**:
  - Raising an error from a function that does not return a `Result` type is a compile-time type checking error.
  - Attempting to use `try` on an expression that does not return a `Result` type is a compile-time type checking error.

## 8. Undefined Behavior (UB)
To ensure performance and correctness, Mantiq explicitly categorizes operations that trigger undefined behavior:

- **Reading Uninitialized Memory**: Checked and prevented at compile-time for local variables. Accessing unallocated or uninitialized memory via raw pointers is Undefined Behavior.
- **Invalid Union Field Access**: For tagged unions, this is runtime-checked and panics. For untagged unions, reading a field that is not the active variant is Undefined Behavior.
- **Out-of-bounds Access**: Checked and panics at runtime for lists and strings. Unsafe array indexing or raw pointer offsets out of bounds is Undefined Behavior.
- **Null Dereference**: Dereferencing raw pointers that are null is Undefined Behavior. Option types are used instead to represent nullable values safely.
- **Bitwise Shifts**: Shifting an integer by greater than or equal to its bit-width is Undefined Behavior.
- **Arithmetic Overflow**: Signed and unsigned integer overflow wrap using two's complement and are defined. Division by zero panics at runtime.

## 9. Name Resolution Phases
Mantiq enforces a strict multi-pass compilation pipeline to resolve names and bindings:

- **Pass 1 (Global Symbols)**: Registers all top-level symbols (functions, globals, structs, classes, interfaces, enums, unions, and imports) in the global scope. Forward-referencing is fully supported for all top-level declarations.
- **Pass 2 (Lexical Scopes)**: Resolves local variable declarations, parameters, loop variables, and identifiers sequentially in nested lexical scopes. Local variables and parameters cannot be forward-referenced.
- **Late Binding (Generics)**: Generic templates are skipped during the initial name resolution passes. When instantiated, the template AST is cloned and bound to concrete types, followed by localized Pass 1 and Pass 2 name resolution execution on the clone.

## 10. Codegen Boundary
Mantiq maintains a clean separation between compiler-generated LLVM IR, hardware intrinsics, and the C Runtime library:

- **Compiler Emitted (Direct LLVM)**: Primitive operations (arithmetic, bitwise, shifts, comparisons), control flow (branches, jumps, basic blocks), stack allocation (`alloca`), memory accesses (`load`, `store`), pointer offsets (`getelementptr`), and structural data accesses (`extractvalue`, `insertvalue`).
- **Compiler Intrinsics**: Bulk memory operations (using `@llvm.memcpy.p0.p0.i64` for structure copies).
- **Runtime Library (Delegated)**: Heap allocation (`mantiq_malloc`, `mantiq_free`), dynamic collection/dictionary lookup, runtime panics (`mantiq_panic`), string concatenation and formatting, task spawning/awaiting, and quantum hardware simulation interfaces.

## 11. Debugging Support
Mantiq incorporates instrumentation in both the compilation and execution phases to aid debugging:

- **IR Comments**: The code generator annotates all output LLVM blocks, expressions, and statements with a source span comment indicating the 1-based start row and column in the original source file (e.g. `; Span: [row: 10, col: 4] - Expr: BinaryExpr`).
- **Panic Trace Location**: Failures in runtime checks (such as out-of-bounds indexing or division by zero) raise location-aware panics reporting the file, line, and column of the offending expression to stderr (e.g. `Runtime Panic: Index out of bounds at main.mq:12:5`) before program exit.

## 12. Target Assumptions
Mantiq is designed as a highly portable, multi-platform language from day one:

- **Supported Platforms**: Portably compiles and targets Linux, macOS, Windows, Raspberry Pi, and arbitrary ARM/x86 architectures.
- **Portability Boundary**: Avoids direct hardware or OS-specific syscalls. Instead, uses standard platform calling conventions (ABIs) managed by LLVM, and delegates operating system interactions (I/O, threading, allocations) to a portable C standard library runtime interface (`runtime.c`).

## 13. Struct Magic/Dunder Methods

- **Feature**: Struct Magic/Dunder Methods
- **Syntax**:
  - Constructor: `public fn __init__(self as ptr[StructType], ...)`
  - Destructor: `public fn __del__(self as ptr[StructType])`
  - Operator overloading: `public fn __add__(self as StructType, other as StructType) -> StructType`, `public fn __neg__(self as StructType) -> StructType`, etc.
  - Indexing: `public fn __getitem__(self as StructType, idx as IndexType) -> ReturnType`, `public fn __setitem__(self as ptr[StructType], idx as IndexType, val as ValueType)`
- **Semantics**:
  - If a struct defines `__init__`, instantiating the struct via `StructType(...)` is lowered to stack allocation, zero-initialization, and calling the `__init__` constructor with a pointer to the allocated memory.
  - If a struct defines `__del__`, the struct is classified as a move-only type (`hasDestructor` returns `true`, and `isCopyType` returns `false`). The destructor is called when the object's lifetime ends or when called explicitly.
  - Binary and unary operator overload methods on structs are invoked implicitly via standard operator expressions (e.g., `p1 + p2` translates to `p1.__add__(p2)`).
  - Indexing methods are invoked implicitly via subscript expressions (e.g., `p[idx]` translates to `p.__getitem__(idx)`, and `p[idx] = val` translates to `p.__setitem__(idx, val)`).
  - Pointers to structs are automatically dereferenced when calling these magic methods.
- **Examples**:
  ```mq
  struct Point:
      public var x as i32
      public var y as i32

      public fn __init__(self as ptr[Point], x as i32, y as i32):
          (deref self).x = x
          (deref self).y = y

      public fn __add__(self as Point, other as Point) -> Point:
          return Point(self.x + other.x, self.y + other.y)
  ```
- **Errors**:
  - Defining `__init__` or `__del__` with incorrect signatures (e.g., not having `ptr[StructType]` as the first parameter) is a compile-time type checking error.
