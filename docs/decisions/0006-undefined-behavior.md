# 0006 - Undefined Behavior (UB) Definition

## Context
Defining what constitutes Undefined Behavior (UB) is critical to ensuring consistent compiler optimizations, language safety, and debugging expectations. While LLVM assumes C-like UB rules, Mantiq specifies safe defaults for several common operations and explicitly defines others as UB.

## Decision
Mantiq defines the following behaviors to be either **Safe (Defined)** or **Undefined Behavior (UB)**:

### 1. Memory Access and Initialization
- **Uninitialized Variables**: Reading from an uninitialized local variable is prevented at compile-time by the semantic analyzer, which requires all variables to have an initial value. 
- **Raw Pointers**: Reading or writing through an uninitialized or dangling raw pointer (`ptr` / `RawPointer`) is **Undefined Behavior**.
- **Null Pointer Dereference**: Dereferencing a null pointer is **Undefined Behavior** (typically resulting in a segmentation fault at the hardware level). Mantiq prevents implicit nulls by wrapping optional references in the `Option[T]` type.

### 2. Union Field Access
- **Tagged Unions**: Accessing a union field that is not the currently active variant is prevented by pattern matching and active tag checks, yielding a runtime panic or compile error.
- **Untagged (Unsafe) Unions**: Reading a field that is not the active variant is **Undefined Behavior** (reinterpreting the raw bits under a different type representation).

### 3. Collection Bounds Access
- **List and String Indexing**: Out-of-bounds access (`index >= length` or `index < 0`) triggers a runtime panic and terminates execution.
- **Unsafe Access**: If indexing bounds checks are bypassed (e.g. using raw pointer offsets), out-of-bounds read/write is **Undefined Behavior**.

### 4. Integer Arithmetic and Overflow
- **Signed/Unsigned Integer Overflow**: Arithmetic overflow wraps around according to two's complement rules (defined behavior). The compiler does not emit `nsw` (No Signed Wrap) or `nuw` (No Unsigned Wrap) attributes on LLVM arithmetic instructions unless wrapping checks are explicitly enabled.
- **Division by Zero**: Division or modulo by zero results in a defined runtime panic or hardware exception.

### 5. Bitwise Shifts
- **Shift Width**: Shifting an integer by a width equal to or greater than its bit-width (e.g., `x << 32` on a 32-bit integer) is **Undefined Behavior**, directly inheriting LLVM shift constraints.

## Implementation Implications
The LLVM IR generator (`codegen.zig`) must align with these definitions:
- Avoid generating `nsw` or `nuw` flags on LLVM arithmetic operations to ensure overflow behaves predictably.
- Maintain array/list bounds-checking wrappers on index expressions unless optimization flags explicitly request safety checks to be bypassed.
