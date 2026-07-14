# Language Specification: Functions

## Overview

Mantiq and Nizam support a rich set of function forms: named functions, anonymous closures, generic functions, async functions, extern FFI functions, variadic functions, expression-body functions, and methods on structs/classes. All functions are first-class values with type `fn(...) -> RetType` or `Closure`.

---

## 1. Named Function Declarations

### 1.1 Standard Form

```nizam
fn name(param1 as Type1, param2 as Type2) -> ReturnType:
    body
    return value
```

Parameters are specified with `name as Type`. The return type is specified with `-> ReturnType`. If omitted, the function returns `void`.

### 1.2 Expression-Body Form

```nizam
fn name(params) -> ReturnType => expression
```

Shorthand for functions whose body is a single expression. The expression value is implicitly returned.

```nizam
fn square(x as f64) -> f64 => x * x
fn add(a as i32, b as i32) -> i32 => a + b
```

Lowered as a `FunDecl` with a `BlockStmt` body containing a `ReturnStmt`.

### 1.3 Block-Body Form

```nizam
fn name(params):
    statement1
    statement2
    return value
```

The body is always wrapped in a `BlockStmt` node in the AST, even for expression-body forms.

### 1.4 Multiple Return Values (Tuple)

```nizam
fn divmod(a as i32, b as i32) -> (i32, i32):
    return a / b, a % b
```

Returned as a `Tuple[A, B]` type.

---

## 2. Closures (Anonymous Functions)

### 2.1 Lambda Form

```nizam
let f = (x as i32, y as i32) => x + y
```

Short-form closure with typed parameters and expression body.

### 2.2 Full Anonymous Function Form

```nizam
let f = fn(x as i32, y as i32) -> i32:
    return x + y
```

Full-form closure with block body.

### 2.3 Closure Capture

Closures automatically capture variables from their enclosing scope:

```nizam
fn make_multiplier(x as i32) -> fn(i32) -> i32:
    let multiply = (y as i32) => x * y    // captures x
    return multiply

fn main() -> i32:
    let times3 = make_multiplier(3)
    let result as i32 = times3(5)          // 15
    return result
```

Captured variables are identified during semantic analysis (`sema.zig` upvalue detection). The capture tuple is heap-allocated and packed into the closure's environment pointer.

### 2.4 Closure Type

- **LLVM IR**: `{ ptr, ptr }` — function pointer + environment pointer
- **Copy/Move**: Copy
- **Internal**: Each closure gets a unique `closure_id`. The outlined function is named `__mantiq_closure_<id>`.

### 2.5 First-Class Functions

Named functions can be referenced without calling them:

```nizam
fn add(a as i32, b as i32) -> i32:
    return a + b

fn apply_func(op as fn(i32, i32) -> i32, x as i32, y as i32) -> i32:
    return op(x, y)

fn main():
    let my_op = add
    let res as i32 = apply_func(my_op, 100, 200)
```

---

## 3. Parameter Features

### 3.1 Type Annotations

Each parameter may have a type annotation:

```nizam
fn f(a as i32, b as str, c as List[f64]) -> void:
    pass
```

If a type annotation is omitted, the parameter type is inferred from the call site (or defaults to `Any` in Mantiq). In Nizam, all parameters must have explicit type annotations.

### 3.2 Default Values

Parameters can have default values:

```nizam
fn move(x as i32 = 0, y as i32 = 0) -> i32:
    return x + y

fn main():
    print(move())        // 0 (both default)
    print(move(10))      // 10 (x=10, y=0)
    print(move(y=10, x=5))  // 15 (keyword args)
```

Default values are parsed and stored as AST nodes in `FunDecl.default_values`. During codegen, omitted arguments at a call site are replaced with the default.

### 3.3 Keyword Arguments

Arguments can be passed by name in any order:

```nizam
fn configure(host as str, port as i32, timeout as i32 = 30):
    ...

fn main():
    configure(port=8080, host="localhost")
    configure("localhost", 8080)
    configure("localhost", port=8080, timeout=60)
```

Keyword arguments are parsed in `lowerCallExpr` as `KeywordArg` AST nodes. During typechecking, they are reordered to match the parameter declaration order, and defaults fill any remaining parameters.

### 3.4 Variadic Parameters

The `...args as Type` syntax captures variable numbers of arguments:

```nizam
fn sum_all(base as i32, ...args as i32) -> i32:
    let mut total as i32 = base
    for num as i32 in args:
        total = total + num
    return total

fn main():
    print(sum_all(10, 1, 2, 3))   // 16
```

The variadic parameter is lowered to `List[Type]` in the AST. At the call site, extra arguments are packed into the list.

### 3.5 Spread Operator

The `...expr` syntax spreads a list into individual arguments:

```nizam
fn main():
    let extra as List[i32] = [4, 5]
    print(sum_all(20, ...extra))   // 29
```

Lowered as a `SpreadExpr` node. At the call site, the list elements are unpacked into the argument list.

### 3.6 Self Parameter (Methods)

Struct/union/class methods receive `self` as the first parameter:

```nizam
struct Vector2:
    var x as f64
    var y as f64

    fn length(self as ptr[Vector2]) -> f64:
        return sqrt(self.x * self.x + self.y * self.y)

    fn add(self as ptr[Vector2], other as Vector2) -> Vector2:
        return Vector2(x=self.x + other.x, y=self.y + other.y)
```

The `has_self` flag is set on `FunDecl` when the first parameter is named `self`. During codegen, the receiver pointer is automatically passed as the first argument via `MethodCallExpr`.

---

## 4. Generic Functions

### 4.1 Declaration

```nizam
fn identity[T](x as T) -> T:
    return x

fn calc[T](a as T, b as T) -> T:
    return a + b
```

Generic type parameters are declared in square brackets before the parameter list.

### 4.2 Inference

Generic arguments are inferred from the concrete argument types:

```nizam
fn main():
    print(calc(10, 20))         // T = i32 → calc_i32
    print(calc(1.5, 2.5))       // T = f64 → calc_f64
```

### 4.3 Explicit Generic Arguments

```nizam
let p = GenericPoint[i32](x=10, y=20)
```

Explicit type arguments are passed in square brackets at the call site for struct constructors and generic functions.

### 4.4 Monomorphization

Each unique combination of type arguments produces a separate instantiation with a mangled name (`<base>_<typearg>`). See Decision 0027 for full details.

---

## 5. Async Functions and Spawn

### 5.1 Declaration

```nizam
async fn calc(x as i32) -> i32:
    return x
```

The `async` modifier wraps the return type in `Task[T]`. An async function's return type is `Task<i32>` rather than `i32`.

### 5.2 Spawn

```nizam
fn main():
    let task = spawn calc(21)
    let result as i32 = await task
    print(result)
```

`spawn` creates a new concurrent task. The runtime uses pthread-based concurrency (`MantiqTask` struct in `runtime.c`).

### 5.3 Await

The `await` expression blocks until a spawned task completes and returns the result:

```nizam
let result as i32 = await task
```

Lowered as `AwaitExpr` AST node with the task expression as its child.

### 5.4 Spawn Statement Form

```nizam
spawn my_function(args)
```

Can also be used as a statement (fire-and-forget).

---

## 6. Extern Functions (FFI)

### 6.1 Declaration

```nizam
extern fn time(t as i64) -> i64:
    pass

extern fn sqrt(x as f64) -> f64:
    pass
```

The `extern` modifier generates a `declare` in LLVM IR instead of a `define`. The body must be `pass` (or omitted). The function symbol name preserves the original name (no module mangling).

### 6.2 Linking

External libraries are linked using `link` declarations:

```nizam
link "m"
link "pthread"
```

These map to `-l` flags during AOT compilation.

### 6.3 C ABI

Extern functions follow the C calling convention (SysV x86_64 on Linux). Types are laid out in a C-compatible manner in `layout.zig`.

---

## 7. Function Types as Values

### 7.1 Type Syntax

```nizam
fn(param1: Type1, param2: Type2) -> ReturnType
```

### 7.2 Passing Functions

```nizam
fn apply(op as fn(i32, i32) -> i32, x as i32, y as i32) -> i32:
    return op(x, y)

fn main():
    let res = apply(add, 100, 200)   // add is a named function
```

### 7.3 Type Representation

| Concept | `FunctionType` Fields | LLVM IR |
|---------|-----------------------|---------|
| Named function | `param_types`, `return_type`, `is_variadic`, `is_async` | `{ ptr, ptr }` |
| Closure | Same + `closure_id` + captured env | `{ ptr, ptr }` (outlined + env heap) |

Both `Function` and `Closure` are Copy types.

---

## 8. System Modifier Keywords

The following modifiers can appear before function declarations. Currently only `async` and `extern` are implemented; the others are reserved for future use:

| Modifier | Status | Effect |
|----------|--------|--------|
| `async` | ✅ Implemented | Wraps return type in `Task[T]` |
| `extern` | ✅ Implemented | Generates LLVM `declare` (FFI import) |
| `inline` | 🔲 Reserved | Hint for inlining |
| `static` | 🔲 Reserved | Internal linkage |
| `volatile` | 🔲 Reserved | No optimization on calls |
| `atomic` | 🔲 Reserved | Atomic operation semantics |

---

## 9. Method Calls

### 9.1 Struct/Union Methods

```nizam
let v = Vector2(x=1.0, y=2.0)
let len = v.length()     // MethodCallExpr → FunDecl with has_self
```

Method calls are represented as `MethodCallExpr` AST nodes with:
- `receiver`: The object expression
- `method_name`: The method name
- `arguments`: The call arguments (excluding `self`)
- `is_dynamic`: Whether it's a dynamic dispatch (class method)

### 9.2 Module Function Calls

```nizam
import std.math
let result = std.math.sqrt(144.0)
```

Module-qualified calls are `CallExpr` with a `MemberExpr` callee whose receiver type is a `Module`.

### 9.3 Static Method Calls (Associated Functions)

```nizam
let s = String.make("hello")    // Associated function (called on type)
```

The typechecker resolves `String` as a struct type and calls the associated function.

---

## 10. Return Behavior

### 10.1 Implicit Return

If a function body ends without a `return` statement, codegen inserts a synthetic return with a zero/null/void value based on the return type:

| Return Type | Synthetic Value |
|-------------|-----------------|
| `void` | `ret void` |
| `ptr` | `ret ptr null` |
| `float`/`double` | `ret <type> 0.0` |
| Struct/Array/Union | `ret <type> zeroinitializer` |
| Integer | `ret <type> 0` |

### 10.2 Auto-Drop Before Return

When a `return` statement is executed, the borrow checker injects drops for all owned move-type variables in the enclosing scopes that are NOT being returned. See Decision 0026 for details.

### 10.3 Return Value Move

Returning a local variable of Move type transfers ownership to the caller:

```nizam
fn make_string() -> String:
    let s as String = String.make("hello")
    return s    // ownership moves to caller
```

---

## 11. Main Function

The `main` function has special treatment:

- Its return type is implicitly `i32` (exit code)
- If no explicit return is present, codegen inserts `ret i32 0`
- Global variable initialization is emitted before `main` in script mode
- Auto-drops are emitted before the synthetic return

```nizam
fn main():
    print("Hello")
    // implicit: return 0
```

---

## 12. Compiler Architecture

### Pipeline

```
lower.zig (CST → FunDecl/ClosureExpr AST nodes)
  → sema.zig (symbol resolution, capture analysis)
    → typecheck.zig (type inference, generic instantiation)
      → borrowck.zig (auto-drop injection at scope exit)
        → codegen.zig (LLVM IR emission)
```

### AST Nodes

| Node | Purpose | Key Fields |
|------|---------|------------|
| `FunDecl` | Named function | `name`, `generic_params`, `params`, `param_types`, `default_values`, `body`, `is_async`, `is_extern`, `has_self`, `is_variadic`, `return_type`, `auto_drops` |
| `ClosureExpr` | Anonymous function | `params`, `param_types`, `body`, `return_type`, `captured_vars` |
| `CallExpr` | Function call | `callee`, `arguments`, `generic_args` |
| `MethodCallExpr` | Method call | `receiver`, `method_name`, `arguments`, `is_dynamic` |
| `ReturnStmt` | Return statement | `values`, `auto_drops` |
| `SpawnStmt` | Spawn task | `call_expr` |
| `AwaitExpr` | Await task | `task_expr` |
| `KeywordArg` | Keyword argument | `name`, `value` |
| `SpreadExpr` | Spread operator | `iterable` |

### Symbol Resolution

- **Pass 1** (`declarePass1`): Generic `FunDecl` nodes are skipped (templates). Non-generic names are registered as `Function` symbols.
- **Pass 2** (`resolvePass2`): Function parameters are registered in a new scope. The body is resolved, including identifier resolution and closure capture analysis (lines 662–684 of `sema.zig` detect upvalues by checking whether a referenced symbol belongs to a parent scope).

### Codegen

- **Non-extern functions**: Emit `define <ret> @<name>(ptr %env, <params>)` with `%env` as a hidden first parameter (for closure environment).
- **Extern functions**: Emit `declare <ret> @<name>(<params>)` — no environment parameter.
- **`main`**: Emit `define i32 @main()` with implicit `ret i32 0`.
- **Closures**: Each closure is outlined to a separate LLVM function named `__mantiq_closure_<id>`. The environment is heap-allocated via `mantiq_malloc`, and captured variables are packed by value. The closure value is `{ ptr, ptr }` = `{ @outlined_fn, %env_ptr }`.
- **Variadic calls**: The variadic argument is passed as a `List[Type]` value (the extra args are packed into the list at the call site).
- **Method calls**: The receiver pointer is passed as the first argument (`ptr %env` slot), and the method function is called directly (static dispatch for struct methods).
- **Keyword arguments**: Flattened during typechecking — reordered to match parameter order, defaults filled in, then passed positionally to codegen.

### Function Name Mangling

| Context | Scheme | Example |
|---------|--------|---------|
| Module function | `<module>_<name>` | `math_sqrt` |
| Generic function | `<name>_<typearg>` | `calc_i32` |
| Generic struct | `<name>_<typearg>` | `GenericPoint_i32` |
| Closure | `__mantiq_closure_<id>` | `__mantiq_closure_0` |
| Extern | Original name | `sqrt` |
| `main` | `main` | `main` |

---

## 13. Examples

### All Function Forms

```nizam
// 1. Standard function
fn add(a as i32, b as i32) -> i32:
    return a + b

// 2. Expression-body function
fn square(x as f64) -> f64 => x * x

// 3. Void function
fn greet(name as str):
    print("Hello, ", name)

// 4. Generic function
fn identity[T](x as T) -> T:
    return x

// 5. Generic with inference
fn pair[T](a as T, b as T) -> (T, T):
    return a, b

// 6. Default values + keyword args
fn connect(host as str = "localhost", port as i32 = 8080) -> str:
    return host + ":" + port to str

// 7. Variadic
fn sum(...values as i32) -> i32:
    let mut total as i32 = 0
    for v as i32 in values:
        total = total + v
    return total

// 8. Async + spawn + await
async fn compute(x as i32) -> i32:
    return x * 2

fn main():
    let t = spawn compute(21)
    let r as i32 = await t

// 9. Closure with capture
fn make_counter() -> fn() -> i32:
    let mut count as i32 = 0
    let inc = fn() -> i32:
        count = count + 1
        return count
    return inc

// 10. First-class function
fn execute(f as fn(i32) -> i32, x as i32) -> i32:
    return f(x)

// 11. Extern FFI
link "m"
extern fn sqrt(x as f64) -> f64:
    pass

// 12. Method on struct
struct Point:
    var x as f64
    var y as f64

    fn magnitude(self as ptr[Point]) -> f64:
        return sqrt(self.x * self.x + self.y * self.y)
```
