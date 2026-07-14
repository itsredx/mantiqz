# Decision 0021: Strict Parameter Type Checking for Struct/Union Methods and Module Functions

## Context
In Nizam, memory safety and ABI compatibility are critical since structural types (like structs and unions) can be passed by pointer (`ptr[T]`) or by value. Previously, `typecheck.zig` only validated parameters for direct function calls (`CallExpr`), but completely bypassed typechecking of arguments for struct/union method calls and module function calls (`MethodCallExpr`). This allowed signature mismatches to compile successfully but fail at runtime (e.g., JIT evaluation of `s1.append(s2)` resulted in a segmentation fault because the caller passed a struct value `%mantiq_std_string_String` but the callee expected a pointer `ptr`).

To prevent these unsafe states, we enforce compile-time parameter count and type checking on all `MethodCallExpr` nodes.

---

## Language Specification

- Feature: Parameter Count and Type Checking for Struct/Union Method and Module Calls
- Syntax:
  Calling a struct/union method:
  ```nizam
  receiver.method_name(arg1, arg2, ...)
  ```
  Calling a module function:
  ```nizam
  module_name.function_name(arg1, arg2, ...)
  ```
- Semantics:
  - If the receiver is a module, the compiler validates that `m.arguments.len` equals the number of parameters defined in the module function's signature. Each argument `arg` must be implicitly convertible to the parameter's declared type.
  - If the receiver is a struct or union instance (e.g., `s1.append(...)`), the compiler looks up the mangled method name (e.g. `String_append`). The first parameter in the method's type signature represents the implicit `self` receiver. The compiler validates that `m.arguments.len` equals `param_types.len - 1`. Each argument `arg` must be implicitly convertible to the expected parameter type.
  - If the method is static (called on a type name receiver, e.g. `String.make(...)`), `m.arguments.len` must equal `param_types.len`.
- Examples:
  ```nizam
  from std.string import String
  let mut s1 = String.make("Hello ")
  let s2 = String.make("world!")

  // Invalid: s2 has type String, but append expects ptr[String]
  s1.append(s2)

  // Valid: ref s2 has type ptr[String]
  s1.append(ref s2)
  ```
- Errors:
  - Argument count mismatch:
    `Type Error: Method 'append' expects 1 arguments, but got 2`
  - Argument type mismatch:
    `Type Error: Argument 1 expects type 'ptr', but got 'mantiq_std_string_String'`
