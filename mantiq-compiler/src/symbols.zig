//! Symbol table — scope-based name resolution infrastructure.
//!
//! Defines `Scope` (a lexical scope with parent chain) and `Symbol` (a named
//! declaration with kind, type, and optional metadata). Scopes support
//! `define` (local insertion) and `resolve` (walk parent chain). The
//! `closure_node` field on Scope marks closure boundaries for capture analysis.
//!
//! Key types:
//! - `SymbolType` — Variable, Function, Class, Struct, Interface, Enum, Union, Module
//! - `Symbol` — name, kind, decl_node, sym_type, module_scope, is_context_manager
//! - `Scope` — parent pointer, symbol map, closure boundary marker

const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");

pub const SymbolType = enum {
    Variable,
    Function,
    Class,
    Struct,
    Interface,
    Enum,
    Union,
    Module,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolType,
    decl_node: ?*ast.Node,
    sym_type: ?types.TypeKind = null,
    module_scope: ?*Scope = null,
    is_context_manager: bool = false,
};

pub const Scope = struct {
    parent: ?*Scope,
    symbols: std.StringHashMap(*Symbol),
    allocator: std.mem.Allocator,
    closure_node: ?*ast.Node = null,

    pub fn create(allocator: std.mem.Allocator, parent: ?*Scope) !*Scope {
        const scope = try allocator.create(Scope);
        scope.* = .{
            .parent = parent,
            .symbols = std.StringHashMap(*Symbol).init(allocator),
            .allocator = allocator,
        };
        return scope;
    }

    pub fn define(self: *Scope, sym: *Symbol) !void {
        try self.symbols.put(sym.name, sym);
    }

    pub const Resolved = struct {
        sym: *Symbol,
        scope: *Scope,
    };

    pub fn resolve(self: *Scope, name: []const u8) ?Resolved {
        if (self.symbols.get(name)) |sym| {
            return Resolved{ .sym = sym, .scope = self };
        }
        if (self.parent) |p| {
            return p.resolve(name);
        }
        return null;
    }

    // Resolves only within the immediate lexical scope
    pub fn resolveLocal(self: *Scope, name: []const u8) ?*Symbol {
        return self.symbols.get(name);
    }
};
