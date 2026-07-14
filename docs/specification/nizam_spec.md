# Nizam Language Specification

Nizam is a purely functional and systems-level programming language designed for predictability, zero-cost abstractions, and maximum performance. It enforces strict memory ownership, provides advanced systems-level constructs, and ensures safe concurrency natively.

## 1. Core Principles
- **No Implicit Allocation:** Dynamic data structures (like growable Strings or Lists) are not built-in; they must be imported and managed manually or via standard libraries.
- **Strict Immutability by Default:** Variables are immutable unless explicitly marked with `mut`.
- **Zero-Cost Abstractions:** Features like Quantum types are eliminated via Dead Code Elimination (DCE) if unused.

## 2. Primitive Types
### Integers
- **Signed:** `i8`, `i16`, `i32`, `i64`, `isize`
- **Unsigned:** `u8`, `u16`, `u32`, `u64`, `usize`

### Floating Point
- `f16`: Half-precision float.
- `bf16`: Bfloat16, mandatory for AI/ML tensor memory efficiency natively.
- `f32`, `f64`: Standard floats.
- `f128`: Quad-precision for scientific calculations.

### Characters and Strings
- `char`: 4-byte Unicode character.
- `byte`: Alias for `u8`.
- `cstr` (C compatible null-terminated), `asciistr` / `astr` (fast, memory efficient), `utf8str` / `str` / `u8str` / `ustr` (default for many ops).

### Memory and Arrays
- `slice`: Dynamically-sized view into contiguous sequence `[T]`.
- `List[T, N]`: Fixed-size array of element type `T` and compile-time size `N`.

### Control & Context
- `Result[T, E]`: Functional error handling `Ok(T)` / `Err(E)`.
- `Option[T]`: Safe nullability `Some(T)` / `None`.

### Quantum Built-ins
- `qbit`: Fundamental quantum bit.
- `qreg[N]`: Quantum register of `N` qubits.

## 3. Syntax and Features
### Variables and Constants
- `const MAX as usize = 1024` (Compile-time)
- `let x as i32 = 10` (Immutable)
- `let mut y = 20` (Mutable)
- `var z = 30` (Shorthand for `let mut`)

### Memory Management & Lifetimes
Manual and strict.
- `let r as life a i32 = ref num` (Safe reference with lifetime 'a')
- `let p as ptr[i32] = ref num` (Unsafe raw pointer)
- `deref p` to manually dereference.
- `make[T]()` to allocate, `drop(val)` to deallocate.

### Systems Modifiers
- `inline fn`, `static var`, `extern fn`, `volatile var`, `atomic var`.

### Concurrency
- `for@vec`: SIMD vectorized loops.
- `for@par`: Multi-threaded parallel loops.

### Data Structures
- `struct`: Stack allocated value types.
- `enum`: Algebraic Data Types with methods.
- `union`: C-style unions.
