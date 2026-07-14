# Decision 0013: std.process Module & Command Line Interface

## Context

Mantiq and Nizam require access to command line arguments and process control primitives (specifically exiting with a return code). Standard libraries in other modern systems systems natively support this.

## Decision

We introduce the `std.process` standard library module containing:
1. `exit(code as i32) -> Void`
2. `args() -> List[AsciiStr]`

To support this cleanly without introducing implicit global variables in user code:
- The compiled entry point `@main` is modified to accept `i32 %argc` and `ptr %argv`.
- The first operation in `@main` is calling a runtime initialization function `@mantiq_init(i32, ptr)` which stores the CLI parameters in static global state.
- `args()` constructs and returns a dynamic list (`{ ptr, i64, i64 }`) wrapping the static CLI arguments as ASCII string slices (`{ ptr, i64 }`).

## Consequences

- All Mantiq and Nizam binaries now have access to standard CLI arguments.
- Any invocation of `main` from external platforms (e.g. LLVM JIT, custom runner) will pass `argc`/`argv` cleanly.
- `exit` cleanly maps to standard C runtime library `exit` with no extra overhead.
