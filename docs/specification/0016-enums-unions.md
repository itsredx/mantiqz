# Language Specification: Enums and Unions

## Overview

Enums and unions are user-defined algebraic data types. **Enums** provide discriminated tagged unions with named variants (optionally carrying payloads). **Unions** provide C-style overlapping storage, either plain (with `unsafe` access) or tagged (paired with an enum discriminator for safe access).

---

## 1. Enums

### 1.1 Declaration

```nizam
enum Color:
    Red
    Green
    Blue

enum Option[T]:
    Some(T)
    Empty

enum Status:
    Ok = 0
    Error = 1
```

**Grammar**:

```js
enum_decl: $ => prec(10, seq(
    'enum', $.identifier, optional($.generic_params), ':', $.enum_body
))

enum_variant: $ => seq(
    $.identifier,
    optional(seq('(', optional($.typed_params), ')')),
    optional($.type_annotation),
    optional(seq('=', $.expression)),
    optional(','), $._newline
)
```

### 1.2 AST

```zig
// ast.zig:192-201
EnumDecl: struct {
    name: []const u8,
    generic_params: ?[][]const u8 = null,
    variants: []*Node,
},
EnumVariant: struct {
    name: []const u8,
    value: ?*Node,                    // explicit discriminant
    payload_types: ?[]TypeAnnotation,  // optional payload type list
},
```

### 1.3 Type Representation

```zig
// types.zig:110-119
EnumVariantType: struct {
    name: []const u8,
    value: ?u32,                    // discriminant value
    payload_types: ?[]const Type,
},
EnumType: struct {
    name: []const u8,
    variants: []EnumVariantType,
},
```

### 1.4 Discriminants

Discriminants are assigned automatically starting from 0, incrementing by 1 per variant. Explicit values can be set with `= N`:

```zig
// typecheck.zig — discriminant assignment
var implicit_val: u32 = 0;
for (e.variants) |variant| {
    var actual_val = implicit_val;
    if (v_data.value) |val_node| {
        actual_val = @intFromFloat(val_node.data.NumberLiteral.value);
    }
    // store actual_val, then:
    implicit_val = actual_val + 1;
}
```

| Variant | Auto Value | Explicit |
|---------|-----------|----------|
| `Red` | 0 | — |
| `Green` | 1 | — |
| `Blue` | 2 | — |
| `Ok` | 0 | 0 |
| `Error` | 1 | — (auto = 1 after explicit 0) |

### 1.5 LLVM Type

**Decision**: Fixed-size `{ i32, [4 x i64] }` — 40 bytes.

```llvm
%Color = type { i32, [4 x i64] }     ; 4 + 32 = 36 → 40 with padding
```

| Field | Type | Size | Purpose |
|-------|------|------|---------|
| `.0` | `i32` | 4 | Tag/discriminant |
| `.1` | `[4 x i64]` | 32 | Inline payload storage |

**Codegen** (`codegen.zig:1378-1383`):

```zig
.EnumDecl => {
    const et = node.inferred_type.?.enum_type.?;
    try self.type_out.writer().print("%{s} = type {{ i32, [4 x i64] }}\n\n", .{et.name});
},
```

### 1.6 Construction

**Payload-less variant** — insert the tag value:

```llvm
; let c = Color.Green  (Green = 1)
%t.1 = insertvalue %Color zeroinitializer, i32 1, 0
```

When accessed as `EnumType.VariantName`, the MemberExpr returns the variant value. If it has no payload, the inferred type is the enum type itself. If it has a payload, the inferred type is a `Function` that takes the payload types and returns the enum type:

```zig
// typecheck.zig:1857-1881
if (ev.payload_types) |pts| {
    node.inferred_type = .{ .kind = .Function, .function = func_type };
} else {
    node.inferred_type = obj_type;  // the enum type itself
}
```

**Payload-bearing variant** — insert tag + store payload into array field:

```llvm
; let opt = Option.Some(42)
%t.1 = insertvalue %Option zeroinitializer, i32 0, 0    ; tag = 0
%t.2 = alloca %Option
store %Option %t.1, ptr %t.2
%t.3 = getelementptr %Option, ptr %t.2, i32 0, i32 1     ; payload ptr
store i32 42, ptr %t.3
%t.4 = load %Option, ptr %t.2
```

### 1.7 Copy/Move Classification

**Decision**: Enum is Copy if all payload types across all variants are Copy.

```zig
// types.zig:247-258
.Enum => {
    if (t.enum_type) |et| {
        for (et.variants) |variant| {
            if (variant.payload_types) |payloads| {
                for (payloads) |pt| {
                    if (!isCopyType(pt)) return false;
                }
            }
        }
    }
    return true;
},
```

### 1.8 ABI

Enum is listed alongside primitives in `getArgABI`/`getRetABI`, returning **Direct** mode. The LLVM type `{ i32, [4 x i64] }` is passed directly.

### 1.9 Methods

Enums can have methods:

```nizam
enum Shape:
    Circle(radius as f32)
    Rectangle(w as f32, h as f32)
    Point

    fn area(ref self) as f32:
        match self:
            case Circle(r): return 3.14 * r * r
            case Rectangle(w, h): return w * h
            case Point: return 0.0
```

### 1.10 Printing

Enum values are printed as their tag integer:

```llvm
%tag = extractvalue %Color %val, 0
call void @mantiq_print_i32(i32 %tag)
```

---

## 2. Plain Unions

### 2.1 Declaration

```nizam
union Value:
    var i as i32
    var f as f32
```

**Grammar**:

```js
union_decl: $ => seq(
    'union',
    field('name', $.identifier),
    optional(field('generic_params', $.generic_params)),
    ':', field('body', $.block_body)
)
```

Note: No `tag_type` — this distinguishes plain unions from tagged unions.

### 2.2 AST

```zig
// ast.zig:173-179
UnionDecl: struct {
    name: []const u8,
    tag_type: ?TypeAnnotation = null,   // null = plain union
    generic_params: ?[][]const u8 = null,
    fields: []*Node,
    methods: []*Node,
},
```

### 2.3 Type Representation

```zig
// types.zig:103-108
UnionType: struct {
    name: []const u8,
    fields: []StructField,
    methods: []StructMethod = &[_]StructMethod{},
    tag_type: ?Type = null,     // null = plain union
},
```

### 2.4 LLVM Type

**Decision**: Opaque byte array `{ [N x i8] }`.

```llvm
%Value = type { [4 x i8] }     ; max(i32=4, f32=4, bool=1) = 4 bytes
```

Size = maximum field size padded to alignment. The type is opaque — LLVM sees only a byte array.

### 2.5 Construction

Unions are constructed with a keyword argument specifying the active field:

```nizam
let v as Value = Value(f=3.14)
```

This stores the value directly into the union's byte array:

```zig
// codegen.zig:3659-3699
// For plain union: store the value directly
try writer.print("  store {s} {s}, ptr {s}\n", .{ arg_t, arg_val, alloca_name });
```

### 2.6 Field Access — `unsafe` Required

**Decision**: Plain union field access requires an `unsafe` block.

```zig
// typecheck.zig:1896-1900
if (ut.tag_type == null and !self.in_unsafe_block) {
    std.debug.print("Safety Error: Accessing union field '{s}' is unsafe...\n", .{m.property});
    return error.TypeMismatch;
}
```

Usage:

```nizam
unsafe:
    let i_val as i32 = v.i
```

Codegen: bitcast the union pointer to the field type and load:

```llvm
%t.1 = alloca %Value
store %Value %v, ptr %t.1
%t.2 = bitcast ptr %t.1 to ptr
%t.3 = load i32, ptr %t.2
```

### 2.7 Layout

```zig
// layout.zig:154-180
.Union => {
    if (t.union_type) |ut| {
        var max_size: usize = 0;
        for (ut.fields) |f| {
            const field_size = getSize(f.type_kind, target);
            if (field_size > max_size) max_size = field_size;
        }
        var max_align: usize = 1;
        for (ut.fields) |f| {
            const field_align = getAlign(f.type_kind, target);
            if (field_align > max_align) max_align = field_align;
        }
        const padding = (max_align - (max_size % max_align)) % max_align;
        return max_size + padding;        // plain union
    }
},
```

---

## 3. Tagged Unions

### 3.1 Declaration

```nizam
enum NodeKind:
    Var
    Func
    Block

union(NodeKind) NodeData:
    var var_decl as i32
    var fun_decl as i32
    var block_stmt as i32
```

**Grammar**: Same as plain union with optional `tag_type`:

```js
union_decl: $ => seq(
    'union',
    optional(seq('(', field('tag_type', $._type_desc), ')')),
    field('name', $.identifier),
    ...
)
```

### 3.2 Validation

The tag type must be an enum. The number of enum variants must match the number of union fields 1-to-1:

```zig
// typecheck.zig — after fields + tag type processed
if (et.variants.len != ut.fields.len) {
    std.debug.print("Type Error: Tagged union '{s}' has {d} fields but tag enum '{s}' has {d} variants.\n", ...);
    return error.TypeMismatch;
}
```

### 3.3 LLVM Type

**Decision**: `{ tag_type, [N x i8] }`.

```llvm
%NodeData = type { i32, [4 x i8] }    ; i32 tag + 4-byte payload
```

| Field | Type | Size | Contents |
|-------|------|------|----------|
| `.0` | `i32` (tag enum) | 4 | Discriminator identifying active field |
| `.1` | `[N x i8]` | N | Payload for the active field |

```zig
// codegen.zig:679-708
if (ut.tag_type) |tag_t| {
    // ... compute max_size, max_align, payload_size ...
    const tag_t_llvm = typeToLLVM(self.allocator, tag_t);
    try self.type_out.writer().print("%{s} = type {{ {s}, [{d} x i8] }}\n\n",
        .{ ut.name, tag_t_llvm, payload_size });
}
```

### 3.4 Construction

Tagged unions store both the tag value and the field data:

```llvm
; let u = NodeData(fun_decl=42)
; tag = 1 (index of fun_decl in the fields list)
%tag_val = insertvalue i32 zeroinitializer, i32 1, 0
%tag_ptr = getelementptr %NodeData, ptr %alloca, i32 0, i32 0
store i32 %tag_val, ptr %tag_ptr

%payload_ptr = getelementptr %NodeData, ptr %alloca, i32 0, i32 1
store i32 42, ptr %payload_ptr
```

### 3.5 Field Access (Safe)

Unlike plain unions, tagged union fields can be accessed **without** `unsafe`:

```zig
// typecheck.zig — safe if tag_type != null
if (ut.tag_type == null and !self.in_unsafe_block) {
    return error.TypeMismatch;  // only plain unions need unsafe
}
```

Codegen: GEP to element 1 (payload), load the field value:

```llvm
%payload_ptr = getelementptr %NodeData, ptr %alloca, i32 0, i32 1
%f_val = load i32, ptr %payload_ptr
```

### 3.6 Tag Access

The `.tag` property reads the discriminator:

```nizam
let tag_val as NodeKind = u.tag
```

```zig
// typecheck.zig:1901-1904
if (ut.tag_type != null and (std.mem.eql(u8, m.property, "tag") or ...)) {
    node.inferred_type = ut.tag_type.?;
}
```

Codegen: GEP to element 0, load the tag.

### 3.7 Layout

Tagged union size = tag + padding + max field size, aligned to `max(tag_align, field_align)`:

```zig
// layout.zig:154-180
if (ut.tag_type) |tag_t| {
    const tag_size = getSize(tag_t, target);
    const tag_align = getAlign(tag_t, target);
    const tag_padding = (max_align - (tag_size % max_align)) % max_align;
    const union_align = @max(tag_align, max_align);
    const raw_size = tag_size + tag_padding + payload_size;
    const final_padding = (union_align - (raw_size % union_align)) % union_align;
    return raw_size + final_padding;
}
```

---

## 4. Size / Alignment / ABI Summary

| Construct | Size | Align | LLVM Type | ABI |
|-----------|------|-------|-----------|-----|
| Enum (no payload) | 40 | 8 | `{ i32, [4 x i64] }` | Direct |
| Enum (with payload) | 40 | 8 | `{ i32, [4 x i64] }` | Direct |
| Plain union | max field (padded) | max field align | `{ [N x i8] }` | Size-based |
| Tagged union | tag + pad + payload | max(tag_align, field_align) | `{ tag_type, [N x i8] }` | Size-based |

---

## 5. Copy/Move Classification

| Type | Copy Rule |
|------|-----------|
| Enum | Copy iff all payload types across all variants are Copy |
| Plain union | Copy iff all field types are Copy |
| Tagged union | Copy iff all field types are Copy |

---

## 6. Methods

Unions can have methods, with the same name mangling scheme as structs (`UnionName_methodName`):

```zig
// sema.zig:595-600
method.data.FunDecl.name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{u.name, original_name});
```

Enum methods use the enum name in mangling. Method calls on enums dispatch via match internally.

---

## 7. Examples

### Simple Enum

```nizam
enum Color:
    Red
    Green
    Blue

let c as Color = Color.Green
```

### Enum with Payload

```nizam
enum Option:
    Some(i32)
    Empty

let opt as Option = Option.Some(42)
let nothing as Option = Option.Empty
```

### Enum with Explicit Discriminants

```nizam
enum Status:
    Ok = 0
    Error = 1
    Unknown = 255
```

### Plain Union

```nizam
union Value:
    var i as i32
    var f as f32

let v as Value = Value(f=3.14)
unsafe:
    let bits as i32 = v.i      // read f32 bits as i32
```

### Tagged Union

```nizam
enum Type:
    Int
    Float

union(Type) Data:
    var int_val as i32
    var float_val as f32

let d as Data = Data(float_val=2.72)
let tag as Type = d.tag         // reads discriminator
let val as f32 = d.float_val    // safe: no unsafe needed
```

### Enum with Methods

```nizam
enum Shape:
    Circle(radius as f32)
    Rect(w as f32, h as f32)

    fn area(ref self) as f32:
        match self:
            case Circle(r): return 3.14159 * r * r
            case Rect(w, h): return w * h
```

---

## 8. Relevant Files

| File | Role |
|------|------|
| `grammar.js:113-132` | Enum and union CST grammar |
| `grammar.js:306-324` | Enum body and variant grammar |
| `ast.zig:173-201` | `UnionDecl`, `EnumDecl`, `EnumVariant` AST nodes |
| `lower.zig:1420-1599` | CST→AST lowering for enums and unions |
| `types.zig:103-119` | `UnionType`, `EnumVariantType`, `EnumType` structs |
| `types.zig:247-282` | Copy type classification for enum/union |
| `layout.zig:37,71-99` | Alignment for enum (8) and union |
| `layout.zig:109,154-180` | Size for enum (40) and union |
| `typecheck.zig:1568-1750` | Enum/union type checking |
| `typecheck.zig:1857-1917` | MemberExpr for constructors and field access |
| `codegen.zig:710-715` | Enum LLVM type emission `{ i32, [4 x i64] }` |
| `codegen.zig:679-708` | Union LLVM type emission |
| `codegen.zig:1350-1386` | Union/Enum declaration codegen |
| `codegen.zig:3120-3148` | Enum variant constructor codegen |
| `codegen.zig:3659-3699` | Union construction codegen |
| `codegen.zig:4283-4408` | Field access codegen |
| `sema.zig:264-268` | Symbol declaration for enum/union |
| `abi.zig:26-28` | Enum as Direct ABI |
