# Decision 0014: std.time Module

## Context

Nizam and Mantiq programs need standard time primitives to query the system time and suspend thread execution (sleep). These operations are essential for benchmarking, timeouts, rate limiting, and standard scheduling.

## Decision

We introduce the standard library module `std.time` with the following builtins:
1. `now() -> i64`
2. `sleep(seconds as i32) -> Void`

### Implementation Details:
- **`now()`**: Maps to the standard C library function `time(NULL)`. Returns a 64-bit integer representing elapsed seconds since the Unix epoch (January 1, 1970).
- **`sleep(seconds)`**: Suspends the thread using standard POSIX `sleep()` on Linux/macOS and `Sleep()` (with millisecond conversion) on Windows.

## Consequences

- Programs can measure basic time intervals (at 1-second resolution) and sleep for integer-second intervals.
- The C runtime implementation matches POSIX/Windows conventions.
