//! ABI (Application Binary Interface) — SysV x86_64 calling convention classification.
//!
//! Determines how function arguments and return values are passed in registers
//! or on the stack. Each type is classified as `Direct` (native LLVM pass),
//! `Coerce` (force into integer registers), or `ByVal` (hidden pointer).
//! Classification feeds into `codegen.zig` for argument/return value codegen.
//!
//! Key types:
//! - `PassMode` — `Direct` / `ByVal` / `Coerce`
//! - `ABISignature` — pass mode + LLVM type string + struct flag
//! - `getArgABI` — classify a type as an argument
//! - `getRetABI` — classify a type as a return value

const std = @import("std");
const types = @import("types.zig");
const layout = @import("layout.zig");

pub const PassMode = enum {
    /// Passed directly using its LLVM type natively.
    Direct,
    /// Passed as a pointer, but with the `byval` attribute (caller copies).
    ByVal,
    /// Coerced into an integer type (e.g. `i64` or `{ i64, i64 }`) to force register passing.
    Coerce,
};

pub const ABISignature = struct {
    mode: PassMode,
    llvm_type: []const u8,
    is_struct: bool,
};

/// Computes the ABI passing mechanism for an argument type.
pub fn getArgABI(t: types.Type, target: layout.Target) ABISignature {
    const size = layout.getSize(t, target);
    
    // Primitives and native types are always passed Directly.
    switch (t.kind) {
        .Void, .I8, .U8, .Char, .Boolean, .I16, .U16, .F16, .BFloat16, .I32, .U32, .F32, .I64, .U64, .F64, .ISize, .USize, .I128, .U128, .F128, .Enum, .RawPointer, .CStr, .QBit, .Class, .Interface, .Slice, .Task => {
            return .{ .mode = .Direct, .llvm_type = "", .is_struct = false };
        },
        else => {} // Composite types drop down for size analysis.
    }

    if (size <= 8) {
        // Fit into a single register
        return .{ .mode = .Coerce, .llvm_type = "i64", .is_struct = true };
    } else if (size <= 16) {
        // Fit into two registers natively
        return .{ .mode = .Coerce, .llvm_type = "{ i64, i64 }", .is_struct = true };
    } else {
        // Too large, pass by pointer byval
        return .{ .mode = .ByVal, .llvm_type = "ptr", .is_struct = true };
    }
}

/// Computes the ABI passing mechanism for a return type.
pub fn getRetABI(t: types.Type, target: layout.Target) ABISignature {
    // SysV x86_64 allows returning up to 16 bytes in rax and rdx.
    // If > 16 bytes, LLVM uses sret (hidden pointer argument), but since sret is complex,
    // and Mantiq currently returns composites directly via LLVM's `ret` instruction,
    // LLVM will automatically lower `{ i64, i64 }` returns to rax/rdx.
    // If it's > 16 bytes, we might need a proper sret implementation later.
    // For now, we will classify composites as Coerce if <= 16, and Direct if > 16 (letting LLVM handle it natively for now).
    
    const size = layout.getSize(t, target);
    
    switch (t.kind) {
        .Void, .I8, .U8, .Char, .Boolean, .I16, .U16, .F16, .BFloat16, .I32, .U32, .F32, .I64, .U64, .F64, .ISize, .USize, .I128, .U128, .F128, .Enum, .RawPointer, .CStr, .QBit, .Class, .Interface, .Slice, .Task => {
            return .{ .mode = .Direct, .llvm_type = "", .is_struct = false };
        },
        else => {}
    }

    if (size <= 8) {
        return .{ .mode = .Coerce, .llvm_type = "i64", .is_struct = true };
    } else if (size <= 16) {
        return .{ .mode = .Coerce, .llvm_type = "{ i64, i64 }", .is_struct = true };
    } else {
        return .{ .mode = .Direct, .llvm_type = "", .is_struct = true }; // Deferred sret implementation
    }
}
