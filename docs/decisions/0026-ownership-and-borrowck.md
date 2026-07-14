# Decision 0026: Ownership Model and Borrow Checking

## Context
Mantiq and Nizam need a memory management strategy that guarantees safety without a garbage collector. Rust's affine type system (ownership + moves) was chosen as the model: each value has exactly one owner, ownership is transferred via moves, and values are automatically cleaned up when their owner goes out of scope. Copy types (primitives) are exempt and duplicated implicitly. The borrow checker in `borrowck.zig` enforces these rules, and the codegen in `codegen.zig` emits `mantiq_free` calls for heap-allocated values at scope exit.

---

## Language Specification

### Feature: Affine Type System (Move Semantics)

Every type is classified as either **Copy** or **Move** (affine). Copy types can be freely duplicated; Move types cannot — they must be explicitly copied or their ownership must be transferred.

### Type Classification Rules

Types are classified by `types.isCopyType` and `types.isMoveType` (the inverse):

| Category | Types | Copy/Move | Rationale |
|---|---|---|---|
| Primitives | `I8`–`I128`, `U8`–`U128`, `ISize`, `USize`, `F16`–`F128`, `Boolean`, `Char`, `RawPointer`, `Function`, `Closure` | Copy | Stored inline in registers/stack; cheap bitwise copy |
| Quantum | `QBit`, `QReg` | Copy | Lightweight register references |
| Enum (no payload) | Plain variants | Copy | Stored as a single integer tag |
| Enum (with payload) | Payload-bearing variants | Copy only if all payload types are Copy | Recursive check |
| Tuple | Any arity | Copy only if all element types are Copy | Recursive check |
| Struct | Named fields | Copy only if all field types are Copy | Recursive check |
| Union | Named fields | Copy only if all field types are Copy | Recursive check |
| Option/Result | `?T`, `Result[T, E]` | Copy only if payload T is Copy | Recursive check |
| String types | `String`, `Utf8Str`, `AsciiStr`, `WebStr`, `RangeStr`, `CStr` | Move | Heap-allocated or owned buffers |
| Collections | `List`, `Dict`, `Slice` | Move | Dynamically allocated |
| Classes | Any class instance | Move | Heap-managed or complex |

#### Recursive Check

For composite types (structs, tuples, enums with payloads, unions, `Option`, `Result`), the copy/move classification is determined recursively: a composite is Copy if and only if all of its constituent types are Copy. This ensures that inserting a single heap-allocated field into a struct makes the entire struct a Move type.

### Ownership State Machine

Each variable tracked by the borrow checker transitions through three states (`ObjectState` in `borrowck.zig`):

```
  ┌──────────┐
  │  Owned   │
  └────┬─────┘
       │
    ┌──┴──┐
    │     │
    ▼     ▼
 ┌─────┐ ┌────────┐
 │Moved│ │ Dropped│
 └─────┘ └────────┘
```

- **Owned**: The variable holds valid data and is responsible for cleanup.
- **Moved**: The ownership has been transferred elsewhere. Any use triggers `UseAfterMove`.
- **Dropped**: Cleanup has already occurred (via explicit `drop()` call). Any use triggers `UseAfterDrop`.

The state can only go forward: `Owned → Moved` or `Owned → Dropped`. There is no recovery path.

### Auto-Drop (Scope-Based Cleanup)

When a scope exits (block end, function return, `return` statement, parameterized block, `with` statement), the borrow checker collects all symbols in that scope that are:
1. Still in `Owned` state, AND
2. Have a Move type (`types.isMoveType`) OR are marked `is_context_manager`

These symbols are appended to the AST node's `auto_drops` array. During codegen, `genAutoDrops` emits LLVM IR that:
- Loads each variable's value
- For context managers: dispatches `mantiq_fs_close` (on `i32` file descriptors) or `__exit__` method (on struct instances with `__exit__`)
- For heap-allocated values: extracts the heap pointer, null-checks it, then calls `mantiq_free`

### Explicit `drop()` built-in

The `drop()` function is a compiler builtin registered in `sema.zig` for both `std.mem` and the global scope. It takes exactly one argument and transitions the variable's state to `Dropped`. During codegen, `drop(x)` lowers to `call void @mantiq_free(ptr %x)`. Calling `drop()` on a value that was already moved or dropped produces a compile error.

### Move Triggers

A move occurs (`borrowck.handleMove`) when an identifier of Move type is used in any of these positions:
1. **Variable initialization**: `let b as String = a` — moves `a` into `b`
2. **Function call argument**: `foo(a)` — passes ownership to the function
3. **List literal element**: `[a, b]` — moves values into the collection
4. **Return value**: `return a` — transfers ownership to the caller

### Error Detection

| Error | Trigger |
|---|---|
| `UseAfterMove` | Identifier used while state is `Moved` |
| `UseAfterDrop` | Identifier used while state is `Dropped` |
| `BorrowClash` | Reserved for future shared/mutable borrow conflicts |
| `InvalidDrop` | `drop()` called with != 1 argument |

### Lifetime Annotations (Explicit Lifetimes)

The `life[a]` syntax allows annotating a variable's expected lifetime on its type annotation, e.g.:
```nizam
let reference as life[a] mut String = source
```
The borrow checker extracts the lifetime annotation from the type annotation (`TypeAnnotation.lifetime`) during identifier resolution and stores it in `VariableState.annotated_lifetime`. This is currently tracked but **not yet enforced** — it serves as a foundation for future lifetime elision and borrow checker hardening.

### Context Managers (`with` statement)

The `with` statement integrates with the ownership system:
1. `sema.zig` marks the bound variable as `is_context_manager = true`
2. `borrowck.zig` tracks it as a regular Owned variable within the `with` block
3. At scope exit, it is added to `auto_drops` automatically
4. Codegen dispatches to either `mantiq_fs_close` (for integer file descriptors) or the struct's `__exit__` method

---

## Implementation Details

### Pipeline Integration

The borrow checker runs as a standalone pass consuming the AST produced by `typecheck.zig` and producing annotated AST nodes consumed by `codegen.zig`:

```
sema.zig → typecheck.zig → borrowck.zig → cfg.zig → dce.zig → codegen.zig
```

### File: `borrowck.zig` (386 lines)

- **`BorrowChecker`** struct holds a `HashMap(*Symbol, VariableState)` for the global state map and an `ArrayList(ArrayList(*Symbol))` for the lexical scope stack.
- **`checkProgram`** iterates over top-level declarations and dispatches to `checkNode`.
- **`checkNode`** is a recursive AST walker handling all statement/expression types. For each scope-creating construct (`FunDecl`, `BlockStmt`, `ParamBlockStmt`, `WithStmt`), it pushes a new scope, processes children, pops the scope, and computes `auto_drops`.
- **`handleMove`** checks the type via `types.isMoveType` and transitions the variable to `Moved`.
- **`ReturnStmt`** has special handling: it walks all enclosing scopes to find owned move-type variables that are NOT being returned, and schedules them for drop.

### File: `types.zig`

- **`isCopyType`** — Recursive check that returns `true` for primitives and all-composite-copy composites; `false` for strings, collections, classes, and other heap-allocated types.
- **`isMoveType`** — Simply `!isCopyType`.
- **`isTriviallyCopyable`** — Returns `true` for types safe for `memcpy` (no destructor needed). Strings return `false` because they own heap buffers.
- **`hasDestructor`** — Returns `true` for heap-owning types (`String`, `Utf8Str`, `List` without fixed length, and composites containing them).

### File: `codegen.zig`

- **`genAutoDrops`** receives the `auto_drops` array from the borrow checker and emits:
  1. A load of each variable's value
  2. A null-check of the heap pointer
  3. A branch: if non-null, call `@mantiq_free(ptr)`; else skip
  4. For context managers: `@mantiq_fs_close(i32)` or `@{struct}___exit__(ptr)` instead of `@mantiq_free`
- Called at every scope-exit point: function body end, block end, param block end, before return, and after `with` body.

### `auto_drops` on AST Nodes

Five AST node types carry an `auto_drops: ?[]*Symbols.Symbol` field populated by `borrowck.zig` and consumed by `codegen.zig`:

| Node | Scope Type |
|---|---|
| `FunDecl` | Function body |
| `BlockStmt` | Block statement |
| `ParamBlockStmt` | Parameterized block |
| `ReturnStmt` | Return statement (drops non-returned values from all enclosing scopes) |
| `WithStmt` | Context manager block |

---

## Examples

### Move Semantics
```nizam
from std.string import String
let s1 as String = String.make("Mantiq")
let s2 as String = s1       // OK: s1 moves to s2
let crash as String = s1    // ERROR: UseAfterMove
```

### Explicit `drop()`
```nizam
let ptr as Any = make()
drop(ptr)                   // OK: ptr is now Dropped
let crash as Any = ptr      // ERROR: UseAfterDrop
```

### Auto-Drop at Scope Exit
```nizam
from std.string import String
fn test():
    let s as String = String.make("temp")
    // s is automatically freed here via auto_drops
```

### Context Manager
```nizam
import std.fs
fn main():
    with open("file.txt", "w") as f:
        write(f, "hello")
    // f is automatically closed here
```

### Lifetime Annotation (Tracked Only)
```nizam
from std.string import String
let source as String = String.make("Mantiq")
let reference as life[a] mut String = source
// Announced but not yet enforced by the borrow checker
```

---

## Rationale

- **Affine types over garbage collection**: Move semantics provide deterministic cleanup without a tracing GC, aligning with Nizam's zero-overhead C++ interop goals and Mantiq's systems-level capabilities.
- **Recursive Copy classification**: A struct with a single `String` field becomes a Move type automatically — there is no way to accidentally create a "shallow copy" that aliases a heap buffer.
- **Scope-based auto-drop**: Eliminates the need for explicit `defer` or `try/finally` patterns for most resources by piggybacking on the existing lexical scope structure.
- **Three-state machine (Owned/Moved/Dropped)**: Simpler than Rust's full borrow checker; sufficient for Nizam/Mantiq's current feature set while leaving room for borrow references (`shared_borrows`/`mutable_borrows` fields are already on `VariableState` but unused).

## Consequences

- All heap-allocated types must be registered in `isCopyType` returning `false` and `hasDestructor` returning `true` (if they own heap memory).
- The borrow checker only handles moves and drops; shared and mutable borrows (`shared_borrows`, `mutable_borrows`) are tracked but not enforced — this is a known gap for future work.
- Explicit lifetime annotations are parsed and stored but not verified — the `VariableState.annotated_lifetime` field is populated but no lifetime inference or checking occurs.
- `genAutoDrops` null-checks every heap pointer before calling `mantiq_free`, adding a small runtime branch per dropped variable. This is a safety overhead that could be optimized away in the future through `@nonnull` annotations.
- Context manager cleanup is hardcoded to two patterns (`mantiq_fs_close` and `__exit__` method). Adding new resource types requires updating `codegen.zig:genAutoDrops`.
