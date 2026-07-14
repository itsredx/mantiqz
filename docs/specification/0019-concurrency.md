# Language Specification: Concurrency

## Overview

Concurrency is actor-model based with `spawn` (create thread) and `await` (block on completion). The `Task[T]` type represents an in-flight computation. A separate `for@par` / `for@vec` mechanism provides loop-level parallelism. The `async` keyword is a declarative flag (no coroutine transformation).

---

## 1. Spawn

### 1.1 Grammar

```js
spawn_stmt: $ => prec.right(seq('spawn', $.expression, optional($._newline)))
```

`spawn` is both a statement and an expression. It appears in two positions:

- **Statement** (`grammar.js:205`): as a declaration in block body
- **Unary operator** (`grammar.js:411`): `await` is a unary prefix operator

### 1.2 Syntax

```nizam
spawn compute(42)              // statement form — discards Task<T>
let t = spawn compute(42)      // expression form — yields Task<T>
```

### 1.3 AST

```zig
// ast.zig:238-240
SpawnStmt: struct {
    call_expr: *Node,             // the function call or closure to spawn
},
```

### 1.4 Semantics

**Trampoline outlining** — the compiler generates a trampoline function containing all argument captures and spawns it on a new OS thread:

1. **Allocate** environment struct on heap via `@mantiq_malloc(i64 128)` containing copies of all argument values
2. **Generate** trampoline `{func}_trampoline_{N}` that:
   - Unpacks arguments from the env struct (GEP + load)
   - Calls the target function
   - If non-void return: heap-allocates result buffer, stores result, returns pointer
   - Returns `ptr` to result (or `null` for void)
3. **Emit** `call ptr @mantiq_spawn(ptr @trampoline, ptr %env)`

```llvm
; spawn compute(42)
%env_struct_compute = type { i32 }

%env = call ptr @mantiq_malloc(i64 128)
store i32 42, ptr %env

define ptr @compute_trampoline_0(ptr %env) {
entry:
  %arg_ptr.0 = getelementptr inbounds %env_struct_compute, ptr %env, i32 0, i32 0
  %arg.0 = load i32, ptr %arg_ptr.0
  %res = call i32 @compute(i32 %arg.0)
  %res_ptr = call ptr @mantiq_malloc(i64 128)
  store i32 %res, ptr %res_ptr
  ret ptr %res_ptr
}

%task = call ptr @mantiq_spawn(ptr @compute_trampoline_0, ptr %env)
```

**Closure spawn** — when spawning a closure directly, reuses the closure's fat pointer:

```llvm
%closure = call { ptr, ptr } @make_closure(...)
%task = call ptr @mantiq_spawn(ptr @closure_func, ptr null)
```

### 1.5 Type

```zig
// typecheck.zig:2238-2243
.SpawnStmt => |*s| {
    try self.checkNode(s.call_expr);
    const payload_t = try self.allocator.create(types.Type);
    payload_t.* = s.call_expr.inferred_type orelse types.Type{ .kind = .Any };
    node.inferred_type = .{ .kind = .Task, .payload = payload_t };
},
```

The inferred type is `Task[T]` where `T` is the return type of the spawned function.

---

## 2. Await

### 2.1 Grammar

```js
_unary: $ => choice(
    $.unary_expression,
    $.async_expression,
    $._power
),
// ...
// await is a unary prefix operator:
seq(choice($.kw_not, '!', '-', '+', '~', 'deref', 'size', 'type', 'await'), $._unary),
```

### 2.2 Syntax

```nizam
let result = await spawn compute(42)
let data = await task_var       // await any Task<T> expression
```

### 2.3 AST

```zig
// ast.zig:316-318
AwaitExpr: struct {
    task_expr: *Node,
},
```

### 2.4 Semantics

**Blocking wait** — calls `mantiq_await(task_ptr)` which:

1. Locks the task's mutex
2. Waits on `pthread_cond_wait` (or `SleepConditionVariableCS` on Windows) until `is_done`
3. Extracts the result pointer
4. Loads the value from the heap-allocated result buffer
5. Cleans up (join thread, destroy mutex/cond, free task struct)

```llvm
%task = call ptr @mantiq_spawn(ptr @trampoline, ptr %env)
%result_ptr = call ptr @mantiq_await(ptr %task)
%result = load T, ptr %result_ptr
```

### 2.5 Type

```zig
// typecheck.zig:2244-2255
.AwaitExpr => |*a| {
    try self.checkNode(a.task_expr);
    const task_type = a.task_expr.inferred_type orelse types.Type{ .kind = .Any };
    if (task_type.kind != .Task and task_type.kind != .Any) {
        std.debug.print("Type Error: 'await' requires a Task<T> type, got {s}\n", .{@tagName(task_type.kind)});
        return error.TypeMismatch;
    }
    const unwrapped = task_type.payload orelse types.Type{ .kind = .Void };
    node.inferred_type = unwrapped.*;
},
```

Operand must be `Task[T]` — result unwraps to `T`.

---

## 3. Task[T] Type

### 3.1 TypeKind

```zig
// types.zig:46
Task,
```

### 3.2 Representation

`Task[T]` is a **compiler-internal type** (not a user-visible struct or builtin). It has:

```zig
// types.zig:56 — payload stored in Type struct field
payload: ?*Type,
```

### 3.3 Classification

| Property | Value |
|----------|-------|
| Copy/Move | Move (opaque OS thread handle) |
| Has destructor | Yes (must join/cleanup) |
| ABI | `ptr` (pass as opaque pointer) |

---

## 4. The `async` Keyword

### 4.1 Grammar

```js
fun_modifier: $ => choice('async', 'inline', 'const', 'unsafe', 'abstract', 'static', 'extern', 'final')
```

### 4.2 Syntax

```nizam
async fn fetch_user_data(id as u64) as String:
    let response = await network.get(f"...")
    return response
```

### 4.3 Semantics

`async` is a **declarative flag only** — no coroutine transformation. It propagates:

```zig
// lower.zig:915-936 — detected during function lowering
// ast.zig — FunDecl stored with is_async: bool
// typecheck.zig:613 — propagates to FunctionType.is_async
```

- The function remains a regular LLVM function with no state machine transformation
- `async` exists for future use (async-aware schedulers, `__await__` protocols, documentation)

---

## 5. Runtime: MantiqTask

### 5.1 Struct

```c
// Linux/POSIX
typedef struct {
    pthread_t thread;
    void* (*func)(void*);
    void* env;
    void* result;
    int is_done;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} MantiqTask;

// Windows
typedef struct {
    HANDLE thread;
    void* (*func)(void*);
    void* env;
    void* result;
    int is_done;
    CRITICAL_SECTION mutex;
    CONDITION_VARIABLE cond;
} MantiqTask;
```

### 5.2 Lifecycle

```
spawn:
  mantiq_malloc(task)
  set func, env
  pthread_create → task_runner
  └─ task_runner:
       task->result = func(env)
       mutex_lock
       is_done = 1
       cond_signal
       mutex_unlock
       return

await:
  mantiq_await(task)
  mutex_lock
  while !is_done:  cond_wait
  mutex_unlock
  result = task->result
  pthread_join
  mutex_destroy
  cond_destroy
  sys_free(task)
  return result
```

### 5.3 Spawn

```c
MantiqTask* mantiq_spawn(void* (*func)(void*), void* env) {
    MantiqTask* task = mantiq_malloc(sizeof(MantiqTask));
    task->func = func;
    task->env = env;
    task->result = NULL;
    task->is_done = 0;
    pthread_mutex_init(&task->mutex, NULL);
    pthread_cond_init(&task->cond, NULL);
    pthread_create(&task->thread, NULL, task_runner, task);
    return task;
}
```

### 5.4 Await

```c
void* mantiq_await(MantiqTask* task) {
    if (!task) return NULL;
    pthread_mutex_lock(&task->mutex);
    while (!task->is_done) {
        pthread_cond_wait(&task->cond, &task->mutex);
    }
    pthread_mutex_unlock(&task->mutex);
    void* result = task->result;
    pthread_join(task->thread, NULL);
    pthread_mutex_destroy(&task->mutex);
    pthread_cond_destroy(&task->cond);
    sys_free(task);
    return result;
}
```

---

## 6. Parallel and Vectorized Loops

### 6.1 Syntax

```nizam
for@par i in 0..CPU_CORES:
    thread_work(i)

for@vec i in 0..1024:
    data[i] *= 2.0
```

### 6.2 Semantics

`for@par` uses the same closure outlining infrastructure as spawn:

```zig
// codegen.zig:1524-1551
// Generate par_closure function
define void @__mantiq_par_closure_0(ptr %env, i32 %i.param) { ... }
// Dispatch
call void @__mantiq_parallel_for(i32 %start, i32 %end, ptr @closure, ptr null)
```

### 6.3 Runtime

```c
// runtime.c:47-54 — currently sequential
void __mantiq_parallel_for(int start, int end,
    void (*body)(void* env, int i), void* env) {
    for (int i = start; i < end; i++) {
        body(env, i);
    }
}
```

`for@par` dispatch is currently sequential. Full thread-pool dispatch is planned.

`for@vec` is a compiler hint only — no explicit SIMD codegen changes.

---

## 7. Codegen Declarations

```zig
// codegen.zig:433-434
"@mantiq_spawn",
"@mantiq_await",
```

These are declared as external LLVM functions:

```llvm
declare ptr @mantiq_spawn(ptr, ptr)
declare ptr @mantiq_await(ptr)
```

---

## 8. Examples

### Basic Spawn and Await

```nizam
fn compute(x as i32) as i32:
    return x * x

fn main() as i32:
    let task = spawn compute(42)
    let result as i32 = await task
    return result    // 1764
```

### Spawning Multiple Tasks

```nizam
fn work(id as u64) as u64:
    return id * 2

let tasks = [
    spawn work(1),
    spawn work(2),
    spawn work(3),
]
let results = [await tasks[0], await tasks[1], await tasks[2]]
```

### Spawning a Closure

```nizam
fn main():
    let msg as String = String.make("hello")
    spawn fn():
        print(msg)
    // msg captured by value (closure outlining)
```

### Spawn as Statement

```nizam
fn fire_and_forget():
    // Task is created but never awaited
    spawn background_work()
```

### Parallel Loop

```nizam
for@par i in 0..100:
    process(items[i])
```

### Vectorized Loop

```nizam
for@vec i in 0..1024:
    data[i] *= 2.0
```

---

## 9. Limitations

| Limitation | Impact |
|------------|--------|
| Threads not pooled | `spawn` creates a new pthread each time |
| `for@par` sequential | No actual parallel dispatch |
| No channels | `channel[T]()`, `.send()`, `.recv()` not implemented |
| No `yield` | No cooperative multitasking |
| Environment memory leak | Trampoline env not freed after use |
| No `__await__` protocol | User types cannot be `await`-ed |

---

## 10. Relevant Files

| File | Lines | Role |
|------|-------|------|
| `grammar.js` | 19, 205, 272, 411, 430, 434 | spawn_stmt, async_expression, await unary operator |
| `ast.zig` | 85, 105, 238-240, 316-318 | SpawnStmt, AwaitExpr, is_async flag |
| `lower.zig` | 280-292, 915-936, 2334-2357, 2380-2403 | CST→AST lowering for spawn/await/async |
| `types.zig` | 46, 56, 61-68 | Task TypeKind, payload, FunctionType.is_async |
| `typecheck.zig` | 613, 2238-2255 | Task type inference, await unwrapping |
| `codegen.zig` | 433-434, 1524-1551, 4172-4281 | LLVM declarations, spawn trampoline, await, for@par |
| `runtime.c` | 47-54, 620-737 | mantiq_spawn, mantiq_await, __mantiq_parallel_for, MantiqTask (pthread + Windows) |
| `docs/decisions/0029-async-actor-model.md` | Full | Decision record for async/actor model |
