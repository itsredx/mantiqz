# 0002: Print Statement Buffering & Flushing

- **Feature**: Automatic stdout flushing in `print` built-ins.
- **Why did I do this?**: When using `print(..., end="")`, the standard C library's `stdout` buffers the output until a newline `\n` is encountered. This caused consecutive `print` statements in the REPL (and in scripts) to not appear immediately on the terminal. By injecting an explicit `@mantiq_flush_stdout()` (which calls `fflush(stdout)`) at the end of every `print` compilation sequence, we guarantee that all outputs are immediately visible regardless of the `end` delimiter.
- **Semantics**: Every Mantiq `print()` call automatically resolves and forces a buffer flush to the operating system after executing all its positional parameters and the `end` sequence.
- **Examples**: `print(6, 7, end="---")` will immediately display `6 7---` without waiting for a subsequent `print("\n")`.
