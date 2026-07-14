# Decision 0016: std.collections Module

## Context
Nizam and Mantiq programs require dynamic collections, specifically growable lists (`List[T]`) and hash tables (`Dict[K, V]`). These types require dynamic heap allocation. In Nizam (strict system mode), we require explicit imports to highlight allocations and keep Nizam's zero-implicit-allocation guarantee.

## Decision
We introduce the `std.collections` module containing:
1. `List[T]`
2. `Dict[K, V]`

### Implementation Details:
- **Memory Representation**:
  - Both `List[T]` and `Dict[K, V]` are represented at the LLVM IR level as a 3-word fat pointer structure `{ ptr, i64, i64 }` representing `{ data_pointer, length, capacity }`.
- **Nizam Rules**:
  - Using `List[T]` or `Dict[K, V]` in Nizam mode without `from std.collections import List, Dict` raises a compile-time error.
  - The compiler bypasses this restriction for the built-in fixed-size array type `List[T, N]`.
- **Zero-Cost List Length & Clearing**:
  - `List.length()` is lowered to an LLVM `extractvalue` on index 1 of the fat pointer structure, generating no runtime calls.
  - `List.clear()` is lowered to a local store of `0` at the memory address of index 1 of the fat pointer structure.
- **Generic Growable Append**:
  - `List.append(item)` calls a generic C helper `__mantiq_list_append(void* list_addr, void* elem_addr, int64_t elem_size)` which manages resizing, memory growth, and element copying.
