# Decision 0027: Generic Monomorphization Strategy

## Context
Nizam and Mantiq require generic programming — parameterized types and functions that work with arbitrary types while maintaining zero-cost abstractions. The compiler uses **compile-time monomorphization** (like C++ templates or Rust generics): each generic declaration is instantiated separately for each concrete type argument at compile time, producing specialized code with no runtime dispatch overhead.

---

## Language Specification

### Feature: Generic Declarations

Generic type parameters are declared in square brackets on functions, structs, unions, and enums:

```nizam
fn identity[T](x as T) as T:
    return x

struct GenericPoint[T]:
    public var x as T
    public var y as T
```

#### Syntax

| Construct | Syntax |
|---|---|
| Generic function | `fn name[Params](params) -> RetType: body` |
| Generic struct | `struct Name[Params]: fields / methods` |
| Generic union | `union Name[Params]: fields / methods` |
| Generic enum | `enum Name[Params]: variants` (TODO: not yet implemented) |
| Explicit call with args | `name[TypeArgs](args)` |
| Type annotation with args | `TypeName[TypeArgs]` |

#### Semantics

- **Type parameters** are placeholders in the parameter `ParamType` and return `RetType` annotations. They are replaced with concrete types at instantiation time.
- **Generic declarations are templates**: the compiler stores them verbatim and skips type-checking until they are instantiated.
- **Instantiation is eager**: using `GenericPoint[i32]` in a type annotation immediately triggers monomorphization.
- **Inference**: generic arguments on function calls can be inferred from the concrete argument types (e.g., `identity(42)` infers `T = i32`).

### Name Mangling

Each monomorphized instance receives a unique mangled name to avoid symbol collisions:

```
<BaseName>_<TypeArg1>_<TypeArg2>_...
```

Examples:
- `GenericPoint[i32]` → struct `GenericPoint_i32`
- `calc[i32]` → function `calc_i32`
- `calc[f64]` → function `calc_f64`
- Closures in mangled names → `Closure_<id>` (e.g., `run_callback_Closure_0`)

### Supported Generic Constructs

| Construct | Status | Notes |
|---|---|---|
| Generic functions | ✅ Implemented | Inference from argument types |
| Generic structs | ✅ Implemented | Constructor calls with `Name[Args](...)` |
| Generic unions | ⚠️ Parsed only | No template cache; instantiation not yet wired |
| Generic enums | ❌ Not implemented | `generic_params = null` in lowering |

---

## Implementation Details

### Pipeline Flow

```
lower.zig (parse generic syntax into AST)
  → sema.zig (skip generic templates; skip concrete only)
    → typecheck.zig (register templates; instantiate on use)
      → borrowck.zig / cfg.zig / dce.zig (on monomorphized nodes)
        → codegen.zig (skip templates; emit only concrete instances)
```

### AST Representation (`ast.zig`)

Generic parameters and arguments are stored as data fields on existing AST node types — there are no dedicated generic node variants:

| Node | Field | Type | Purpose |
|---|---|---|---|
| `FunDecl` | `generic_params` | `?[]const u8` | `["T"]` for `fn foo[T](...)` |
| `StructDecl` | `generic_params` | `?[]const u8` | `["T"]` for `struct Foo[T]` |
| `UnionDecl` | `generic_params` | `?[]const u8` | `["T"]` for `union Bar[T]` |
| `EnumDecl` | `generic_params` | `?[]const u8` | (not yet populated) |
| `CallExpr` | `generic_args` | `?[]TypeAnnotation` | Explicit args at call site, e.g. `foo[i32](x)` |
| `TypeAnnotation` | `generics` | `?[]TypeAnnotation` | Type-level args, e.g. `Foo[i32]` |

### Parsing / Lowering (`lower.zig`)

The tree-sitter CST is walked to extract generic information:

1. **Generic parameter lists** on declarations: the CST field `generic_params` contains a `type_list` child node; each identifier in that list is extracted into `[]const u8`.
2. **Type annotation generics** (e.g., `GenericPoint[i32]`): the `lowerTypeAnnotation` function recurses into child nodes to build `TypeAnnotation.generics` arrays.
3. **Call site generics** (e.g., `GenericPoint[i32](x=10)`): `lowerCallExpr` extracts the `generic_params` child into `CallExpr.generic_args`.

### Semantic Analysis (`sema.zig`)

Generic templates are **skipped** during symbol resolution:
- `FunDecl` with `generic_params != null` → returns early without injecting symbols.
- `StructDecl` with `generic_params != null` → returns early without resolving fields.
- `UnionDecl` with `generic_params != null` → returns early.

This prevents the template body from polluting the symbol table. Only concrete (monomorphized) declarations go through full semantic analysis.

### Type Checking — The Core Engine (`typecheck.zig`)

#### Template Registration

When `checkNode` encounters a declaration with `generic_params`:
- **StructDecl**: stored in `struct_templates: StringHashMap(*ast.Node)` keyed by name.
- **UnionDecl**: skipped (no cache yet).
- **FunDecl**: not cached; instantiation happens on-demand at call sites.

#### Struct Monomorphization (`instantiateStruct`)

1. **Mangle name**: `<base>_<arg1>_<arg2>...` using `types.formatType()`.
2. **Cache check**: if `struct_types` already contains the mangled name, return cached `*StructType`.
3. **Build bindings**: `StringHashMap(Type)` mapping each generic parameter name to its concrete type (e.g., `"T" → i32`).
4. **Clone AST**: `cloneNode(allocator, template, bindings)` deep-copies the template and substitutes all `TypeAnnotation` names matching generic params:
   - `fn cloneTypeAnnotation` checks if the annotation name is in `bindings`; if so, replaces with the formatted concrete type name (e.g., `T` → `i32`).
   - The cloned `StructDecl` has `generic_params = null` (no longer generic).
5. **Append to program**: the cloned declaration is appended to the program declarations list.
6. **Re-analyze**: runs `sema.declarePass1`, `sema.resolvePass2`, and `self.checkNode` on the cloned node.
7. **Cache and return**: the resulting `*StructType` is cached in `struct_types`.

#### Function Monomorphization (at CallExpr)

When `checkNode` encounters a call to a generic function:

1. **Infer bindings**: `inferGenericBindings` matches each argument's actual type against the parameter's type annotation. If the annotation name matches a generic parameter, the binding is recorded.
2. **Mangle name**: `<base>_<arg1>_<arg2>...`.
3. **Deduplication check**: scans program declarations for an existing instance with the mangled name.
4. **Clone AST** (if not yet instantiated): `cloneNode` with bindings, strip `generic_params`, append to program.
5. **Re-analyze**: runs sema and typecheck on the cloned function.
6. **Patch call site**: the `Identifier` callee is patched to point to the monomorphized function's symbol.

#### `inferGenericBindings`

```zig
pub fn inferGenericBindings(annot, actual, generics, bindings):
    if annot.name matches a generic param:
        bind param -> actual type
    if annot is a container (e.g., List[T]) and actual is a container:
        recurse on inner type
```

Currently handles single-level inference (e.g., `fn foo[T](x as T)` → `T = i32` from `foo(42)`). For container types like `List[T]`, it recurses one level.

#### `cloneTypeAnnotation`

```zig
pub fn cloneTypeAnnotation(allocator, annot, bindings):
    if annot.name is in bindings:
        replace annot.name with the formatted concrete type
    else:
        dupe annot.name
    recurse into annot.generics if present
```

### Code Generation (`codegen.zig`)

Generic templates are filtered out at codegen time:
- `collectFunctionsFromDecl`: skips `FunDecl` with `generic_params != null`.
- `genDecl` for `StructDecl`/`UnionDecl`: skips if `generic_params != null`.
- `genExpr` for `FunDecl`: skips if `generic_params != null`.

Only monomorphized concrete declarations reach LLVM IR emission. The mangled names from typechecking are used directly as LLVM function/type names.

### Built-in Generic Types

`List[T]`, `Dict[K,V]`, `Option[T]`, `Result[T,E]` are handled as special cases in `validateType` rather than through the monomorphization engine:

- `List[T, N]` → `Type.payload = T`, `Type.array_len = N`
- `Dict[K, V]` → `Type.tuple_types = [K, V]`
- `Option[T]` / `Result[T,E]` → `Type.payload = T`

These types are registered as `.Class` symbols during semantic analysis in Mantiq mode.

---

## Examples

### Generic Function (Inferred)
```nizam
fn calc[T](a as T, b as T) -> T:
    return a + b

fn main():
    print(calc(10, 20))      // instantiated as calc_i32
    print(calc(1.5, 2.5))    // instantiated as calc_f64
```

### Generic Struct
```nizam
struct GenericPoint[T]:
    public var x as T
    public var y as T

    fn get_x(self as GenericPoint[T]) -> T:
        return self.x

fn main():
    let p1 as GenericPoint[i32] = GenericPoint[i32](x=10, y=20)
    let p2 as GenericPoint[f64] = GenericPoint[f64](x=1.5, y=2.5)
    print(p1.get_x())
    print(p2.get_x())
```

### Generic with Closure Argument
```nizam
fn run_callback[T](op as T) -> i32:
    return op(10)

fn main():
    let x as i32 = 50
    let my_closure = fn(y as i32) => x + y
    print(run_callback(my_closure))   // instantiated as run_callback_Closure_0
```

---

## Rationale

- **Compile-time monomorphization** over runtime generics (type erasure, boxing): eliminates runtime dispatch overhead and enables per-type optimization (inlining, constant propagation). This aligns with the zero-cost abstraction philosophy shared with C++ templates and Rust generics.
- **Clone-and-recheck** strategy over type-level substitution: by cloning the AST and running semantic analysis + typechecking on each instance, the compiler reuses all existing passes without needing a type-level substitution engine. Complex features (name resolution in generic bodies, method dispatch, borrow checking on concrete types) work naturally.
- **Template caching with mangled names**: avoids re-instantiating the same generic combination, both at typecheck time (`struct_types` cache) and at codegen time (deduplication scan).
- **Skip during sema/codegen**: by skipping generic templates during semantic analysis and code generation, the compiler avoids wasted work on bodies that won't be emitted.

## Consequences

- **Code bloat**: each unique combination of type arguments produces a separate function/type in the binary. There is no mechanism for sharing instantiations across translation units.
- **No generic enum support**: `EnumDecl` lowering explicitly sets `generic_params = null` with a TODO. Generic enums remain unimplemented.
- **Union generics are parsed but not instantiated**: the parser extracts `generic_params` for unions, but `typecheck.zig` has no template cache for them and skips without registering.
- **Inference is shallow**: `inferGenericBindings` handles only single-level parameter matching and one level of container nesting. Complex inference (e.g., nested generics, higher-kinded patterns) does not work.
- **`Result` generic is "hacked"**: the `Result[T, E]` type uses a single `payload` pointer for both T and E, with a note that proper handling is pending.
- **Monomorphized names may collide**: the simple underscore-joined mangling scheme could produce collisions if two distinct generic parameters have the same formatted name. A more robust scheme (e.g., mangling with type hash or index) may be needed for production use.
- **Closures inside generics**: closures captured in generic function bodies get monomorphized with a `Closure_<id>` suffix, which is unique per instantiation but not predictable across compilation runs.
