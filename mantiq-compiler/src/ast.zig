//! AST (Abstract Syntax Tree) — the compiler's intermediate representation.
//! 
//! The AST is produced by `lower.zig` from the tree-sitter CST and consumed by
//! `sema.zig`, `typecheck.zig`, `borrowck.zig`, and `codegen.zig`. Every source
//! construct maps to one of the 46+ `NodeType` variants in `NodeData`.
//! 
//! Key types:
//! - `Node` / `NodeData` — tagged union of all AST node variants
//! - `TypeAnnotation` — parsed type syntax (including generics, lifetimes, ref/mut)
//! - `LanguageMode` — `Nizam` (strict) or `Mantiq` (full)
//! - `ImportKind` — `normal`, `path`, `vendor`, `c`, `pkg`
//! - `Span` — source-location range (byte offset + row/col)
//! - `MatchCase` — pattern-match arm with optional guard
//! - `MacroDef` — macro definition with parameters and body

const std = @import("std");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

pub var show_ir: bool = false;
pub var show_debug: bool = false;

pub fn debugPrint(comptime format: []const u8, args: anytype) void {
    if (show_debug) {
        std.debug.print(format, args);
    }
}

pub const LanguageMode = enum {
    Nizam,
    Mantiq,
};

pub const TypeAnnotation = struct {
    name: []const u8,
    is_ref: bool = false,
    is_mut: bool = false,
    lifetime: ?[]const u8 = null,
    generics: ?[]TypeAnnotation = null,
    params: ?[]TypeAnnotation = null,
    return_type: ?*TypeAnnotation = null,
};

pub const Span = struct {
    start_byte: u32,
    end_byte: u32,
    start_row: u32,
    start_col: u32,
    end_row: u32,
    end_col: u32,
};

pub const ImportKind = enum {
    normal,
    path,
    vendor,
    c,
    pkg,
};

pub const NodeType = enum {
    Program,
    // Declarations
    ImportDecl,
    LinkDecl,
    FunDecl,
    VarDecl,
    ClassDecl,
    StructDecl,
    UnionDecl,
    InterfaceDecl,
    FieldDecl,
    EnumDecl,
    EnumVariant,
    // Statements
    IfStmt,
    ForStmt,
    WhileStmt,
    BreakStmt,
    ContinueStmt,
    PassStmt,
    ReturnStmt,
    BlockStmt,
    ParamBlockStmt,
    SpawnStmt,
    TryStmt,
    ThrowStmt,
    // Expressions
    BinaryExpr,
    UnaryExpr,
    CastExpr,
    CallExpr,
    MethodCallExpr,
    MemberExpr,
    ClosureExpr,
    Identifier,
    NumberLiteral,
    StringLiteral,
    InterpolatedString,
    BooleanLiteral,
    KeywordArg,
    ListLiteral,
    DictLiteral,
    IndexExpr,
    AwaitExpr,
    SpreadExpr,
    MatchStmt,
    UnsafeBlock,
    MacroDecl,
    MacroInvocation,
    WithStmt,
};

pub const Node = struct {
    node_type: NodeType,
    span: Span,
    data: NodeData,
    inferred_type: ?types.Type = null,
    module_name: ?[]const u8 = null,
};

pub const NodeData = union(NodeType) {
    Program: struct {
        declarations: []const *Node,
    },
    ImportDecl: struct {
        kind: ImportKind = .normal,
        target: []const u8,
        imported_symbols: [][]const u8,
        alias: ?[]const u8,
        module_ast: ?*Node = null,
    },
    LinkDecl: struct {
        kind: ImportKind = .normal,
        target: []const u8,
    },
    FunDecl: struct {
        name: []const u8,
        generic_params: ?[][]const u8 = null,
        params: []const *Node,
        param_names: []const []const u8,
        param_types: []?TypeAnnotation,
        default_values: []?*Node,
        body: *Node,
        is_async: bool,
        is_extern: bool = false,
        is_inline: bool = false,
        return_type: ?TypeAnnotation = null,
        has_self: bool = false,
        is_variadic: bool = false,
        auto_drops: ?[]*symbols.Symbol = null,
    },
    VarDecl: struct {
        names: [][]const u8,
        type_annots: []?TypeAnnotation,
        initializers: ?[]*Node,
        is_mut: bool,
        is_static: bool = false,
        resolved_symbols: ?[]*symbols.Symbol = null,
    },

    ClassDecl: struct {
        name: []const u8,
        base_class: ?[]const u8,
        interfaces: [][]const u8,
        fields: []*Node,
        methods: []*Node,
    },
    StructDecl: struct {
        name: []const u8,
        generic_params: ?[][]const u8 = null,
        fields: []*Node,
        methods: []*Node,
    },
    UnionDecl: struct {
        name: []const u8,
        tag_type: ?TypeAnnotation = null,
        generic_params: ?[][]const u8 = null,
        fields: []*Node,
        methods: []*Node,
    },
    InterfaceDecl: struct {
        name: []const u8,
        super_interfaces: [][]const u8,
        methods: []*Node,
    },
    FieldDecl: struct {
        name: []const u8,
        access_modifier: []const u8,
        is_mutable: bool,
        type_annot: TypeAnnotation,
        default_value: ?*Node,
    },
    EnumDecl: struct {
        name: []const u8,
        generic_params: ?[][]const u8 = null,
        variants: []*Node,
    },
    EnumVariant: struct {
        name: []const u8,
        value: ?*Node,
        payload_types: ?[]TypeAnnotation,
    },
    IfStmt: struct {
        condition: *Node,
        then_branch: *Node,
        else_branch: ?*Node,
    },
    ForStmt: struct {
        iterator: []const u8,
        type_annot: ?TypeAnnotation,
        iterable: *Node,
        body: *Node,
        is_parallel: bool,
        is_vectorized: bool,
    },
    WhileStmt: struct {
        condition: *Node,
        body: *Node,
    },
    BreakStmt: struct {},
    ContinueStmt: struct {},
    PassStmt: struct {},
    ReturnStmt: struct {
        values: ?[]*Node,
        auto_drops: ?[]*symbols.Symbol = null,
    },
    BlockStmt: struct {
        statements: []const *Node,
        auto_drops: ?[]*symbols.Symbol = null,
    },
    ParamBlockStmt: struct {
        params: []const *Node,
        param_types: []TypeAnnotation,
        return_names: [][]const u8,
        return_types: []TypeAnnotation,
        body: *Node,
        auto_drops: ?[]*symbols.Symbol = null,
    },
    SpawnStmt: struct {
        call_expr: *Node,
    },
    TryStmt: struct {
        body: *Node,
        catch_binding: ?[]const u8,
        catch_body: ?*Node,
        unwrapped_type: ?types.Type = null,
    },
    ThrowStmt: struct {
        value: *Node,
    },
    BinaryExpr: struct {
        left: *Node,
        right: *Node,
        operator: []const u8,
    },
    UnaryExpr: struct {
        operand: *Node,
        operator: []const u8,
    },
    CastExpr: struct {
        operand: *Node,
        target_type: TypeAnnotation,
    },
    CallExpr: struct {
        callee: *Node,
        arguments: []*Node,
        generic_args: ?[]TypeAnnotation = null,
    },
    MethodCallExpr: struct {
        receiver: *Node,
        method_name: []const u8,
        arguments: []*Node,
        is_dynamic: bool,
    },
    MemberExpr: struct {
        object: *Node,
        property: []const u8,
    },
    ClosureExpr: struct {
        params: []const *Node,
        param_types: []?TypeAnnotation,
        body: *Node,
        return_type: ?TypeAnnotation,
        captured_vars: ?[][]const u8 = null,
    },
    Identifier: struct {
        name: []const u8,
        resolved_symbol: ?*symbols.Symbol = null,
    },
    NumberLiteral: struct {
        value: f64,
    },
    StringLiteral: struct {
        value: []const u8,
    },
    InterpolatedString: struct {
        parts: []*Node,
    },
    BooleanLiteral: struct {
        value: bool,
    },
    KeywordArg: struct {
        name: []const u8,
        value: *Node,
    },
    ListLiteral: struct {
        elements: []*Node,
    },
    DictLiteral: struct {
        keys: []*Node,
        values: []*Node,
    },
    IndexExpr: struct {
        object: *Node,
        index: *Node,
    },
    AwaitExpr: struct {
        task_expr: *Node,
    },
    SpreadExpr: struct {
        iterable: *Node,
    },
    MatchStmt: struct {
        subject: *Node,
        cases: []MatchCase,
    },
    UnsafeBlock: struct {
        body: *Node,
    },
    MacroDecl: struct {
        name: []const u8,
        params: []const *Node,
        param_names: []const []const u8,
        param_types: []?TypeAnnotation,
        body: *Node,
    },
    MacroInvocation: struct {
        name: []const u8,
        arguments: []*Node,
    },
    WithStmt: struct {
        expr: *Node,
        var_name: ?[]const u8,
        body: *Node,
        resolved_symbol: ?*symbols.Symbol = null,
        auto_drops: ?[]*symbols.Symbol = null,
    },
};

pub const MatchCase = struct {
    pattern: *Node,
    guard: ?*Node,
    body: *Node,
};
