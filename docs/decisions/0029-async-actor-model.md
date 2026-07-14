# Decision 0029: Async / Spawn Actor Model

## Context

Mantiq and Nizam need a concurrency model that supports non-blocking execution and parallelism. The design is modeled on an **actor-like** approach: `spawn` creates a new OS thread that executes a function (or closure), and `await` blocks until the spawned task completes, retrieving its result.

The implementation must integrate with:
- The existing closure capture / outlining infrastructure
- The type system (via `Task<T>`)
- The C runtime for cross-platform thread creation

Channel-based communication (`channel[T]`, `.send()`, `.recv()`) and cooperative multitasking (`yield`) are planned but **not yet implemented**.

---

## Language Specification

### Feature: `async fn` Declarations

Functions can be declared with the `async` modifier:

```nizam
async fn fetch_user_data(id as u64) as String:
    let response = await network.get(f"api/data/{id}")
    return response
```

The `async` keyword is a `fun_modifier` in the grammar:

```js
fun_modifier: $ => choice('async', 'inline', 'const', 'unsafe', 'abstract', 'static', 'extern', 'final'),
```

**Semantics**: `async` is a marker flag (`FunDecl.is_async`) that propagates to the function's `FunctionType.is_async`. It does **not** change the function signature or calling convention — the function remains a regular LLVM function. The flag exists for future use (e.g., async-aware schedulers, `__await__` protocols) and for documentation.

### Feature: `spawn` Expression

`spawn` can be used as either a **statement** or a **unary operator**:

```nizam
spawn fetch_user_data(101)                // statement form
spawn async fn():                          // spawn a closure
    chan.send(42)
let task = spawn fetch_user_data(101)     // expression form, yields Task<T>
```

**Decision: Trampoline outlining.** When a function is spawned, the compiler:

1. **Allocates** an environment struct on the heap containing copies of all argument values
2. **Generates** a trampoline function `{func_name}_trampoline_{N}` that:
   - Unpacks arguments from the environment struct
   - Calls the target function with those arguments
   - If the return type is non-void, allocates a heap buffer for the result and returns a pointer to it
3. **Emits** `call ptr @mantiq_spawn(ptr @trampoline, ptr %env)`

```llvm
define void @fetch_user_data_trampoline_0(ptr %env) {
entry:
  %arg0 = getelementptr inbounds %env.0, ptr %env, i32 0, i32 0
  %val0 = load i64, ptr %arg0
  call void @fetch_user_data(i64 %val0)
  ret void
}

%env = call ptr @mantiq_malloc(i64 8)
store i64 %id, ptr %env
%task = call ptr @mantiq_spawn(ptr @fetch_user_data_trampoline_0, ptr %env)
```

**Special case — closures**: When spawning a closure directly (`spawn fn() => ...`), the closure's codegen path (outlining + fat pointer packing) is reused. The `mantiq_spawn` call extracts the function pointer from the fat pointer.

### Feature: `await` Expression

```nizam
let result = await spawn fetch_user_data(101)
let data = await task_var   // await any Task<T> expression
```

**Decision: Blocking wait on condition variable.** `await` calls `mantiq_await(task_ptr)` in the runtime, which:

1. Locks the task's mutex
2. Spins on `pthread_cond_wait` (or `SleepConditionVariableCS` on Windows) until `is_done` is set
3. Extracts the result pointer (or `null` for `void` tasks)
4. Loads the value from the heap-allocated result buffer
5. Cleans up the task struct and thread handle

```llvm
%task = call ptr @mantiq_spawn(ptr @trampoline, ptr %env)
%result_ptr = call ptr @mantiq_await(ptr %task)
%result = load String, ptr %result_ptr
```

**Type checking** (`typecheck.zig:2244–2255`):
- Operand must be `Task<T>` (or `Any`)
- Result type unwraps to `T` (the task's payload type)

### Feature: `Task<T>` Type

`Task<T>` is the type of a spawned computation:

```zig
// typecheck.zig:2238–2243
.SpawnStmt => |*s| {
    try self.checkNode(s.call_expr);
    const payload_t = try self.allocator.create(types.Type);
    payload_t.* = s.call_expr.inferred_type orelse types.Type{ .kind = .Any };
    node.inferred_type = .{ .kind = .Task, .payload = payload_t };
},
```

- `Task` is a `TypeKind` variant with an optional `payload` type
- It is **not** a struct or built-in — it only exists as a compiler-internal type
- `await` consumes the task and yields the payload type

### Concurrency Primitives: `for@par` and `for@vec`

These are loop-level parallel constructs, separate from the spawn/await mechanism:

```nizam
for@vec i in 0..1024:          // SIMD vectorization hint
    data[i] *= 2.0

for@par i in 0..CPU_CORES:     // parallel loop
    thread_work(i)
```

`for@par` uses the same closure outlining infrastructure:

```llvm
define void @__mantiq_par_closure_0(ptr %env, i32 %i.param) {
entry:
  ...
  ret void
}
call void @__mantiq_parallel_for(i32 %start, i32 %end, ptr @closure, ptr null)
```

The runtime's `__mantiq_parallel_for` currently dispatches loops **sequentially** — full thread-pool dispatch is planned.

---

## Runtime Architecture

### MantiqTask Struct

```c
typedef struct {
    pthread_t thread;            // OS thread handle
    void* (*func)(void*);       // trampoline function pointer
    void* env;                  // heap-allocated environment
    void* result;               // heap-allocated result buffer (or NULL)
    int is_done;                // completion flag
    pthread_mutex_t mutex;      // mutex for condition variable
    pthread_cond_t cond;        // condition variable for await signalling
} MantiqTask;
```

On Windows, `HANDLE thread`, `CRITICAL_SECTION`, and `CONDITION_VARIABLE` are used instead.

### Lifecycle

```
spawn:
  func(env) ───→ pthread_create ───→ task_runner ───→ func(env) ───→ signal is_done
                                              ↑                            │
await:                                        │                            │
  mantiq_await ──→ mutex_lock ──→ cond_wait ──┘                            │
                               ←── cond_signal ←────────────────────────────┘
                               → mutex_unlock → join → cleanup → return result
```

1. `mantiq_spawn` allocates a `MantiqTask`, sets the function/env pointers, and creates a thread
2. The thread's `task_runner` calls `func(env)`, stores the result, sets `is_done`, and signals the condition variable
3. `mantiq_await` waits on the condition variable until `is_done`, then joins the thread, frees the task struct, and returns the result pointer

### Allocator Interaction

Both the trampoline environment and the result buffer are allocated with `mantiq_malloc` (mimalloc or libc). The runtime does **not** free the environment — the trampoline is expected to free it after unpacking (though this is **not currently implemented**, see limitations).

---

## Current Limitations

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| No channel primitives | `channel[T]()`, `.send()`, `.recv()` don't compile | Implement channel type + runtime functions |
| No `yield` keyword | Cooperative multitasking not possible | Grammar + AST + codegen for yield |
| Threads aren't pooled | `spawn` creates a new pthread each time | Add a thread-pool work-stealing scheduler |
| `for@par` is sequential | Parallel loops don't actually parallelize | Replace with actual thread-pool dispatch |
| Environment/result memory leak | Trampoline env and result buffers are never freed | Add cleanup in the trampoline or runtime |
| No comprehensive tests | spawn/await/Task have no test coverage in `tests.zig` | Add integration tests |
| No `__await__` dunder | Custom awaitable types are not supported | Implement dunder protocol for async/await |

---

## Examples

### Basic Spawn and Await

```nizam
fn compute(x as i32) as i32:
    return x * x

fn main() as i32:
    let task = spawn compute(42)
    let result as i32 = await task
    return result    // 1764
```

### Spawning a Closure

```nizam
fn main():
    let msg as String = String.make("hello")
    spawn fn():
        print(msg)
    // msg is captured by value
```

### Spawning an Async Function

```nizam
async fn work(id as u64) as u64:
    return id * 2

let tasks = [
    spawn work(1),
    spawn work(2),
    spawn work(3),
]
let results = [await tasks[0], await tasks[1], await tasks[2]]
```

### Parallel Loop

```nizam
for@par i in 0..100:
    process(items[i])
```

---

## Relevant Files

| File | Role |
|------|------|
| `grammar.js` | `spawn_stmt`, `async` fun_modifier, `spawn` unary operator, `async_expression`, `await` unary operator |
| `ast.zig` | `SpawnStmt`, `AwaitExpr` node types; `FunDecl.is_async` flag |
| `lower.zig:280-292` | CST→AST dispatch for spawn/await/async |
| `lower.zig:915-936` | `async` modifier parsing in function declarations |
| `lower.zig:2334-2357` | `lowerSpawnStmt` implementation |
| `lower.zig:2380-2403` | `lowerUnaryExpr` for await/async/spawn operators |
| `types.zig:46` | `TypeKind.Task` definition |
| `types.zig:61-68` | `FunctionType.is_async` flag |
| `typecheck.zig:613` | Async flag propagation to function type |
| `typecheck.zig:2238-2243` | `SpawnStmt` → `Task<T>` type inference |
| `typecheck.zig:2244-2255` | `AwaitExpr` → payload type unwrapping |
| `codegen.zig:433-434` | LLVM declarations for `mantiq_spawn` / `mantiq_await` |
| `codegen.zig:4172-4254` | Spawn trampoline generation (env struct, outlining, args) |
| `codegen.zig:4255-4261` | Spawn of closure expressions |
| `codegen.zig:4265-4279` | Await codegen (call + result load) |
| `codegen.zig:1524-1551` | `for@par` closure outlining |
| `runtime.c:620-735` | `MantiqTask` struct, `mantiq_spawn`, `mantiq_await` (pthread + Windows) |
| `runtime.c:47-54` | `__mantiq_parallel_for` (sequential placeholder) |
