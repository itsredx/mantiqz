# 0007 - Name Resolution Phases

## Context
A robust name resolution strategy is critical to support mutually recursive functions, recursive struct definitions, forward references, and template monomorphization for generics. Without a clear multi-pass design, compilers run into order-of-declaration bugs or ghost failures during generic expansion.

## Decision
Mantiq implements a strict **two-pass name resolution** protocol in `sema.zig`, followed by **late-binding resolution** during typechecking for generics.

### 1. Pass 1: Global Symbol Registration (Forward Declarations)
During Pass 1, the semantic analyzer recursively visits only the top-level declarations to register their symbols in the global scope. 
- **What is resolved**: Symbol names, kinds, and declaration AST nodes for:
  - Functions (`FunDecl`)
  - Global Variables (`VarDecl` at the program level)
  - Structs (`StructDecl`)
  - Unions (`UnionDecl`)
  - Enums (`EnumDecl`)
  - Classes (`ClassDecl`)
  - Interfaces (`InterfaceDecl`)
  - Imports (`ImportDecl`)
- **Forward Reference Rules**: Any of these top-level declarations can reference each other, regardless of their order in the source file. For example, a struct field can type-annotate using a struct declared later in the file, and a function can call a function declared further down.

### 2. Pass 2: Scope Resolution (Local & Sequential)
During Pass 2, the semantic analyzer traverses the AST bodies and expressions, establishing nested lexical scopes.
- **What is resolved**:
  - Local variables (`VarDecl` inside blocks)
  - Function parameters
  - Match case bindings
  - For-loop iterator variables
  - Identifier references (bound to their defining symbol)
  - Method name mangling (e.g. `StructName_methodName`)
- **Forward Reference Rules**: Local variables, parameters, and iterator bindings cannot be forward-referenced. They are resolved sequentially and are only available in the lexical scopes nested beneath/after their declaration.

### 3. Generics and Monomorphization (Late Binding)
To prevent unbound generic type placeholders (like `T` or `N`) from polluting the global scope or causing name resolution errors:
- **Pass 2 Skipping**: During Pass 2, any generic template (e.g., a `StructDecl` or `FunDecl` with `generic_params != null`) is skipped.
- **Instantiation Passes**: When a generic template is instantiated with concrete types during type checking:
  1. The compiler clones the template's AST node.
  2. Concrete types replace all occurrences of the generic type parameters.
  3. The compiler runs Pass 1 (`declarePass1`) on the cloned node to register the monomorphized name (e.g., `GenericPoint_i32`).
  4. The compiler runs Pass 2 (`resolvePass2`) on the cloned node to resolve all internal identifiers and nested method scopes.
  5. Finally, the monomorphized clone is type-checked.

## Implementation Implications
This discipline guarantees that:
- Structural circular dependencies (like mutually recursive functions or structs containing pointers to each other) compile correctly.
- Generic templates remain completely clean of resolution state until they are fully bound and monomorphized.
