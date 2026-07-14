//! Type system representation — defines every type the compiler recognises.
//! 
//! The type system sits at the core of semantic analysis. Types are constructed
//! by `typecheck.zig` (via `validateType`) and queried by `codegen.zig` (via
//! `typeToLLVM`), `borrowck.zig` (copy vs move), `layout.zig` (size/align),
//! and `abi.zig` (calling convention).
//! 
//! Key types:
//! - `TypeKind` — 40+ enum variants covering primitives, strings, collections,
//!   quantum, OOP, functions, and raw pointers
//! - `Type` — a fully resolved type with optional payload, tuple_types, function
//!   signature, struct/enum/union/class metadata, closure id, array length, etc.
//! - `FunctionType` — parameter types, names, defaults, variadic/async flags
//! - `StructType` / `EnumType` / `UnionType` / `ClassType` / `InterfaceType` —
//!   user-defined type descriptors
//! - `parseTypeString` — maps aliases (`byte` → `U8`, `str` → `Utf8Str`, etc.)
//! - Classification helpers: `isCopyType`, `isMoveType`, `isTriviallyCopyable`,
//!   `hasDestructor`, `isImplicitlyConvertible`

const std = @import("std");
const layout = @import("layout.zig");

pub const TypeKind = enum {
    Unknown,
    Any,
    Void,
    
    // Signed Integers
    I8, I16, I32, I64, I128, ISize,
    // Unsigned Integers
    U8, U16, U32, U64, U128, USize,
    
    // Floats
    F16, BFloat16, F32, F64, F128,
    
    // Characters & Booleans
    Char, Boolean,
    
    // Strings
    CStr, AsciiStr, Utf8Str, WebStr, RangeStr, String,
    
    // Collections
    Slice, List, Tuple, Dict,
    
    // Context & Control
    Result, Option, Task,
    
    // Quantum
    QBit, QReg,
    
    // OOP / Dynamic
    Closure, Class, Interface, Error, Struct, Enum, Union, Module,
    
    // Functions
    Function,
    
    // Pointers
    RawPointer,
};

pub const FunctionType = struct {
    param_types: []const Type,
    param_names: ?[]const []const u8 = null,
    default_values: ?[]?*anyopaque = null,
    return_type: *Type,
    is_variadic: bool = false,
    is_async: bool = false,
    is_inline: bool = false,
};

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
    defining_class_name: ?[]const u8 = null,
};

pub const InterfaceType = struct {
    name: []const u8,
    super_interfaces: []const *InterfaceType = &[_]*InterfaceType{},
    methods: []StructMethod = &[_]StructMethod{},
};

pub const ClassType = struct {
    name: []const u8,
    base_class: ?*ClassType = null,
    interfaces: []const *InterfaceType = &[_]*InterfaceType{},
    fields: []StructField = &[_]StructField{},
    methods: []StructMethod = &[_]StructMethod{},
};

pub const StructType = struct {
    name: []const u8,
    fields: []StructField,
    methods: []StructMethod = &[_]StructMethod{},
};

pub const UnionType = struct {
    name: []const u8,
    fields: []StructField,
    methods: []StructMethod = &[_]StructMethod{},
    tag_type: ?Type = null,
};

pub const EnumVariantType = struct {
    name: []const u8,
    value: ?u32 = null,
    payload_types: ?[]const Type = null,
};

pub const EnumType = struct {
    name: []const u8,
    variants: []EnumVariantType,
};

pub const Type = struct {
    kind: TypeKind,
    payload: ?*Type = null,
    tuple_types: ?[]const Type = null,
    function: ?*FunctionType = null,
    struct_type: ?*StructType = null,
    class_type: ?*ClassType = null,
    interface_type: ?*InterfaceType = null,
    enum_type: ?*EnumType = null,
    union_type: ?*UnionType = null,
    closure_id: ?u32 = null,
    array_len: ?usize = null,
    module_scope: ?*anyopaque = null,
};

pub fn parseTypeString(type_str: []const u8) TypeKind {
    // Basic types mapping for Mantiq / Nizam
    if (std.mem.eql(u8, type_str, "i8")) return .I8;
    if (std.mem.eql(u8, type_str, "i16")) return .I16;
    if (std.mem.eql(u8, type_str, "i32")) return .I32;
    if (std.mem.eql(u8, type_str, "i64")) return .I64;
    if (std.mem.eql(u8, type_str, "i128")) return .I128;
    if (std.mem.eql(u8, type_str, "isize")) return .ISize;
    
    if (std.mem.eql(u8, type_str, "u8") or std.mem.eql(u8, type_str, "byte")) return .U8;
    if (std.mem.eql(u8, type_str, "u16")) return .U16;
    if (std.mem.eql(u8, type_str, "u32")) return .U32;
    if (std.mem.eql(u8, type_str, "u64")) return .U64;
    if (std.mem.eql(u8, type_str, "u128")) return .U128;
    if (std.mem.eql(u8, type_str, "usize")) return .USize;
    
    if (std.mem.eql(u8, type_str, "f16")) return .F16;
    if (std.mem.eql(u8, type_str, "bf16")) return .BFloat16;
    if (std.mem.eql(u8, type_str, "f32")) return .F32;
    if (std.mem.eql(u8, type_str, "f64")) return .F64;
    if (std.mem.eql(u8, type_str, "f128")) return .F128;
    
    if (std.mem.eql(u8, type_str, "char")) return .Char;
    if (std.mem.eql(u8, type_str, "bool")) return .Boolean;
    
    if (std.mem.eql(u8, type_str, "cstr")) return .CStr;
    if (std.mem.eql(u8, type_str, "asciistr") or std.mem.eql(u8, type_str, "astr") or std.mem.eql(u8, type_str, "AsciiStr")) return .AsciiStr;
    if (std.mem.eql(u8, type_str, "utf8str") or std.mem.eql(u8, type_str, "str") or std.mem.eql(u8, type_str, "u8str") or std.mem.eql(u8, type_str, "ustr") or std.mem.eql(u8, type_str, "Utf8Str")) return .Utf8Str;
    if (std.mem.eql(u8, type_str, "webstr") or std.mem.eql(u8, type_str, "utf16str") or std.mem.eql(u8, type_str, "u16str") or std.mem.eql(u8, type_str, "wstr") or std.mem.eql(u8, type_str, "WebStr")) return .WebStr;
    if (std.mem.eql(u8, type_str, "rangestr") or std.mem.eql(u8, type_str, "rstr") or std.mem.eql(u8, type_str, "utf32str") or std.mem.eql(u8, type_str, "u32str") or std.mem.eql(u8, type_str, "RangeStr")) return .RangeStr;
    if (std.mem.eql(u8, type_str, "String")) return .String;
    
    // Keep exact match for collections right now, parser needs more complex generic handling later
    if (std.mem.startsWith(u8, type_str, "slice")) return .Slice;
    if (std.mem.startsWith(u8, type_str, "List")) return .List;
    if (std.mem.startsWith(u8, type_str, "Dict")) return .Dict;
    if (std.mem.startsWith(u8, type_str, "Result")) return .Result;
    if (std.mem.startsWith(u8, type_str, "Option")) return .Option;
    if (std.mem.startsWith(u8, type_str, "ptr")) return .RawPointer;
    
    if (std.mem.eql(u8, type_str, "qbit")) return .QBit;
    if (std.mem.startsWith(u8, type_str, "qreg")) return .QReg;
    
    if (std.mem.eql(u8, type_str, "Any")) return .Any;
    if (std.mem.eql(u8, type_str, "void")) return .Void;

    return .Unknown;
}

pub fn isImplicitlyConvertible(from: Type, to: Type) bool {
    if (from.kind == to.kind) {
        if (from.kind == .Tuple) {
            if (from.tuple_types != null and to.tuple_types != null) {
                if (from.tuple_types.?.len != to.tuple_types.?.len) return false;
                for (from.tuple_types.?, 0..) |ft, i| {
                    if (!isImplicitlyConvertible(ft, to.tuple_types.?[i])) return false;
                }
                return true;
            }
            return false;
        }
        if (from.kind == .RawPointer) {
            if (from.payload != null and to.payload != null) {
                return isImplicitlyConvertible(from.payload.?.*, to.payload.?.*);
            }
            return (from.payload == null) == (to.payload == null);
        }
        if (from.kind == .Function or from.kind == .Closure) {
            return functionTypesEqual(from, to);
        }
        return true;
    }
    // Allow implicit conversion between Function and Closure types
    if ((from.kind == .Function or from.kind == .Closure) and (to.kind == .Function or to.kind == .Closure)) {
        return functionTypesEqual(from, to);
    }
    if (to.kind == .Any or from.kind == .Any) return true; // Anything can be cast to Any, and Any can cast to anything
    if (from.kind == .Error or to.kind == .Error) return true; // Prevent cascading errors

    // Allow string literals (.String / .AsciiStr) to be assigned to string encodings
    if (from.kind == .String or from.kind == .AsciiStr) {
        return switch (to.kind) {
            .CStr, .AsciiStr, .Utf8Str, .WebStr, .RangeStr, .String => true,
            else => false,
        };
    }

    // Allow implicit conversion between numeric types for literal assignments
    const from_is_num = switch (from.kind) {
        .I8, .I16, .I32, .I64, .I128, .ISize, .U8, .U16, .U32, .U64, .U128, .USize, .F16, .BFloat16, .F32, .F64, .F128 => true,
        else => false,
    };
    const to_is_num = switch (to.kind) {
        .I8, .I16, .I32, .I64, .I128, .ISize, .U8, .U16, .U32, .U64, .U128, .USize, .F16, .BFloat16, .F32, .F64, .F128 => true,
        else => false,
    };
    if (from_is_num and to_is_num) return true;

    // Explicit typing enforced: no implicit widenings or string conversions.

    return false;
}

pub fn isCopyType(t: Type) bool {
    switch (t.kind) {
        .I8, .I16, .I32, .I64, .I128, .ISize,
        .U8, .U16, .U32, .U64, .U128, .USize,
        .F16, .BFloat16, .F32, .F64, .F128,
        .Char, .Boolean, .QBit, .QReg, .RawPointer, .Function, .Closure,
        .CStr, .AsciiStr, .Utf8Str, .WebStr, .RangeStr => return true,
        
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
        .Tuple => {
            if (t.tuple_types) |ttypes| {
                for (ttypes) |tt| {
                    if (!isCopyType(tt)) return false;
                }
            }
            return true;
        },
        .Struct => {
            if (t.struct_type) |st| {
                for (st.methods) |method| {
                    if (std.mem.endsWith(u8, method.name, "___del__")) return false;
                }
                for (st.fields) |field| {
                    if (!isCopyType(field.type_kind)) return false;
                }
            }
            return true;
        },
        .Union => {
            if (t.union_type) |ut| {
                for (ut.fields) |field| {
                    if (!isCopyType(field.type_kind)) return false;
                }
            }
            return true;
        },
        .Option => {
            if (t.payload) |p| {
                return isCopyType(p.*);
            }
            return true;
        },
        .Result => {
            // A Result is generic over T and E (currently hacked as payload)
            // Properly, Result payload would contain T, but we'll assume it's NOT Copy if generic
            // since Result encapsulates Option/Any etc. For now we will return false unless payload is known copy
            if (t.payload) |p| {
                return isCopyType(p.*);
            }
            return false;
        },
        // Strings, lists, classes, Any etc are passed by reference or moved
        else => return false,
    }
}

pub fn isMoveType(t: Type) bool {
    return !isCopyType(t);
}

pub fn functionTypesEqual(a: Type, b: Type) bool {
    if ((a.kind != .Function and a.kind != .Closure) or (b.kind != .Function and b.kind != .Closure)) return false;
    const fa = a.function orelse return false;
    const fb = b.function orelse return false;
    
    if (fa.is_variadic != fb.is_variadic) return false;
    if (fa.is_async != fb.is_async) return false;
    if (fa.param_types.len != fb.param_types.len) return false;
    
    for (fa.param_types, 0..) |pt, i| {
        if (!isImplicitlyConvertible(pt, fb.param_types[i])) return false;
    }
    
    return isImplicitlyConvertible(fa.return_type.*, fb.return_type.*);
}

pub fn formatType(t: Type) []const u8 {
    return switch (t.kind) {
        .Unknown => "unknown",
        .Any => "Any",
        .Void => "void",
        .I8 => "i8", .I16 => "i16", .I32 => "i32", .I64 => "i64", .I128 => "i128", .ISize => "isize",
        .U8 => "u8", .U16 => "u16", .U32 => "u32", .U64 => "u64", .U128 => "u128", .USize => "usize",
        .F16 => "f16", .BFloat16 => "bf16", .F32 => "f32", .F64 => "f64", .F128 => "f128",
        .Char => "char", .Boolean => "bool",
        .CStr => "cstr", .AsciiStr => "asciistr", .Utf8Str => "utf8str",
        .WebStr => "webstr", .RangeStr => "rangestr", .String => "String",
        .Slice => "slice", .List => "List", .Tuple => "Tuple", .Dict => "Dict",
        .Result => "Result", .Option => "Option",
        .Function, .Closure => "fn",
        .Class => if (t.class_type != null) t.class_type.?.name else "Class",
        .Interface => if (t.interface_type != null) t.interface_type.?.name else "Interface",
        .Struct => if (t.struct_type != null) t.struct_type.?.name else "Struct",
        .Enum => if (t.enum_type != null) t.enum_type.?.name else "Enum",
        .Union => if (t.union_type != null) t.union_type.?.name else "Union",
        .QBit => "qbit", .QReg => "qreg",
        .Error => "Error",
        .Task => "Task",
        .RawPointer => "ptr",
        .Module => "module",
    };
}

pub fn getTypeSize(t: Type) usize {
    return layout.getSize(t, layout.Target.x86_64_linux);
}

pub fn getTypeAlignment(t: Type) usize {
    return layout.getAlign(t, layout.Target.x86_64_linux);
}

pub const UnionLayout = struct {
    size: usize,
    alignment: usize,
};

pub fn getTypeStride(t: Type) usize {
    const size = getTypeSize(t);
    const align_val = getTypeAlignment(t);
    if (align_val == 0) return size;
    const padding = (align_val - (size % align_val)) % align_val;
    return size + padding;
}

pub fn getStructFieldOffset(t: Type, field_name: []const u8) ?usize {
    if (t.kind != .Struct or t.struct_type == null) return null;
    const st = t.struct_type.?;
    var offset: usize = 0;
    for (st.fields) |f| {
        const field_align = getTypeAlignment(f.type_kind);
        const field_size = getTypeSize(f.type_kind);
        const padding = (field_align - (offset % field_align)) % field_align;
        offset += padding;
        if (std.mem.eql(u8, f.name, field_name)) {
            return offset;
        }
        offset += field_size;
    }
    return null;
}

pub fn getUnionLayout(t: Type) ?UnionLayout {
    if (t.kind != .Union or t.union_type == null) return null;
    return UnionLayout{
        .size = getTypeSize(t),
        .alignment = getTypeAlignment(t),
    };
}

pub fn isZeroSizedType(t: Type) bool {
    return getTypeSize(t) == 0;
}

pub fn isTriviallyCopyable(t: Type) bool {
    switch (t.kind) {
        .String, .CStr, .AsciiStr, .Utf8Str, .WebStr, .RangeStr, .Class, .Interface => return false,
        .List => {
            if (t.array_len == null) return false;
            if (t.payload) |p| {
                return isTriviallyCopyable(p.*);
            }
            return true;
        },
        .Struct => {
            if (t.struct_type) |st| {
                for (st.fields) |f| {
                    if (!isTriviallyCopyable(f.type_kind)) return false;
                }
            }
            return true;
        },
        .Union => {
            if (t.union_type) |ut| {
                for (ut.fields) |f| {
                    if (!isTriviallyCopyable(f.type_kind)) return false;
                }
            }
            return true;
        },
        .Tuple => {
            if (t.tuple_types) |ttypes| {
                for (ttypes) |tt| {
                    if (!isTriviallyCopyable(tt)) return false;
                }
            }
            return true;
        },
        else => return true,
    }
}

pub fn hasDestructor(t: Type) bool {
    switch (t.kind) {
        .String, .Utf8Str, .WebStr, .AsciiStr, .RangeStr, .Class => return true,
        .List => return t.array_len == null,
        .Struct => {
            if (t.struct_type) |st| {
                for (st.methods) |method| {
                    if (std.mem.endsWith(u8, method.name, "___del__")) return true;
                }
                for (st.fields) |f| {
                    if (hasDestructor(f.type_kind)) return true;
                }
            }
            return false;
        },
        .Union => {
            if (t.union_type) |ut| {
                for (ut.fields) |f| {
                    if (hasDestructor(f.type_kind)) return true;
                }
            }
            return false;
        },
        .Tuple => {
            if (t.tuple_types) |ttypes| {
                for (ttypes) |tt| {
                    if (hasDestructor(tt)) return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

pub fn getArrayElementType(t: Type) ?Type {
    if (t.kind == .List) {
        if (t.payload) |p| {
            return p.*;
        }
    }
    return null;
}

pub fn getPointeeType(t: Type) ?Type {
    if (t.kind == .Slice or t.kind == .Option or t.kind == .RawPointer) {
        if (t.payload) |p| {
            return p.*;
        }
    }
    return null;
}

pub fn isSized(t: Type) bool {
    _ = t;
    return true;
}
