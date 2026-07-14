# Specification 0005: std.collections Module

- Feature: Standard Dynamic Collections
- Syntax:
  ```python
  from std.collections import List, Dict
  
  # Dynamic list initialization
  let l = List[i32]()
  l.append(42)
  let size = l.length()
  l.clear()
  
  # Dynamic dictionary initialization
  let d = Dict[String, i32]()
  d["alice"] = 100
  let has_alice = d.has("alice")
  ```
- Semantics:
  - `List[T]` provides a growable dynamic array.
  - `List[T].append(val as T) -> Void` appends an element.
  - `List[T].length() -> i64` returns the number of elements.
  - `List[T].clear() -> Void` clears all elements from the list.
  - `Dict[K, V]` provides a hash map.
  - `Dict[K, V].length() -> i64` returns the number of active entries.
  - `Dict[K, V].has(key as K) -> Boolean` checks key presence.
  - `Dict[K, V].clear() -> Void` removes all entries.
- Examples:
  ```python
  from std.collections import List, Dict
  import std.io
  
  fn main():
      let names = List[String]()
      names.append("Alice")
      names.append("Bob")
      println(names.length()) # 2
      
      let scores = Dict[String, i32]()
      scores["Alice"] = 95
      if scores.has("Alice"):
          println("Has Alice")
  ```
- Errors:
  - Accessing dynamic `List` or `Dict` in Nizam mode without importing them from `std.collections` causes a compile-time error.
  - Passing wrong types to methods or using invalid methods generates compile-time type mismatch errors.
