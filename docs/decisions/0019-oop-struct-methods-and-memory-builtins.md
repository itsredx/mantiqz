# Decision 0019: OOP Struct Methods and Memory Builtins Renaming

## Context
In Nizam, memory allocation was previously handled using the builtins `alloc`, `realloc`, and `free` from the `std.mem` module. Additionally, helper functions for structs (like `String` and `StringBuilder` in the `std.string` module) were implemented as global functions rather than nested object-oriented struct methods, which conflicted with the syntax paradigms of Mantiq.

To unify Mantiq and Nizam syntax and clean up the standard library, we transitioned to:
1. Object-Oriented style struct methods (e.g. `String.make()`, `s.append()`).
2. Renaming the `std.mem` builtins to `make`, `drop`, and `resize` to align with the core language memory builtins.

---

## Language Specification

### Feature: Struct Methods and Associated Functions
Struct declarations can contain nested functions. If the receiver of the method call is a Struct Type (static lookup) or Struct/Union instance, the compiler dispatches the call statically to the mangled function name (`StructName_FunctionName`).

#### Syntax:
```nizam
struct StructName:
    public var field as Type

    // Associated Function (Static method)
    fn associated_func(arg as Type) as StructName:
        ...

    // Instance Method (OOP-style method)
    fn instance_method(self as ptr[StructName], arg as Type):
        ...
```

#### Semantics:
- **Associated Functions (Static calls):** Called as `StructName.method_name(...)`. The compiler resolves the type of `StructName`, and does not pass a receiver pointer.
- **Instance Methods:** Called as `instance.method_name(...)` where `instance` is a variable of type `StructName`. The compiler automatically obtains the pointer (LValue) of the receiver `instance` and passes it as the first parameter `self` of type `ptr[StructName]`.

#### Examples:
```nizam
let mut s1 = String.make("Hello")
s1.append(ref s2)
s1.deinit()
```

#### Errors:
- Calling an instance method on a type that does not exist or has no such method results in a compilation error:
  `Type Error: Struct 'StructName' has no method named 'method_name'`
- Mismatched argument counts:
  `Type Error: Enum variant 'method_name' expects X arguments, got Y`

---

### Feature: Standard Memory Builtins (`make`, `drop`, `resize`)
Memory management builtins are updated to modern naming.

#### Syntax:
- `make(cap as usize)`: Allocates `cap` bytes and returns `ptr[Any]`.
- `resize(p as ptr, cap as usize)`: Resizes allocation pointed to by `p` to `cap` bytes and returns `ptr[Any]`.
- `drop(p as ptr)`: Frees the memory block pointed to by `p`.

#### Semantics:
- `make` falls back to a base size of 1 when no generic arguments are supplied, allowing direct byte-level allocation (compatible with the old `alloc`).
- `resize` resizes the buffer, acting like the old `realloc`.
- `drop` releases the heap memory, acting like the old `free`.

#### Examples:
```nizam
let p = make(16)
let new_p = resize(p, 32)
drop(new_p)
```
