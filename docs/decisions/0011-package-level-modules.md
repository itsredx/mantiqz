# 0011 - Package-Level Modules

## Context
As Mantiq and Nizam projects grow, maintaining all code within a single source file becomes unmanageable. We need a clean module system that treats other Nizam (`.nz`) and Mantiq (`.mq`) files in the workspace/package as modules. This allows code organization, reusability, and encapsulation without compromising compilation performance or complicating JIT/AOT pipelines.

## Decision
We implement a package-level module resolution system. Every file is treated as a package-level module named after its filename (minus the extension). When an import statement is encountered, the compiler dynamically resolves the target file, compiles it recursively, registers its public symbols in a module namespace or imports them directly, and merges their declarations into the final LLVM IR module code generation step.

## Specification

- **Feature**: Package-Level Modules (Nizam & Mantiq)
- **Syntax**:
  ```python
  import <module_path>
  from <module_path> import <symbol1>, <symbol2>
  ```
  Where `<module_path>` is a dot-separated path (e.g. `math` or `utils.math`).
- **Semantics**:
  1. The compiler searches the current working directory / package directory for the module file.
  2. A dot-separated path like `a.b` translates to `a/b.nz` or `a/b.mq` relative to the current directory.
  3. If both `.nz` and `.mq` exist, the compiler prioritizes based on the importing file's language mode (e.g. Nizam prioritizes `.nz`, Mantiq prioritizes `.mq`).
  4. The resolved module is parsed, lowered, analyzed (semantic pass), and typechecked in its own context.
  5. If `import <module_path>` is used, the module's global scope is bound as a `.Module` symbol named after the last component of the path. Members of the module are accessed via dot notation (e.g. `math.add`).
  6. If `from <module_path> import <symbols>` is used, the specified symbols are imported directly into the importing module's scope.
  7. All compiled declarations from the imported module are mangled with the module name prefix (e.g. `math_add`, `%math_MyStruct`) to prevent symbol collisions, and then appended to the final LLVM IR output.
- **Examples**:
  Using `import math`:
  ```python
  import math
  
  fn main() -> i32:
      let res = math.add(5, 10)
      return res
  ```
  Using `from math import MyStruct, add`:
  ```python
  from math import MyStruct, add
  
  fn main() -> i32:
      let s = MyStruct(value = 42)
      return add(s.value, 1)
  ```
- **Errors**:
  - `error.FileNotFound`: Raised if the imported module file cannot be found in the workspace directory.
  - `Type Error: Module has no member named '<name>'`: Raised when trying to access a non-existent member of a module namespace.
  - `Semantic Error: Module '<path>' has no symbol named '<name>'`: Raised when trying to import a non-existent symbol from a module.
  - Cyclic imports are detected and prevented by keeping a registry of compiled modules.

## Implementation Details
1. **Module Loading & Caching**: The compiler maintains a cache of loaded module scopes (`loaded_modules`) to avoid re-compiling the same module multiple times and to prevent cyclic dependency loops.
2. **Name Mangling**: Under the hood, LLVM symbols for global variables, functions, and structs in a module `foo` are mangled to `foo_<name>` (e.g. `@foo_add` or `%foo_MyStruct`). This guarantees no collision with other modules.
3. **AST Merging**: After independent analysis and typechecking of all modules, the compiler driver merges the declarations from all imported modules into the main program's AST root.
