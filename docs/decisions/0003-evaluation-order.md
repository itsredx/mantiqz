# 0003 - Evaluation Order Rules

## Context
Compilers often suffer from subtle, untraceable bugs when the evaluation order of expressions and side effects is left undefined (as in C/C++) or is inconsistently applied across the AST. For example, evaluating `print(f(a()), g(b()))` where both `f` and `g` mutate shared state can lead to chaotic debugging if the compiler arbitrarily decides which argument evaluates first.

Mantiq requires a strict, predictable evaluation model to ensure deterministic behavior across AOT execution, JIT environments, and its Quantum/Async subsystems.

## Decision
Mantiq enforces **strict, left-to-right evaluation** for all expressions and arguments.

### 1. Function Arguments
Function arguments are evaluated strictly from left to right.
In an expression like `f(expr1, expr2, expr3)`, the compiler guarantees the evaluation sequence:
1. `expr1`
2. `expr2`
3. `expr3`
4. Invocation of `f()`

### 2. Binary and Compound Expressions
Binary expressions (`a + b`, `a * b`, `a == b`) evaluate the left-hand operand (`a`) completely before the right-hand operand (`b`).
For assignments (`a = b`), the right-hand side (`b`) is fully evaluated before the memory address of `a` is resolved and mutated.

### 3. Strict vs Lazy Evaluation
- **Strict Evaluation**: Mantiq is a strictly evaluated language. All arguments and operands are fully evaluated before being passed to functions or operations.
- **Lazy Evaluation (Short-Circuiting)**: Future logical operators (`and`, `or`) will be the *only* exception, utilizing standard lazy short-circuiting where the right operand is only evaluated if the left operand's boolean value does not determine the final outcome.

### 4. Side Effects
Side effects follow the exact left-to-right sequence. If a program relies on mutating shared state within a single statement (e.g. `arr[i] = i++`), the sequence of mutations corresponds exactly to the textual left-to-right ordering of the expression tokens.

## Implementation Details
In `src/codegen.zig`, this behavior is explicitly guaranteed by the sequential AST traversal. For example, within `genCallExpr` and `genExpr(BinaryExpr)`, the Tree-sitter AST nodes are visited using deterministic iterative `for` loops or sequential sequential `genExpr(left); genExpr(right);` calls, ensuring that LLVM IR instructions are generated and appended strictly in left-to-right order.
