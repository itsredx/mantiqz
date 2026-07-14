# Decision 0020: Resolve JIT/REPL Linkage Errors for Imported Modules

## Context
In the Mantiq/Nizam compiler REPL, each input snippet is compiled into a separate LLVM module. When subsequent snippets reference structs, unions, or modules imported or defined in earlier snippets (e.g. `let mut my_str = string.String.make("hello")`), the code generator of the new snippet must declare these external functions so they can be resolved during the LLIT/JIT linking phase. Previously, the compiler only generated external declarations for simple `CallExpr` nodes, leaving `MethodCallExpr` static dispatch and module calls without proper LLVM declarations, which caused JIT assembler errors (`use of undefined value '@mantiq_std_string_String_make'`).

---

## Language Specification

### Feature: External Function and Method Declarations for JIT Linkage

#### Syntax:
- Automatically managed by the compiler backend when generating LLVM IR for a snippet.
- For any function/method call that is not defined within the current snippet's AST but is resolved in the persistent symbol table, the backend emits a `declare` statement at the top of the LLVM module.

#### Semantics:
- When a `MethodCallExpr` is evaluated in static dispatch or module call mode, the code generator checks if the target mangled name (e.g., `@mantiq_std_string_String_make` or `@mantiq_std_string_make`) is already defined in the current LLVM module.
- If it is not defined, it searches the cached type signature (`types.StructMethod` / `types.UnionMethod` or the corresponding `FunDecl` symbol) and generates an external LLVM signature declaration:
  `declare <ret_type> @<mangled_name>(<parameter_types>)`

#### Examples:
Snippet 1:
```nizam
import std.string
```
Snippet 2:
```nizam
let mut my_str = string.String.make("hello")
```
LLVM output for Snippet 2:
```llvm
%mantiq_std_string_String = type { ptr, i64, i64 }
declare %mantiq_std_string_String @mantiq_std_string_String_make(ptr)
...
```

#### Errors:
No compile-time user errors are introduced by this feature. It fixes a backend code generation defect.
