# Language Specification: Structs

## Overview

Structs are user-defined aggregate types with named fields and associated methods. They support C-compatible layout, generics (via clone-and-recheck monomorphization), access modifiers, default values, and method dispatch with self-referencing type inference.

---

## 1. Declaration

### 1.1 Grammar

```js
struct_decl: $ => seq(
    repeat($.decorator),
    optional($.access_modifier),
    'struct', $.identifier,
    optional($.generic_params),
    ':', $.block_body
)
```

### 1.2 Syntax

```nizam
struct Vector2:
    var x as f64
    var y as f64
```

Fields are declared with `var name as Type` inside the struct body. Methods are `fn` declarations in the same body.

### 1.3 AST

```zig
// ast.zig:167-172
StructDecl: struct {
    name: []const u8,
    generic_params: ?[][]const u8 = null,
    fields: []*Node,
    methods: []*Node,
},
```

Each field is a `FieldDecl`:

```zig
// ast.zig:185-191
FieldDecl: struct {
    name: []const u8,
    access_modifier: []const u8,    // "public" | "private"
    is_mutable: bool,
    type_annot: TypeAnnotation,
    default_value: ?*Node,
},
```

---

## 2. Type Representation

### 2.1 StructType

```zig
// types.zig:97-101
pub const StructType = struct {
    name: []const u8,
    fields: []StructField,
    methods: []StructMethod = &[_]StructMethod{},
};
```

### 2.2 StructField

```zig
// types.zig:70-76
pub const StructField = struct {
    name: []const u8,
    type_kind: Type,
    access_modifier: []const u8 = "public",
    is_mutable: bool = false,
    default_value: ?*anyopaque = null,
};
```

### 2.3 StructMethod

```zig
// types.zig:78-81
pub const StructMethod = struct {
    name: []const u8,
    type_kind: Type,       // FunctionType representing the method signature
};
```

---

## 3. LLVM Type Emission

**Decision**: Structs emit as LLVM packed struct types with sequential field types.

```zig
// codegen.zig:1336-1349
.StructDecl => |*s| {
    if (s.generic_params != null) return;
    const st = node.inferred_type.?.struct_type.?;
    var fields_str = std.ArrayList(u8).init(self.allocator);
    for (st.fields, 0..) |sf, i| {
        if (i > 0) try fields_str.appendSlice(", ");
        try fields_str.appendSlice(typeToLLVM(self.allocator, sf.type_kind));
    }
    try self.type_out.writer().print("%{s} = type {{ {s} }}\n\n", .{ st.name, fields_str.items });
},
```

Example:

```nizam
struct Point:
    var x as i32
    var y as i32
```

```llvm
%Point = type { i32, i32 }
```

---

## 4. Layout (Size and Alignment)

**Decision**: C-compatible struct layout with padding.

```zig
// layout.zig:138-153
.Struct => {
    if (t.struct_type) |st| {
        var total_size: usize = 0;
        var max_align: usize = 1;
        for (st.fields) |f| {
            const field_align = getAlign(f.type_kind, target);
            const field_size = getSize(f.type_kind, target);
            const padding = (field_align - (total_size % field_align)) % field_align;
            total_size += padding + field_size;
            if (field_align > max_align) max_align = field_align;
        }
        const padding = (max_align - (total_size % max_align)) % max_align;
        return total_size + padding;
    }
    return target.pointer_size;
},
```

Alignment is the maximum field alignment. Fields are placed at offsets that satisfy each field's alignment requirement. Trailing padding rounds the total size to the struct's alignment.

**`getStructFieldOffset`** (`types.zig:371-386`): Computes the byte offset of a named field using the same padding algorithm, used by codegen for GEP generation.

---

## 5. Classification

### 5.1 Copy / Move

**Decision**: Struct is Copy if all field types are Copy; otherwise Move.

```zig
// types.zig — isCopyType
.Struct => {
    if (t.struct_type) |st| {
        for (st.fields) |f| {
            if (!isCopyType(f.type_kind)) return false;
        }
    }
    return true;
},
```

### 5.2 Trivially Copyable

```zig
// types.zig:410-417
.Struct => {
    if (t.struct_type) |st| {
        for (st.fields) |f| {
            if (!isTriviallyCopyable(f.type_kind)) return false;
        }
    }
    return true;
},
```

### 5.3 Destructor

A struct has a destructor if any of its fields has a destructor (e.g., a `String` field triggers auto-drop of the struct).

---

## 6. Generic Structs

**Decision**: Clone-and-recheck monomorphization.

When a struct has `generic_params`, the type checker registers it as a template in `struct_templates` and does not fully type-check it:

```zig
// typecheck.zig:1470-1472
if (s.generic_params != null) {
    try self.struct_templates.put(s.name, node);
    return;
}
```

When a concrete instantiation is encountered (e.g. `List[i32]`), the template is deep-copied, generic parameters are substituted, and the copy is fully type-checked as a new struct type:

```zig
// typecheck.zig:298-455
if (self.struct_templates.get(annot.name)) |tmpl| {
    const cloned = try cloneNode(self.allocator, tmpl, null);
    // substitute generic bindings
    cloned.data.StructDecl.name = mangled_name;
    cloned.data.StructDecl.generic_params = null;
    // re-check the clone
    const prev_in_unsafe = self.in_unsafe_block;
    try self.checkNode(cloned);
    // cache the result
    try self.struct_templates.put(mangled_name, cloned);
}
```

The mangled name includes the concrete types, e.g. `List_i32` for `List[i32]`.

---

## 7. Methods

### 7.1 Declaration

Methods are `fn` declarations inside the struct body. The first parameter is conventionally `ref self` or `self`:

```nizam
struct Vector2:
    var x as f64
    var y as f64

    fn length(ref self) as f64:
        return sqrt(self.x * self.x + self.y * self.y)

    fn scale(ref mut self, factor as f64):
        self.x = self.x * factor
        self.y = self.y * factor
```

### 7.2 Name Mangling

**Decision**: Methods are mangled to `StructName_methodName` in the symbol table.

```zig
// sema.zig:581-583
if (method.node_type == .FunDecl) {
    const original_name = method.data.FunDecl.name;
    method.data.FunDecl.name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{s.name, original_name});
}
```

### 7.3 Self Type Inference

When the first parameter is named `self` without an explicit type annotation, its type is inferred to be the enclosing struct type:

```zig
// typecheck.zig:1513-1514
if (p_i == 0 and std.mem.eql(u8, f.param_names[p_i], "self")) {
    param.inferred_type = node.inferred_type.?;
}
```

### 7.4 Two-Pass Method Processing

Method type checking is done in two passes (`typecheck.zig:1491-1546`):

1. **Pass 1**: Pre-populate method signatures into `st.methods` (for early self-referencing access)
2. **Pass 2**: Type-check field declarations and method bodies (after signatures are known)

---

## 8. Field Access

### 8.1 Read Access

```nizam
let v as Vector2 = Vector2(x=1.0, y=2.0)
let x_val as f64 = v.x
```

**Codegen**: GEP into the struct type:

```llvm
%v_alloca = alloca %Vector2
store %Vector2 %v_val, ptr %v_alloca
%field_ptr = getelementptr inbounds %Vector2, ptr %v_alloca, i32 0, i32 0   ; field 0 = x
%x_val = load f64, ptr %field_ptr
```

### 8.2 Write Access

```nizam
v.x = 3.0
```

Codegen stores to the GEP result directly.

---

## 9. Construction

Structs are constructed with keyword arguments:

```nizam
let v as Vector2 = Vector2(x=1.0, y=2.0)
```

Each field must be provided unless it has a default value. The codegen stores each field into the corresponding GEP offset, then loads the fully constructed struct.

---

## 10. Access Modifiers

```nizam
struct Config:
    public var visible as i32
    private var secret as i32
```

| Modifier | Semantics |
|----------|-----------|
| `public` (default) | Accessible from outside the struct |
| `private` | Only accessible within the struct's methods |

The access modifier is stored in `FieldDecl.access_modifier` and propagated to `StructField.access_modifier`. Enforcement is during type checking (field access crossing module boundaries).

---

## 11. Default Values

Fields can have default values:

```nizam
struct Config:
    var timeout as i32 = 30
    var retries as i32 = 3
```

If a field has a default value, it can be omitted during construction:

```nizam
let cfg as Config = Config(timeout=60)   // retries defaults to 3
```

The default value is stored as `FieldDecl.default_value` (an AST node) and evaluated during codegen when the field is not explicitly provided.

---

## 12. Classification and Auto-Drop

Structs inherit their classification from their fields:

| Struct Fields | Copy/Move | Has Destructor |
|--------------|-----------|----------------|
| All primitives | Copy | No |
| Contains `String`, `List`, etc. | Move | Yes |
| Contains other Move types | Move | If any field has destructor |

Auto-drop at scope exit walks the struct's fields and frees any heap-allocated data (see Decision 0026).

---

## 13. ABI

Structs fall through to the size-based ABI classification in `abi.zig`:

| Size | Mode | LLVM |
|------|------|------|
| ≤ 8 bytes | Coerce → `i64` | Register (rax) |
| ≤ 16 bytes | Coerce → `{ i64, i64 }` | Two registers (rax, rdx) |
| > 16 bytes | ByVal → `ptr byval(T)` | Hidden pointer |

---

## 14. Examples

### Basic Struct

```nizam
struct Point:
    var x as i32
    var y as i32

fn main():
    let p as Point = Point(x=10, y=20)
    print(p.x)
```

### Struct with Methods

```nizam
struct Rectangle:
    var width as f64
    var height as f64

    fn area(ref self) as f64:
        return self.width * self.height

    fn scale(ref mut self, factor as f64):
        self.width = self.width * factor
        self.height = self.height * factor
```

### Generic Struct

```nizam
struct Pair[T]:
    var first as T
    var second as T

    fn swap(ref mut self):
        let tmp as T = self.first
        self.first = self.second
        self.second = tmp

let p as Pair[i32] = Pair[i32](first=1, second=2)
p.swap()
```

### Default Values

```nizam
struct Config:
    var host as str = "localhost"
    var port as i32 = 8080

let cfg as Config = Config()                 // both defaults
let cfg2 as Config = Config(port=9090)       // host defaults to "localhost"
```

---

## 15. Relevant Files

| File | Role |
|------|------|
| `grammar.js:103-111` | `struct_decl` CST grammar |
| `ast.zig:167-172,185-191` | `StructDecl`, `FieldDecl` AST nodes |
| `lower.zig:1384-1463` | CST→AST lowering for structs/fields |
| `types.zig:70-81,97-101` | `StructField`, `StructMethod`, `StructType` |
| `types.zig:371-386` | `getStructFieldOffset` for layout |
| `layout.zig:60-69,138-153` | Struct alignment and size computation |
| `typecheck.zig:1469-1548` | Struct type checking (two-pass) |
| `typecheck.zig:298-455` | Generic struct instantiation |
| `codegen.zig:1336-1349` | Struct LLVM type emission |
| `codegen.zig:642-663` | Type collection for struct declarations |
| `codegen.zig:2493` | StructDecl skipped in statement codegen |
| `sema.zig:261-263` | Struct symbol declaration |
| `sema.zig:573-588` | Struct scope/method name mangling |
| `abi.zig:29-41` | Struct ABI (size-based fallthrough) |
