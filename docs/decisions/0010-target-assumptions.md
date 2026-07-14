# 0010 - Target Assumptions (Multi-Platform Targeting)

## Context
Deciding the target platform landscape from day one impacts the compiler backend design, ABI selection, syscall usage, threading runtime models, and standard library dependencies. If a compiler assumes a single platform (e.g. Linux-only), migrating to Windows, macOS, or embedded ARM architectures (like Raspberry Pi) later requires massive refactoring.

## Decision
Mantiq is designed as a **multi-platform, portable language from day one**, targeting:
- **Operating Systems**: Linux, macOS, and Windows.
- **Architectures/Chips**: x86_64, ARM64 (Apple Silicon, ARMv8), and 32-bit ARM (ARMv7, Raspberry Pi).

To ensure high portability across this diverse landscape, Mantiq adopts the following architectural choices:

### 1. No Direct System Calls in Compiler or Generated IR
- The compiler never emits raw OS-specific syscall instructions (e.g., `syscall` on Linux x86_64 or `svc` on ARM).
- All interactions with the underlying operating system are routed through standard C library functions (Libc) or portable LLVM intrinsics.

### 2. ABI Compatibility (LLVM Native Lowering)
- The compiler leverages LLVM's target triple configuration (e.g., `x86_64-pc-windows-msvc`, `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu`).
- Calling conventions, register allocations, stack alignment, and calling conventions (System V AMD64 ABI on POSIX vs. Microsoft x64 calling convention on Windows) are automatically managed by the LLVM backend.

### 3. Portable C Runtime Library (`runtime.c`)
- The runtime is written in portable C (C11 standard) and depends only on:
  - Portable Standard C library headers (`<stdio.h>`, `<stdlib.h>`, `<string.h>`, `<stdint.h>`).
  - Standard POSIX threading (`<pthread.h>`) or standard platform threading layers.
- For memory allocation, it uses a portable allocator interface (`sys_malloc` / `sys_free`) backed by `mimalloc` or the host system's native allocator depending on target capabilities.

### 4. Cross-Platform File I/O and Console I/O
- File operations are modeled using standard ANSI C file pointers (`FILE*`) and standard operations (`fopen`, `fread`, `fwrite`, `fclose`) rather than POSIX-specific file descriptors (`int fd`, `read`, `write`) or Windows handles.
- Console output is buffered and flushed using standard `<stdio.h>` calls (`printf`, `fprintf`, `fflush`), ensuring consistent print behavior across all terminal hosts.

## Implementation Implications
- The same generated LLVM IR (for code semantics) can be compiled to any target CPU and OS simply by running the LLVM optimizer and compiler (`llc` / `clang`) with the appropriate target triple.
- Platform-specific logic is confined entirely to the runtime compilation stage (e.g. linking `pthread` on Linux/macOS vs. native threads on Windows).
