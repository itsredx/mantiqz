# 0038 - Magic Methods (Dunder Methods) for Structs

## Context & Motivation
To match the class magic methods functionality and allow struct value types to support initialization (`__init__`), custom cleanup (`__del__`), operator overloading (`__add__`, `__neg__`, etc.), and subscript indexing (`__getitem__`, `__setitem__`), we extended the magic method system to Struct types.

Unlike classes (which are reference types managed by pointers), structs are value types and are subject to value semantics, stack lifetimes, move-only constraints, and platform calling conventions (ABI).

---

## Design & Implementation Details

### 1. Struct Constructor (`__init__`)
- **Semantics**: Instantiating a struct `Point(10, 20)` allocates space on the stack via `alloca`, writes a zeroinitializer, and invokes the struct's `__init__` method, passing the stack pointer as `self`.
- **Calling Convention**: The method is called as a static function where `self` is a pointer (`ptr[Struct]`). Subsequent arguments map to the constructor parameters.

### 2. Move-Only Structs with Custom Destructors (`__del__`)
- **Semantics**: If a struct defines a custom `__del__` method, it has side effects and custom cleanup logic.
- **Rule Enforcement**:
  - `types.hasDestructor` returns `true` for structs defining `___del__`.
  - `types.isCopyType` returns `false` for structs defining `___del__`.
  - This promotes the struct to a move-only type, preventing accidental duplicates and enforcing cleanup rules.

### 3. Operator and Index Overloads
- **Operator Overloads**: Standard operator expressions (unary and binary) on struct types are rewritten to `.MethodCallExpr` nodes.
- **Indexing Overloads**: Subscript access and assignment (e.g. `obj[idx]` and `obj[idx] = val`) are rewritten to call `__getitem__` and `__setitem__`.
- **Receiver Pointer Auto-Dereference**: If the receiver is a raw pointer to a struct, the typechecker and code generator automatically dereference it to bind to the method receiver.

### 4. ABI Coercion Compatibility
- **Problem**: In x86_64-linux ABI, small structs fit in registers and are returned or passed via coerced types (e.g., a struct `Point` consisting of two `i32`s is returned as an `i64`). The code generator's static dispatch in `MethodCallExpr` was generating return calls with the raw struct type (`%Point`) rather than the coerced type (`i64`), causing a register size/memory layout mismatch between caller and callee.
- **Solution**: We updated `MethodCallExpr` static dispatch codegen to check target return ABI using `abi.getRetABI` and apply the necessary LLVM IR coercion:
  - Generate the call with the coerced type.
  - Store the coerced value back to an alloca stack slot of the original struct type.
  - Load the struct type value from the stack slot to restore the original type.
