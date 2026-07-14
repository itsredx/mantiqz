//! Unit tests for the compiler's core data structures.
//!
//! Tests cover type parsing and formatting (`types.zig`), symbol table
//! operations (`symbols.zig`), type layout size and alignment (`layout.zig`),
//! ABI calling convention classification (`abi.zig`), and AST lowering
//! invariants (`ast.zig`). Run via `zig test` or the compiler's built-in
//! test runner (`mantiq-compiler` without arguments).
//!
//! Key test sections:
//! - Type string parsing: `i8` → `I8`, `*T` → `RawPointer`, etc.
//! - Copy/Move classification for all type kinds
//! - Struct/union/enum layout size and alignment
//! - Symbol scope define/resolve/shadow semantics
//! - ABI argument and return value pass-mode classification

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const layout = @import("layout.zig");
const symbols = @import("symbols.zig");
const ast = @import("ast.zig");
const abi = @import("abi.zig");

// ============================================================
// types.zig tests — parseTypeString
// ============================================================

test "parseTypeString: signed integers" {
    try testing.expectEqual(types.TypeKind.I8, types.parseTypeString("i8"));
    try testing.expectEqual(types.TypeKind.I16, types.parseTypeString("i16"));
    try testing.expectEqual(types.TypeKind.I32, types.parseTypeString("i32"));
    try testing.expectEqual(types.TypeKind.I64, types.parseTypeString("i64"));
    try testing.expectEqual(types.TypeKind.I128, types.parseTypeString("i128"));
    try testing.expectEqual(types.TypeKind.ISize, types.parseTypeString("isize"));
}

test "parseTypeString: unsigned integers" {
    try testing.expectEqual(types.TypeKind.U8, types.parseTypeString("u8"));
    try testing.expectEqual(types.TypeKind.U8, types.parseTypeString("byte"));
    try testing.expectEqual(types.TypeKind.U16, types.parseTypeString("u16"));
    try testing.expectEqual(types.TypeKind.U32, types.parseTypeString("u32"));
    try testing.expectEqual(types.TypeKind.U64, types.parseTypeString("u64"));
    try testing.expectEqual(types.TypeKind.U128, types.parseTypeString("u128"));
    try testing.expectEqual(types.TypeKind.USize, types.parseTypeString("usize"));
}

test "parseTypeString: floats" {
    try testing.expectEqual(types.TypeKind.F16, types.parseTypeString("f16"));
    try testing.expectEqual(types.TypeKind.BFloat16, types.parseTypeString("bf16"));
    try testing.expectEqual(types.TypeKind.F32, types.parseTypeString("f32"));
    try testing.expectEqual(types.TypeKind.F64, types.parseTypeString("f64"));
    try testing.expectEqual(types.TypeKind.F128, types.parseTypeString("f128"));
}

test "parseTypeString: char and bool" {
    try testing.expectEqual(types.TypeKind.Char, types.parseTypeString("char"));
    try testing.expectEqual(types.TypeKind.Boolean, types.parseTypeString("bool"));
}

test "parseTypeString: string types" {
    try testing.expectEqual(types.TypeKind.CStr, types.parseTypeString("cstr"));
    try testing.expectEqual(types.TypeKind.AsciiStr, types.parseTypeString("asciistr"));
    try testing.expectEqual(types.TypeKind.AsciiStr, types.parseTypeString("astr"));
    try testing.expectEqual(types.TypeKind.Utf8Str, types.parseTypeString("utf8str"));
    try testing.expectEqual(types.TypeKind.Utf8Str, types.parseTypeString("str"));
    try testing.expectEqual(types.TypeKind.Utf8Str, types.parseTypeString("u8str"));
    try testing.expectEqual(types.TypeKind.Utf8Str, types.parseTypeString("ustr"));
    try testing.expectEqual(types.TypeKind.WebStr, types.parseTypeString("webstr"));
    try testing.expectEqual(types.TypeKind.WebStr, types.parseTypeString("utf16str"));
    try testing.expectEqual(types.TypeKind.WebStr, types.parseTypeString("u16str"));
    try testing.expectEqual(types.TypeKind.WebStr, types.parseTypeString("wstr"));
    try testing.expectEqual(types.TypeKind.RangeStr, types.parseTypeString("rangestr"));
    try testing.expectEqual(types.TypeKind.RangeStr, types.parseTypeString("rstr"));
    try testing.expectEqual(types.TypeKind.RangeStr, types.parseTypeString("utf32str"));
    try testing.expectEqual(types.TypeKind.RangeStr, types.parseTypeString("u32str"));
    try testing.expectEqual(types.TypeKind.String, types.parseTypeString("String"));
}

test "parseTypeString: collections and generics" {
    try testing.expectEqual(types.TypeKind.Slice, types.parseTypeString("slice"));
    try testing.expectEqual(types.TypeKind.List, types.parseTypeString("List"));
    try testing.expectEqual(types.TypeKind.Dict, types.parseTypeString("Dict"));
    try testing.expectEqual(types.TypeKind.Result, types.parseTypeString("Result"));
    try testing.expectEqual(types.TypeKind.Option, types.parseTypeString("Option"));
    try testing.expectEqual(types.TypeKind.RawPointer, types.parseTypeString("ptr"));
}

test "parseTypeString: quantum types" {
    try testing.expectEqual(types.TypeKind.QBit, types.parseTypeString("qbit"));
    try testing.expectEqual(types.TypeKind.QReg, types.parseTypeString("qreg"));
}

test "parseTypeString: special types" {
    try testing.expectEqual(types.TypeKind.Any, types.parseTypeString("Any"));
    try testing.expectEqual(types.TypeKind.Void, types.parseTypeString("void"));
}

test "parseTypeString: unknown type" {
    try testing.expectEqual(types.TypeKind.Unknown, types.parseTypeString("nonsense"));
    try testing.expectEqual(types.TypeKind.Unknown, types.parseTypeString(""));
    try testing.expectEqual(types.TypeKind.Unknown, types.parseTypeString("int"));
}

// ============================================================
// types.zig tests — isImplicitlyConvertible
// ============================================================

test "isImplicitlyConvertible: same primitive types" {
    const i32_type = types.Type{ .kind = .I32 };
    try testing.expect(types.isImplicitlyConvertible(i32_type, i32_type));
}

test "isImplicitlyConvertible: numeric widening allowed" {
    const i32_type = types.Type{ .kind = .I32 };
    const i64_type = types.Type{ .kind = .I64 };
    try testing.expect(types.isImplicitlyConvertible(i32_type, i64_type));
    try testing.expect(types.isImplicitlyConvertible(i64_type, i32_type));
}

test "isImplicitlyConvertible: int to float allowed" {
    const i32_type = types.Type{ .kind = .I32 };
    const f64_type = types.Type{ .kind = .F64 };
    try testing.expect(types.isImplicitlyConvertible(i32_type, f64_type));
}

test "isImplicitlyConvertible: Any is compatible with everything" {
    const any_type = types.Type{ .kind = .Any };
    const i32_type = types.Type{ .kind = .I32 };
    const str_type = types.Type{ .kind = .Utf8Str };
    try testing.expect(types.isImplicitlyConvertible(any_type, i32_type));
    try testing.expect(types.isImplicitlyConvertible(i32_type, any_type));
    try testing.expect(types.isImplicitlyConvertible(any_type, str_type));
}

test "isImplicitlyConvertible: Error is compatible with everything" {
    const err_type = types.Type{ .kind = .Error };
    const i32_type = types.Type{ .kind = .I32 };
    try testing.expect(types.isImplicitlyConvertible(err_type, i32_type));
    try testing.expect(types.isImplicitlyConvertible(i32_type, err_type));
}

test "isImplicitlyConvertible: String and AsciiStr to string encodings" {
    const string_type = types.Type{ .kind = .String };
    const ascii_type = types.Type{ .kind = .AsciiStr };
    const cstr_type = types.Type{ .kind = .CStr };
    const utf8_type = types.Type{ .kind = .Utf8Str };
    const web_type = types.Type{ .kind = .WebStr };
    try testing.expect(types.isImplicitlyConvertible(string_type, cstr_type));
    try testing.expect(types.isImplicitlyConvertible(string_type, utf8_type));
    try testing.expect(types.isImplicitlyConvertible(string_type, web_type));
    
    try testing.expect(types.isImplicitlyConvertible(ascii_type, cstr_type));
    try testing.expect(types.isImplicitlyConvertible(ascii_type, utf8_type));
    try testing.expect(types.isImplicitlyConvertible(ascii_type, string_type));
}

test "isImplicitlyConvertible: incompatible types" {
    const bool_type = types.Type{ .kind = .Boolean };
    const i32_type = types.Type{ .kind = .I32 };
    try testing.expect(!types.isImplicitlyConvertible(bool_type, i32_type));
    try testing.expect(!types.isImplicitlyConvertible(i32_type, bool_type));
}

test "isImplicitlyConvertible: String to non-string fails" {
    const string_type = types.Type{ .kind = .String };
    const i32_type = types.Type{ .kind = .I32 };
    try testing.expect(!types.isImplicitlyConvertible(string_type, i32_type));
}

// ============================================================
// types.zig tests — isCopyType / isMoveType
// ============================================================

test "isCopyType: primitives are Copy" {
    try testing.expect(types.isCopyType(.{ .kind = .I32 }));
    try testing.expect(types.isCopyType(.{ .kind = .U64 }));
    try testing.expect(types.isCopyType(.{ .kind = .F32 }));
    try testing.expect(types.isCopyType(.{ .kind = .Boolean }));
    try testing.expect(types.isCopyType(.{ .kind = .Char }));
    try testing.expect(types.isCopyType(.{ .kind = .QBit }));
    try testing.expect(types.isCopyType(.{ .kind = .RawPointer }));
    try testing.expect(types.isCopyType(.{ .kind = .Function }));
    try testing.expect(types.isCopyType(.{ .kind = .Closure }));
}

test "isCopyType: strings are Copy" {
    try testing.expect(!types.isCopyType(.{ .kind = .String }));
    try testing.expect(types.isCopyType(.{ .kind = .Utf8Str }));
    try testing.expect(types.isCopyType(.{ .kind = .AsciiStr }));
    try testing.expect(types.isCopyType(.{ .kind = .WebStr }));
    try testing.expect(types.isCopyType(.{ .kind = .CStr }));
}

test "isCopyType: collections are not Copy" {
    try testing.expect(!types.isCopyType(.{ .kind = .List }));
    try testing.expect(!types.isCopyType(.{ .kind = .Dict }));
    try testing.expect(!types.isCopyType(.{ .kind = .Slice }));
}

test "isMoveType: inverse of isCopyType" {
    try testing.expect(!types.isMoveType(.{ .kind = .I32 }));
    try testing.expect(types.isMoveType(.{ .kind = .String }));
    try testing.expect(types.isMoveType(.{ .kind = .List }));
}

// ============================================================
// types.zig tests — formatType
// ============================================================

test "formatType: basic types" {
    try testing.expectEqualStrings("i32", types.formatType(.{ .kind = .I32 }));
    try testing.expectEqualStrings("u64", types.formatType(.{ .kind = .U64 }));
    try testing.expectEqualStrings("f32", types.formatType(.{ .kind = .F32 }));
    try testing.expectEqualStrings("bool", types.formatType(.{ .kind = .Boolean }));
    try testing.expectEqualStrings("char", types.formatType(.{ .kind = .Char }));
    try testing.expectEqualStrings("void", types.formatType(.{ .kind = .Void }));
    try testing.expectEqualStrings("Any", types.formatType(.{ .kind = .Any }));
    try testing.expectEqualStrings("unknown", types.formatType(.{ .kind = .Unknown }));
}

test "formatType: string types" {
    try testing.expectEqualStrings("cstr", types.formatType(.{ .kind = .CStr }));
    try testing.expectEqualStrings("utf8str", types.formatType(.{ .kind = .Utf8Str }));
    try testing.expectEqualStrings("String", types.formatType(.{ .kind = .String }));
}

test "formatType: collection types" {
    try testing.expectEqualStrings("List", types.formatType(.{ .kind = .List }));
    try testing.expectEqualStrings("Dict", types.formatType(.{ .kind = .Dict }));
    try testing.expectEqualStrings("Tuple", types.formatType(.{ .kind = .Tuple }));
}

test "formatType: quantum types" {
    try testing.expectEqualStrings("qbit", types.formatType(.{ .kind = .QBit }));
    try testing.expectEqualStrings("qreg", types.formatType(.{ .kind = .QReg }));
}

// ============================================================
// types.zig tests — getTypeSize / getTypeAlignment / getTypeStride
// ============================================================

test "getTypeSize: primitives" {
    try testing.expectEqual(@as(usize, 1), types.getTypeSize(.{ .kind = .I8 }));
    try testing.expectEqual(@as(usize, 1), types.getTypeSize(.{ .kind = .U8 }));
    try testing.expectEqual(@as(usize, 1), types.getTypeSize(.{ .kind = .Boolean }));
    try testing.expectEqual(@as(usize, 2), types.getTypeSize(.{ .kind = .I16 }));
    try testing.expectEqual(@as(usize, 4), types.getTypeSize(.{ .kind = .I32 }));
    try testing.expectEqual(@as(usize, 8), types.getTypeSize(.{ .kind = .I64 }));
    try testing.expectEqual(@as(usize, 16), types.getTypeSize(.{ .kind = .I128 }));
    try testing.expectEqual(@as(usize, 0), types.getTypeSize(.{ .kind = .Void }));
}

test "getTypeSize: floats" {
    try testing.expectEqual(@as(usize, 2), types.getTypeSize(.{ .kind = .F16 }));
    try testing.expectEqual(@as(usize, 2), types.getTypeSize(.{ .kind = .BFloat16 }));
    try testing.expectEqual(@as(usize, 4), types.getTypeSize(.{ .kind = .F32 }));
    try testing.expectEqual(@as(usize, 8), types.getTypeSize(.{ .kind = .F64 }));
    try testing.expectEqual(@as(usize, 16), types.getTypeSize(.{ .kind = .F128 }));
}

test "getTypeSize: pointer-sized types" {
    try testing.expectEqual(@as(usize, 8), types.getTypeSize(.{ .kind = .RawPointer }));
    try testing.expectEqual(@as(usize, 8), types.getTypeSize(.{ .kind = .CStr }));
    try testing.expectEqual(@as(usize, 16), types.getTypeSize(.{ .kind = .Function }));
}

test "getTypeSize: string types are ptr*2" {
    try testing.expectEqual(@as(usize, 16), types.getTypeSize(.{ .kind = .Utf8Str }));
    try testing.expectEqual(@as(usize, 16), types.getTypeSize(.{ .kind = .AsciiStr }));
    try testing.expectEqual(@as(usize, 16), types.getTypeSize(.{ .kind = .String }));
}

test "getTypeAlignment: primitives" {
    try testing.expectEqual(@as(usize, 1), types.getTypeAlignment(.{ .kind = .I8 }));
    try testing.expectEqual(@as(usize, 2), types.getTypeAlignment(.{ .kind = .I16 }));
    try testing.expectEqual(@as(usize, 4), types.getTypeAlignment(.{ .kind = .I32 }));
    try testing.expectEqual(@as(usize, 8), types.getTypeAlignment(.{ .kind = .I64 }));
    try testing.expectEqual(@as(usize, 16), types.getTypeAlignment(.{ .kind = .I128 }));
}

test "getTypeStride: accounts for alignment padding" {
    // For i8: size=1, align=1, stride=1
    try testing.expectEqual(@as(usize, 1), types.getTypeStride(.{ .kind = .I8 }));
    // For i32: size=4, align=4, stride=4
    try testing.expectEqual(@as(usize, 4), types.getTypeStride(.{ .kind = .I32 }));
    // For i64: size=8, align=8, stride=8
    try testing.expectEqual(@as(usize, 8), types.getTypeStride(.{ .kind = .I64 }));
}

// ============================================================
// types.zig tests — isZeroSizedType
// ============================================================

test "isZeroSizedType" {
    try testing.expect(types.isZeroSizedType(.{ .kind = .Void }));
    try testing.expect(!types.isZeroSizedType(.{ .kind = .I32 }));
    try testing.expect(!types.isZeroSizedType(.{ .kind = .Boolean }));
}

// ============================================================
// types.zig tests — isTriviallyCopyable
// ============================================================

test "isTriviallyCopyable: primitives are trivially copyable" {
    try testing.expect(types.isTriviallyCopyable(.{ .kind = .I32 }));
    try testing.expect(types.isTriviallyCopyable(.{ .kind = .F64 }));
    try testing.expect(types.isTriviallyCopyable(.{ .kind = .Boolean }));
    try testing.expect(types.isTriviallyCopyable(.{ .kind = .RawPointer }));
}

test "isTriviallyCopyable: strings are not trivially copyable" {
    try testing.expect(!types.isTriviallyCopyable(.{ .kind = .String }));
    try testing.expect(!types.isTriviallyCopyable(.{ .kind = .Utf8Str }));
    try testing.expect(!types.isTriviallyCopyable(.{ .kind = .CStr }));
}

// ============================================================
// types.zig tests — hasDestructor
// ============================================================

test "hasDestructor: strings need destructors" {
    try testing.expect(types.hasDestructor(.{ .kind = .String }));
    try testing.expect(types.hasDestructor(.{ .kind = .Utf8Str }));
    try testing.expect(types.hasDestructor(.{ .kind = .WebStr }));
    try testing.expect(types.hasDestructor(.{ .kind = .AsciiStr }));
    try testing.expect(types.hasDestructor(.{ .kind = .RangeStr }));
}

test "hasDestructor: dynamically-sized List needs destructor" {
    try testing.expect(types.hasDestructor(.{ .kind = .List }));
}

test "hasDestructor: fixed-size List does not need destructor" {
    try testing.expect(!types.hasDestructor(.{ .kind = .List, .array_len = 4 }));
}

test "hasDestructor: primitives do not need destructors" {
    try testing.expect(!types.hasDestructor(.{ .kind = .I32 }));
    try testing.expect(!types.hasDestructor(.{ .kind = .Boolean }));
    try testing.expect(!types.hasDestructor(.{ .kind = .F64 }));
}

// ============================================================
// types.zig tests — getArrayElementType / getPointeeType
// ============================================================

test "getArrayElementType: returns payload for List" {
    var inner = types.Type{ .kind = .I32 };
    const list_type = types.Type{ .kind = .List, .payload = &inner };
    const elem = types.getArrayElementType(list_type);
    try testing.expect(elem != null);
    try testing.expectEqual(types.TypeKind.I32, elem.?.kind);
}

test "getArrayElementType: returns null for non-List" {
    const i32_type = types.Type{ .kind = .I32 };
    try testing.expect(types.getArrayElementType(i32_type) == null);
}

test "getPointeeType: returns payload for Slice" {
    var inner = types.Type{ .kind = .F32 };
    const slice_type = types.Type{ .kind = .Slice, .payload = &inner };
    const pointee = types.getPointeeType(slice_type);
    try testing.expect(pointee != null);
    try testing.expectEqual(types.TypeKind.F32, pointee.?.kind);
}

test "getPointeeType: returns payload for Option" {
    var inner = types.Type{ .kind = .I64 };
    const opt_type = types.Type{ .kind = .Option, .payload = &inner };
    const pointee = types.getPointeeType(opt_type);
    try testing.expect(pointee != null);
    try testing.expectEqual(types.TypeKind.I64, pointee.?.kind);
}

test "getPointeeType: returns payload for RawPointer" {
    var inner = types.Type{ .kind = .U8 };
    const ptr_type = types.Type{ .kind = .RawPointer, .payload = &inner };
    const pointee = types.getPointeeType(ptr_type);
    try testing.expect(pointee != null);
    try testing.expectEqual(types.TypeKind.U8, pointee.?.kind);
}

test "getPointeeType: returns null for non-pointer types" {
    try testing.expect(types.getPointeeType(.{ .kind = .I32 }) == null);
}

// ============================================================
// types.zig tests — isSized
// ============================================================

test "isSized: all types are currently sized" {
    try testing.expect(types.isSized(.{ .kind = .I32 }));
    try testing.expect(types.isSized(.{ .kind = .List }));
    try testing.expect(types.isSized(.{ .kind = .Void }));
}

// ============================================================
// layout.zig tests — getAlign
// ============================================================

test "layout getAlign: primitives on x86_64" {
    const target = layout.Target.x86_64_linux;
    try testing.expectEqual(@as(usize, 1), layout.getAlign(.{ .kind = .Void }, target));
    try testing.expectEqual(@as(usize, 1), layout.getAlign(.{ .kind = .I8 }, target));
    try testing.expectEqual(@as(usize, 1), layout.getAlign(.{ .kind = .Boolean }, target));
    try testing.expectEqual(@as(usize, 2), layout.getAlign(.{ .kind = .I16 }, target));
    try testing.expectEqual(@as(usize, 2), layout.getAlign(.{ .kind = .F16 }, target));
    try testing.expectEqual(@as(usize, 4), layout.getAlign(.{ .kind = .I32 }, target));
    try testing.expectEqual(@as(usize, 4), layout.getAlign(.{ .kind = .F32 }, target));
    try testing.expectEqual(@as(usize, 8), layout.getAlign(.{ .kind = .I64 }, target));
    try testing.expectEqual(@as(usize, 8), layout.getAlign(.{ .kind = .F64 }, target));
    try testing.expectEqual(@as(usize, 16), layout.getAlign(.{ .kind = .I128 }, target));
    try testing.expectEqual(@as(usize, 16), layout.getAlign(.{ .kind = .F128 }, target));
}

test "layout getAlign: pointer-like types" {
    const target = layout.Target.x86_64_linux;
    try testing.expectEqual(@as(usize, 8), layout.getAlign(.{ .kind = .RawPointer }, target));
    try testing.expectEqual(@as(usize, 8), layout.getAlign(.{ .kind = .Closure }, target));
    try testing.expectEqual(@as(usize, 8), layout.getAlign(.{ .kind = .Interface }, target));
    try testing.expectEqual(@as(usize, 8), layout.getAlign(.{ .kind = .String }, target));
    try testing.expectEqual(@as(usize, 8), layout.getAlign(.{ .kind = .Function }, target));
}

test "layout getAlign: quantum types" {
    const target = layout.Target.x86_64_linux;
    try testing.expectEqual(@as(usize, 4), layout.getAlign(.{ .kind = .QBit }, target));
    try testing.expectEqual(@as(usize, 8), layout.getAlign(.{ .kind = .QReg }, target));
}

// ============================================================
// layout.zig tests — getSize
// ============================================================

test "layout getSize: primitives on x86_64" {
    const target = layout.Target.x86_64_linux;
    try testing.expectEqual(@as(usize, 0), layout.getSize(.{ .kind = .Void }, target));
    try testing.expectEqual(@as(usize, 1), layout.getSize(.{ .kind = .I8 }, target));
    try testing.expectEqual(@as(usize, 1), layout.getSize(.{ .kind = .Boolean }, target));
    try testing.expectEqual(@as(usize, 2), layout.getSize(.{ .kind = .I16 }, target));
    try testing.expectEqual(@as(usize, 4), layout.getSize(.{ .kind = .I32 }, target));
    try testing.expectEqual(@as(usize, 8), layout.getSize(.{ .kind = .I64 }, target));
    try testing.expectEqual(@as(usize, 16), layout.getSize(.{ .kind = .I128 }, target));
}

test "layout getSize: string types (fat pointers)" {
    const target = layout.Target.x86_64_linux;
    try testing.expectEqual(@as(usize, 16), layout.getSize(.{ .kind = .Utf8Str }, target));
    try testing.expectEqual(@as(usize, 16), layout.getSize(.{ .kind = .AsciiStr }, target));
    try testing.expectEqual(@as(usize, 16), layout.getSize(.{ .kind = .String }, target));
    try testing.expectEqual(@as(usize, 8), layout.getSize(.{ .kind = .CStr }, target));
}

test "layout getSize: collections without array_len (dynamic)" {
    const target = layout.Target.x86_64_linux;
    // Dynamic list/dict: ptr + len + cap = 3 * pointer_size
    try testing.expectEqual(@as(usize, 24), layout.getSize(.{ .kind = .List }, target));
    try testing.expectEqual(@as(usize, 24), layout.getSize(.{ .kind = .Dict }, target));
}

test "layout getSize: Option and Result" {
    const target = layout.Target.x86_64_linux;
    try testing.expectEqual(@as(usize, 16), layout.getSize(.{ .kind = .Option }, target));
    try testing.expectEqual(@as(usize, 24), layout.getSize(.{ .kind = .Result }, target));
}

test "layout getSize: quantum types" {
    const target = layout.Target.x86_64_linux;
    try testing.expectEqual(@as(usize, 4), layout.getSize(.{ .kind = .QBit }, target));
    try testing.expectEqual(@as(usize, 16), layout.getSize(.{ .kind = .QReg }, target));
}

// ============================================================
// layout.zig tests — struct layout
// ============================================================

test "layout getSize: struct with fields" {
    const target = layout.Target.x86_64_linux;
    var fields = [_]types.StructField{
        .{ .name = "x", .type_kind = .{ .kind = .I32 } },
        .{ .name = "y", .type_kind = .{ .kind = .I32 } },
    };
    var st = types.StructType{
        .name = "Point",
        .fields = &fields,
    };
    const struct_type = types.Type{ .kind = .Struct, .struct_type = &st };
    // Two i32 fields: 4 + 4 = 8, align 4, total 8
    try testing.expectEqual(@as(usize, 8), layout.getSize(struct_type, target));
    try testing.expectEqual(@as(usize, 4), layout.getAlign(struct_type, target));
}

test "layout getSize: struct with padding" {
    const target = layout.Target.x86_64_linux;
    var fields = [_]types.StructField{
        .{ .name = "a", .type_kind = .{ .kind = .I8 } },
        .{ .name = "b", .type_kind = .{ .kind = .I64 } },
    };
    var st = types.StructType{
        .name = "Padded",
        .fields = &fields,
    };
    const struct_type = types.Type{ .kind = .Struct, .struct_type = &st };
    // i8 (1 byte) + 7 padding + i64 (8 bytes) = 16, align 8
    try testing.expectEqual(@as(usize, 16), layout.getSize(struct_type, target));
    try testing.expectEqual(@as(usize, 8), layout.getAlign(struct_type, target));
}

// ============================================================
// layout.zig tests — tuple layout
// ============================================================

test "layout getSize: tuple" {
    const target = layout.Target.x86_64_linux;
    var tuple_types_arr = [_]types.Type{
        .{ .kind = .I32 },
        .{ .kind = .I32 },
    };
    const tuple_type = types.Type{ .kind = .Tuple, .tuple_types = &tuple_types_arr };
    // Two i32: 4 + 4 = 8
    try testing.expectEqual(@as(usize, 8), layout.getSize(tuple_type, target));
}

// ============================================================
// layout.zig tests — union layout
// ============================================================

test "layout getSize: union without tag" {
    const target = layout.Target.x86_64_linux;
    var fields = [_]types.StructField{
        .{ .name = "int_val", .type_kind = .{ .kind = .I32 } },
        .{ .name = "long_val", .type_kind = .{ .kind = .I64 } },
    };
    var ut = types.UnionType{
        .name = "MyUnion",
        .fields = &fields,
    };
    const union_type = types.Type{ .kind = .Union, .union_type = &ut };
    // max(4, 8) = 8, aligned to 8
    try testing.expectEqual(@as(usize, 8), layout.getSize(union_type, target));
    try testing.expectEqual(@as(usize, 8), layout.getAlign(union_type, target));
}

// ============================================================
// types.zig tests — getStructFieldOffset
// ============================================================

test "getStructFieldOffset: simple struct" {
    var fields = [_]types.StructField{
        .{ .name = "x", .type_kind = .{ .kind = .I32 } },
        .{ .name = "y", .type_kind = .{ .kind = .I32 } },
    };
    var st = types.StructType{
        .name = "Point",
        .fields = &fields,
    };
    const struct_type = types.Type{ .kind = .Struct, .struct_type = &st };
    try testing.expectEqual(@as(?usize, 0), types.getStructFieldOffset(struct_type, "x"));
    try testing.expectEqual(@as(?usize, 4), types.getStructFieldOffset(struct_type, "y"));
}

test "getStructFieldOffset: struct with padding" {
    var fields = [_]types.StructField{
        .{ .name = "a", .type_kind = .{ .kind = .I8 } },
        .{ .name = "b", .type_kind = .{ .kind = .I64 } },
    };
    var st = types.StructType{
        .name = "Padded",
        .fields = &fields,
    };
    const struct_type = types.Type{ .kind = .Struct, .struct_type = &st };
    try testing.expectEqual(@as(?usize, 0), types.getStructFieldOffset(struct_type, "a"));
    try testing.expectEqual(@as(?usize, 8), types.getStructFieldOffset(struct_type, "b"));
}

test "getStructFieldOffset: non-existent field returns null" {
    var fields = [_]types.StructField{
        .{ .name = "x", .type_kind = .{ .kind = .I32 } },
    };
    var st = types.StructType{
        .name = "Single",
        .fields = &fields,
    };
    const struct_type = types.Type{ .kind = .Struct, .struct_type = &st };
    try testing.expect(types.getStructFieldOffset(struct_type, "nonexistent") == null);
}

test "getStructFieldOffset: non-struct returns null" {
    const i32_type = types.Type{ .kind = .I32 };
    try testing.expect(types.getStructFieldOffset(i32_type, "x") == null);
}

// ============================================================
// types.zig tests — getUnionLayout
// ============================================================

test "getUnionLayout: returns correct size and alignment" {
    var fields = [_]types.StructField{
        .{ .name = "a", .type_kind = .{ .kind = .I32 } },
        .{ .name = "b", .type_kind = .{ .kind = .I64 } },
    };
    var ut = types.UnionType{
        .name = "U",
        .fields = &fields,
    };
    const union_type = types.Type{ .kind = .Union, .union_type = &ut };
    const ul = types.getUnionLayout(union_type);
    try testing.expect(ul != null);
    try testing.expectEqual(@as(usize, 8), ul.?.size);
    try testing.expectEqual(@as(usize, 8), ul.?.alignment);
}

test "getUnionLayout: non-union returns null" {
    try testing.expect(types.getUnionLayout(.{ .kind = .I32 }) == null);
}

// ============================================================
// symbols.zig tests — Scope
// ============================================================

test "Scope: create and define symbol" {
    const allocator = testing.allocator;
    const scope = try symbols.Scope.create(allocator, null);
    defer allocator.destroy(scope);
    defer scope.symbols.deinit();

    var sym = symbols.Symbol{
        .name = "x",
        .kind = .Variable,
        .decl_node = null,
    };
    try scope.define(&sym);

    const resolved = scope.resolve("x");
    try testing.expect(resolved != null);
    try testing.expectEqualStrings("x", resolved.?.sym.name);
    try testing.expectEqual(symbols.SymbolType.Variable, resolved.?.sym.kind);
}

test "Scope: resolve returns null for undefined symbol" {
    const allocator = testing.allocator;
    const scope = try symbols.Scope.create(allocator, null);
    defer allocator.destroy(scope);
    defer scope.symbols.deinit();

    try testing.expect(scope.resolve("undefined_var") == null);
}

test "Scope: resolveLocal only checks current scope" {
    const allocator = testing.allocator;
    const parent = try symbols.Scope.create(allocator, null);
    defer allocator.destroy(parent);
    defer parent.symbols.deinit();

    const child = try symbols.Scope.create(allocator, parent);
    defer allocator.destroy(child);
    defer child.symbols.deinit();

    var sym = symbols.Symbol{
        .name = "parent_var",
        .kind = .Variable,
        .decl_node = null,
    };
    try parent.define(&sym);

    // resolveLocal on child should NOT find parent's symbol
    try testing.expect(child.resolveLocal("parent_var") == null);
    // but resolve (which walks parent chain) should find it
    try testing.expect(child.resolve("parent_var") != null);
}

test "Scope: nested scope resolution walks parent chain" {
    const allocator = testing.allocator;
    const grandparent = try symbols.Scope.create(allocator, null);
    defer allocator.destroy(grandparent);
    defer grandparent.symbols.deinit();

    const parent = try symbols.Scope.create(allocator, grandparent);
    defer allocator.destroy(parent);
    defer parent.symbols.deinit();

    const child = try symbols.Scope.create(allocator, parent);
    defer allocator.destroy(child);
    defer child.symbols.deinit();

    var sym = symbols.Symbol{
        .name = "deep_var",
        .kind = .Function,
        .decl_node = null,
    };
    try grandparent.define(&sym);

    const resolved = child.resolve("deep_var");
    try testing.expect(resolved != null);
    try testing.expectEqual(symbols.SymbolType.Function, resolved.?.sym.kind);
}

test "Scope: shadowing in child scope" {
    const allocator = testing.allocator;
    const parent = try symbols.Scope.create(allocator, null);
    defer allocator.destroy(parent);
    defer parent.symbols.deinit();

    const child = try symbols.Scope.create(allocator, parent);
    defer allocator.destroy(child);
    defer child.symbols.deinit();

    var parent_sym = symbols.Symbol{
        .name = "x",
        .kind = .Variable,
        .decl_node = null,
    };
    try parent.define(&parent_sym);

    var child_sym = symbols.Symbol{
        .name = "x",
        .kind = .Function,
        .decl_node = null,
    };
    try child.define(&child_sym);

    // Child resolves its own 'x' (Function), not parent's (Variable)
    const resolved = child.resolve("x");
    try testing.expect(resolved != null);
    try testing.expectEqual(symbols.SymbolType.Function, resolved.?.sym.kind);
}

// ============================================================
// abi.zig tests — getArgABI / getRetABI
// ============================================================

test "abi getArgABI: primitives passed directly" {
    const target = layout.Target.x86_64_linux;
    const result = abi.getArgABI(.{ .kind = .I32 }, target);
    try testing.expectEqual(abi.PassMode.Direct, result.mode);
    try testing.expect(!result.is_struct);
}

test "abi getArgABI: pointer passed directly" {
    const target = layout.Target.x86_64_linux;
    const result = abi.getArgABI(.{ .kind = .RawPointer }, target);
    try testing.expectEqual(abi.PassMode.Direct, result.mode);
}

test "abi getArgABI: small composite coerced to i64" {
    const target = layout.Target.x86_64_linux;
    // Option type is 16 bytes — fits in two registers
    const result = abi.getArgABI(.{ .kind = .Option }, target);
    try testing.expectEqual(abi.PassMode.Coerce, result.mode);
    try testing.expectEqualStrings("{ i64, i64 }", result.llvm_type);
    try testing.expect(result.is_struct);
}

test "abi getArgABI: large composite passed byval" {
    const target = layout.Target.x86_64_linux;
    // Result type is 24 bytes — too big for registers
    const result = abi.getArgABI(.{ .kind = .Result }, target);
    try testing.expectEqual(abi.PassMode.ByVal, result.mode);
    try testing.expectEqualStrings("ptr", result.llvm_type);
}

test "abi getRetABI: primitives returned directly" {
    const target = layout.Target.x86_64_linux;
    const result = abi.getRetABI(.{ .kind = .F64 }, target);
    try testing.expectEqual(abi.PassMode.Direct, result.mode);
    try testing.expect(!result.is_struct);
}

test "abi getRetABI: small composite coerced" {
    const target = layout.Target.x86_64_linux;
    const result = abi.getRetABI(.{ .kind = .Option }, target);
    try testing.expectEqual(abi.PassMode.Coerce, result.mode);
}

test "abi getRetABI: large composite returned directly (deferred sret)" {
    const target = layout.Target.x86_64_linux;
    const result = abi.getRetABI(.{ .kind = .Result }, target);
    try testing.expectEqual(abi.PassMode.Direct, result.mode);
    try testing.expect(result.is_struct);
}

// ============================================================
// ast.zig tests — Span / TypeAnnotation basics
// ============================================================

test "ast Span: zero span" {
    const span = ast.Span{
        .start_byte = 0,
        .end_byte = 0,
        .start_row = 0,
        .start_col = 0,
        .end_row = 0,
        .end_col = 0,
    };
    try testing.expectEqual(@as(u32, 0), span.start_byte);
    try testing.expectEqual(@as(u32, 0), span.end_byte);
}

test "ast TypeAnnotation: basic construction" {
    const annot = ast.TypeAnnotation{
        .name = "i32",
    };
    try testing.expectEqualStrings("i32", annot.name);
    try testing.expect(!annot.is_ref);
    try testing.expect(!annot.is_mut);
    try testing.expect(annot.lifetime == null);
    try testing.expect(annot.generics == null);
}

test "ast TypeAnnotation: ref and mut" {
    const annot = ast.TypeAnnotation{
        .name = "String",
        .is_ref = true,
        .is_mut = true,
        .lifetime = "a",
    };
    try testing.expect(annot.is_ref);
    try testing.expect(annot.is_mut);
    try testing.expectEqualStrings("a", annot.lifetime.?);
}

// ============================================================
// layout.zig tests — Target constants
// ============================================================

test "layout Target: x86_64_linux constants" {
    const target = layout.Target.x86_64_linux;
    try testing.expectEqualStrings("x86_64", target.arch);
    try testing.expectEqualStrings("linux", target.os);
    try testing.expectEqualStrings("gnu", target.env);
    try testing.expectEqual(@as(usize, 8), target.pointer_size);
    try testing.expectEqual(layout.Endianness.Little, target.endianness);
}
