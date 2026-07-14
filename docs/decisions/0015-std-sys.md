# Decision 0015: std.sys Module & Platform APIs

## Context

Nizam and Mantiq programs require standard interfaces to query host characteristics (operating system and CPU architecture) and retrieve or modify environment variables.

## Decision

We introduce the standard library module `std.sys` containing:
1. `os() -> AsciiStr`
2. `arch() -> AsciiStr`
3. `getenv(name as AsciiStr) -> AsciiStr`
4. `setenv(name as AsciiStr, value as AsciiStr) -> Void`
5. `unsetenv(name as AsciiStr) -> Void`

### Implementation Details:
- **ABI Safety**: To prevent architecture/calling convention mismatches across platforms (System V AMD64 ABI on Unix/macOS vs. Windows x64 ABI), strings returned from runtime C helpers (`os()`, `arch()`, `getenv()`) return a pointer (`ptr`) to thread-safe static/global structs. The compiler loads the `{ ptr, i64 }` slice struct directly from the returned address.
- **Portability**: OS/Arch names are queried via compile-time preprocessor macros in `runtime.c`. Environment functions use POSIX `getenv`, `setenv`, and `unsetenv` on Unix-like targets, and `SetEnvironmentVariableA` on Windows.
