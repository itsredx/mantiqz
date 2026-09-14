# Specification 0026: std.perf Module

- **Feature**: Standard Performance Monitoring & Resident Set Size (RSS) Tracking
- **Source**: `mantiq/std/perf.nz`
- **Syntax**:
  ```nizam
  from std.perf import make_perf_report, begin_phase, end_phase, finish_report, print_report
  from std.perf import get_time_ns, get_rss_bytes, start_clock, elapsed_ns

  # Nanosecond timestamp and memory queries
  let t_start as i64 = get_time_ns()
  let mem_bytes as i64 = get_rss_bytes()

  # Multi-phase performance reporting
  var rep as PerfReport = make_perf_report()

  let c1 as PerfClock = begin_phase(ref rep, "Compilation" to String)
  # ... execute workload ...
  end_phase(ref rep, c1)

  finish_report(ref rep)
  print_report(rep)
  ```

- **Semantics**:
  - `std.perf` provides high-resolution, monotonic timing (`clock_gettime(CLOCK_MONOTONIC)`) and kernel resident set size tracking (`getrusage(RUSAGE_SELF)`).
  - Designed for compiler self-benchmarking and performance regression monitoring.

### Data Structures

1. **`TimeSpec`**:
   - `tv_sec as i64`: Epoch seconds.
   - `tv_nsec as i64`: Nanoseconds fraction.

2. **`RUsage`**:
   - Mirrors POSIX `struct rusage` layout (`ru_utime`, `ru_stime`, `ru_maxrss`, etc.).

3. **`PerfClock`**:
   - `start_ns as i64`: Starting timestamp in nanoseconds.
   - `label as String`: Human-readable phase label.

4. **`PhaseReport`**:
   - `name as String`: Phase name.
   - `time_ns as i64`: Nanoseconds spent in phase.
   - `rss_before as i64`: Resident set size before phase execution in bytes.
   - `rss_after as i64`: Resident set size after phase execution in bytes.

5. **`PerfReport`**:
   - `phases as List[PhaseReport]`: Sequential collection of tracked execution phases.
   - `total_start_ns as i64`: Benchmark start time.
   - `total_rss_start as i64`: Initial peak RSS memory.
   - `total_time_ns as i64`: Total cumulative elapsed nanoseconds.

### Functions

- `get_time_ns() as i64`: Returns current monotonic time in nanoseconds.
- `get_rss_bytes() as i64`: Returns current peak resident memory in bytes (converted from `ru_maxrss * 1024`).
- `start_clock(label as String) as PerfClock`: Begins a new timed interval tagged with `label`.
- `elapsed_ns(clock as PerfClock) as i64`: Returns the elapsed nanoseconds since `start_clock`.
- `make_perf_report() as PerfReport`: Initializes a multi-phase report capturing current time and memory baseline.
- `begin_phase(report as ptr[PerfReport], name as String) as PerfClock`: Marks the start of a phase.
- `end_phase(report as ptr[PerfReport], clock as PerfClock)`: Computes phase duration and RSS delta, appending to report.
- `finish_report(report as ptr[PerfReport])`: Computes total elapsed time across all phases.
- `fmt_time(ns as i64) as String`: Formats nanoseconds into adaptive string representation (`ns`, `us`, `ms`, `s`).
- `fmt_bytes(bytes as i64) as String`: Formats byte counts into human-readable representation (`B`, `KB`, `MB`).
- `print_report(report as PerfReport)`: Prints an ANSI box-formatted terminal table showing total time, peak RSS, and each phase's duration and memory delta.
