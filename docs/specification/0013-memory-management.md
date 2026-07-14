# Language Specification: Memory Management

## Overview

Mantiq and Nizam use an **affine type system** with explicit allocation and automatic scope-based deallocation. Memory is managed through three built-in functions (`make`, `drop`, `resize`), pointer operators (`ref`, `deref`, `ptr[T]`), lifetime annotations (`life[a]`), and `unsafe` blocks for bypassing safety checks. The borrow checker injects automatic destructors at scope exit via `auto_drops`.

In **Nizam** mode, all heap allocation is explicit — types like `String`, `List`, `Option`, `Result` require explicit `import` from `std`. In **Mantiq** mode, these types are available globally.

---

## 1. Built-in Allocation Functions

### 1.1 `make`

Allocates memory on the heap. Signature:

```nizam
make[T](capacity as i32 = 1) -> ptr[T]
```

- `T` is the element type (passed as a generic type argument)
- `capacity` is the number of elements (defaults to 1)
- Returns a raw pointer `ptr[T]` to the allocated memory

Examples:

```nizam
let p as ptr[u8] = make(16)         // 16 bytes of u8
let buf as ptr[i32] = make[i32](10) // 10 × i32 = 40 bytes
let ptr as Any = make()             // Default: 1 byte, returned as Any
```

**Codegen**: Computes `total_size = sizeof(T) * capacity`, then emits `call ptr @mantiq_malloc(i64 %total_size)`. Returns the allocated pointer.

**Allocator**: The runtime uses mimalloc when available, falling back to `libc malloc`:

```c
void* mantiq_malloc(size_t size) {
    void* ptr = sys_malloc(size);
    if (!ptr) { abort(); }
    return ptr;
}
```

### 1.2 `drop`

Deallocates memory. Signature:

```nizam
drop(ptr as ptr[T])
```

Examples:

```nizam
drop(ptr)         // Free the allocation
drop(buf to ptr)  // Explicit cast to ptr before freeing
```

**Codegen**: Emits `call void @mantiq_free(ptr %val)`. The argument must be a pointer.

### 1.3 `resize`

Resizes an existing allocation. Signature:

```nizam
resize(ptr as ptr[T], new_size as i32) -> ptr[T]
```

Example:

```nizam
let new_ptr as ptr[u8] = resize(ptr, 32)
```

**Codegen**: Emits `call ptr @mantiq_realloc(ptr %old, i64 %new_size)`. Returns the new pointer (may differ from the old one if the allocator moved the block).

### Built-in Registration

`make`, `drop`, and `resize` are registered as built-in symbols in two scopes:

| Scope | Symbol Name | Where |
|-------|-------------|-------|
| Global (always) | `make`, `drop` | `sema.zig:169` |
| `std.mem` import | `make`, `drop`, `resize` | `sema.zig:290` |

In Nizam mode, `resize` requires `from std.mem import resize`.

---

## 2. Pointer Operators

### 2.1 `ref` (Address-Of)

```nizam
ref expr          → ptr[T] where T is the type of expr
ref mut expr      → ptr[T]  (mutable reference)
```

Takes the address of a variable, producing a `RawPointer` with payload type `T`.

```nizam
let x as i32 = 42
let p as ptr[i32] = ref x    // p points to x
let r as life[a] i32 = ref num  // Safe reference with lifetime 'a'
```

**Typechecking** (`typecheck.zig:1358-1363`):
- `ref expr` → `RawPointer { payload = typeof(expr) }`
- `ref mut expr` → same type but semantically mutable

**Codegen** (`codegen.zig:5161-5165`):
- `ref` returns the LValue (stack address) of the operand via `genLValue`

### 2.2 `deref` (Pointer Read)

```nizam
deref ptr_expr    → T where T is the payload type of ptr_expr
```

Reads the value through a pointer.

```nizam
let val as i32 = deref p
```

**Typechecking** (`typecheck.zig:1364-1376`):
- Operand must be `RawPointer` type
- Result type is the pointer's payload type
- Error if operand is not a pointer

**Codegen** (`codegen.zig:5166-5174`):
- Emits `<result> = load T, ptr %ptr_val`

For LValue position (e.g., `deref p = 42`), `deref` returns the pointer value directly as the address to store into (`codegen.zig:2007-2016`).

### 2.3 `ptr[T]` Type

The `ptr[T]` type annotation represents a raw pointer to `T`:

```nizam
let p as ptr[i32] = ref x
let buf as ptr[u8] = make(16)
```

- **LLVM IR**: `ptr`
- **Copy/Move**: Copy
- **`hasDestructor`**: No (raw pointers do not own memory)

Indexing into a raw pointer:

```nizam
let first = deref p[0]    // Read first element
p[0] = 42                  // Write through LValue
```

**Codegen**: `getelementptr inbounds T, ptr %p, i64 %index` for indexed access.

### 2.4 Auto-Dereference

When a method is called on a `ptr[Struct]`, the pointer is automatically dereferenced to reach the underlying struct type:

```nizam
struct Vector2:
    var x as f64
    var y as f64
    fn length(ref self) -> f64:
        return sqrt(self.x * self.x + self.y * self.y)

fn test(p as ptr[Vector2]):
    let len = p.length()   // auto-deref: p → Vector2, then call method
```

---

## 3. Lifetime Annotations

### 3.1 `life[a]` Syntax

```nizam
let r as life[a] mut String = source
```

The `life[a]` annotation declares that the reference is valid for lifetime `'a`. It is syntactic sugar that sets `is_ref = true` and stores the lifetime string in `TypeAnnotation.lifetime`.

### 3.2 Current Status

**Parsed and stored, but not enforced.** The borrow checker extracts the lifetime annotation from the type annotation during identifier resolution and stores it in `VariableState.annotated_lifetime`. This serves as a foundation for future lifetime elision and borrow checker hardening.

```nizam
from std.string import String
let source as String = String.make("Mantiq")
let reference as life[a] mut String = source
let trigger as Any = reference    // works, but borrows not checked
```

### 3.3 Lifetime in References

Lifetimes can appear on `ref` parameters in method declarations:

```nizam
fn __init__(ref mut self, x as f32, y as f32):
    ...

fn area(ref self) as f32:
    return self.x * self.y
```

These are parsed into `TypeAnnotation.is_ref = true` with optional `lifetime`.

---

## 4. Auto-Drop (Scope-Based Deallocation)

### 4.1 Mechanism

The borrow checker (`borrowck.zig`) injects automatic drop calls at scope exit for owned move-type variables. See Decision 0026 for full details.

**Rules**: At scope exit (block end, function return, `return` statement, `with` block), any variable that is:
1. Still in `Owned` state, AND
2. Has a Move type (`types.isMoveType`) OR is marked `is_context_manager`

is appended to the AST node's `auto_drops` array.

### 4.2 Codegen (`genAutoDrops`)

For each symbol in `auto_drops`:
1. **Load** the variable's value
2. **Context managers**: Dispatch to `mantiq_fs_close(i32)` or `@{struct}___exit__(ptr)`
3. **Heap types**: Extract the heap pointer from fat pointer structs:
   - `ptr` types: use the value directly
   - `{ ptr, i64 }` strings: extract field 0 (data pointer)
   - `{ ptr, i64, i64 }` strings: extract field 0
   - `{ i8, ptr }` Option: extract field 1 (payload pointer)
4. **Null-check**: `icmp ne ptr %heap_ptr, null`
5. **Branch**: if non-null, `call void @mantiq_free(ptr %heap_ptr)`

### 4.3 Statement-Level Temporaries

Intermediate expression results that allocate heap memory are tracked in `statement_temporaries`. At the end of each statement, these temporaries are freed:

```zig
fn flushStatementTemps(self: *LLVMCodegen) !void {
    var dealloc_iter = self.statement_temporaries.iterator();
    while (dealloc_iter.next()) |entry| {
        try self.out.writer().print("  call void @mantiq_free(ptr {s})\n", .{entry.value_ptr.*});
    }
    self.statement_temporaries.clearRetainingCapacity();
}
```

---

## 5. `unsafe` Blocks

### 5.1 Syntax

```nizam
unsafe:
    <body>
```

### 5.2 Semantics

- `unsafe` blocks disable certain safety checks in the typechecker
- Currently, the only enforced check is **union field access without a tag** (plain unions):
  - Accessing a field of a plain (untagged) union requires an `unsafe` block
  - Tagged unions (with an enum tag) do not require `unsafe`
- `unsafe` blocks pass through transparently in codegen (`codegen.zig:1463-1465`)

### 5.3 Example

```nizam
union Value:
    var i as i32
    var f as f32

fn main():
    let v as Value = Value(f=3.14)
    unsafe:
        let i_val as i32 = v.i    // OK: reading untagged union field
```

### 5.4 AST

```zig
UnsafeBlock: struct {
    body: *Node,
}
```

### 5.5 Typechecker Integration

```zig
// typecheck.zig:31
in_unsafe_block: bool = false,

// typecheck.zig:1599-1605
.UnsafeBlock => |*u| {
    const prev_unsafe = self.in_unsafe_block;
    self.in_unsafe_block = true;
    try self.checkNode(u.body);
    node.inferred_type = u.body.inferred_type;
    self.in_unsafe_block = prev_unsafe;
},
```

---

## 6. `size()` and `alignof()` Intrinsics

### 6.1 Syntax

```nizam
let sz = size(Type)
let al = alignof(Type)
```

### 6.2 Status

**Documented in `NIZAM.nz` (lines 212-213) but NOT implemented** in any compiler pass. There is no lowering, typechecking, or codegen for these intrinsics. They are placeholder features for future work.

---

## 7. Ownership Lifecycle

### 7.1 State Machine

Each variable tracked by the borrow checker follows:

```
Owned → Moved | Dropped
```

- **Owned**: The variable holds valid data and is responsible for cleanup on scope exit
- **Moved**: Ownership transferred elsewhere (use triggers `UseAfterMove` error)
- **Dropped**: Explicitly deallocated via `drop()` (use triggers `UseAfterDrop` error)

### 7.2 Move Triggers

A move occurs when a Move-type identifier is used in:
1. **Variable initialization**: `let b as String = a`
2. **Function call argument**: `foo(a)`
3. **List literal element**: `[a, b]`
4. **Return value**: `return a`

Copy types (primitives, `Function`, `Closure`, `RawPointer`, string views) are never moved.

### 7.3 Explicit Drop

```nizam
let ptr as Any = make()
drop(ptr)            // ptr → Dropped state
let crash = ptr      // ERROR: UseAfterDrop
```

---

## 8. Runtime Memory Functions

The runtime (`runtime.c`) provides the allocator interface:

| Function | Signature | Purpose |
|----------|-----------|---------|
| `mantiq_malloc` | `void*(size_t)` | Heap allocation (aborts on failure) |
| `mantiq_free` | `void(void*)` | Heap deallocation |
| `mantiq_realloc` | `void*(void*, size_t)` | Heap reallocation (aborts on failure) |

### Allocator Selection

| Condition | Allocator | Macro Prefix |
|-----------|-----------|--------------|
| `<mimalloc.h>` available | mimalloc | `mi_malloc` / `mi_free` / `mi_realloc` |
| Fallback | libc | `malloc` / `free` / `realloc` |

---

## 9. Memory Layout

### 9.1 Fat Pointer Layouts

Types that own heap memory use fat pointer representations on x86_64:

| Type | Layout | Size | Heap Pointer Field |
|------|--------|------|--------------------|
| `String` | `{ ptr, i64, i64 }` | 24 bytes | Field 0 (data ptr) |
| `Utf8Str` / `str` | `{ ptr, i64 }` | 16 bytes | Field 0 (data ptr) |
| `List[T]` (dynamic) | `{ ptr, i64, i64 }` | 24 bytes | Field 0 (buffer ptr) |
| `Dict[K,V]` | `{ ptr, i64, i64 }` | 24 bytes | Field 0 (hash table ptr) |
| `Option[T]` | `{ i8, ptr }` | 16 bytes | Field 1 (payload ptr) |
| `Result[T,E]` | `{ i8, ptr, ptr }` | 24 bytes | Fields 1, 2 (ok/err ptr) |
| `Any` | `{ ptr, ptr }` | 16 bytes | Field 0 (boxed data ptr) |
| `ptr[T]` | `ptr` | 8 bytes | The value itself |

### 9.2 Null-Check Pattern

Every auto-drop sequence includes a null check before calling `mantiq_free`:

```llvm
%t.1 = load { ptr, i64, i64 }, ptr %s
%t.2 = extractvalue { ptr, i64, i64 } %t.1, 0
%t.3 = icmp ne ptr %t.2, null
br i1 %t.3, label %drop.do.1, label %drop.cont.1
drop.do.1:
  call void @mantiq_free(ptr %t.2)
  br label %drop.cont.1
drop.cont.1:
```

---

## 10. Examples

### Basic Allocation and Deallocation

```nizam
import std.mem

fn main():
    let buf as ptr[u8] = make(16)     // Allocate 16 bytes
    // use buf ...
    drop(buf to ptr)                  // Free memory
```

### `make` with Type and Capacity

```nizam
let p as ptr[i32] = make[i32](10)    // 10 × sizeof(i32) = 40 bytes
for i in 0..10:
    p[i] = i * 2
```

### `resize`

```nizam
import std.mem

fn main():
    let p as ptr[u8] = make(16)
    let new_p as ptr[u8] = resize(p, 32)    // Grow to 32 bytes
    drop(new_p)
```

### `ref` and `deref`

```nizam
fn main():
    let x as i32 = 42
    let p as ptr[i32] = ref x          // Take address
    let val as i32 = deref p           // Read through pointer
    print(val)                         // 42
```

### Unsafe Union Access

```nizam
union Data:
    var i as i32
    var f as f32

fn main():
    let d as Data = Data(i=100)
    unsafe:
        let val as i32 = d.i           // Reading untagged union field
        print(val)
```

### Auto-Drop at Scope Exit

```nizam
from std.string import String

fn test():
    let s as String = String.make("hello")
    // s is automatically freed here via auto_drops
```

### Lifetime Annotation (Tracked Only)

```nizam
from std.string import String
let source as String = String.make("Mantiq")
let reference as life[a] mut String = source
// Tracked but not enforced by the current borrow checker
```

### Allocator Choice at Compile Time

The runtime selects the allocator automatically. If mimalloc is available during compilation, it is used; otherwise, libc malloc is the fallback. The allocator name is printed at runtime initialization.
