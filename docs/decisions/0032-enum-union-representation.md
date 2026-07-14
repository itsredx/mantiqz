# Decision 0032: Enum and Union Representation

## Context

Mantiq/Nizam supports three algebraic data constructs:

1. **Enums** — tagged unions with named variants, optionally carrying payload types (like Rust enums)
2. **Plain unions** — C-style unions where all fields share the same storage, access requires `unsafe`
3. **Tagged unions** — a union paired with an enum tag discriminator, providing safe field access

The representation must balance C-compatible layout (for FFI) with safe discriminated access.

---

## Language Specification

### Enum

#### Grammar

```js
enum_decl: $ => prec(10, seq(
    'enum', $.identifier, optional($.generic_params), ':', $.enum_body
))

enum_variant: $ => seq(
    $.identifier,
    optional(seq('(', optional($.typed_params), ')')),  // payload types
    optional($.type_annotation),                         // value annotation
    optional(seq('=', $.expression)),                    // explicit discriminant
    optional(','), $._newline
)
```

#### Syntax

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

enum Shape:
    Circle(radius as f32)
    Rectangle(w as f32, h as f32)
    Point
```

#### AST

```zig
// ast.zig:192-201
EnumDecl: struct {
    name: []const u8,
    generic_params: ?[][]const u8 = null,
    variants: []*Node,
},
EnumVariant: struct {
    name: []const u8,
    value: ?*Node,                    // explicit discriminant expression (or auto)
    payload_types: ?[]TypeAnnotation,  // optional payload type list
},
```

#### Type Representation

```zig
// types.zig:110-119
EnumVariantType: struct {
    name: []const u8,
    value: ?u32,                    // discriminant value (auto-incremented or explicit)
    payload_types: ?[]const Type,
},
EnumType: struct {
    name: []const u8,
    variants: []EnumVariantType,
},
```

#### LLVM Type

**Decision: Fixed-size `{ i32, [4 x i64] }` layout.**

```llvm
%Color = type { i32, [4 x i64] }     ; 4 + 32 = 36 bytes → 40 with padding
```

| Field | Type | Size | Purpose |
|-------|------|------|---------|
| `.0`  | `i32` | 4 | Tag/discriminant value |
| `.1`  | `[4 x i64]` | 32 | Inline payload storage (max 32 bytes) |

The payload array provides 32 bytes of storage — enough for most payload types (two `i128`s, four `i64`s, eight `i32`s, etc.). If the payload exceeds 32 bytes, the generated LLVM IR would be incorrect (this is a current limitation).

#### Discriminant Values

Discriminants are assigned automatically starting from 0, incrementing by 1 per variant. Explicit values can be set with `= N`:

| Variant | Auto Value | Explicit |
|---------|-----------|----------|
| `Red` | 0 | — |
| `Green` | 1 | — |
| `Blue` | 2 | — |
| `Ok` | 0 | 0 |
| `Error` | 1 | 1 |

```zig
// typecheck.zig — discriminant assignment
var implicit_val: u32 = 0;
for (e.variants) |variant| {
    var actual_val = implicit_val;
    if (v_data.value) |val_node| {
        actual_val = @intFromFloat(val_node.data.NumberLiteral.value);
    }
    // store actual_val in variant
    implicit_val = actual_val + 1;
}
```

#### Variant Construction

**Payload-less variant**: Constructed by inserting the tag value:

```llvm
; let c = Color.Green  (Green = 1)
%t.1 = insertvalue %Color zeroinitializer, i32 1, 0
```

**Payload-bearing variant**: Insert the tag, then store the payload into the array field:

```llvm
; let opt = Option.Some(42)
%t.1 = insertvalue %Option zeroinitializer, i32 0, 0    ; tag = 0 (Some)
%t.2 = alloca %Option
store %Option %t.1, ptr %t.2
%t.3 = getelementptr %Option, ptr %t.2, i32 0, i32 1     ; &payload
store i32 42, ptr %t.3
%t.4 = load %Option, ptr %t.2
```

When a payload-less variant is used in an expression that expects a function type (e.g. `Option.Some` which has a payload), the MemberExpr returns the discriminant as a string tag value. The subsequent CallExpr uses that tag to construct the full enum value.

#### Copy/Move Classification

**Decision: Enum is Copy if all payload types are Copy.**

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

#### ABI

**Decision: Enum is always Direct (passed/returned in registers).**

Enum is listed alongside primitives in `getArgABI` and `getRetABI`, returning `Direct` mode. The LLVM type `{ i32, [4 x i64] }` is passed directly in registers if ≤ 2 × 64-bit (two integer class items), otherwise LLVM handles it.

---

### Plain Union

#### Grammar

```js
union_decl: $ => seq(
    'union',
    field('name', $.identifier),
    optional(field('generic_params', $.generic_params)),
    ':', field('body', $.block_body)
)
```

Note: No `tag_type` — this distinguishes plain unions from tagged unions.

#### Syntax

```nizam
union Value:
    var i as i32
    var f as f32
    var b as bool
```

#### AST

```zig
// ast.zig:173-179
UnionDecl: struct {
    name: []const u8,
    tag_type: ?TypeAnnotation = null,    // null = plain union
    generic_params: ?[][]const u8 = null,
    fields: []*Node,
    methods: []*Node,
},
```

#### Type Representation

```zig
// types.zig:103-108
UnionType: struct {
    name: []const u8,
    fields: []StructField,
    methods: []StructMethod,
    tag_type: ?Type = null,     // null = plain union
},
```

#### LLVM Type

**Decision: Opaque byte array `{ [N x i8] }`.**

```llvm
%Value = type { [4 x i8] }     ; max(i32=4, f32=4, bool=1) = 4 bytes
```

The size is the maximum field size, padded to alignment. The type is opaque — LLVM sees only a byte array. Field access is done via `bitcast` to the target type's pointer:

```llvm
; Accessing v.i (i32 field)
%t.1 = alloca %Value
store %Value %v, ptr %t.1
%t.2 = bitcast ptr %t.1 to ptr
%t.3 = load i32, ptr %t.2
```

#### Safety

**Decision: Plain union field access requires `unsafe`.**

```zig
// typecheck.zig:1896-1900
if (ut.tag_type == null and !self.in_unsafe_block) {
    std.debug.print("Safety Error: Accessing union field '{s}' is unsafe ...\n", .{m.property});
    return error.TypeMismatch;
}
```

This prevents reading the wrong field from a union without explicit acknowledgement.

#### Construction

Unions are constructed with a keyword argument specifying the active field:

```nizam
let v as Value = Value(f=3.14)
```

This generates a store of the value directly into the union's byte array storage.

---

### Tagged Union

#### Grammar

```js
union_decl: $ => seq(
    'union',
    optional(seq('(', field('tag_type', $._type_desc), ')')),  // optional tag type
    field('name', $.identifier),
    ...
)
```

#### Syntax

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

The tag type must be an enum. The number of enum variants **must match** the number of union fields 1-to-1.

#### LLVM Type

**Decision: `{ tag_type, [N x i8] }`.**

```llvm
%NodeData = type { i32, [4 x i8] }    ; i32 tag + 4-byte payload
```

| Field | Type | Size | Contents |
|-------|------|------|----------|
| `.0`  | `i32` (or tag enum type) | 4 | Tag value identifying active field |
| `.1`  | `[N x i8]` | N | Payload storage for the active field |

#### Field Access (Safe)

Unlike plain unions, tagged union fields can be accessed **without** `unsafe`:

```zig
// typecheck.zig:1896-1917
if (ut.tag_type == null and !self.in_unsafe_block) {
    return error.TypeMismatch;  // only plain unions need unsafe
}
// Access `.tag` or `.active_tag` property to read the discriminator
if (ut.tag_type != null and (std.mem.eql(u8, m.property, "tag") or ...)) {
    node.inferred_type = ut.tag_type.?;
}
```

Field access on a tagged union:

```llvm
; Reading u.fun_decl (i32) from NodeData tagged union
%t.1 = alloca %NodeData
store %NodeData %u, ptr %t.1
%t.2 = getelementptr %NodeData, ptr %t.1, i32 0, i32 1    ; payload ptr
%t.3 = load i32, ptr %t.2
```

#### Tag Access

The `.tag` property reads the discriminator:

```nizam
let tag_val as NodeKind = u.tag
```

GEP to element 0 of the tagged union struct, load the tag value.

#### 1-to-1 Validation

```zig
// typecheck.zig — after processing fields and tag type
if (et.variants.len != ut.fields.len) {
    std.debug.print("Type Error: Tagged union '{s}' has {d} fields but tag enum '{s}' has {d} variants.\n", ...);
    return error.TypeMismatch;
}
```

---

## Size and Alignment Summary

| Construct | Size | Align | LLVM Type |
|-----------|------|-------|-----------|
| Enum (no payload) | 40 | 8 | `{ i32, [4 x i64] }` |
| Enum (with payload) | 40 | 8 | `{ i32, [4 x i64] }` |
| Plain union | max field size (padded) | max field align | `{ [N x i8] }` |
| Tagged union | tag + padding + max field size | max(tag_align, field_align) | `{ tag_type, [N x i8] }` |

### Layout Computation

**Tagged union layout** (`layout.zig:154-180`):

```
payload_size = max(field_size) + padding(max_align)
raw_size     = tag_size + tag_padding(max_align) + payload_size
final_size   = raw_size + final_padding(max(tag_align, field_align))
```

**Union alignment** — max of all field alignments, plus tag alignment if tagged.

**Enum alignment** — fixed at 8 (the max of the i32 tag alignment and the [4 x i64] element alignment).

---

## Examples

### Plain Enum

```nizam
enum Color:
    Red
    Green
    Blue

let c = Color.Green
// LLVM: %t.1 = insertvalue %Color zeroinitializer, i32 1, 0
```

### Enum with Payload

```nizam
enum Option:
    Some(i32)
    Empty

let opt = Option.Some(42)
// LLVM: tag = 0 (Some), payload = i32 42
```

### Enum with Explicit Values

```nizam
enum Status:
    Ok = 0
    Error = 1
```

### Plain Union

```nizam
union Value:
    var i as i32
    var f as f32

let v = Value(f=3.14)
unsafe:
    let i_val = v.i    // read the bits as i32
```

### Tagged Union

```nizam
enum NodeKind:
    Var
    Func
    Block

union(NodeKind) NodeData:
    var var_decl as i32
    var fun_decl as i32
    var block_stmt as i32

let u = NodeData(fun_decl=42)
let f_val = u.fun_decl           // safe: no unsafe needed
let tag_val = u.tag              // reads the discriminator
```

---

## Current Limitations

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| Fixed 32-byte payload array | Payload types > 32 bytes produce incorrect IR | Compute payload array size dynamically from max variant size |
| No generic enums | `enum Option[T]` parsed but not typechecked | Add generic parameter substitution in `EnumDecl` |
| Enum is always `i32` tag | Limits to 2³² variants (acceptable) | Allow `u8`/`u16` tags for small enums |
| Tagged union validation only at declaration | Runtime tag mismatch not checked at field access | Add runtime tag check before field access |
| Union `Methods` not tested | Methods on unions are parsed but edge cases unverified | Add test coverage |

---

## Relevant Files

| File | Role |
|------|------|
| `grammar.js:113-132` | Enum and union CST grammar |
| `grammar.js:306-324` | Enum body and variant grammar |
| `ast.zig:173-201` | `UnionDecl`, `EnumDecl`, `EnumVariant` AST nodes |
| `lower.zig:1420-1599` | CST→AST lowering for enums and unions |
| `types.zig:103-119` | `UnionType`, `EnumVariantType`, `EnumType` structs |
| `types.zig:247-282` | Copy type classification for enum/union |
| `layout.zig:37,71-99` | Alignment for enum (8) and union (max field align) |
| `layout.zig:109,154-180` | Size for enum (40) and union (tagged/plain) |
| `typecheck.zig:1568-1750` | Enum/union type checking, tag validation, variant inference |
| `typecheck.zig:1857-1917` | MemberExpr for enum constructors and union field access |
| `codegen.zig:710-715` | Enum LLVM type emission `{ i32, [4 x i64] }` |
| `codegen.zig:679-708` | Union LLVM type emission (`{ [N x i8] }` or `{ tag, [N x i8] }`) |
| `codegen.zig:1350-1386` | Union/Enum declaration codegen |
| `codegen.zig:3120-3148` | Enum variant constructor codegen (payload) |
| `codegen.zig:3659-3699` | Union construction codegen |
| `codegen.zig:4283-4408` | Enum variant and union field access codegen |
| `abi.zig:26-28` | Enum as Direct ABI |
| `main.zig:300-335,596-615` | Test cases for unions, tagged unions, enums |
