# Decision 0045: Bidirectional Python FFI Subsystem and Tier 2 Static Typed `extern[python]`

## Context

High-performance systems programming languages must interoperate smoothly with the Python data science and machine learning ecosystem (NumPy, PyTorch, pandas, OS libraries) without sacrificing execution speed, type safety, or concurrency predictability.

Previously, Mantiq and Nizam only provided traditional C FFI (`extern fn`). Calling Python from Nizam or calling Nizam routines from Python required manual C boilerplate, fragile `ctypes` wrappers, or third-party binding generators (Cython, pybind11).

We need a native, bidirectional Foreign Function Interface (FFI) embedded directly within the self-hosted Nizam compiler pipeline that:
1. Compiles Nizam modules directly into native CPython C-extension modules (`--target python-ext`) adhering to the PEP 384 Limited API (`abi3`) with zero header dependencies (`Python.h`).
2. Provides first-class object synthesis for Nizam structs and classes with automatic memory lifecycle tracking.
3. Exposes raw Nizam arrays directly to Python through the PEP 3118 Buffer Protocol with zero memory copying.
4. Statically verifies thread safety and releases the CPython GIL via `@nogil`.
5. Enables calling Python code from Nizam either dynamically (`import[python]`) or through zero-overhead, statically-typed declarations (`extern[python]`).
6. Integrates with standard Python packaging (`pyproject.toml`, PEP 517).

---

## Architectural Design

The bidirectional Python FFI is structured into six progressive phases and a high-level static declaration tier:

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                    Nizam <-> Python Bidirectional FFI Model                   │
├───────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│  [ Export Pipeline: Nizam -> Python ]                                         │
│   Phase 1: PEP 384 abi3 shared libraries (.abi3.so) via Vectorcall           │
│   Phase 2: %PyTypeObject synthesis for Nizam structs and classes              │
│   Phase 3: PEP 3118 buffer protocol (bf_getbuffer / bf_releasebuffer)         │
│   Phase 4: Transitive static @nogil analysis & GIL release                    │
│   Phase 6: PEP 517 build backend (nizam_build)                                │
│                                                                               │
│  [ Import Pipeline: Python -> Nizam ]                                         │
│   Phase 5: Embedded Python runtime & dynamic PyObject calls                   │
│   Tier 2:  Static typed extern[python] declarations with lazy pointer cache   │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: PEP 384 Limited API (`abi3`) C-Extension Generation

1. **Target Flag**:
   - `nizam build <file.nz> --target python-ext [-o <module.abi3.so>]`
   - Sets `Target.python_ext()` in `src/layout.nz` with 64-bit word size and `abi = "abi3"`.
2. **Zero `Python.h` Header Dependency**:
   - The code generator emits LLVM type declarations for CPython C-API structures directly:
     - `%PyMethodDef = type { ptr, ptr, i32, ptr }`
     - `%PyModuleDef_Base = type { i64, ptr, i64, ptr }`
     - `%PyModuleDef = type { %PyModuleDef_Base, ptr, ptr, i64, ptr, ptr, ptr, ptr, ptr }`
   - Emits external declarations for stable C-API functions (`PyModule_Create2`, `PyArg_ParseTuple`, `PyLong_FromLongLong`, `PyFloat_FromDouble`, `PyUnicode_FromString`, etc.).
3. **Vectorcall Trampoline Generation**:
   - For every public module-level function, the compiler generates a trampoline (`@__nizam_py_trampoline_<name>`):
     - Unpacks arguments from Python `args` tuple using `PyArg_ParseTuple`.
     - Coerces values into native Nizam representation.
     - Calls the native function.
     - Boxes the return value into a Python object (`Py_None` for void).
4. **Module Initialization**:
   - Emits `@__nizam_py_methods` array terminated with `{ null, null, 0, null }`.
   - Emits `@__nizam_py_module_def` describing the module.
   - Emits `@PyInit_<modulename>()` exporting the module via `PyModule_Create2(..., 1013)`.

---

## Phase 2: Struct & Class CPython Type Synthesis

1. **Type Object Emission**:
   - For each exported `struct` or `class`, the compiler generates a `%PyTypeObject` table.
   - Configures `tp_name`, `tp_basicsize`, `tp_flags` (`Py_TPFLAGS_DEFAULT | Py_TPFLAGS_BASETYPE`).
2. **Lifecycle Handlers**:
   - `tp_new`: Allocates Python object header (`sizeof(PyObject) + sizeof(NativeStruct)`).
   - `tp_init`: Unpacks constructor parameters and initializes native struct fields.
   - `tp_dealloc`: Runs borrow checker auto-drops and frees associated heap buffers before calling `PyObject_Free`.
3. **Members & Methods**:
   - `tp_members`: Exposes native struct fields via `PyMemberDef` with exact byte offsets.
   - `tp_methods`: Maps member methods to Python instance calls with `self` binding.

---

## Phase 3: Shared-Ownership PEP 3118 Buffer Protocol

1. **Zero-Copy Memory Sharing**:
   - Implements the PEP 3118 buffer protocol on Nizam array/buffer structures.
2. **Protocol Handlers**:
   - `bf_getbuffer` (`@__nizam_py_getbuffer`): Populates `Py_buffer` descriptor:
     - `buf`: Direct pointer to native linear buffer.
     - `len`: Byte length.
     - `itemsize`: Element size (e.g. 8 for `f64`).
     - `format`: Format string (`"d"` for f64, `"q"` for i64, `"B"` for u8).
     - `ndim = 1`, `shape`, `strides`.
   - `bf_releasebuffer` (`@__nizam_py_releasebuffer`): Releases internal reference counts.
3. **Python Interop**:
   - Enables zero-copy instantiation of `memoryview` and NumPy `np.asarray()` directly over Nizam heap memory.

---

## Phase 4: Transitive Static GIL Safety Engine & `@nogil`

1. **Language Decorator**:
   ```nizam
   @nogil
   fn parallel_transform(data as ptr[f64], n as i64):
       ...
   ```
2. **Compile-Time Static Validation (`src/sema.nz`)**:
   - Statically verifies that functions annotated with `@nogil`:
     - Do not allocate Python objects.
     - Do not call any CPython C-API functions.
     - Do not read or write `PyObject` handles.
     - Only invoke other `@nogil` functions transitively.
3. **Runtime Threading Optimization**:
   - Emits `Py_BEGIN_ALLOW_THREADS` before invoking the native function.
   - Emits `Py_END_ALLOW_THREADS` upon function exit.
   - Releases the CPython Global Interpreter Lock so Python multi-threading can utilize full hardware parallelism.

---

## Phase 5: Dynamic Embedded Python in Nizam (`import[python]`)

1. **Syntax**:
   ```nizam
   import[python] numpy as np
   import[python] math
   ```
2. **Runtime Integration (`src/runtime.c`)**:
   - Dynamically loads CPython symbols via weak linkage (`__attribute__((weak))`).
   - Automatically initializes the Python interpreter (`Py_Initialize`) on first invocation if not already initialized.
3. **`PyObject` Dynamic Dispatch**:
   - Variable declarations with type `PyObject` support dynamic attribute resolution (`obj.attr`), method calls (`obj.method(...)`), and conversions back into Nizam static types.

---

## Phase 6: In-Process Loader & PEP 517 Packaging Backend

1. **Packaging Backend**:
   - Implemented under `mantiq/python/nizam_build/`.
   - Conforms to PEP 517 and PEP 518 specifications (`build_meta:__legacy__`).
2. **Configuration (`pyproject.toml`)**:
   ```toml
   [build-system]
   requires = ["setuptools"]
   build-backend = "nizam_build.core"

   [tool.nizam]
   module-name = "my_math"
   sources = ["src/math.nz"]
   ```
3. **Direct Installation**:
   - Supports standard Python package management:
     ```bash
     pip install .
     python -m build --wheel
     ```

---

## Tier 2: Static Typed `extern[python]` Declarations

While `import[python]` provides dynamic scripting convenience, systems code requires strict compile-time types, fast call times, and compiler-checked signatures. Tier 2 introduces static typed declarations:

### 1. Syntax

#### Block Syntax
```nizam
extern[python] "math":
    fn sqrt(x as f64) as f64
    fn pow(base as f64, exp as f64) as f64
    fn floor(x as f64) as f64

extern[python] "os.path":
    fn join(a as cstr, b as cstr) as cstr
    fn dirname(p as cstr) as cstr
```

#### Inline Syntax
```nizam
extern[python] "math" fn ceil(x as f64) as f64
extern[python] "math" fn isnan(x as f64) as bool
extern[python] "builtins" fn abs(x as i64) as i64
```

### 2. Zero-Overhead Lazy Callable Caching

Calling Python functions via `PyObject_GetAttrString` on every invocation incurs significant dictionary lookup overhead. To solve this, the code generator (`src/codegen.nz:emit_python_extern_fun`) synthesizes a static pointer cache:

```llvm
@__nizam_py_cached_sqrt_0 = internal global ptr null
```

During execution:
1. The function checks if `@__nizam_py_cached_sqrt_0` is null.
2. If null:
   - Resolves the module and function via `PyImport_ImportModule` and `PyObject_GetAttrString`.
   - Stores the resulting callable pointer in `@__nizam_py_cached_sqrt_0`.
3. Calls the cached pointer directly via Python Vectorcall (`PyObject_CallObject`).
4. Converts return values into native Nizam representation.

### 3. Verification & Compliance
- Phase 1–6 integration test suites are verified under `mantiq/src/tests/python/`:
  - `run_phase_1_tests.sh` (Primitives & Vectorcall)
  - `run_phase_2_tests.sh` (Struct/Class type synthesis)
  - `run_phase_3_tests.sh` (Buffer protocol)
  - `run_phase_4_tests.sh` (GIL release & safety)
  - `run_phase_5_tests.sh` (Dynamic embedded Python)
  - `run_phase_6_tests.sh` (PEP 517 build backend)
  - `run_extern_python_tests.sh` (Tier 2 static typed declarations)
