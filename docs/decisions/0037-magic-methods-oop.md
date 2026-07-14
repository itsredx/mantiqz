# 0037 - Magic Methods (Dunder Methods) for Classes

## Context & Motivation
To support operator overloading, indexing, callability, constructor initialization, and string representation for user-defined OOP types in Mantiq/Nizam, we need a system for resolving magic methods (like `__init__`, `__add__`, `__getitem__`, `__setitem__`, `__neg__`, `__str__`/`__repr__`, and `__call__`).

Instead of adding complex type-coercion logic and new LLVM IR code generator paths for every operator, we designed a unified **AST Rewriter** in the Semantic Analyzer/Typechecker (`typecheck.zig`). The typechecker transparently intercepts operations on class instances and rewrites them into `.MethodCallExpr` nodes targeting the corresponding magic method defined on the class. Since code generation already supports method calls, this approach guarantees compatibility across AOT, JIT, and JIT/REPL configurations without modifying `codegen.zig`.

---

## Language Specification

### 1. Class Constructors (`__init__`)
- **Feature**: Instance initialization on instantiation.
- **Syntax**: `ClassName(arguments)` calls `public fn __init__(mut self as ClassName, ...)` if defined.
- **Semantics**: Allocates memory, points to the class vtable, then invokes `__init__` passing the allocated instance as `self` (along with the provided arguments).
- **Examples**:
  ```python
  class Vector2:
      x as i32
      y as i32
      public fn __init__(mut self as Vector2, x as i32, y as i32):
          self.x = x
          self.y = y
  
  let v = Vector2(10, 20)
  ```
- **Errors**: `Type Error: Missing required argument 'x' for __init__`, or argument type mismatch.

### 2. Operator Overloading (`__add__`, `__sub__`, etc.)
- **Feature**: Binary operator overloading on class instances.
- **Syntax**:
  - `+` maps to `__add__`
  - `-` maps to `__sub__`
  - `*` maps to `__mul__`
  - `==` maps to `__eq__`
  - `!=` maps to `__ne__`
  - `<` maps to `__lt__`
  - `<=` maps to `__le__`
  - `>` maps to `__gt__`
  - `>=` maps to `__ge__`
- **Semantics**: If the left-hand operand has type `.Class` and defines the corresponding magic method, the `BinaryExpr` is rewritten to `MethodCallExpr` where the receiver is the LHS, the method name is the magic method, and the argument is the RHS.
- **Examples**:
  ```python
  let v3 = v1 + v2 // Rewritten to v1.__add__(v2)
  ```
- **Errors**: Argument type mismatch if the RHS type doesn't match the method signature.

### 3. Unary Minus (`__neg__`)
- **Feature**: Unary negation of class instances.
- **Syntax**: `-expr` maps to `__neg__`.
- **Semantics**: If the operand type is a `.Class` and defines `__neg__`, the `UnaryExpr` is rewritten to `MethodCallExpr` calling `__neg__` with no arguments.
- **Examples**:
  ```python
  let v4 = -v1 // Rewritten to v1.__neg__()
  ```
- **Errors**: Compiler error if `-` is used on an instance that does not define `__neg__`.

### 4. Indexing (`__getitem__` & `__setitem__`)
- **Feature**: Index reading and writing for class instances.
- **Syntax**:
  - `obj[index]` (read) maps to `__getitem__`
  - `obj[index] = value` (write) maps to `__setitem__`
- **Semantics**: 
  - `IndexExpr` is rewritten to `MethodCallExpr` calling `__getitem__` with the index as the single argument.
  - `BinaryExpr` with operator `=` having a LHS of type `IndexExpr` is rewritten to `MethodCallExpr` calling `__setitem__` with the index and assigned value as arguments.
- **Examples**:
  ```python
  let x = v1[0]     // Rewritten to v1.__getitem__(0)
  v1[0] = 100       // Rewritten to v1.__setitem__(0, 100)
  ```
- **Errors**: Type mismatch if indices or value types do not match method signatures.

### 5. Stringification (`__str__` & `__repr__`)
- **Feature**: Conversion of class instances to standard string representations during output.
- **Syntax**: `print(obj)` or `println(obj)` invokes `__str__` (fallback to `__repr__`) if defined.
- **Semantics**: The `print` call-argument node is wrapped in a `MethodCallExpr` calling `__str__` (or `__repr__`), returning a `String` which is then outputted.
- **Examples**:
  ```python
  print(v1) // Rewritten to print(v1.__str__())
  ```
- **Errors**: None. Fallback prints raw address if neither is defined.

### 6. Callability (`__call__`)
- **Feature**: Making class instances callable.
- **Syntax**: `instance(arguments)` maps to `__call__` if the callee type is a class instance.
- **Semantics**: Differentiates between constructor instantiation (where the identifier resolves to the class declaration) and instance invocation (where the callee is an object variable/expression). Rewrites `CallExpr` to `MethodCallExpr` calling `__call__`.
- **Examples**:
  ```python
  let v2 = v1(2) // Rewritten to v1.__call__(2)
  ```
- **Errors**: `Type Error: Class instance is not callable (no __call__ method defined)` if invoked on an instance without `__call__`.
