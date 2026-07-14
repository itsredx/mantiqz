//! Type layout — size and alignment computation for every type.
//!
//! Provides `getSize` and `getAlign` functions used by `codegen.zig` (alloca sizing),
//! `abi.zig` (classify structs/unions), and the borrow checker. Alignment is
//! target-aware via `Target` (currently `x86_64_linux` with plans for more).
//! Enum types are fixed at 40 bytes. Struct layout follows C-compatible padding.
//!
//! Key types:
//! - `Target` — architecture, OS, pointer size, endianness, data layout
//! - `getSize` — byte size of any `Type` (including struct field walking)
//! - `getAlign` — byte alignment of any `Type`
//! - `getStructFieldOffset` — byte offset of a named struct field (for GEP)

const std = @import("std");
const types = @import("types.zig");

pub const Endianness = enum {
    Little,
    Big,
};

pub const Target = struct {
    arch: []const u8,
    os: []const u8,
    env: []const u8,
    pointer_size: usize,
    endianness: Endianness,
    data_layout: []const u8,
    triple: []const u8,

    pub const x86_64_linux = Target{
        .arch = "x86_64",
        .os = "linux",
        .env = "gnu",
        .pointer_size = 8,
        .endianness = .Little,
        .data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128",
        .triple = "x86_64-unknown-linux-gnu",
    };
};

pub fn getAlign(t: types.Type, target: Target) usize {
    switch (t.kind) {
        .Void => return 1,
        .I8, .U8, .Char, .Boolean => return 1,
        .I16, .U16, .F16, .BFloat16 => return 2,
        .I32, .U32, .F32 => return 4,
        .I64, .U64, .F64, .ISize, .USize => return 8,
        .I128, .U128, .F128 => return 16,
        .Enum => return 8, // Enums currently fallback to 8 alignment
        .Slice, .Closure, .Interface => return target.pointer_size,
        .String, .Utf8Str, .AsciiStr, .WebStr, .RangeStr, .CStr => return target.pointer_size,
        .RawPointer => return target.pointer_size,
        .List, .Dict => {
            if (t.array_len != null) {
                if (t.payload) |p| {
                    return getAlign(p.*, target);
                }
            }
            return target.pointer_size;
        },
        .Tuple => {
            if (t.tuple_types) |types_list| {
                var max_align: usize = 1;
                for (types_list) |et| {
                    const a = getAlign(et, target);
                    if (a > max_align) max_align = a;
                }
                return max_align;
            }
            return target.pointer_size;
        },
        .Struct => {
            if (t.struct_type) |st| {
                var max_align: usize = 1;
                for (st.fields) |f| {
                    const field_align = getAlign(f.type_kind, target);
                    if (field_align > max_align) max_align = field_align;
                }
                return max_align;
            }
            return target.pointer_size;
        },
        .Union => {
            if (t.union_type) |ut| {
                var max_align: usize = 1;
                for (ut.fields) |f| {
                    const field_align = getAlign(f.type_kind, target);
                    if (field_align > max_align) max_align = field_align;
                }
                if (ut.tag_type) |tag_t| {
                    const tag_align = getAlign(tag_t, target);
                    if (tag_align > max_align) max_align = tag_align;
                }
                return max_align;
            }
            return target.pointer_size;
        },
        .Option => {
            return target.pointer_size;
        },
        .Result => {
            return target.pointer_size;
        },
        .Any => return target.pointer_size,
        .QBit => return 4,
        .QReg => return target.pointer_size,
        .Class => return target.pointer_size,
        .Function => return target.pointer_size,
        .Unknown, .Task, .Error, .Module => return target.pointer_size,
    }
}

pub fn getSize(t: types.Type, target: Target) usize {
    switch (t.kind) {
        .Void => return 0,
        .I8, .U8, .Char, .Boolean => return 1,
        .I16, .U16, .F16, .BFloat16 => return 2,
        .I32, .U32, .F32 => return 4,
        .I64, .U64, .F64, .ISize, .USize => return 8,
        .I128, .U128, .F128 => return 16,
        .Enum => return 40,
        .Slice, .Interface => return target.pointer_size,
        .String, .Utf8Str, .AsciiStr, .WebStr, .RangeStr => return target.pointer_size * 2,
        .CStr => return target.pointer_size,
        .RawPointer => return target.pointer_size,
        .List, .Dict => {
            if (t.array_len) |len| {
                if (t.payload) |p| {
                    return getSize(p.*, target) * len;
                }
            }
            return target.pointer_size * 3;
        },
        .Tuple => {
            if (t.tuple_types) |types_list| {
                var total_size: usize = 0;
                var max_align: usize = 1;
                for (types_list) |et| {
                    const field_align = getAlign(et, target);
                    const field_size = getSize(et, target);
                    const padding = (field_align - (total_size % field_align)) % field_align;
                    total_size += padding + field_size;
                    if (field_align > max_align) max_align = field_align;
                }
                const padding = (max_align - (total_size % max_align)) % max_align;
                return total_size + padding;
            }
            return target.pointer_size;
        },
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
                const payload_size = max_size + padding;
                if (ut.tag_type) |tag_t| {
                    const tag_size = getSize(tag_t, target);
                    const tag_align = getAlign(tag_t, target);
                    const tag_padding = (max_align - (tag_size % max_align)) % max_align;
                    const union_align = @max(tag_align, max_align);
                    const raw_size = tag_size + tag_padding + payload_size;
                    const final_padding = (union_align - (raw_size % union_align)) % union_align;
                    return raw_size + final_padding;
                }
                return payload_size;
            }
            return target.pointer_size;
        },
        .Option => {
            return target.pointer_size * 2;
        },
        .Result => {
            return target.pointer_size * 3;
        },
        .Any => return target.pointer_size * 2,
        .QBit => return 4,
        .QReg => return target.pointer_size * 2,
        .Class => return target.pointer_size,
        .Function, .Closure => return target.pointer_size * 2,
        .Unknown, .Task, .Error, .Module => return target.pointer_size,
    }
}
