# Language Specification: Classes and Interfaces

## Overview

Classes provide single-inheritance reference types with virtual dispatch via vtables. Interfaces define method contracts that classes can implement. Both support generics. Classes are only available in Mantiq (dynamic) mode — Nizam (strict) mode rejects `class` declarations and uses `struct` instead.

---

## 1. Class Declaration

### 1.1 Grammar

```js
class_decl: $ => seq(
    repeat($.decorator),
    optional($.access_modifier),
    'class',
    $.identifier,
    optional($.generic_params),
    optional(seq('(', commaSep1($._base_type), ')')),
    ':',
    $.block_body
),
```

### 1.2 Syntax

```nizam
class Shape:
    x as i32
    y as i32

    fn area(self) as f64:
        return 0.0

class Circle(Shape):
    radius as f64

    @override
    fn area(self) as f64:
        return 3.14159 * self.radius * self.radius
```

### 1.3 AST

```zig
// ast.zig:160-166
ClassDecl: struct {
    name: []const u8,
    base_class: ?[]const u8,
    interfaces: [][]const u8,
    fields: []*Node,
    methods: []*Node,
},
```

Fields are parsed as `var_decl` nodes inside the class body (`lower.zig:1309-1311`). Methods are `fun_decl` nodes (`lower.zig:1373-1375`).

### 1.4 Grammar Details (grammar.js)

The class header supports:
- **Decorators**: `@override`, `@final`, `@gpu`, `@vec`, `@par` — parsed before the `class` keyword
- **Access modifier**: `public` or `private`
- **Generic parameters**: `class Box[T, U]:` — parsed via `$.generic_params`
- **Base class + interfaces**: `(BaseClass, Interface1, Interface2)` — comma-separated list of `_base_type`
- **Body**: indented `$.block_body` containing fields and methods

**Base/interface parsing**: In the lowerer (`lower.zig:1293-1301`), identifiers after the class name are assigned as follows:
- 1st identifier after name → `base_class`
- 2nd+ identifiers → `interfaces` list

This means a class `class Foo(Bar, Baz):` has base class `Bar` and implements interface `Baz`.

---

## 2. Interface Declaration

### 2.1 Grammar

```js
interface_decl: $ => seq(
    'interface',
    $.identifier,
    optional($.generic_params),
    ':',
    $.block_body
),
```

### 2.2 Syntax

```nizam
interface Drawable:
    fn draw(self)
    fn get_bounding_box(self) as (f64, f64, f64, f64)
```

### 2.3 AST

```zig
// ast.zig:180-184
InterfaceDecl: struct {
    name: []const u8,
    super_interfaces: [][]const u8,
    methods: []*Node,
},
```

**Note**: The grammar does not currently parse super-interface names from the interface header. The lowerer sets `super_interfaces` to an empty slice (`lower.zig:1780`). Interface extension (`interface Foo(Bar):`) is a planned extension.

---

## 3. Semantic Analysis

### 3.1 Symbol Registration (sema.zig pass 1)

| Node | Symbol Kind | Detail |
|------|-------------|--------|
| `ClassDecl` | `.Class` | `declareSymbol(cl.name, .Class, node)` at `sema.zig:272-273` |
| `InterfaceDecl` | `.Interface` | `declareSymbol(iface.name, .Interface, node)` at `sema.zig:275-276` |

Both are registered in the current scope for resolution by later declarations.

### 3.2 Scope Resolution (sema.zig pass 2)

Both classes and interfaces create a child scope for their methods:

```zig
// sema.zig:573-580 — ClassDecl
const class_scope = try symbols.Scope.create(self.allocator, self.current_scope);
self.current_scope = class_scope;
for (c.methods) |method| { try self.resolvePass2(method); }
self.current_scope = self.current_scope.parent.?;
```

---

## 4. Type System

### 4.1 Type Kinds

```zig
// types.zig:52
Closure, Class, Interface, Error, Struct, Enum, Union, Module,
```

### 4.2 ClassType

```zig
// types.zig:90-96
pub const ClassType = struct {
    name: []const u8,
    base_class: ?*ClassType = null,
    interfaces: []const *InterfaceType = &[_]*InterfaceType{},
    fields: []StructField = &[_]StructField{},
    methods: []StructMethod = &[_]StructMethod{},
};
```

### 4.3 InterfaceType

```zig
// types.zig:84-88
pub const InterfaceType = struct {
    name: []const u8,
    super_interfaces: []const *InterfaceType = &[_]*InterfaceType{},
    methods: []StructMethod = &[_]StructMethod{},
};
```

### 4.4 Shared Field/Method Types

```zig
// types.zig:70-82
pub const StructField = struct {
    name: []const u8,
    type_kind: Type,
    access_modifier: []const u8 = "public",
    is_mutable: bool = false,
    default_value: ?*anyopaque = null,
};

pub const StructMethod = struct {
    name: []const u8,
    type_kind: Type,
    defining_class_name: ?[]const u8 = null,  // tracks overrides
};
```

### 4.5 Copy/Move Classification

| Type | `isCopyType` | `isMoveType` | Implication |
|------|-------------|-------------|-------------|
| `Class` | `false` | `true` | Heap-allocated, owned pointer; moved on assignment |

`types.zig:403` returns `false` for Class. `types.zig:441` returns `true` for Class.

### 4.6 Layout

| Type | Size | Alignment | Notes |
|------|------|-----------|-------|
| `Class` | 8 | 8 | Heap-allocated; pointer-sized handle (`layout.zig:108,203`) |
| `Interface` | 8 | 8 | Fat pointer `{ptr to data, ptr to vtable}` (`layout.zig:51,123`) |

---

## 5. Type Checking

### 5.1 Class Type Construction (typecheck.zig:1764-1836)

1. Create `ClassType` in allocator, assign to node's `inferred_type`
2. Look up `base_class` in `self.class_types` map — error if not found
3. Look up each interface in `self.interface_types` map — error if not found
4. Copy base class fields, then append own fields (with type checking)
5. Copy base class methods, then overlay own methods (override detection via name match; `defining_class_name` is updated to the subclass name)
6. Register in `self.class_types` map for recursive resolution

### 5.2 Interface Type Construction (typecheck.zig:1838-1864)

1. Create `InterfaceType` in allocator
2. Look up each `super_interface` in `self.interface_types` map
3. Type-check each method and store in method list
4. Register in `self.interface_types` map

### 5.3 Field Access (typecheck.zig:1942-1955)

```zig
} else if (obj_type.kind == .Class and obj_type.class_type != null) {
    const ct = obj_type.class_type.?;
    for (ct.fields) |cf| {
        if (std.mem.eql(u8, cf.name, m.property)) {
            node.inferred_type = cf.type_kind;
            break;
        }
    }
}
```

Fields include inherited fields (copied from base class during type construction).

### 5.4 Method Call — Static Dispatch

For `rec_type.kind == .Class`: method is resolved on `ct.methods` list (includes inherited/overridden methods). `m.is_dynamic` is set to `true`.

```zig
// typecheck.zig:2004-2027
} else if (rec_type.kind == .Class and rec_type.class_type != null) {
    m.is_dynamic = true;
    // Look up method by name in ct.methods
}
```

### 5.5 Method Call — Dynamic Dispatch (Interface / Any)

```zig
// typecheck.zig:2028-2033
} else if (rec_type.kind == .Any or rec_type.kind == .Interface) {
    m.is_dynamic = true;
    // Warn for Any dispatch; allowed in Mantiq mode
}
```

---

## 6. Code Generation

### 6.1 LLVM Type Layout (codegen.zig:1270-1334)

Class instances are heap-allocated structs with a vtable pointer at index 0:

```llvm
%Shape = type { ptr, i32, i32 }   ; { vtable_ptr, x, y }
%Circle = type { ptr, i32, i32, f64 }  ; { vtable_ptr, x, y, radius }
```

- Field index = inherited field count + position in own fields, plus 1 (skip vtable)
- Codegen traverses class hierarchy via `class_stack` (walking `base_class` pointers)

### 6.2 VTable Generation (codegen.zig:1293-1299)

```llvm
@__vtable_Shape = global [1 x ptr] [ptr @Shape_area]
@__vtable_Circle = global [2 x ptr] [ptr @Circle_area, ptr @Circle_getRadius]
```

Only the class's own methods (including overrides) are in the vtable. The `defining_class_name` field on `StructMethod` determines which concrete function pointer goes into the vtable.

### 6.3 Destructor Generation (codegen.zig:1306-1333)

Each class gets a `__del__` function that recursively destroys fields with destructors:

```llvm
define void @Circle___del__(ptr %self) {
entry:
  %t.0 = getelementptr inbounds %Circle, ptr %self, i32 0, i32 3
  %t.1 = load f64, ptr %t.0
  ret void
}
```

Fields of class type are freed via `mantiq_free` and their `__del__` called recursively.

### 6.4 Virtual Method Call (codegen.zig:4435-4479)

```llvm
; Load vtable pointer from object[0]
%vt = getelementptr inbounds %Circle, ptr %obj, i32 0, i32 0
%vp = load ptr, ptr %vt
; Index into vtable for method at position idx
%fp_ptr = getelementptr inbounds ptr, ptr %vp, i32 0  ; idx
%fp = load ptr, ptr %fp_ptr
; Call through function pointer
call void %fp(ptr %obj, ...)
```

### 6.5 Interface Dispatch

Interfaces are compiled to a fat pointer `{ptr to object, ptr to vtable}`. The codegen for `Interface` type kind is handled via `typeToLLVM` producing the `{ptr, ptr}` representation. Interface method dispatch loads the vtable from the fat pointer and indexes into it.

`codegen.zig:1335` — InterfaceDecl codegen is currently a no-op (empty block); only the vtable/type metadata is relevant for dispatch.

### 6.6 Interlude Generation (codegen.zig:3614-3627)

When a class constructor returns a new instance, the vtable pointer is stored at index 0:

```llvm
%vt_ptr = getelementptr inbounds %Shape, ptr %alloc, i32 0, i32 0
store ptr @__vtable_Shape, ptr %vt_ptr
```

---

## 7. Pipeline Position

```
Source → Parse → Lower → Sema → Typecheck → CFG → DCE → Codegen → JIT/AOT
                                      ↑
                            ClassType / InterfaceType
                            construction and method resolution
```

| Pass | ClassDecl | InterfaceDecl |
|------|-----------|---------------|
| `sema.zig` | Declare symbol as `.Class` (`line 272`); resolve methods (`line 573`) | Declare as `.Interface` (`line 275`); resolve methods (`line 582`) |
| `typecheck.zig` | Build `ClassType` with fields, methods, inheritance, override detection (`line 1764`) | Build `InterfaceType` with methods, super-interface links (`line 1838`) |
| `codegen.zig` | Emit LLVM struct type, vtable global, `__del__`, method functions (`line 1270`) | No-op (`line 1335`) |
| `dce.zig` | Unimplemented | Unimplemented |
| `cfg.zig` | Unimplemented | Unimplemented |
| `borrowck.zig` | Unimplemented | Unimplemented |

---

## 8. Inheritance

### 8.1 Single Inheritance

```nizam
class Animal:
    name as str
    fn speak(self) as str: return "..."

class Dog(Animal):
    @override
    fn speak(self) as str: return "Woof!"
```

- Fields from `Animal` are copied into `Dog`'s field list during type checking
- Methods from `Animal` are copied; overridden methods get `defining_class_name = "Dog"`
- Vtable for `Dog` includes both inherited and new methods

### 8.2 Override Detection

```zig
// typecheck.zig:1819-1834
var overridden = false;
for (methods.items) |*existing| {
    if (std.mem.eql(u8, existing.name, md.name)) {
        existing.type_kind = method.inferred_type.?;
        existing.defining_class_name = c.name;
        overridden = true;
        break;
    }
}
```

The `@override` decorator is parsed in the grammar but not semantically enforced.

### 8.3 No Multiple Inheritance

Classes support only single base class. Multiple interface implementation is supported.

---

## 9. Interfaces

### 9.1 Definition and Implementation

```nizam
interface Drawable:
    fn draw(self)
    fn get_area(self) as f64

class Circle(Shape, Drawable):
    radius as f64
    fn draw(self): ...
    fn get_area(self) as f64: return 3.14159 * self.radius * self.radius
```

### 9.2 Interface Extension

Interface extension via `super_interfaces` is defined in the AST type (`ast.zig:182`) but the grammar does not currently parse a super-interface list. The field is initialized to an empty slice (`lower.zig:1780`).

### 9.3 Duck Typing (Mantiq Mode)

When a method is called on a value of type `.Interface` or `.Any`, dispatch is marked as `is_dynamic = true` and the return type is inferred as `.Any`. At runtime, the vtable lookup will fail gracefully if the object does not implement the expected method.

---

## 10. Generics

Classes and interfaces support generic type parameters:

```js
// grammar.js — class_decl includes optional($.generic_params)
```

```nizam
class Box[T]:
    value as T
    fn get(self) as T: return self.value
    fn set(self, val as T): self.value = val

interface Container[T]:
    fn add(self, item as T)
    fn get(self, idx as i32) as T
```

Generic parameters are parsed but monomorphization is handled at the typechecker level (type unification and substitution).

---

## 11. Memory Model

### 11.1 Heap Allocation

Class instances are always heap-allocated. The `self` parameter in methods is a pointer to the heap object. Copying a class variable copies the **pointer**, not the data (move semantics).

### 11.2 Ownership

| Type | Copy | Move | Destructor |
|------|------|------|------------|
| `Class` | No | Yes | `__del__` auto-generated |
| `Interface` | Yes (fat ptr) | Yes | None |

```zig
// types.zig:403 — isCopyType
.Class, .Interface => return false,  // Class is move-only
```

```zig
// types.zig:441 — isMoveType
.Class => return true,
```

### 11.3 `__del__` Generation

Every class gets a synthesized destructor that:
1. Walks all fields (inherited + own)
2. For class-typed fields: calls `__del__` recursively, then `mantiq_free`
3. For heap-allocated fields (String, etc.): calls `mantiq_free`

---

## 12. Nizam Mode Restriction

In Nizam (strict) mode, `class` declarations are rejected during lowering:

```zig
// lower.zig — enforcement (specific line varies by version)
if (self.mode == .Nizam and node_type == .ClassDecl) {
    return error.InvalidSyntax;  // "classes not allowed in Nizam mode"
}
```

Use `struct` with explicit interfaces instead.

---

## 13. Examples

### Basic Class

```nizam
class Counter:
    count as i32

    fn new() as Counter:
        let c as Counter
        c.count = 0
        return c

    fn increment(self):
        self.count += 1

    fn get(self) as i32:
        return self.count
```

### Inheritance

```nizam
class Animal:
    name as str
    fn speak(self) as str: return "..."

class Dog(Animal):
    @override
    fn speak(self) as str: return "Woof!"
```

### Interface Implementation

```nizam
interface Comparable[T]:
    fn less_than(self, other as T) as bool
    fn equals(self, other as T) as bool

class Point(Comparable[Point]):
    x as i32
    y as i32

    fn less_than(self, other as Point) as bool:
        return self.x < other.x or (self.x == other.x and self.y < other.y)

    fn equals(self, other as Point) as bool:
        return self.x == other.x and self.y == other.y
```

### Generic Class

```nizam
class Wrapper[T]:
    value as T
    fn get(self) as T: return self.value
```

---

## 14. Limitations

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| No multiple inheritance | Only single base class | Use interfaces for multiple subtyping |
| Interface extension not parsed | `super_interfaces` always empty | Parse parent interface list in grammar |
| No interface conformance check | Interface implementation not verified | Add `checkImplements(iface, class)` pass |
| No `@override` enforcement | Decorator parsed but not validated | Typechecker override signature check |
| No constructor syntax | `new()` is a convention, not language | Add `__init__` / `new` protocol |
| No access control enforcement | `public`/`private` parsed but not checked | Add visibility checks in typechecker |
| Interface codegen no-op | No vtable dispatch for interface calls | Implement fat-pointer dispatch in codegen |
| No `Abstract` enforcement | Abstract methods not declared | Add `abstract` keyword |
| No generics monomorphization cache | Redundant type instantiation | Add generic instantiation cache |
| Borrowck skips classes | No ownership analysis for class fields | Extend borrowck for class types |

---

## 15. Relevant Files

| File | Lines | Role |
|------|-------|------|
| `grammar.js` | 50-51, 82-101 | `class_decl` and `interface_decl` grammar |
| `ast.zig` | 68, 71, 160-166, 180-191 | `ClassDecl`, `InterfaceDecl`, `FieldDecl` AST |
| `types.zig` | 52, 70-96, 128-129, 338-339, 403, 441 | `ClassType`, `InterfaceType`, copy/move classification |
| `layout.zig` | 51, 108, 123, 203 | Class/Interface size and alignment |
| `lower.zig` | 193, 271, 275, 1279-1397, 1745-1786 | CST→AST lowering |
| `sema.zig` | 272-276, 432-433, 573-588 | Symbol registration and method resolution |
| `typecheck.zig` | 74, 87, 283, 287, 1210, 1764-1864, 1942-2033 | Type construction, field/method lookup |
| `codegen.zig` | 484-485, 652, 1270-1335, 3614-3627, 4410-4479 | LLVM type, vtable, method dispatch |
| `abi.zig` | — | Class passed as pointer (byval) |
