# Specification 0010: Nizam std.path Module

- Feature: POSIX and Windows Path Manipulation Functions
- Syntax:
  ```python
  from std.path import join, join_ref, dirname, dirname_ref, basename, basename_ref, isabs, isabs_ref, exists, exists_ref, is_windows
  from std.string import String

  // By-value usage
  let path = join(String.make("/usr"), String.make("bin"))
  let is_absolute = isabs(path)

  // By-reference/pointer usage (avoids moving String variables)
  let p1 = String.make("/usr")
  let p2 = String.make("bin")
  let joined = join_ref(ref p1, ref p2)
  ```
- Semantics:
  - `is_windows() as bool`
    - Returns `True` if compiled/running on Windows, `False` otherwise.
  - `join(p1 as String, p2 as String) as String` and `join_ref(p1 as ptr[String], p2 as ptr[String]) as String`
    - Joins two path components using host OS rules.
    - If `p2` is absolute (starts with `/` on POSIX, or `/`, `\`, drive letters `C:\`, UNC `\\` on Windows), it overrides `p1` and returns a copy of `p2`.
    - If `p1` is empty, returns `p2`. If `p2` is empty, returns `p1` (with a trailing separator if not already present).
    - Otherwise, joins `p1` and `p2` separated by the host path separator (`\` on Windows, `/` on Linux/macOS).
  - `dirname(path as String) as String` and `dirname_ref(path as ptr[String]) as String`
    - Returns the directory component of the path.
    - Preserves drive letters (`C:\`) and UNC paths (`\\server\share`) on Windows.
    - If no separator is present in the relative part, returns `.` (or prefix + `.` if a drive letter is present without a path component). If the path consists only of separators, returns the root separator (`/` or `\`).
  - `basename(path as String) as String` and `basename_ref(path as ptr[String]) as String`
    - Returns the last path component.
  - `isabs(path as String) as bool` and `isabs_ref(path as ptr[String]) as bool`
    - Returns `True` if the path is absolute on the host OS.
  - `exists(path as String) as bool` and `exists_ref(path as ptr[String]) as bool`
    - Checks the physical existence of a file or directory at the path.
- Examples:
  ```python
  from std.path import join, dirname, basename, isabs, is_windows
  from std.string import String

  fn main():
      // POSIX path
      let p1 = String.make("/usr")
      let p2 = String.make("bin")
      let joined = join(p1, p2) // "/usr/bin"
      let dir = dirname(joined) // "/usr"
      let base = basename(joined) // "bin"

      if is_windows():
          // Windows path
          let w1 = String.make("C:\\Windows")
          let w2 = String.make("System32")
          let w_joined = join(w1, w2) // "C:\Windows\System32"
          let w_dir = dirname(w_joined) // "C:\Windows"
  ```
- Errors:
  - Accessing a string variable after passing it to a by-value function (e.g., calling `join(p1, p2)` and then calling `p1.deinit()`) results in a borrow checker error (`error.UseAfterMove`).
  - Standard heap cleanups are automatically inserted by the compiler for owned variables, but explicit pointers used in references require the user to manage string deinitialization to prevent memory leaks.
