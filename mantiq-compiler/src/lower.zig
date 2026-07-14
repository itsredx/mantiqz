//! CST-to-AST lowering — converts tree-sitter concrete syntax trees into the typed AST.
//!
//! The largest file in the compiler (3100+ lines). Walks tree-sitter CST nodes
//! produced by `parser.zig` and constructs `ast.Node` values. Handles every
//! grammar production: expressions, statements, declarations, type annotations,
//! macros, destructuring, parameterized blocks, unsafe blocks, and more.
//!
//! Key responsibilities:
//! - `lowerNode` — dispatch to per-grammar-rule lowering functions
//! - `lowerBinaryExpr` / `lowerUnaryExpr` — operator AST construction
//! - `lowerBlockStmt` — parameterized blocks with params and return annotations
//! - `lowerImportDecl` / `lowerLinkDecl` — import AST construction
//! - `lowerTryStmt` / `lowerJumpStmt` — try/catch/raise AST construction
//! - Macro expansion — `lowerMacroDef` / `lowerMacroCall`
//! - Nizam strict-mode enforcement during lowering

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const c = parser.c;

pub const LowerError = error{
    OutOfMemory,
    StrictNizamViolation,
    UnsupportedNode,
    InvalidSyntax,
};

pub const MacroDef = struct {
    param_names: [][]const u8,
    body_ast: *ast.Node,
};

pub const Lowerer = struct {
    allocator: std.mem.Allocator,
    mode: ast.LanguageMode,
    source: []const u8,
    macros: *std.StringHashMap(MacroDef),
    macro_args: std.StringHashMap(*ast.Node),
    next_hygiene_id: usize,

    pub fn init(allocator: std.mem.Allocator, mode: ast.LanguageMode, source: []const u8, macros: *std.StringHashMap(MacroDef)) Lowerer {
        return .{
            .allocator = allocator,
            .mode = mode,
            .source = source,
            .macros = macros,
            .macro_args = std.StringHashMap(*ast.Node).init(allocator),
            .next_hygiene_id = 1,
        };
    }

    fn getSpan(ts_node: c.TSNode) ast.Span {
        const start_point = c.ts_node_start_point(ts_node);
        const end_point = c.ts_node_end_point(ts_node);
        return .{
            .start_byte = c.ts_node_start_byte(ts_node),
            .end_byte = c.ts_node_end_byte(ts_node),
            .start_row = start_point.row,
            .start_col = start_point.column,
            .end_row = end_point.row,
            .end_col = end_point.column,
        };
    }

    fn extractText(self: *Lowerer, ts_node: c.TSNode) []const u8 {
        const start = c.ts_node_start_byte(ts_node);
        const end = c.ts_node_end_byte(ts_node);
        return self.source[start..end];
    }

    // ── Shared helpers to reduce tree-sitter iteration boilerplate ──

    /// Get the i-th child of a node with the required u32 cast.
    fn tsChild(node: c.TSNode, i: usize) c.TSNode {
        return c.ts_node_child(node, @as(u32, @intCast(i)));
    }

    /// Return the node-type string for a tree-sitter node.
    fn tsType(node: c.TSNode) []const u8 {
        return std.mem.span(c.ts_node_type(node));
    }

    /// Allocate an AST node and initialize it in one step.
    fn createNode(self: *Lowerer, node_type: ast.NodeType, span: ast.Span, data: ast.NodeData) LowerError!*ast.Node {
        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = node_type,
            .span = span,
            .data = data,
        };
        return node;
    }

    pub fn lowerProgram(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        const node_type_str = tsType(ts_node);

        if (!std.mem.eql(u8, node_type_str, "source_file") and !std.mem.eql(u8, node_type_str, "program")) {
            std.debug.print("Invalid root node type: {s}\n", .{node_type_str});
            return error.InvalidSyntax;
        }

        var decls = std.ArrayList(*ast.Node).init(self.allocator);
        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = tsChild(ts_node, i);
            if (c.ts_node_is_named(child)) {
                if (self.lowerNode(child)) |ast_node| {
                    try decls.append(ast_node);
                } else |err| {
                    return err;
                }
            }
        }

        return self.createNode(.Program, getSpan(ts_node), .{
            .Program = .{
                .declarations = try decls.toOwnedSlice(),
            },
        });
    }

    fn lowerMatchStmt(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var subject: ?*ast.Node = null;
        var cases = std.ArrayList(ast.MatchCase).init(self.allocator);
        
        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = tsChild(ts_node, i);
            if (!c.ts_node_is_named(child)) continue;
            
            const c_type = tsType(child);
            if (std.mem.eql(u8, c_type, "comment")) continue;
            if (std.mem.eql(u8, c_type, "match_case")) {
                var pattern: ?*ast.Node = null;
                var guard: ?*ast.Node = null;
                var body: ?*ast.Node = null;
                
                const case_child_count = c.ts_node_child_count(child);
                for (0..case_child_count) |j| {
                    const cc = tsChild(child, j);
                    if (!c.ts_node_is_named(cc)) continue;
                    const cc_type = tsType(cc);
                    if (std.mem.eql(u8, cc_type, "kw_case")) {
                        // ignore
                    } else if (std.mem.eql(u8, cc_type, "block_body") or std.mem.eql(u8, cc_type, "statement") or std.mem.eql(u8, cc_type, "expr_stmt")) {
                        if (std.mem.eql(u8, cc_type, "block_body")) {
                            body = try self.lowerBlockStmt(cc);
                        } else {
                            body = try self.lowerNode(cc);
                        }
                    } else if (pattern == null) {
                        pattern = try self.lowerNode(cc);
                    } else if (guard == null) {
                        guard = try self.lowerNode(cc);
                    }
                }
                
                if (pattern != null and body != null) {
                    try cases.append(ast.MatchCase{
                        .pattern = pattern.?,
                        .guard = guard,
                        .body = body.?,
                    });
                }
            } else if (std.mem.eql(u8, c_type, "kw_match")) {
                // ignore
            } else if (subject == null) {
                subject = try self.lowerNode(child);
            }
        }
        
        if (subject == null) return error.InvalidSyntax;

        return self.createNode(.MatchStmt, getSpan(ts_node), .{
            .MatchStmt = .{
                .subject = subject.?,
                .cases = try cases.toOwnedSlice(),
            },
        });
    }

    pub fn lowerNode(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        const node_type = tsType(ts_node);

        if (std.mem.eql(u8, node_type, "match_stmt")) {
            return self.lowerMatchStmt(ts_node);
        } else if (std.mem.eql(u8, node_type, "var_decl")) {
            return self.lowerVarDecl(ts_node);
        } else if (std.mem.eql(u8, node_type, "class_decl")) {
            if (self.mode == .Nizam) {
                std.debug.print("Error: 'class' is a Mantiq-only feature. Use 'struct' in Nizam strict mode.\n", .{});
                return error.StrictNizamViolation;
            }
            return self.lowerClassDecl(ts_node);
        } else if (std.mem.eql(u8, node_type, "fun_decl")) {
            return self.lowerFunDecl(ts_node);
        } else if (std.mem.eql(u8, node_type, "import_decl")) {
            return self.lowerImportDecl(ts_node);
        } else if (std.mem.eql(u8, node_type, "link_decl")) {
            return self.lowerLinkDecl(ts_node);
        } else if (std.mem.eql(u8, node_type, "if_stmt")) {
            return self.lowerIfStmt(ts_node);
        } else if (std.mem.eql(u8, node_type, "while_stmt")) {
            return self.lowerWhileStmt(ts_node);
        } else if (std.mem.eql(u8, node_type, "pass_stmt")) {
            return self.lowerPassStmt(ts_node);
        } else if (std.mem.eql(u8, node_type, "jump_stmt")) {
            return self.lowerJumpStmt(ts_node);
        } else if (std.mem.eql(u8, node_type, "identifier") or std.mem.eql(u8, node_type, "self_reference")) {
            const name = self.extractText(ts_node);
            if (self.macro_args.get(name)) |arg_node| {
                return try self.cloneNode(arg_node, null, null);
            }
            return self.createNode(.Identifier, getSpan(ts_node), .{
                .Identifier = .{ .name = name },
            });
        } else if (std.mem.eql(u8, node_type, "null_literal")) {
            return self.createNode(.Identifier, getSpan(ts_node), .{
                .Identifier = .{ .name = "None" },
            });
        } else if (std.mem.eql(u8, node_type, "number")) {
            const val_str = self.extractText(ts_node);
const val = std.fmt.parseFloat(f64, val_str) catch {
                std.debug.print("Syntax Error: Invalid numeric literal '{s}' at row {d}, col {d}\n", .{ val_str, getSpan(ts_node).start_row, getSpan(ts_node).start_col });
                return error.InvalidSyntax;
            };
            return self.createNode(.NumberLiteral, getSpan(ts_node), .{
                .NumberLiteral = .{ .value = val },
            });
        } else if (std.mem.eql(u8, node_type, "boolean_literal")) {
            const text = self.extractText(ts_node);
            const val = std.mem.eql(u8, text, "True");
            return self.createNode(.BooleanLiteral, getSpan(ts_node), .{
                .BooleanLiteral = .{ .value = val },
            });
        } else if (std.mem.eql(u8, node_type, "string")) {
            return self.createNode(.StringLiteral, getSpan(ts_node), .{
                .StringLiteral = .{ .value = self.extractText(ts_node) },
            });
        } else if (std.mem.eql(u8, node_type, "interpolated_str")) {
            var parts = std.ArrayList(*ast.Node).init(self.allocator);
            var child_idx: u32 = 0;
            while (child_idx < c.ts_node_child_count(ts_node)) : (child_idx += 1) {
                const child = c.ts_node_child(ts_node, child_idx);
                const c_type_str = tsType(child);
                if (std.mem.eql(u8, c_type_str, "string_content")) {
                    const str_node = try self.createNode(.StringLiteral, getSpan(child), .{
                        .StringLiteral = .{ .value = self.extractText(child) },
                    });
                    try parts.append(str_node);
                } else if (std.mem.eql(u8, c_type_str, "interpolation")) {
                    var expr_child_idx: u32 = 0;
                    while (expr_child_idx < c.ts_node_child_count(child)) : (expr_child_idx += 1) {
                        const expr_child = c.ts_node_child(child, expr_child_idx);
                        if (c.ts_node_is_named(expr_child)) {
                            const lowered_expr = try self.lowerNode(expr_child);
                            try parts.append(lowered_expr);
                        }
                    }
                }
            }
            return self.createNode(.InterpolatedString, getSpan(ts_node), .{
                .InterpolatedString = .{ .parts = try parts.toOwnedSlice() },
            });
        } else if (std.mem.eql(u8, node_type, "binary_expression")) {
            return self.lowerBinaryExpr(ts_node);
        } else if (std.mem.eql(u8, node_type, "call_expression")) {
            return self.lowerCallExpr(ts_node);
        } else if (std.mem.eql(u8, node_type, "cast_expression")) {
            return self.lowerCastExpr(ts_node);
        } else if (std.mem.eql(u8, node_type, "class_decl")) {
            return self.lowerClassDecl(ts_node);
        } else if (std.mem.eql(u8, node_type, "struct_decl")) {
            return self.lowerStructDecl(ts_node);
        } else if (std.mem.eql(u8, node_type, "interface_decl")) {
            return self.lowerInterfaceDecl(ts_node);
        } else if (std.mem.eql(u8, node_type, "enum_decl")) {
            return self.lowerEnumDecl(ts_node);
        } else if (std.mem.eql(u8, node_type, "union_decl")) {
            return self.lowerUnionDecl(ts_node);
        } else if (std.mem.eql(u8, node_type, "member_expression")) {
            return self.lowerMemberExpr(ts_node);
        } else if (std.mem.eql(u8, node_type, "index_expression")) {
            return self.lowerIndexExpr(ts_node);
        } else if (std.mem.eql(u8, node_type, "list_literal")) {
            return self.lowerListLiteral(ts_node);
        } else if (std.mem.eql(u8, node_type, "dict_literal")) {
            return self.lowerDictLiteral(ts_node);
        } else if (std.mem.eql(u8, node_type, "try_expression") or std.mem.eql(u8, node_type, "try_stmt") or std.mem.eql(u8, node_type, "try_expr")) {
            return self.lowerTryStmt(ts_node);
        } else if (std.mem.eql(u8, node_type, "spread_expr")) {
            return self.lowerSpreadExpr(ts_node);
        } else if (std.mem.eql(u8, node_type, "fun_expr") or std.mem.eql(u8, node_type, "anonymous_function") or std.mem.eql(u8, node_type, "lambda_expr")) {
            return self.lowerClosure(ts_node);
        } else if (std.mem.eql(u8, node_type, "for_stmt")) {
            return self.lowerForStmt(ts_node);
        } else if (std.mem.eql(u8, node_type, "spawn_stmt")) {
            return self.lowerSpawnStmt(ts_node);
        } else if (std.mem.eql(u8, node_type, "unsafe_block")) {
            return self.lowerUnsafeBlock(ts_node);
        } else if (std.mem.eql(u8, node_type, "macro_decl")) {
            return self.lowerMacroDecl(ts_node);
        } else if (std.mem.eql(u8, node_type, "macro_invocation")) {
            return self.lowerMacroInvocation(ts_node);
        } else if (std.mem.eql(u8, node_type, "block_stmt") or std.mem.eql(u8, node_type, "block_body")) {
            return self.lowerBlockStmt(ts_node);
        } else if (std.mem.eql(u8, node_type, "with_stmt")) {
            return self.lowerWithStmt(ts_node);
        } else if (std.mem.eql(u8, node_type, "unary_expression") or std.mem.eql(u8, node_type, "async_expression")) {
            return self.lowerUnaryExpr(ts_node);
        } else if (std.mem.eql(u8, node_type, "binary_expression") or std.mem.eql(u8, node_type, "assignment")) {
            return try self.lowerBinaryExpr(ts_node);
        } else if (std.mem.eql(u8, node_type, "ternary")) {
            return try self.lowerTernary(ts_node);
        } else if (std.mem.eql(u8, node_type, "expression") or std.mem.eql(u8, node_type, "primary") or std.mem.eql(u8, node_type, "expression_statement") or std.mem.eql(u8, node_type, "statement") or std.mem.eql(u8, node_type, "expr_stmt") or std.mem.eql(u8, node_type, "collection_item")) {
            // Unwrap expression containers
            const child_count = c.ts_node_child_count(ts_node);
            for (0..child_count) |i| {
                const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
                if (c.ts_node_is_named(child)) {
                    return self.lowerNode(child);
                }
            }
            std.debug.print("Failed lowering unwrapping node type: {s}\n", .{node_type});
            return error.InvalidSyntax;
        } else if (std.mem.eql(u8, node_type, "comment")) {
            return try self.lowerPassStmt(ts_node);
        } else if (std.mem.eql(u8, node_type, "ERROR")) {
            const pt = c.ts_node_start_point(ts_node);
            const str = c.ts_node_string(ts_node);
            std.debug.print("Tree-sitter parse error at line {d}, col {d} (byte {d})\nAST:\n{s}\n", .{pt.row, pt.column, c.ts_node_start_byte(ts_node), str});
            return error.InvalidSyntax;
        } else {
            std.debug.print("FATAL: Unhandled node type in lowerNode: '{s}'\n", .{node_type});
            @panic("Unhandled node type in lowerNode");
        }
    }

    fn lowerImportDecl(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        const span = getSpan(ts_node);
        const child_count = c.ts_node_child_count(ts_node);

        var target_path = std.ArrayList(u8).init(self.allocator);
        var imported_symbols = std.ArrayList([]const u8).init(self.allocator);
        var alias: ?[]const u8 = null;
        var kind: ast.ImportKind = .normal;

        for (0..child_count) |i| {
            const child = tsChild(ts_node, i);
            const c_type = tsType(child);

            const field_name_ptr = c.ts_node_field_name_for_child(ts_node, @as(u32, @intCast(i)));
            if (field_name_ptr != null) {
                const field_name = std.mem.span(field_name_ptr);
                if (std.mem.eql(u8, field_name, "tag")) {
                    const tag_text = self.extractText(child);
                    if (std.mem.eql(u8, tag_text, "vendor")) {
                        kind = .vendor;
                    } else if (std.mem.eql(u8, tag_text, "c")) {
                        kind = .c;
                    } else if (std.mem.eql(u8, tag_text, "path")) {
                        kind = .path;
                    } else if (std.mem.eql(u8, tag_text, "pkg")) {
                        kind = .pkg;
                    }
                    continue;
                }
            }

            if (std.mem.eql(u8, c_type, "string")) {
                const text = self.extractText(child);
                if (text.len >= 2) {
                    try target_path.appendSlice(text[1 .. text.len - 1]);
                }
            } else if (std.mem.eql(u8, c_type, "module_path")) {
                const path_count = c.ts_node_child_count(child);
                for (0..path_count) |p_i| {
                    const p_child = tsChild(child, p_i);
                    if (c.ts_node_is_named(p_child)) {
                        const path_part = self.extractText(p_child);
                        if (target_path.items.len > 0) {
                            try target_path.append('.');
                        }
                        try target_path.appendSlice(path_part);
                    }
                }
            } else if (std.mem.eql(u8, c_type, "identifier")) {
                const ident = self.extractText(child);
                if (i > 0) {
                    const prev_child = tsChild(ts_node, i - 1);
                    if (std.mem.eql(u8, tsType(prev_child), "as")) {
                        alias = ident;
                        continue;
                    }
                }
                try imported_symbols.append(ident);
            }
        }

        return self.createNode(.ImportDecl, span, .{
            .ImportDecl = .{
                .kind = kind,
                .target = try target_path.toOwnedSlice(),
                .imported_symbols = try imported_symbols.toOwnedSlice(),
                .alias = alias,
            },
        });
    }

    fn lowerLinkDecl(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        const span = getSpan(ts_node);
        const child_count = c.ts_node_child_count(ts_node);
        
        var target_path = std.ArrayList(u8).init(self.allocator);
        var kind: ast.ImportKind = .normal;

        for (0..child_count) |i| {
            const child = tsChild(ts_node, i);
            const c_type = tsType(child);

            const field_name_ptr = c.ts_node_field_name_for_child(ts_node, @as(u32, @intCast(i)));
            if (field_name_ptr != null) {
                const field_name = std.mem.span(field_name_ptr);
                if (std.mem.eql(u8, field_name, "tag")) {
                    const tag_text = self.extractText(child);
                    if (std.mem.eql(u8, tag_text, "vendor")) kind = .vendor
                    else if (std.mem.eql(u8, tag_text, "c")) kind = .c
                    else if (std.mem.eql(u8, tag_text, "path")) kind = .path
                    else if (std.mem.eql(u8, tag_text, "pkg")) kind = .pkg;
                    continue;
                }
            }

            if (std.mem.eql(u8, c_type, "string")) {
                const text = self.extractText(child);
                if (text.len >= 2) {
                    try target_path.appendSlice(text[1 .. text.len - 1]);
                }
            }
        }

        return self.createNode(.LinkDecl, span, .{
            .LinkDecl = .{
                .kind = kind,
                .target = try target_path.toOwnedSlice(),
            },
        });
    }

    fn lowerIfStmt(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        const span = getSpan(ts_node);
        const child_count = c.ts_node_child_count(ts_node);

        var root_if: ?*ast.Node = null;
        var current_if: ?*ast.Node = null;
        
        var state: enum { ExpectIf, ExpectCondition, ExpectThen, ExpectElifOrElse, ExpectElifCondition, ExpectElseThen } = .ExpectIf;
        
        var temp_condition: ?*ast.Node = null;

        for (0..child_count) |i| {
            const child = tsChild(ts_node, i);
            const c_type = tsType(child);
            
            if (std.mem.eql(u8, c_type, ":") or std.mem.eql(u8, c_type, "comment")) continue;
            
            switch (state) {
                .ExpectIf => {
                    if (std.mem.eql(u8, c_type, "if")) state = .ExpectCondition;
                },
                .ExpectCondition => {
                    if (c.ts_node_is_named(child)) {
                        temp_condition = try self.lowerNode(child);
                        state = .ExpectThen;
                    }
                },
                .ExpectThen => {
                    if (c.ts_node_is_named(child)) {
                        const branch = try self.lowerIfBranch(child);
                        
                        const if_node = try self.createNode(.IfStmt, getSpan(child), .{
                            .IfStmt = .{
                                .condition = temp_condition.?,
                                .then_branch = branch,
                                .else_branch = null,
                            },
                        });
                        
                        if (root_if == null) {
                            root_if = if_node;
                            if_node.span = span;
                        } else {
                            current_if.?.data.IfStmt.else_branch = if_node;
                        }
                        current_if = if_node;
                        state = .ExpectElifOrElse;
                    }
                },
                .ExpectElifOrElse => {
                    if (std.mem.eql(u8, c_type, "elif")) {
                        state = .ExpectElifCondition;
                    } else if (std.mem.eql(u8, c_type, "else")) {
                        state = .ExpectElseThen;
                    }
                },
                .ExpectElifCondition => {
                    if (c.ts_node_is_named(child)) {
                        temp_condition = try self.lowerNode(child);
                        state = .ExpectThen;
                    }
                },
                .ExpectElseThen => {
                    if (c.ts_node_is_named(child)) {
                        const branch = try self.lowerIfBranch(child);
                        current_if.?.data.IfStmt.else_branch = branch;
                        state = .ExpectElifOrElse;
                    }
                }
            }
        }
        
        return root_if orelse error.InvalidSyntax;
    }

    fn lowerTernary(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        const then_child = c.ts_node_named_child(ts_node, 0);
        const cond_child = c.ts_node_named_child(ts_node, 1);
        const else_child = c.ts_node_named_child(ts_node, 2);
        
        const then_node = try self.lowerNode(then_child);
        const cond_node = try self.lowerNode(cond_child);
        const else_node = try self.lowerNode(else_child);
        
        const if_node = try self.allocator.create(ast.Node);
        if_node.* = .{
            .node_type = .IfStmt,
            .span = getSpan(ts_node),
            .data = .{
                .IfStmt = .{
                    .condition = cond_node,
                    .then_branch = then_node,
                    .else_branch = else_node,
                }
            }
        };
        return if_node;
    }

    fn lowerIfBranch(self: *Lowerer, child: c.TSNode) LowerError!*ast.Node {
        const c_type = std.mem.span(c.ts_node_type(child));
        if (std.mem.eql(u8, c_type, "block_body")) {
            var body_stmts = std.ArrayList(*ast.Node).init(self.allocator);
            const body_child_count = c.ts_node_child_count(child);
            for (0..body_child_count) |b_i| {
                const stmt_child = c.ts_node_child(child, @as(u32, @intCast(b_i)));
                if (c.ts_node_is_named(stmt_child)) {
                    const stmt_ast = try self.lowerNode(stmt_child);
                    try body_stmts.append(stmt_ast);
                }
            }
            const block_node = try self.allocator.create(ast.Node);
            block_node.* = .{
                .node_type = .BlockStmt,
                .span = getSpan(child),
                .data = .{ .BlockStmt = .{ .statements = try body_stmts.toOwnedSlice() } },
            };
            return block_node;
        } else {
            return try self.lowerNode(child);
        }
    }

    fn lowerJumpStmt(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        const span = getSpan(ts_node);
        const text = self.extractText(ts_node);

        if (std.mem.startsWith(u8, text, "return")) {
            var values = std.ArrayList(*ast.Node).init(self.allocator);
            const child_count = c.ts_node_child_count(ts_node);
            for (0..child_count) |i| {
                const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
                if (c.ts_node_is_named(child)) {
                    try values.append(try self.lowerNode(child));
                }
            }

            const ret_node = try self.allocator.create(ast.Node);
            ret_node.* = .{
                .node_type = .ReturnStmt,
                .span = span,
                .data = .{
                    .ReturnStmt = .{
                        .values = if (values.items.len > 0) try values.toOwnedSlice() else null,
                    },
                },
            };
            return ret_node;
        }

        if (std.mem.startsWith(u8, text, "break")) {
            const break_node = try self.allocator.create(ast.Node);
            break_node.* = .{
                .node_type = .BreakStmt,
                .span = span,
                .data = .{ .BreakStmt = .{} },
            };
            return break_node;
        }

        if (std.mem.startsWith(u8, text, "continue")) {
            const continue_node = try self.allocator.create(ast.Node);
            continue_node.* = .{
                .node_type = .ContinueStmt,
                .span = span,
                .data = .{ .ContinueStmt = .{} },
            };
            return continue_node;
        }

        if (std.mem.startsWith(u8, text, "raise")) {
            var value: ?*ast.Node = null;
            const child_count = c.ts_node_child_count(ts_node);
            for (0..child_count) |i| {
                const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
                if (c.ts_node_is_named(child)) {
                    value = try self.lowerNode(child);
                    break;
                }
            }
            if (value == null) return error.InvalidSyntax;

            const raise_node = try self.allocator.create(ast.Node);
            raise_node.* = .{
                .node_type = .ThrowStmt,
                .span = span,
                .data = .{ .ThrowStmt = .{ .value = value.? } },
            };
            return raise_node;
        }

        return error.InvalidSyntax;
    }

    fn lowerTryStmt(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var body: ?*ast.Node = null;
        var catch_binding: ?[]const u8 = null;
        var catch_body: ?*ast.Node = null;

        const child_count = c.ts_node_child_count(ts_node);
        var in_except = false;
        
        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            const child_type = std.mem.span(c.ts_node_type(child));
            
            if (std.mem.eql(u8, child_type, "comment")) continue;
            if (std.mem.eql(u8, child_type, "except") or std.mem.eql(u8, child_type, "catch")) { // from grammar keyword
                in_except = true;
            } else if (std.mem.eql(u8, child_type, "block_body")) {
                var body_stmts = std.ArrayList(*ast.Node).init(self.allocator);
                const body_child_count = c.ts_node_child_count(child);
                for (0..body_child_count) |b_i| {
                    const stmt_child = c.ts_node_child(child, @as(u32, @intCast(b_i)));
                    if (c.ts_node_is_named(stmt_child)) {
                        try body_stmts.append(try self.lowerNode(stmt_child));
                    }
                }
                const block_node = try self.allocator.create(ast.Node);
                block_node.* = .{
                    .node_type = .BlockStmt,
                    .span = getSpan(child),
                    .data = .{ .BlockStmt = .{ .statements = try body_stmts.toOwnedSlice() } },
                };
                
                if (in_except) {
                    catch_body = block_node;
                } else {
                    body = block_node;
                }
            } else if (c.ts_node_is_named(child) and std.mem.eql(u8, child_type, "identifier") and in_except) {
                catch_binding = self.extractText(child);
            } else if (c.ts_node_is_named(child) and !in_except and body == null and !std.mem.eql(u8, child_type, "kw_try")) {
                body = try self.lowerNode(child);
            }
        }
        
        if (body == null) return error.InvalidSyntax;

        const try_node = try self.allocator.create(ast.Node);
        try_node.* = .{
            .node_type = .TryStmt,
            .span = getSpan(ts_node),
            .data = .{
                .TryStmt = .{
                    .body = body.?,
                    .catch_binding = catch_binding,
                    .catch_body = catch_body,
                },
            },
        };
        return try_node;
    }

    fn lowerPassStmt(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        return self.createNode(.PassStmt, getSpan(ts_node), .{ .PassStmt = .{} });
    }

    fn lowerWhileStmt(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var condition: ?*ast.Node = null;
        var body: ?*ast.Node = null;

        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = tsChild(ts_node, i);
            if (std.mem.eql(u8, tsType(child), "comment")) continue;
            if (c.ts_node_is_named(child)) {
                if (condition == null) {
                    condition = try self.lowerNode(child);
                } else if (body == null) {
                    body = try self.lowerIfBranch(child);
                }
            }
        }

        if (condition == null or body == null) {
            return error.InvalidSyntax;
        }

        return self.createNode(.WhileStmt, getSpan(ts_node), .{
            .WhileStmt = .{
                .condition = condition.?,
                .body = body.?,
            },
        });
    }

    fn lowerTypeList(self: *Lowerer, type_list_node: c.TSNode) LowerError![]ast.TypeAnnotation {
        const child_count = c.ts_node_child_count(type_list_node);
        var nodes = std.ArrayList(c.TSNode).init(self.allocator);
        defer nodes.deinit();
        for (0..child_count) |i| {
            const child = tsChild(type_list_node, i);
            const c_type = tsType(child);
            const is_type_kw = std.mem.eql(u8, c_type, "fn") or
                std.mem.eql(u8, c_type, "ref") or
                std.mem.eql(u8, c_type, "mut") or
                std.mem.eql(u8, c_type, "life");
            if (c.ts_node_is_named(child) or is_type_kw) {
                try nodes.append(child);
            }
        }
        return self.lowerTypeListFromNodes(nodes.items);
    }

    fn lowerSingleTypeFromNodes(self: *Lowerer, nodes: []const c.TSNode, index: *usize) LowerError!ast.TypeAnnotation {
        var annot = ast.TypeAnnotation{ .name = "Any" };
        
        // Consume modifiers
        while (index.* < nodes.len) {
            const mod_child = nodes[index.*];
            const m_type = tsType(mod_child);
            if (std.mem.eql(u8, m_type, "ref")) {
                annot.is_ref = true;
                index.* += 1;
            } else if (std.mem.eql(u8, m_type, "mut")) {
                annot.is_mut = true;
                index.* += 1;
            } else if (std.mem.eql(u8, m_type, "life")) {
                annot.is_ref = true;
                const lt_node = c.ts_node_child_by_field_name(mod_child, "lifetime_args", 13);
                if (!c.ts_node_is_null(lt_node)) {
                    annot.lifetime = try self.allocator.dupe(u8, self.extractText(lt_node));
                }
                index.* += 1;
            } else {
                break;
            }
        }

        if (index.* >= nodes.len) return annot;

        const base_child = nodes[index.*];
        const b_type = tsType(base_child);

        if (std.mem.eql(u8, b_type, "identifier")) {
            annot.name = self.extractText(base_child);
            index.* += 1;
            // Check if the next child is generic_params
            if (index.* < nodes.len) {
                const next_child = nodes[index.*];
                if (std.mem.eql(u8, tsType(next_child), "generic_params")) {
                    const nested_list = c.ts_node_named_child(next_child, 0);
                    if (!c.ts_node_is_null(nested_list)) {
                        annot.generics = try self.lowerTypeList(nested_list);
                    }
                    index.* += 1;
                }
            }
        } else if (std.mem.eql(u8, b_type, "tuple_type_list")) {
            annot.name = "Tuple";
            var gen_list = std.ArrayList(ast.TypeAnnotation).init(self.allocator);
            defer gen_list.deinit();
            const tl_count = c.ts_node_child_count(base_child);
            for (0..tl_count) |j| {
                const tl_child = c.ts_node_child(base_child, @as(u32, @intCast(j)));
                if (c.ts_node_is_named(tl_child)) {
                    const gen_annot = try self.lowerTypeAnnotation(tl_child);
                    try gen_list.append(gen_annot);
                }
            }
            if (gen_list.items.len > 0) {
                annot.generics = try self.allocator.dupe(ast.TypeAnnotation, gen_list.items);
            }
            index.* += 1;
        } else if (std.mem.eql(u8, b_type, "fn")) {
            annot.name = "fn";
            index.* += 1;
            // Consume param list
            if (index.* < nodes.len) {
                const p_child = nodes[index.*];
                if (std.mem.eql(u8, tsType(p_child), "type_list")) {
                    annot.params = try self.lowerTypeList(p_child);
                    index.* += 1;
                }
            }
            // Consume return type
            if (index.* < nodes.len) {
                const rt_annot = try self.lowerSingleTypeFromNodes(nodes, index);
                const rt_ptr = try self.allocator.create(ast.TypeAnnotation);
                rt_ptr.* = rt_annot;
                annot.return_type = rt_ptr;
            }
        } else if (std.mem.eql(u8, b_type, "number") or std.mem.eql(u8, b_type, "string") or std.mem.eql(u8, b_type, "boolean_literal")) {
            annot.name = self.extractText(base_child);
            index.* += 1;
        } else {
            const nested = try self.lowerTypeAnnotation(base_child);
            annot = nested;
            index.* += 1;
        }

        return annot;
    }

    fn lowerTypeListFromNodes(self: *Lowerer, nodes: []const c.TSNode) LowerError![]ast.TypeAnnotation {
        var annots = std.ArrayList(ast.TypeAnnotation).init(self.allocator);
        errdefer annots.deinit();

        var i: usize = 0;
        while (i < nodes.len) {
            const child = nodes[i];
            const c_type = tsType(child);
            // Ignore commas
            if (std.mem.eql(u8, c_type, ",")) {
                i += 1;
                continue;
            }

            const annot = try self.lowerSingleTypeFromNodes(nodes, &i);
            try annots.append(annot);
        }

        return try annots.toOwnedSlice();
    }

    fn lowerTypeAnnotation(self: *Lowerer, ts_node: c.TSNode) LowerError!ast.TypeAnnotation {
        const text = self.extractText(ts_node);
        if (ast.show_debug) {
            std.debug.print("LOWERTYPE: type={s}, text={s}\n", .{tsType(ts_node), text});
        }
        
        const ts_type = tsType(ts_node);
        if (std.mem.eql(u8, ts_type, "identifier")) {
            return ast.TypeAnnotation{ .name = self.extractText(ts_node) };
        }

        if (std.mem.eql(u8, ts_type, "const_generic")) {
            var annot = ast.TypeAnnotation{ .name = self.extractText(ts_node) };
            const cc_count = c.ts_node_child_count(ts_node);
            for (0..cc_count) |i| {
                const cc_child = tsChild(ts_node, i);
                if (c.ts_node_is_named(cc_child)) {
                    annot.name = self.extractText(cc_child);
                    return annot;
                }
            }
            return annot;
        }

        if (std.mem.eql(u8, ts_type, "type_annotation") or std.mem.eql(u8, ts_type, "return_annotation")) {
            const child_count = c.ts_node_child_count(ts_node);
            for (0..child_count) |i| {
                const child = tsChild(ts_node, i);
                if (c.ts_node_is_named(child)) {
                    const c_type = tsType(child);
                    if (std.mem.eql(u8, c_type, "type_annotation") or std.mem.eql(u8, c_type, "return_annotation")) {
                        return self.lowerTypeAnnotation(child);
                    }
                }
            }
        }

        var nodes = std.ArrayList(c.TSNode).init(self.allocator);
        defer nodes.deinit();
        
        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = tsChild(ts_node, i);
            const c_type = tsType(child);
            const is_type_kw = std.mem.eql(u8, c_type, "fn") or
                std.mem.eql(u8, c_type, "ref") or
                std.mem.eql(u8, c_type, "mut") or
                std.mem.eql(u8, c_type, "life");
            if (c.ts_node_is_named(child) or is_type_kw) {
                if (std.mem.eql(u8, c_type, "type_annotation") or std.mem.eql(u8, c_type, "return_annotation")) {
                    return self.lowerTypeAnnotation(child);
                }
                
                const field_name_ptr = c.ts_node_field_name_for_child(ts_node, @as(u32, @intCast(i)));
                if (field_name_ptr != null) {
                    const field_name = std.mem.span(field_name_ptr);
                    if (std.mem.eql(u8, field_name, "lifetime_args")) {
                        continue;
                    }
                }
                
                try nodes.append(child);
            }
        }

        const parsed = try self.lowerTypeListFromNodes(nodes.items);
        if (parsed.len > 0) {
            return parsed[0];
        }
        return ast.TypeAnnotation{ .name = "Any" };
    }

    fn lowerVarDecl(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var names = std.ArrayList([]const u8).init(self.allocator);
        var type_annots = std.ArrayList(?ast.TypeAnnotation).init(self.allocator);
        var initializers = std.ArrayList(*ast.Node).init(self.allocator);
        const is_mut = false;
        var is_static = false;

        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = tsChild(ts_node, i);
            const c_type = tsType(child);
            if (std.mem.eql(u8, c_type, "var_modifier")) {
                const mod_text = self.extractText(child);
                if (std.mem.eql(u8, mod_text, "static")) {
                    is_static = true;
                }
            } else if (c.ts_node_is_named(child)) {
                const child_type = tsType(child);
                if (std.mem.eql(u8, child_type, "typed_var")) {
                    var name: []const u8 = "unknown";
                    var annot: ?ast.TypeAnnotation = null;
                    const tv_count = c.ts_node_child_count(child);
                    for (0..tv_count) |j| {
                        const tv_child = tsChild(child, j);
                        if (c.ts_node_is_named(tv_child)) {
                            const tv_type = tsType(tv_child);
                            if (std.mem.eql(u8, tv_type, "identifier")) {
                                name = self.extractText(tv_child);
                            } else if (std.mem.eql(u8, tv_type, "type_annotation")) {
                                annot = try self.lowerTypeAnnotation(tv_child);
                            }
                        }
                    }
                    try names.append(name);
                    try type_annots.append(annot);
                } else if (std.mem.eql(u8, child_type, "identifier")) {
                    try names.append(self.extractText(child));
                    try type_annots.append(null);
                } else if (std.mem.eql(u8, child_type, "type_annotation")) {
                    const annot = try self.lowerTypeAnnotation(child);
                    for (type_annots.items, 0..) |*existing, idx| {
                        if (existing.* == null) {
                            type_annots.items[idx] = annot;
                        }
                    }
                } else {
                    const init_node = try self.lowerNode(child);
                    try initializers.append(init_node);
                }
            }
        }

        return self.createNode(.VarDecl, getSpan(ts_node), .{
            .VarDecl = .{
                .names = try names.toOwnedSlice(),
                .type_annots = try type_annots.toOwnedSlice(),
                .initializers = if (initializers.items.len > 0) try initializers.toOwnedSlice() else null,
                .is_mut = is_mut,
                .is_static = is_static,
            },
        });
    }

    fn lowerFunDecl(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        // Find the 'named_function' child and any modifiers
        const child_count = c.ts_node_child_count(ts_node);
        var named_fn_node = ts_node;
        var is_async = false;
        var is_extern = false;
        var is_inline = false;
        for (0..child_count) |i| {
            const child = tsChild(ts_node, i);
            const c_type = tsType(child);
            if (std.mem.eql(u8, c_type, "async")) {
                is_async = true;
            } else if (std.mem.eql(u8, c_type, "fun_modifier")) {
                const mod_text = self.extractText(child);
                if (std.mem.eql(u8, mod_text, "async")) {
                    is_async = true;
                } else if (std.mem.eql(u8, mod_text, "extern")) {
                    is_extern = true;
                } else if (std.mem.eql(u8, mod_text, "inline")) {
                    is_inline = true;
                }
            } else if (std.mem.eql(u8, c_type, "named_function")) {
                named_fn_node = child;
            }
        }

        var name: []const u8 = "unknown";
        // The first named child of 'named_function' is usually the identifier
        const name_child = c.ts_node_child(named_fn_node, 0);
        if (c.ts_node_is_named(name_child)) {
            name = self.extractText(name_child);
        }

        // We will fake parsing the parameters and body for the sake of the Sema test
        // Ideally we iterate children and parse `parameters` and `block_body`

        var params = std.ArrayList(*ast.Node).init(self.allocator);
        var param_types = std.ArrayList(?ast.TypeAnnotation).init(self.allocator);
        var param_names = std.ArrayList([]const u8).init(self.allocator);
        var default_values = std.ArrayList(?*ast.Node).init(self.allocator);
        var body_stmts = std.ArrayList(*ast.Node).init(self.allocator);
        var return_type: ?ast.TypeAnnotation = null;
        var is_fun_variadic = false;
        var generic_params_list: ?std.ArrayList([]const u8) = null;

        // Scan children of named_function to find parameters and body
        const nf_child_count = c.ts_node_child_count(named_fn_node);
        for (0..nf_child_count) |i| {
            const child = c.ts_node_child(named_fn_node, @as(u32, @intCast(i)));
            const c_type = std.mem.span(c.ts_node_type(child));
            if (std.mem.eql(u8, c_type, "return_annotation")) {
                return_type = try self.lowerTypeAnnotation(child);
            } else if (std.mem.eql(u8, c_type, "generic_params")) {
                generic_params_list = std.ArrayList([]const u8).init(self.allocator);
                const gp_child_count = c.ts_node_child_count(child);
                for (0..gp_child_count) |gp_i| {
                    const type_list_node = c.ts_node_child(child, @as(u32, @intCast(gp_i)));
                    if (std.mem.eql(u8, std.mem.span(c.ts_node_type(type_list_node)), "type_list")) {
                        const tl_count = c.ts_node_child_count(type_list_node);
                        for (0..tl_count) |tl_i| {
                            const tl_child = c.ts_node_child(type_list_node, @as(u32, @intCast(tl_i)));
                            if (std.mem.eql(u8, std.mem.span(c.ts_node_type(tl_child)), "identifier")) {
                                const t_name = self.extractText(tl_child);
                                try generic_params_list.?.append(t_name);
                            }
                        }
                    }
                }
            } else if (std.mem.eql(u8, c_type, "typed_params")) {
                const param_count = c.ts_node_child_count(child);
                for (0..param_count) |p_i| {
                    const p_child = c.ts_node_child(child, @as(u32, @intCast(p_i)));
                    if (std.mem.eql(u8, std.mem.span(c.ts_node_type(p_child)), "param_decl")) {
                        const id_node = c.ts_node_child_by_field_name(p_child, "name", 4);
                        const type_node = c.ts_node_child_by_field_name(p_child, "type", 4);
                        const default_node = c.ts_node_child_by_field_name(p_child, "default_value", 13);
                        ast.debugPrint("DEBUG: param_decl name field exists: {}, type field exists: {}\n", .{!c.ts_node_is_null(id_node), !c.ts_node_is_null(type_node)});
                        if (!c.ts_node_is_null(id_node)) ast.debugPrint("DEBUG: param name is '{s}'\n", .{self.extractText(id_node)});
                        
                        var is_variadic = false;
                        for (0..c.ts_node_child_count(p_child)) |pd_i| {
                            const pd_child = c.ts_node_child(p_child, @as(u32, @intCast(pd_i)));
                            if (std.mem.eql(u8, std.mem.span(c.ts_node_type(pd_child)), "...")) {
                                is_variadic = true;
                                break;
                            }
                        }
                        
                        if (is_variadic) {
                            is_fun_variadic = true;
                        }
                        
                        if (!c.ts_node_is_null(id_node)) {
                            const param_ast = try self.lowerNode(id_node);
                            const p_name = self.extractText(id_node);
                            try param_names.append(p_name);
                            
                            if (!c.ts_node_is_null(type_node)) {
                                ast.debugPrint("DEBUG: lowerFunDecl type_node type is '{s}'\n", .{std.mem.span(c.ts_node_type(type_node))});
                                const type_annot = try self.lowerTypeAnnotation(type_node);
                                try param_types.append(type_annot);
                            } else {
                                try param_types.append(null);
                            }
                            
                            if (!c.ts_node_is_null(default_node)) {
                                var actual_def_node = default_node;
                                if (std.mem.eql(u8, std.mem.span(c.ts_node_type(actual_def_node)), "=")) {
                                    actual_def_node = c.ts_node_next_sibling(actual_def_node);
                                }
                                const def_ast = try self.lowerNode(actual_def_node);
                                try default_values.append(def_ast);
                            } else {
                                try default_values.append(null);
                            }
                            
                            try params.append(param_ast);
                        } else {
                            std.debug.print("Compile Error: Could not find identifier for parameter in function '{s}'\n", .{name});
                            return error.InvalidSyntax;
                        }
                    }
                }
                if (params.items.len > 255) {
                    std.debug.print("Compile Error: Function '{s}' exceeds the maximum allowed 255 parameters. Found {d} parameters.\n", .{name, params.items.len});
                    return error.InvalidSyntax;
                }
            } else if (std.mem.eql(u8, c_type, "block_body")) {
                const body_child_count = c.ts_node_child_count(child);
                for (0..body_child_count) |b_i| {
                    const stmt_child = c.ts_node_child(child, @as(u32, @intCast(b_i)));
                    if (c.ts_node_is_named(stmt_child)) {
                        const stmt_ast = try self.lowerNode(stmt_child);
                        try body_stmts.append(stmt_ast);
                    }
                }
            }
        }

        const body_node = try self.allocator.create(ast.Node);
        body_node.* = .{
            .node_type = .BlockStmt,
            .span = getSpan(named_fn_node),
            .data = .{
                .BlockStmt = .{
                    .statements = try body_stmts.toOwnedSlice(),
                },
            },
        };

        var has_self = false;
        if (params.items.len > 0) {
            const first_param = params.items[0];
            if (first_param.node_type == .Identifier and std.mem.eql(u8, first_param.data.Identifier.name, "self")) {
                has_self = true;
            }
        }

        if (is_fun_variadic and param_types.items.len > 0) {
            const last_idx = param_types.items.len - 1;
            if (param_types.items[last_idx]) |base_type| {
                var list_type = ast.TypeAnnotation{ .name = "List" };
                var gens = try self.allocator.alloc(ast.TypeAnnotation, 1);
                gens[0] = base_type;
                list_type.generics = gens;
                param_types.items[last_idx] = list_type;
            }
        }

        const fun_node = try self.allocator.create(ast.Node);
        fun_node.* = .{
            .node_type = .FunDecl,
            .span = getSpan(ts_node),
            .data = .{
                .FunDecl = .{
                    .name = name,
                    .generic_params = if (generic_params_list) |*l| try l.toOwnedSlice() else null,
                    .params = try params.toOwnedSlice(),
                    .param_names = try param_names.toOwnedSlice(),
                    .param_types = try param_types.toOwnedSlice(),
                    .default_values = try default_values.toOwnedSlice(),
                    .body = body_node,
                    .is_async = is_async,
                    .is_extern = is_extern,
                    .is_inline = is_inline,
                    .return_type = return_type,
                    .has_self = has_self,
                    .is_variadic = is_fun_variadic,
                },
            },
        };
        return fun_node;
    }

    fn lowerCallExpr(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var callee: ?*ast.Node = null;
        var generic_args: ?[]ast.TypeAnnotation = null;
        var args = std.ArrayList(*ast.Node).init(self.allocator);

        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            const child_type = std.mem.span(c.ts_node_type(child));

            if (c.ts_node_is_named(child)) {
                if (std.mem.eql(u8, child_type, "generic_params")) {
                    var gens = std.ArrayList(ast.TypeAnnotation).init(self.allocator);
                    const list_node = c.ts_node_child(child, 1); // type_list
                    if (c.ts_node_is_named(list_node)) {
                        const count = c.ts_node_child_count(list_node);
                        for (0..count) |g| {
                            const g_child = c.ts_node_child(list_node, @as(u32, @intCast(g)));
                            if (c.ts_node_is_named(g_child)) {
                                try gens.append(try self.lowerTypeAnnotation(g_child));
                            }
                        }
                    }
                    if (gens.items.len > 0) generic_args = try gens.toOwnedSlice();
                    ast.debugPrint("LOWER CALL EXPR: generic args count: {any}\n", .{if (generic_args) |ga| ga.len else 0});
                } else if (std.mem.eql(u8, child_type, "argument_list") or std.mem.eql(u8, child_type, "arguments")) {
                    const arg_count = c.ts_node_child_count(child);
                    for (0..arg_count) |a| {
                        const arg_child = c.ts_node_child(child, @as(u32, @intCast(a)));
                        if (c.ts_node_is_named(arg_child)) {
                            var arg_ast = try self.lowerNode(arg_child);
                            if (arg_ast.node_type == .BinaryExpr and std.mem.eql(u8, arg_ast.data.BinaryExpr.operator, "=")) {
                                const left = arg_ast.data.BinaryExpr.left;
                                if (left.node_type == .Identifier) {
                                    const kw_node = try self.allocator.create(ast.Node);
                                    kw_node.* = .{
                                        .node_type = .KeywordArg,
                                        .span = arg_ast.span,
                                        .data = .{ .KeywordArg = .{
                                            .name = left.data.Identifier.name,
                                            .value = arg_ast.data.BinaryExpr.right,
                                        } }
                                    };
                                    arg_ast = kw_node;
                                }
                            }
                            try args.append(arg_ast);
                        }
                    }
                } else if (callee == null) {
                    callee = try self.lowerNode(child);
                } else {
                    var arg_ast = try self.lowerNode(child);
                    if (arg_ast.node_type == .BinaryExpr and std.mem.eql(u8, arg_ast.data.BinaryExpr.operator, "=")) {
                        const left = arg_ast.data.BinaryExpr.left;
                        if (left.node_type == .Identifier) {
                            const kw_node = try self.allocator.create(ast.Node);
                            kw_node.* = .{
                                .node_type = .KeywordArg,
                                .span = arg_ast.span,
                                .data = .{ .KeywordArg = .{
                                    .name = left.data.Identifier.name,
                                    .value = arg_ast.data.BinaryExpr.right,
                                } }
                            };
                            arg_ast = kw_node;
                        }
                    }
                    try args.append(arg_ast);
                }
            }
        }

        if (callee == null) return error.InvalidSyntax;

        const call_node = try self.allocator.create(ast.Node);

        if (callee.?.node_type == .MemberExpr) {
            call_node.* = .{
                .node_type = .MethodCallExpr,
                .span = getSpan(ts_node),
                .data = .{
                    .MethodCallExpr = .{
                        .receiver = callee.?.data.MemberExpr.object,
                        .method_name = callee.?.data.MemberExpr.property,
                        .arguments = try args.toOwnedSlice(),
                        .is_dynamic = false, // Will be set in typecheck
                    },
                },
            };
        } else {
            call_node.* = .{
                .node_type = .CallExpr,
                .span = getSpan(ts_node),
                .data = .{
                    .CallExpr = .{
                        .callee = callee.?,
                        .arguments = try args.toOwnedSlice(),
                        .generic_args = generic_args,
                    },
                },
            };
        }
        return call_node;
    }

    fn lowerMemberExpr(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        const object_node = c.ts_node_child_by_field_name(ts_node, "object", 6);
        const property_node = c.ts_node_child_by_field_name(ts_node, "property", 8);

        if (c.ts_node_is_null(object_node) or c.ts_node_is_null(property_node)) {
            return error.InvalidSyntax;
        }

        const object = try self.lowerNode(object_node);
        const property = self.extractText(property_node);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .MemberExpr,
            .span = getSpan(ts_node),
            .data = .{
                .MemberExpr = .{
                    .object = object,
                    .property = property,
                },
            },
        };
        return node;
    }

    fn lowerIndexExpr(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        const count = c.ts_node_child_count(ts_node);
        if (count < 4) return error.InvalidSyntax;

        // Tree-sitter struct:
        // object [ expression ]
        const object_node = c.ts_node_child(ts_node, 0);
        // child 1 is '['
        const index_node = c.ts_node_child(ts_node, 2);
        
        const object = try self.lowerNode(object_node);
        const index = try self.lowerNode(index_node);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .IndexExpr,
            .span = getSpan(ts_node),
            .data = .{
                .IndexExpr = .{
                    .object = object,
                    .index = index,
                },
            },
        };
        return node;
    }

    fn lowerClassDecl(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var name: []const u8 = "unknown";
        var base_class: ?[]const u8 = null;
        var interfaces = std.ArrayList([]const u8).init(self.allocator);
        var fields = std.ArrayList(*ast.Node).init(self.allocator);
        var methods = std.ArrayList(*ast.Node).init(self.allocator);

        const child_count = c.ts_node_child_count(ts_node);
        var seen_name = false;

        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            if (c.ts_node_is_named(child)) {
                const child_type = std.mem.span(c.ts_node_type(child));
                if (std.mem.eql(u8, child_type, "identifier") or std.mem.eql(u8, child_type, "type_identifier")) {
                    if (!seen_name) {
                        name = self.extractText(child);
                        seen_name = true;
                    } else if (base_class == null) {
                        base_class = self.extractText(child);
                    } else {
                        try interfaces.append(self.extractText(child));
                    }
                } else if (std.mem.eql(u8, child_type, "block_body")) {
                    const body_count = c.ts_node_child_count(child);
                    var b: usize = 0;
                    while (b < body_count) : (b += 1) {
                        const b_child = c.ts_node_child(child, @as(u32, @intCast(b)));
                        if (c.ts_node_is_named(b_child)) {
                            const b_type = std.mem.span(c.ts_node_type(b_child));
                            if (std.mem.eql(u8, b_type, "var_decl")) {
                                const field = try self.lowerFieldDecl(b_child);
                                try fields.append(field);
                            } else if (std.mem.eql(u8, b_type, "ERROR") or std.mem.eql(u8, b_type, "statement") or std.mem.eql(u8, b_type, "expression_statement")) {
                                const err_text = self.extractText(b_child);
                                var it = std.mem.tokenizeAny(u8, err_text, " \t\r\n");
                                var words = std.ArrayList([]const u8).init(self.allocator);
                                while (it.next()) |word| {
                                    try words.append(word);
                                }
                                
                                var field_name: ?[]const u8 = null;
                                var type_str: []const u8 = "Any";
                                var acc_mod: []const u8 = "public";
                                
                                var as_idx: ?usize = null;
                                for (words.items, 0..) |w, idx_w| {
                                    if (std.mem.eql(u8, w, "as")) {
                                        as_idx = idx_w;
                                        break;
                                    }
                                }
                                
                                if (as_idx) |idx| {
                                    if (idx > 0) field_name = words.items[idx - 1];
                                    
                                    if (idx + 1 < words.items.len) {
                                        type_str = words.items[idx + 1];
                                    } else {
                                        if (b + 1 < body_count) {
                                            const next_child = c.ts_node_child(child, @as(u32, @intCast(b + 1)));
                                            const next_type = std.mem.span(c.ts_node_type(next_child));
                                            if (std.mem.eql(u8, next_type, "statement") or std.mem.eql(u8, next_type, "expression")) {
                                                type_str = self.extractText(next_child);
                                                b += 1;
                                            }
                                        }
                                    }
                                    
                                    if (idx > 1) {
                                        if (std.mem.eql(u8, words.items[0], "public") or std.mem.eql(u8, words.items[0], "private")) {
                                            acc_mod = words.items[0];
                                        }
                                    }
                                    
                                    if (field_name) |fname| {
                                        const field_node = try self.allocator.create(ast.Node);
                                        field_node.* = .{
                                            .node_type = .FieldDecl,
                                            .span = getSpan(b_child),
                                            .inferred_type = null,
                                            .data = .{
                                                .FieldDecl = .{
                                                    .name = fname,
                                                    .access_modifier = acc_mod,
                                                    .is_mutable = false,
                                                    .type_annot = .{ .name = type_str },
                                                    .default_value = null,
                                                },
                                            },
                                        };
                                        try fields.append(field_node);
                                    }
                                }
                            } else if (std.mem.eql(u8, b_type, "function_decl") or std.mem.eql(u8, b_type, "fun_decl")) {
                                const method = try self.lowerNode(b_child);
                                try methods.append(method);
                            }
                        }
                    }
                }
            }
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .ClassDecl,
            .span = getSpan(ts_node),
            .data = .{
                .ClassDecl = .{
                    .name = name,
                    .base_class = base_class,
                    .interfaces = try interfaces.toOwnedSlice(),
                    .fields = try fields.toOwnedSlice(),
                    .methods = try methods.toOwnedSlice(),
                },
            },
        };
        return node;
    }

    fn lowerStructDecl(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var name: []const u8 = "unknown";
        var generic_params: ?[][]const u8 = null;
        var fields = std.ArrayList(*ast.Node).init(self.allocator);
        var methods = std.ArrayList(*ast.Node).init(self.allocator);

        const child_count = c.ts_node_child_count(ts_node);

        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            if (c.ts_node_is_named(child)) {
                const child_type = std.mem.span(c.ts_node_type(child));
                if (std.mem.eql(u8, child_type, "identifier") or std.mem.eql(u8, child_type, "type_identifier")) {
                    name = self.extractText(child);
                } else if (std.mem.eql(u8, child_type, "generic_params")) {
                    var gens = std.ArrayList([]const u8).init(self.allocator);
                    const list_node = c.ts_node_child(child, 1); // type_list
                    if (c.ts_node_is_named(list_node)) {
                        const count = c.ts_node_child_count(list_node);
                        for (0..count) |g| {
                            const g_child = c.ts_node_child(list_node, @as(u32, @intCast(g)));
                            if (c.ts_node_is_named(g_child)) {
                                try gens.append(self.extractText(g_child));
                            }
                        }
                    }
                    if (gens.items.len > 0) generic_params = try gens.toOwnedSlice();
                } else if (std.mem.eql(u8, child_type, "block_body")) {
                    const body_count = c.ts_node_child_count(child);
                    var b: usize = 0;
                    while (b < body_count) : (b += 1) {
                        const b_child = c.ts_node_child(child, @as(u32, @intCast(b)));
                        if (c.ts_node_is_named(b_child)) {
                            const b_type = std.mem.span(c.ts_node_type(b_child));
                            if (std.mem.eql(u8, b_type, "var_decl")) {
                                const field = try self.lowerFieldDecl(b_child);
                                try fields.append(field);
                            } else if (std.mem.eql(u8, b_type, "ERROR") or std.mem.eql(u8, b_type, "statement") or std.mem.eql(u8, b_type, "expression_statement")) {
                                const err_text = self.extractText(b_child);
                                var it = std.mem.tokenizeAny(u8, err_text, " \t\r\n");
                                var words = std.ArrayList([]const u8).init(self.allocator);
                                while (it.next()) |word| {
                                    try words.append(word);
                                }
                                
                                var field_name: ?[]const u8 = null;
                                var type_str: []const u8 = "Any";
                                var acc_mod: []const u8 = "public";
                                
                                var as_idx: ?usize = null;
                                for (words.items, 0..) |w, idx_w| {
                                    if (std.mem.eql(u8, w, "as")) {
                                        as_idx = idx_w;
                                        break;
                                    }
                                }
                                
                                if (as_idx) |idx| {
                                    if (idx > 0) field_name = words.items[idx - 1];
                                    
                                    if (idx + 1 < words.items.len) {
                                        type_str = words.items[idx + 1];
                                    } else {
                                        if (b + 1 < body_count) {
                                            const next_child = c.ts_node_child(child, @as(u32, @intCast(b + 1)));
                                            const next_type = std.mem.span(c.ts_node_type(next_child));
                                            if (std.mem.eql(u8, next_type, "statement") or std.mem.eql(u8, next_type, "expression")) {
                                                type_str = self.extractText(next_child);
                                                b += 1;
                                            }
                                        }
                                    }
                                    
                                    if (idx > 1) {
                                        if (std.mem.eql(u8, words.items[0], "public") or std.mem.eql(u8, words.items[0], "private")) {
                                            acc_mod = words.items[0];
                                        }
                                    }
                                    
                                    if (field_name) |fname| {
                                        const field_node = try self.allocator.create(ast.Node);
                                        field_node.* = .{
                                            .node_type = .FieldDecl,
                                            .span = getSpan(b_child),
                                            .inferred_type = null,
                                            .data = .{
                                                .FieldDecl = .{
                                                    .name = fname,
                                                    .access_modifier = acc_mod,
                                                    .is_mutable = false,
                                                    .type_annot = .{ .name = type_str },
                                                    .default_value = null,
                                                },
                                            },
                                        };
                                        try fields.append(field_node);
                                    }
                                }
                            } else if (std.mem.eql(u8, b_type, "function_decl") or std.mem.eql(u8, b_type, "fun_decl")) {
                                const method = try self.lowerNode(b_child);
                                try methods.append(method);
                            }
                        }
                    }
                }
            }
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .StructDecl,
            .span = getSpan(ts_node),
            .data = .{
                .StructDecl = .{
                    .name = name,
                    .generic_params = generic_params,
                    .fields = try fields.toOwnedSlice(),
                    .methods = try methods.toOwnedSlice(),
                },
            },
        };
        return node;
    }

    fn lowerUnionDecl(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        const name_node = c.ts_node_child_by_field_name(ts_node, "name", 4);
        const name = self.extractText(name_node);

        var tag_type: ?ast.TypeAnnotation = null;
        const tag_node = c.ts_node_child_by_field_name(ts_node, "tag_type", 8);
        if (!c.ts_node_is_null(tag_node)) {
            tag_type = try self.lowerTypeAnnotation(tag_node);
        }

        var generic_params: ?[][]const u8 = null;
        const gp_node = c.ts_node_child_by_field_name(ts_node, "generic_params", 14);
        if (!c.ts_node_is_null(gp_node)) {
            var gens = std.ArrayList([]const u8).init(self.allocator);
            const list_node = c.ts_node_child(gp_node, 1); // type_list
            if (c.ts_node_is_named(list_node)) {
                const count = c.ts_node_child_count(list_node);
                for (0..count) |g| {
                    const g_child = c.ts_node_child(list_node, @as(u32, @intCast(g)));
                    if (c.ts_node_is_named(g_child)) {
                        try gens.append(self.extractText(g_child));
                    }
                }
            }
            if (gens.items.len > 0) generic_params = try gens.toOwnedSlice();
        }

        var fields = std.ArrayList(*ast.Node).init(self.allocator);
        var methods = std.ArrayList(*ast.Node).init(self.allocator);
        const body_node = c.ts_node_child_by_field_name(ts_node, "body", 4);
        if (!c.ts_node_is_null(body_node)) {
            const body_count = c.ts_node_child_count(body_node);
            var b: usize = 0;
            while (b < body_count) : (b += 1) {
                const b_child = c.ts_node_child(body_node, @as(u32, @intCast(b)));
                if (c.ts_node_is_named(b_child)) {
                    const b_type = std.mem.span(c.ts_node_type(b_child));
                    if (std.mem.eql(u8, b_type, "var_decl")) {
                        const field = try self.lowerFieldDecl(b_child);
                        try fields.append(field);
                    } else if (std.mem.eql(u8, b_type, "ERROR")) {
                        const err_text = self.extractText(b_child);
                        var it = std.mem.tokenizeAny(u8, err_text, " \t\r\n");
                        var words = std.ArrayList([]const u8).init(self.allocator);
                        while (it.next()) |word| {
                            try words.append(word);
                        }
                        if (words.items.len >= 2 and std.mem.eql(u8, words.items[words.items.len - 1], "as")) {
                            const field_name = words.items[words.items.len - 2];
                            var acc_mod: []const u8 = "public";
                            if (words.items.len > 2) {
                                if (std.mem.eql(u8, words.items[0], "public") or std.mem.eql(u8, words.items[0], "private")) {
                                    acc_mod = words.items[0];
                                }
                            }
                            // Look ahead to get the type annotation from the next child
                            var type_str: []const u8 = "Any";
                            if (b + 1 < body_count) {
                                const next_child = c.ts_node_child(body_node, @as(u32, @intCast(b + 1)));
                                const next_type = std.mem.span(c.ts_node_type(next_child));
                                if (std.mem.eql(u8, next_type, "statement") or std.mem.eql(u8, next_type, "expression")) {
                                    type_str = self.extractText(next_child);
                                    b += 1;
                                }
                            }
                            
                            const field_node = try self.allocator.create(ast.Node);
                            field_node.* = .{
                                .node_type = .FieldDecl,
                                .span = getSpan(b_child),
                                .inferred_type = null,
                                .data = .{
                                    .FieldDecl = .{
                                        .name = field_name,
                                        .access_modifier = acc_mod,
                                        .is_mutable = false,
                                        .type_annot = .{ .name = type_str },
                                        .default_value = null,
                                    },
                                },
                            };
                            try fields.append(field_node);
                        }
                    } else if (std.mem.eql(u8, b_type, "function_decl") or std.mem.eql(u8, b_type, "fun_decl")) {
                        const method = try self.lowerNode(b_child);
                        try methods.append(method);
                    }
                }
            }
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .UnionDecl,
            .span = getSpan(ts_node),
            .data = .{
                .UnionDecl = .{
                    .name = name,
                    .tag_type = tag_type,
                    .generic_params = generic_params,
                    .fields = try fields.toOwnedSlice(),
                    .methods = try methods.toOwnedSlice(),
                },
            },
        };
        return node;
    }

    fn lowerUnsafeBlock(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        const child_count = c.ts_node_child_count(ts_node);
        var body: ?*ast.Node = null;
        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            if (!c.ts_node_is_named(child)) continue;
            const child_type = std.mem.span(c.ts_node_type(child));
            // Skip the kw_unsafe keyword node, only process block_body
            if (std.mem.eql(u8, child_type, "kw_unsafe")) continue;
            if (std.mem.eql(u8, child_type, "block_body")) {
                // Iterate block_body children into a BlockStmt
                var body_stmts = std.ArrayList(*ast.Node).init(self.allocator);
                const body_child_count = c.ts_node_child_count(child);
                for (0..body_child_count) |b_i| {
                    const stmt_child = c.ts_node_child(child, @as(u32, @intCast(b_i)));
                    if (c.ts_node_is_named(stmt_child)) {
                        const stmt_ast = try self.lowerNode(stmt_child);
                        try body_stmts.append(stmt_ast);
                    }
                }
                const block_node = try self.allocator.create(ast.Node);
                block_node.* = .{
                    .node_type = .BlockStmt,
                    .span = getSpan(child),
                    .data = .{ .BlockStmt = .{ .statements = try body_stmts.toOwnedSlice() } },
                };
                body = block_node;
            } else {
                body = try self.lowerNode(child);
            }
            break;
        }
        if (body == null) {
            std.debug.print("Failed to find body for unsafe_block\n", .{});
            return error.InvalidSyntax;
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .UnsafeBlock,
            .span = getSpan(ts_node),
            .data = .{
                .UnsafeBlock = .{
                    .body = body.?,
                },
            },
        };
        return node;
    }

    fn lowerFieldDecl(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var name: []const u8 = "unknown";
        var acc_mod: []const u8 = "public";
        var type_annot = ast.TypeAnnotation{ .name = "Any" };
        var def_val: ?*ast.Node = null;
        var is_mutable = false;
        
        var seen_eq = false;

        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            const child_type = std.mem.span(c.ts_node_type(child));
            
            if (std.mem.eql(u8, child_type, "var")) {
                is_mutable = true;
            } else if (std.mem.eql(u8, child_type, "let")) {
                is_mutable = false;
            } else if (std.mem.eql(u8, child_type, "access_modifier")) {
                acc_mod = self.extractText(child);
            } else if (std.mem.eql(u8, child_type, "=")) {
                seen_eq = true;
            } else if (c.ts_node_is_named(child)) {
                if (std.mem.eql(u8, child_type, "identifier") and std.mem.eql(u8, name, "unknown")) {
                    name = self.extractText(child);
                } else if (std.mem.eql(u8, child_type, "type_annotation")) {
                    type_annot = try self.lowerTypeAnnotation(child);
                } else if (std.mem.eql(u8, child_type, "typed_var")) {
                    const tv_count = c.ts_node_child_count(child);
                    for (0..tv_count) |j| {
                        const tv_child = c.ts_node_child(child, @as(u32, @intCast(j)));
                        if (c.ts_node_is_named(tv_child)) {
                            const tv_type = std.mem.span(c.ts_node_type(tv_child));
                            if (std.mem.eql(u8, tv_type, "identifier")) {
                                name = self.extractText(tv_child);
                            } else if (std.mem.eql(u8, tv_type, "type_annotation")) {
                                type_annot = try self.lowerTypeAnnotation(tv_child);
                            }
                        }
                    }
                } else if (seen_eq) {
                    def_val = try self.lowerNode(child);
                }
            }
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .FieldDecl,
            .span = getSpan(ts_node),
            .data = .{
                .FieldDecl = .{
                    .name = name,
                    .access_modifier = acc_mod,
                    .is_mutable = is_mutable,
                    .type_annot = type_annot,
                    .default_value = def_val,
                },
            },
        };
        return node;
    }

    fn lowerInterfaceDecl(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var name: []const u8 = "unknown";
        var methods = std.ArrayList(*ast.Node).init(self.allocator);

        const child_count = c.ts_node_child_count(ts_node);

        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            if (c.ts_node_is_named(child)) {
                const child_type = std.mem.span(c.ts_node_type(child));
                if (std.mem.eql(u8, child_type, "identifier") and std.mem.eql(u8, name, "unknown")) {
                    name = self.extractText(child);
                } else if (std.mem.eql(u8, child_type, "block_body")) {
                    const body_count = c.ts_node_child_count(child);
                    for (0..body_count) |b| {
                        const b_child = c.ts_node_child(child, @as(u32, @intCast(b)));
                        if (c.ts_node_is_named(b_child)) {
                            const b_type = std.mem.span(c.ts_node_type(b_child));
                            if (std.mem.eql(u8, b_type, "function_decl") or std.mem.eql(u8, b_type, "fun_decl")) {
                                const method = try self.lowerNode(b_child);
                                try methods.append(method);
                            }
                        }
                    }
                }
            }
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .InterfaceDecl,
            .span = getSpan(ts_node),
            .data = .{
                .InterfaceDecl = .{
                    .name = name,
                    .super_interfaces = &[_][]const u8{},
                    .methods = try methods.toOwnedSlice(),
                },
            },
        };
        return node;
    }

    fn lowerCastExpr(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        const operand_node = c.ts_node_child_by_field_name(ts_node, "operand", 7);

        if (c.ts_node_is_null(operand_node)) {
            return error.InvalidSyntax;
        }

        const operand = try self.lowerNode(operand_node);

        var target_nodes = std.ArrayList(c.TSNode).init(self.allocator);
        defer target_nodes.deinit();

        const cc = c.ts_node_child_count(ts_node);
        for (0..cc) |i| {
            const child = tsChild(ts_node, i);
            const field = c.ts_node_field_name_for_child(ts_node, @as(u32, @intCast(i)));
            if (field == null or !std.mem.eql(u8, std.mem.span(field), "target")) continue;
            if (!c.ts_node_is_named(child)) continue;
            try target_nodes.append(child);
        }

        const parsed_targets = try self.lowerTypeListFromNodes(target_nodes.items);
        var target_type = ast.TypeAnnotation{ .name = "Any" };
        if (parsed_targets.len > 0) {
            target_type = parsed_targets[0];
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .CastExpr,
            .span = getSpan(ts_node),
            .data = .{
                .CastExpr = .{
                    .operand = operand,
                    .target_type = target_type,
                },
            },
        };
        return node;
    }

    fn lowerSpreadExpr(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var iterable: ?*ast.Node = null;
        
        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            if (c.ts_node_is_named(child)) {
                iterable = try self.lowerNode(child);
                break;
            }
        }
        
        if (iterable == null) {
            return error.InvalidSyntax;
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .SpreadExpr,
            .span = getSpan(ts_node),
            .data = .{
                .SpreadExpr = .{
                    .iterable = iterable.?,
                },
            },
        };
        return node;
    }

    fn lowerClosure(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var params = std.ArrayList(*ast.Node).init(self.allocator);
        var param_types = std.ArrayList(?ast.TypeAnnotation).init(self.allocator);
        var body: ?*ast.Node = null;
        var return_type: ?ast.TypeAnnotation = null;
        
        var target_node = ts_node;
        if (std.mem.eql(u8, std.mem.span(c.ts_node_type(ts_node)), "fun_expr")) {
            const child_count = c.ts_node_child_count(ts_node);
            for (0..child_count) |i| {
                const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
                if (c.ts_node_is_named(child)) {
                    const c_type = std.mem.span(c.ts_node_type(child));
                    if (std.mem.eql(u8, c_type, "anonymous_function") or std.mem.eql(u8, c_type, "lambda_expr")) {
                        target_node = child;
                        break;
                    }
                }
            }
        }

        const child_count = c.ts_node_child_count(target_node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(target_node, @as(u32, @intCast(i)));
            if (c.ts_node_is_named(child)) {
                const c_type = std.mem.span(c.ts_node_type(child));
                if (std.mem.eql(u8, c_type, "identifier") or std.mem.eql(u8, c_type, "param_decl")) {
                    const param_ast = try self.lowerNode(child);
                    try params.append(param_ast);
                } else if (std.mem.eql(u8, c_type, "return_annotation")) {
                    const rt_count = c.ts_node_child_count(child);
                    for (0..rt_count) |rti| {
                        const rt_child = c.ts_node_child(child, @as(u32, @intCast(rti)));
                        if (c.ts_node_is_named(rt_child)) {
                            return_type = .{ .name = self.extractText(rt_child), .is_ref = false, .is_mut = false, .lifetime = null };
                            break;
                        }
                    }
                } else if (std.mem.eql(u8, c_type, "typed_params")) {
                    const tp_count = c.ts_node_child_count(child);
                    for (0..tp_count) |tpi| {
                        const tp_child = c.ts_node_child(child, @as(u32, @intCast(tpi)));
                        if (std.mem.eql(u8, std.mem.span(c.ts_node_type(tp_child)), "param_decl")) {
                            const name_node = c.ts_node_child_by_field_name(tp_child, "name", 4);
                            const type_node = c.ts_node_child_by_field_name(tp_child, "type", 4);
                            if (c.ts_node_is_null(name_node)) {
                                return error.InvalidSyntax;
                            }
                            const param_ast = try self.lowerNode(name_node);
                            try params.append(param_ast);
                            if (!c.ts_node_is_null(type_node)) {
                                const annot = try self.lowerTypeAnnotation(type_node);
                                try param_types.append(annot);
                            } else {
                                try param_types.append(null);
                            }
                        } else if (c.ts_node_is_named(tp_child)) {
                            const param_ast = try self.lowerNode(tp_child);
                            try params.append(param_ast);
                            try param_types.append(null);
                        }
                    }
                } else if (std.mem.eql(u8, c_type, "lambda_typed_params")) {
                    const tp_count = c.ts_node_child_count(child);
                    var tp_idx: u32 = 0;
                    while (tp_idx < tp_count) : (tp_idx += 1) {
                        const tp_child = c.ts_node_child(child, tp_idx);
                        if (!c.ts_node_is_named(tp_child)) continue;
                        const field_name_ptr = c.ts_node_field_name_for_child(child, tp_idx);
                        if (field_name_ptr == null) continue;
                        const field_name = std.mem.span(field_name_ptr);
                        if (std.mem.eql(u8, field_name, "name")) {
                            const param_ast = try self.lowerNode(tp_child);
                            try params.append(param_ast);
                            try param_types.append(null);
                        } else if (std.mem.eql(u8, field_name, "type")) {
                            if (param_types.items.len > 0) {
                                const annot = try self.lowerTypeAnnotation(tp_child);
                                param_types.items[param_types.items.len - 1] = annot;
                            } else {
                                return error.InvalidSyntax;
                            }
                        }
                    }
                } else if (std.mem.eql(u8, c_type, "block_body") or body == null) {
                    if (std.mem.eql(u8, c_type, "block_body")) {
                        body = try self.lowerBlockStmt(child);
                    } else {
                        body = try self.lowerNode(child);
                    }
                }
            }
        }

        if (body == null) {
            // Empty closure body fallback
            const empty_body = try self.allocator.create(ast.Node);
            empty_body.* = .{ .node_type = .BlockStmt, .span = getSpan(ts_node), .data = .{ .BlockStmt = .{ .statements = &[_]*ast.Node{} } } };
            body = empty_body;
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .ClosureExpr,
            .span = getSpan(ts_node),
            .data = .{
                .ClosureExpr = .{
                    .params = try params.toOwnedSlice(),
                    .param_types = try param_types.toOwnedSlice(),
                    .body = body.?,
                    .return_type = return_type,
                },
            },
        };
        return node;
    }

    fn lowerBinaryExpr(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var left_node = c.ts_node_child_by_field_name(ts_node, "left", 4);
        var right_node = c.ts_node_child_by_field_name(ts_node, "right", 5);
        var operator_node = c.ts_node_child_by_field_name(ts_node, "operator", 8);

        if (c.ts_node_is_null(left_node)) {
            // Fallback for nodes without fields (like 'assignment')
            const count = c.ts_node_child_count(ts_node);
            ast.debugPrint("DEBUG: binary/assignment node has {d} children\n", .{count});
            for (0..count) |i| {
                const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
                const c_type = std.mem.span(c.ts_node_type(child));
                ast.debugPrint("DEBUG: child {d} is '{s}' (named: {})\n", .{i, c_type, c.ts_node_is_named(child)});
            }
            
            left_node = c.ts_node_child(ts_node, 0);
            operator_node = c.ts_node_child(ts_node, 1);
            right_node = c.ts_node_child(ts_node, 2);
        }

        if (c.ts_node_is_null(left_node) or c.ts_node_is_null(right_node) or c.ts_node_is_null(operator_node)) {
            return error.InvalidSyntax;
        }

        const left = try self.lowerNode(left_node);
        const right = try self.lowerNode(right_node);
        const operator = self.extractText(operator_node);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .BinaryExpr,
            .span = getSpan(ts_node),
            .data = .{
                .BinaryExpr = .{
                    .left = left,
                    .right = right,
                    .operator = operator,
                },
            },
        };
        return node;
    }

    fn lowerWithStmt(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var expr: ?*ast.Node = null;
        var var_name: ?[]const u8 = null;
        var body: ?*ast.Node = null;

        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = tsChild(ts_node, i);
            if (!c.ts_node_is_named(child)) continue;

            const c_type = tsType(child);
            if (std.mem.eql(u8, c_type, "comment")) continue;
            if (std.mem.eql(u8, c_type, "block_body")) {
                body = try self.lowerBlockStmt(child);
            } else if (std.mem.eql(u8, c_type, "kw_with")) {
                // ignore
            } else {
                if (expr == null) {
                    expr = try self.lowerNode(child);
                } else if (std.mem.eql(u8, c_type, "identifier")) {
                    var_name = self.extractText(child);
                }
            }
        }

        if (expr == null or body == null) {
            return error.InvalidSyntax;
        }

        return self.createNode(.WithStmt, getSpan(ts_node), .{
            .WithStmt = .{
                .expr = expr.?,
                .var_name = var_name,
                .body = body.?,
            },
        });
    }

    fn lowerBlockStmt(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var statements = std.ArrayList(*ast.Node).init(self.allocator);
        var params = std.ArrayList(*ast.Node).init(self.allocator);
        var param_types = std.ArrayList(ast.TypeAnnotation).init(self.allocator);
        var return_names = std.ArrayList([]const u8).init(self.allocator);
        var return_types = std.ArrayList(ast.TypeAnnotation).init(self.allocator);
        var has_params_or_returns = false;

        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            if (c.ts_node_is_named(child)) {
                const child_type = std.mem.span(c.ts_node_type(child));
                if (std.mem.eql(u8, child_type, "typed_params")) {
                    has_params_or_returns = true;
                    const p_count = c.ts_node_child_count(child);
                    for (0..p_count) |p| {
                        const p_child = c.ts_node_child(child, @as(u32, @intCast(p)));
                        if (c.ts_node_is_named(p_child)) {
                            const name_node = c.ts_node_child_by_field_name(p_child, "name", 4);
                            const type_node = c.ts_node_child_by_field_name(p_child, "type", 4);
                            if (!c.ts_node_is_null(name_node)) {
                                const id_node = try self.allocator.create(ast.Node);
                                id_node.* = .{
                                    .node_type = .Identifier,
                                    .span = getSpan(name_node),
                                    .data = .{ .Identifier = .{ .name = self.extractText(name_node) } },
                                };
                                try params.append(id_node);
                                
                                if (!c.ts_node_is_null(type_node)) {
                                    try param_types.append(try self.lowerTypeAnnotation(type_node));
                                } else {
                                    try param_types.append(.{ .name = "Any", .generics = null, .lifetime = null });
                                }
                            }
                        }
                    }
                } else if (std.mem.eql(u8, child_type, "return_annotation")) {
                    has_params_or_returns = true;
                    // Try to parse tuple_type_list
                    const t_count = c.ts_node_child_count(child);
                    for (0..t_count) |t| {
                        const t_child = c.ts_node_child(child, @as(u32, @intCast(t)));
                        if (c.ts_node_is_named(t_child) and std.mem.eql(u8, std.mem.span(c.ts_node_type(t_child)), "tuple_type_list")) {
                            const tup_count = c.ts_node_child_count(t_child);
                            for (0..tup_count) |tup| {
                                const tup_child = c.ts_node_child(t_child, @as(u32, @intCast(tup)));
                                if (c.ts_node_is_named(tup_child) and std.mem.eql(u8, std.mem.span(c.ts_node_type(tup_child)), "tuple_type")) {
                                    const id_node = c.ts_node_child(tup_child, 0); // Identifier is first child
                                    if (c.ts_node_is_named(id_node)) {
                                        try return_names.append(self.extractText(id_node));
                                    }
                                    const type_node = c.ts_node_child(tup_child, 2); // type_desc is 3rd child
                                    if (c.ts_node_is_named(type_node)) {
                                        try return_types.append(try self.lowerTypeAnnotation(type_node));
                                    }
                                }
                            }
                        }
                    }
                } else if (std.mem.eql(u8, child_type, "block_body")) {
                    const body_count = c.ts_node_child_count(child);
                    for (0..body_count) |b| {
                        const b_child = c.ts_node_child(child, @as(u32, @intCast(b)));
                        if (c.ts_node_is_named(b_child)) {
                            try statements.append(try self.lowerNode(b_child));
                        }
                    }
                } else {
                    const stmt_node = try self.lowerNode(child);
                    try statements.append(stmt_node);
                }
            }
        }

        const block_body = try self.allocator.create(ast.Node);
        block_body.* = .{
            .node_type = .BlockStmt,
            .span = getSpan(ts_node),
            .data = .{ .BlockStmt = .{ .statements = try statements.toOwnedSlice() } },
        };

        if (has_params_or_returns) {
            const param_block = try self.allocator.create(ast.Node);
            param_block.* = .{
                .node_type = .ParamBlockStmt,
                .span = getSpan(ts_node),
                .data = .{
                    .ParamBlockStmt = .{
                        .params = try params.toOwnedSlice(),
                        .param_types = try param_types.toOwnedSlice(),
                        .return_names = try return_names.toOwnedSlice(),
                        .return_types = try return_types.toOwnedSlice(),
                        .body = block_body,
                    },
                },
            };
            return param_block;
        }

        return block_body;
    }

    fn lowerForStmt(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var iterator: []const u8 = "unknown";
        var type_annot: ?ast.TypeAnnotation = null;
        var iterable: ?*ast.Node = null;
        var body: ?*ast.Node = null;
        var is_parallel = false;
        var is_vectorized = false;

        const text = self.extractText(ts_node);
        if (std.mem.indexOf(u8, text, "for@par") != null) is_parallel = true;
        if (std.mem.indexOf(u8, text, "for@vec") != null) is_vectorized = true;

        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            if (c.ts_node_is_named(child)) {
                const c_type = std.mem.span(c.ts_node_type(child));
                if (std.mem.eql(u8, c_type, "comment")) continue;
                if (std.mem.eql(u8, c_type, "loop_modifier")) {
                    const mod_text = self.extractText(child);
                    if (std.mem.eql(u8, mod_text, "@par")) is_parallel = true;
                    if (std.mem.eql(u8, mod_text, "@vec")) is_vectorized = true;
                } else if (std.mem.eql(u8, c_type, "type_annotation")) {
                    type_annot = try self.lowerTypeAnnotation(child);
                } else if (std.mem.eql(u8, c_type, "kw_in")) {
                    // ignore
                } else if (std.mem.eql(u8, c_type, "identifier")) {
                    if (std.mem.eql(u8, iterator, "unknown")) {
                        iterator = self.extractText(child);
                    } else if (type_annot == null) {
                        const type_name = self.extractText(child);
                        type_annot = ast.TypeAnnotation{ .name = type_name };
                    }
                } else if (std.mem.eql(u8, c_type, "block_body") or std.mem.eql(u8, c_type, "statement")) {
                    if (std.mem.eql(u8, c_type, "block_body")) {
                        body = try self.lowerBlockStmt(child);
                    } else {
                        body = try self.lowerNode(child);
                    }
                } else if (iterable == null) {
                    iterable = try self.lowerNode(child);
                }
            }
        }

        if (body == null) {
            // Empty body fallback
            const empty_body = try self.allocator.create(ast.Node);
            empty_body.* = .{ .node_type = .BlockStmt, .span = getSpan(ts_node), .data = .{ .BlockStmt = .{ .statements = &[_]*ast.Node{} } } };
            body = empty_body;
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .ForStmt,
            .span = getSpan(ts_node),
            .data = .{
                .ForStmt = .{
                    .iterator = iterator,
                    .type_annot = type_annot,
                    .iterable = iterable orelse try self.allocator.create(ast.Node), // Fallback if parsing fails heavily
                    .body = body.?,
                    .is_parallel = is_parallel,
                    .is_vectorized = is_vectorized,
                },
            },
        };
        return node;
    }

    fn lowerListLiteral(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var elements = std.ArrayList(*ast.Node).init(self.allocator);

        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            const child_type = std.mem.span(c.ts_node_type(child));

            if (std.mem.eql(u8, child_type, "arguments") or std.mem.eql(u8, child_type, "argument_list")) {
                const arg_count = c.ts_node_child_count(child);
                for (0..arg_count) |a| {
                    const arg_child = c.ts_node_child(child, @as(u32, @intCast(a)));
                    if (c.ts_node_is_named(arg_child)) {
                        const el = try self.lowerNode(arg_child);
                        try elements.append(el);
                    }
                }
            } else if (c.ts_node_is_named(child)) {
                const el = try self.lowerNode(child);
                try elements.append(el);
            }
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .ListLiteral,
            .span = getSpan(ts_node),
            .data = .{
                .ListLiteral = .{
                    .elements = try elements.toOwnedSlice(),
                },
            },
        };
        return node;
    }

    fn lowerDictLiteral(self: *Lowerer, ts_node: c.TSNode) LowerError!*ast.Node {
        var keys = std.ArrayList(*ast.Node).init(self.allocator);
        var values = std.ArrayList(*ast.Node).init(self.allocator);

        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            const child_type = std.mem.span(c.ts_node_type(child));

            if (std.mem.eql(u8, child_type, "dict_arguments")) {
                const arg_count = c.ts_node_child_count(child);
                for (0..arg_count) |a| {
                    const arg_child = c.ts_node_child(child, @as(u32, @intCast(a)));
                    const arg_type = std.mem.span(c.ts_node_type(arg_child));
                    
                    if (std.mem.eql(u8, arg_type, "dict_item")) {
                        // dict_item has two expression children separated by ':'
                        var key_node: ?*ast.Node = null;
                        var val_node: ?*ast.Node = null;
                        const item_child_count = c.ts_node_child_count(arg_child);
                        for (0..item_child_count) |j| {
                            const item_part = c.ts_node_child(arg_child, @as(u32, @intCast(j)));
                            if (c.ts_node_is_named(item_part)) {
                                if (key_node == null) {
                                    key_node = try self.lowerNode(item_part);
                                } else if (val_node == null) {
                                    val_node = try self.lowerNode(item_part);
                                }
                            }
                        }
                        if (key_node) |k| {
                            if (val_node) |v| {
                                try keys.append(k);
                                try values.append(v);
                            }
                        }
                    }
                }
            }
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .node_type = .DictLiteral,
            .span = getSpan(ts_node),
            .data = .{
                .DictLiteral = .{
                    .keys = try keys.toOwnedSlice(),
                    .values = try values.toOwnedSlice(),
                },
            },
        };
        return node;
    }

    fn lowerSpawnStmt(self: *Lowerer, ts_node: c.TSNode) !*ast.Node {
        const spawn_node = try self.allocator.create(ast.Node);
        var call_expr: ?*ast.Node = null;

        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            if (c.ts_node_is_named(child)) {
                call_expr = try self.lowerNode(child);
                break;
            }
        }

        spawn_node.* = .{
            .node_type = .SpawnStmt,
            .span = getSpan(ts_node),
            .data = .{
                .SpawnStmt = .{
                    .call_expr = call_expr orelse return error.InvalidSyntax,
                },
            },
        };
        return spawn_node;
    }

    fn lowerUnaryExpr(self: *Lowerer, ts_node: c.TSNode) !*ast.Node {
        const child_count = c.ts_node_child_count(ts_node);
        if (child_count == 0) return error.InvalidSyntax;

        const op_node = c.ts_node_child(ts_node, 0);
        const op_type = std.mem.span(c.ts_node_type(op_node));
        
        // If it's a unary expression that just wraps try_expr (no separate operator)
        if (child_count == 1 and c.ts_node_is_named(op_node)) {
            return self.lowerNode(op_node);
        }

        var operand_node: ?*ast.Node = null;
        for (1..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            if (c.ts_node_is_named(child)) {
                operand_node = try self.lowerNode(child);
                break;
            }
        }

        if (std.mem.eql(u8, op_type, "await") or std.mem.eql(u8, op_type, "async")) {
            const await_node = try self.allocator.create(ast.Node);
            await_node.* = .{
                .node_type = .AwaitExpr,
                .span = getSpan(ts_node),
                .data = .{
                    .AwaitExpr = .{
                        .task_expr = operand_node orelse return error.InvalidSyntax,
                    },
                },
            };
            return await_node;
        } else if (std.mem.eql(u8, op_type, "spawn")) {
            const spawn_node = try self.allocator.create(ast.Node);
            spawn_node.* = .{
                .node_type = .SpawnStmt,
                .span = getSpan(ts_node),
                .data = .{
                    .SpawnStmt = .{
                        .call_expr = operand_node orelse return error.InvalidSyntax,
                    },
                },
            };
            return spawn_node;
        } else if (std.mem.eql(u8, op_type, "kw_not") or std.mem.eql(u8, op_type, "not") or std.mem.eql(u8, op_type, "!")) {
            const not_node = try self.allocator.create(ast.Node);
            not_node.* = .{
                .node_type = .UnaryExpr,
                .span = getSpan(ts_node),
                .data = .{
                    .UnaryExpr = .{
                        .operand = operand_node orelse return error.InvalidSyntax,
                        .operator = "not",
                    },
                },
            };
            return not_node;
        } else if (std.mem.eql(u8, op_type, "-") or std.mem.eql(u8, op_type, "+")) {
            const op_str = if (std.mem.eql(u8, op_type, "-")) "-" else "+";
            const un_node = try self.allocator.create(ast.Node);
            un_node.* = .{
                .node_type = .UnaryExpr,
                .span = getSpan(ts_node),
                .data = .{
                    .UnaryExpr = .{
                        .operand = operand_node orelse return error.InvalidSyntax,
                        .operator = op_str,
                    },
                },
            };
            return un_node;
        } else if (std.mem.eql(u8, op_type, "ref")) {
            // Check if next non-named token is "mut" => "ref mut"
            var is_mut = false;
            if (child_count >= 3) {
                const second = c.ts_node_child(ts_node, 1);
                const second_type = std.mem.span(c.ts_node_type(second));
                if (std.mem.eql(u8, second_type, "mut")) {
                    is_mut = true;
                    // Re-find operand after "mut"
                    operand_node = null;
                    for (2..child_count) |i| {
                        const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
                        if (c.ts_node_is_named(child)) {
                            operand_node = try self.lowerNode(child);
                            break;
                        }
                    }
                }
            }
            const ref_node = try self.allocator.create(ast.Node);
            ref_node.* = .{
                .node_type = .UnaryExpr,
                .span = getSpan(ts_node),
                .data = .{
                    .UnaryExpr = .{
                        .operand = operand_node orelse return error.InvalidSyntax,
                        .operator = if (is_mut) "ref mut" else "ref",
                    },
                },
            };
            return ref_node;
        } else if (std.mem.eql(u8, op_type, "deref")) {
            const deref_node = try self.allocator.create(ast.Node);
            deref_node.* = .{
                .node_type = .UnaryExpr,
                .span = getSpan(ts_node),
                .data = .{
                    .UnaryExpr = .{
                        .operand = operand_node orelse return error.InvalidSyntax,
                        .operator = "deref",
                    },
                },
            };
            return deref_node;
        } else if (std.mem.eql(u8, op_type, "~")) {
            const tilde_node = try self.allocator.create(ast.Node);
            tilde_node.* = .{
                .node_type = .UnaryExpr,
                .span = getSpan(ts_node),
                .data = .{
                    .UnaryExpr = .{
                        .operand = operand_node orelse return error.InvalidSyntax,
                        .operator = "~",
                    },
                },
            };
            return tilde_node;
        }
        return operand_node orelse error.InvalidSyntax;
    }

    fn lowerEnumDecl(self: *Lowerer, ts_node: c.TSNode) !*ast.Node {
        var name: []const u8 = "";
        var variants = std.ArrayList(*ast.Node).init(self.allocator);
        
        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            const c_type = std.mem.span(c.ts_node_type(child));
            
            if (std.mem.eql(u8, c_type, "identifier")) {
                name = self.extractText(child);
            } else if (std.mem.eql(u8, c_type, "enum_body")) {
                const body_count = c.ts_node_child_count(child);
                for (0..body_count) |bi| {
                    const b_child = c.ts_node_child(child, @as(u32, @intCast(bi)));
                    if (std.mem.eql(u8, std.mem.span(c.ts_node_type(b_child)), "enum_variant")) {
                        const variant_node = try self.lowerEnumVariant(b_child);
                        try variants.append(variant_node);
                    }
                }
            }
        }
        
        const enum_node = try self.allocator.create(ast.Node);
        enum_node.* = .{
            .node_type = .EnumDecl,
            .span = getSpan(ts_node),
            .data = .{
                .EnumDecl = .{
                    .name = name,
                    .generic_params = null, // TODO: support generic enums
                    .variants = try variants.toOwnedSlice(),
                },
            },
        };
        return enum_node;
    }
    
    fn lowerEnumVariant(self: *Lowerer, ts_node: c.TSNode) !*ast.Node {
        var name: []const u8 = "";
        var value: ?*ast.Node = null;
        var payload_types = std.ArrayList(ast.TypeAnnotation).init(self.allocator);
        
        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            const c_type = std.mem.span(c.ts_node_type(child));
            
            if (std.mem.eql(u8, c_type, "identifier")) {
                name = self.extractText(child);
            } else if (std.mem.eql(u8, c_type, "typed_params")) {
                const tp_count = c.ts_node_child_count(child);
                for (0..tp_count) |tpi| {
                    const tp_child = c.ts_node_child(child, @as(u32, @intCast(tpi)));
                    if (std.mem.eql(u8, std.mem.span(c.ts_node_type(tp_child)), "param_decl")) {
                        const type_node = c.ts_node_child_by_field_name(tp_child, "type", 4);
                        if (!c.ts_node_is_null(type_node)) {
                            const type_annot = try self.lowerTypeAnnotation(type_node);
                            try payload_types.append(type_annot);
                        } else {
                            // It might just be `Some(i32)` where `i32` is parsed as the identifier
                            const id_node = c.ts_node_child_by_field_name(tp_child, "name", 4);
                            if (!c.ts_node_is_null(id_node)) {
                                const t_name = self.extractText(id_node);
                                try payload_types.append(.{ .name = t_name, .is_ref = false, .is_mut = false, .lifetime = null });
                            }
                        }
                    }
                }
            } else if (std.mem.eql(u8, c_type, "type_annotation")) {
                const type_annot = try self.lowerTypeAnnotation(child);
                try payload_types.append(type_annot);
            } else if (c.ts_node_is_named(child)) {
                // If it's an expression (the value assignment)
                value = try self.lowerNode(child);
            }
        }
        
        const variant_node = try self.allocator.create(ast.Node);
        variant_node.* = .{
            .node_type = .EnumVariant,
            .span = getSpan(ts_node),
            .data = .{
                .EnumVariant = .{
                    .name = name,
                    .value = value,
                    .payload_types = if (payload_types.items.len > 0) try payload_types.toOwnedSlice() else null,
                },
            },
        };
        return variant_node;
    }

    fn lowerMacroDecl(self: *Lowerer, ts_node: c.TSNode) !*ast.Node {
        var name: []const u8 = "";
        var params = std.ArrayList(*ast.Node).init(self.allocator);
        var param_names = std.ArrayList([]const u8).init(self.allocator);
        var param_types = std.ArrayList(?ast.TypeAnnotation).init(self.allocator);
        var body_node: ?c.TSNode = null;

        const child_count = c.ts_node_child_count(ts_node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            const c_type = std.mem.span(c.ts_node_type(child));

            if (std.mem.eql(u8, c_type, "identifier")) {
                if (name.len == 0) {
                    name = self.extractText(child);
                }
            } else if (std.mem.eql(u8, c_type, "typed_params")) {
                const tp_count = c.ts_node_child_count(child);
                for (0..tp_count) |tpi| {
                    const tp_child = c.ts_node_child(child, @as(u32, @intCast(tpi)));
                    if (std.mem.eql(u8, std.mem.span(c.ts_node_type(tp_child)), "param_decl")) {
                        const name_node = c.ts_node_child_by_field_name(tp_child, "name", 4);
                        const type_node = c.ts_node_child_by_field_name(tp_child, "type", 4);

                        const p_name = self.extractText(name_node);
                        const p_type = if (c.ts_node_is_null(type_node)) null else try self.lowerTypeAnnotation(type_node);

                        const p_node = try self.allocator.create(ast.Node);
                        p_node.* = .{
                            .node_type = .Identifier,
                            .span = getSpan(name_node),
                            .data = .{ .Identifier = .{ .name = p_name } },
                        };

                        try params.append(p_node);
                        try param_names.append(p_name);
                        try param_types.append(p_type);
                    }
                }
            }
        }

        var idx = child_count;
        while (idx > 0) {
            idx -= 1;
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(idx)));
            if (c.ts_node_is_named(child)) {
                body_node = child;
                break;
            }
        }

        if (body_node == null) {
            return error.InvalidSyntax;
        }

        const body_ast = try self.lowerNode(body_node.?);

        const macro_def = MacroDef{
            .param_names = try param_names.toOwnedSlice(),
            .body_ast = body_ast,
        };
        try self.macros.put(name, macro_def);

        const macro_node = try self.allocator.create(ast.Node);
        macro_node.* = .{
            .node_type = .MacroDecl,
            .span = getSpan(ts_node),
            .data = .{
                .MacroDecl = .{
                    .name = name,
                    .params = try params.toOwnedSlice(),
                    .param_names = macro_def.param_names,
                    .param_types = try param_types.toOwnedSlice(),
                    .body = body_ast,
                },
            },
        };
        return macro_node;
    }

    fn lowerMacroInvocation(self: *Lowerer, ts_node: c.TSNode) !*ast.Node {
        const child_count = c.ts_node_child_count(ts_node);
        var name: []const u8 = "";
        var args_node: ?c.TSNode = null;

        for (0..child_count) |i| {
            const child = c.ts_node_child(ts_node, @as(u32, @intCast(i)));
            const c_type = std.mem.span(c.ts_node_type(child));

            if (std.mem.eql(u8, c_type, "identifier")) {
                name = self.extractText(child);
            } else if (std.mem.eql(u8, c_type, "arguments")) {
                args_node = child;
            }
        }

        const macro_def = self.macros.get(name) orelse {
            std.debug.print("Error: macro '{s}' is undefined.\n", .{name});
            return error.InvalidSyntax;
        };

        var args = std.ArrayList(*ast.Node).init(self.allocator);
        if (args_node) |an| {
            const arg_count = c.ts_node_child_count(an);
            for (0..arg_count) |i| {
                const arg_child = c.ts_node_child(an, @as(u32, @intCast(i)));
                if (c.ts_node_is_named(arg_child)) {
                    const arg_node = try self.lowerNode(arg_child);
                    try args.append(arg_node);
                }
            }
        }

        if (args.items.len != macro_def.param_names.len) {
            std.debug.print("Error: macro '{s}' expects {d} arguments, got {d}.\n", .{ name, macro_def.param_names.len, args.items.len });
            return error.InvalidSyntax;
        }

        for (macro_def.param_names, 0..) |p_name, idx| {
            try self.macro_args.put(p_name, args.items[idx]);
        }

        const hygiene_id = self.next_hygiene_id;
        self.next_hygiene_id += 1;
        var locals = std.StringHashMap(void).init(self.allocator);
        defer locals.deinit();
        try self.collectMacroLocals(macro_def.body_ast, &locals);

        const expanded_ast = try self.cloneNode(macro_def.body_ast, hygiene_id, &locals);

        for (macro_def.param_names) |p_name| {
            _ = self.macro_args.remove(p_name);
        }

        return expanded_ast;
    }

    fn mangleName(self: *Lowerer, name: []const u8, hygiene_id: ?usize, locals: ?*std.StringHashMap(void)) ![]const u8 {
        if (hygiene_id) |hid| {
            if (locals) |locs| {
                if (locs.contains(name)) {
                    return try std.fmt.allocPrint(self.allocator, "{s}_mac{d}", .{ name, hid });
                }
            }
        }
        return name;
    }

    fn cloneNode(self: *Lowerer, node: *ast.Node, hygiene_id: ?usize, locals: ?*std.StringHashMap(void)) LowerError!*ast.Node {
        var cloned = try self.allocator.create(ast.Node);
        cloned.* = node.*;
        cloned.module_name = null;
        
        switch (node.data) {
            .Program => |p| {
                var decls = try self.allocator.alloc(*ast.Node, p.declarations.len);
                for (p.declarations, 0..) |decl, i| {
                    decls[i] = try self.cloneNode(decl, hygiene_id, locals);
                }
                cloned.data = .{ .Program = .{ .declarations = decls } };
            },
            .ImportDecl => |i| {
                cloned.data = .{ .ImportDecl = i };
            },
            .FunDecl => |f| {
                var params = try self.allocator.alloc(*ast.Node, f.params.len);
                for (f.params, 0..) |p, i| {
                    params[i] = try self.cloneNode(p, hygiene_id, locals);
                }
                var default_values = try self.allocator.alloc(?*ast.Node, f.default_values.len);
                for (f.default_values, 0..) |dv, i| {
                    default_values[i] = if (dv) |val| try self.cloneNode(val, hygiene_id, locals) else null;
                }
                cloned.data = .{ .FunDecl = .{
                    .name = try self.mangleName(f.name, hygiene_id, locals),
                    .generic_params = f.generic_params,
                    .params = params,
                    .param_names = f.param_names,
                    .param_types = f.param_types,
                    .default_values = default_values,
                    .body = try self.cloneNode(f.body, hygiene_id, locals),
                    .is_async = f.is_async,
                    .return_type = f.return_type,
                    .has_self = f.has_self,
                    .is_variadic = f.is_variadic,
                } };
            },
            .VarDecl => |v| {
                var initializers: ?[]*ast.Node = null;
                if (v.initializers) |inits| {
                    var new_inits = try self.allocator.alloc(*ast.Node, inits.len);
                    for (inits, 0..) |init_node, i| {
                        new_inits[i] = try self.cloneNode(init_node, hygiene_id, locals);
                    }
                    initializers = new_inits;
                }
                var new_names = try self.allocator.alloc([]const u8, v.names.len);
                for (v.names, 0..) |n, i| {
                    new_names[i] = try self.mangleName(n, hygiene_id, locals);
                }
                cloned.data = .{ .VarDecl = .{
                    .names = new_names,
                    .type_annots = v.type_annots,
                    .initializers = initializers,
                    .is_mut = v.is_mut,
                } };
            },
            .ClassDecl => |cl_decl| {
                var methods = try self.allocator.alloc(*ast.Node, cl_decl.methods.len);
                for (cl_decl.methods, 0..) |m, i| {
                    methods[i] = try self.cloneNode(m, hygiene_id, locals);
                }
                var fields = try self.allocator.alloc(*ast.Node, cl_decl.fields.len);
                for (cl_decl.fields, 0..) |fd, i| {
                    fields[i] = try self.cloneNode(fd, hygiene_id, locals);
                }
                cloned.data = .{ .ClassDecl = .{
                    .name = try self.mangleName(cl_decl.name, hygiene_id, locals),
                    .base_class = cl_decl.base_class,
                    .interfaces = cl_decl.interfaces,
                    .fields = fields,
                    .methods = methods,
                } };
            },
            .StructDecl => |s| {
                var fields = try self.allocator.alloc(*ast.Node, s.fields.len);
                for (s.fields, 0..) |fd, i| {
                    fields[i] = try self.cloneNode(fd, hygiene_id, locals);
                }
                var methods = try self.allocator.alloc(*ast.Node, s.methods.len);
                for (s.methods, 0..) |m, i| {
                    methods[i] = try self.cloneNode(m, hygiene_id, locals);
                }
                cloned.data = .{ .StructDecl = .{
                    .name = s.name,
                    .generic_params = s.generic_params,
                    .fields = fields,
                    .methods = methods,
                } };
            },
            .UnionDecl => |u| {
                var fields = try self.allocator.alloc(*ast.Node, u.fields.len);
                for (u.fields, 0..) |fd, i| {
                    fields[i] = try self.cloneNode(fd, hygiene_id, locals);
                }
                var methods = try self.allocator.alloc(*ast.Node, u.methods.len);
                for (u.methods, 0..) |m, i| {
                    methods[i] = try self.cloneNode(m, hygiene_id, locals);
                }
                cloned.data = .{ .UnionDecl = .{
                    .name = u.name,
                    .tag_type = u.tag_type,
                    .generic_params = u.generic_params,
                    .fields = fields,
                    .methods = methods,
                } };
            },
            .InterfaceDecl => |in| {
                var methods = try self.allocator.alloc(*ast.Node, in.methods.len);
                for (in.methods, 0..) |m, i| {
                    methods[i] = try self.cloneNode(m, hygiene_id, locals);
                }
                cloned.data = .{ .InterfaceDecl = .{
                    .name = in.name,
                    .super_interfaces = in.super_interfaces,
                    .methods = methods,
                } };
            },
            .FieldDecl => |f| {
                cloned.data = .{ .FieldDecl = .{
                    .name = try self.mangleName(f.name, hygiene_id, locals),
                    .access_modifier = f.access_modifier,
                    .is_mutable = f.is_mutable,
                    .type_annot = f.type_annot,
                    .default_value = if (f.default_value) |dv| try self.cloneNode(dv, hygiene_id, locals) else null,
                } };
            },
            .EnumDecl => |e| {
                var variants = try self.allocator.alloc(*ast.Node, e.variants.len);
                for (e.variants, 0..) |v, i| {
                    variants[i] = try self.cloneNode(v, hygiene_id, locals);
                }
                cloned.data = .{ .EnumDecl = .{
                    .name = e.name,
                    .generic_params = e.generic_params,
                    .variants = variants,
                } };
            },
            .EnumVariant => |ev| {
                cloned.data = .{ .EnumVariant = .{
                    .name = ev.name,
                    .value = if (ev.value) |v| try self.cloneNode(v, hygiene_id, locals) else null,
                    .payload_types = ev.payload_types,
                } };
            },
            .IfStmt => |ifs| {
                cloned.data = .{ .IfStmt = .{
                    .condition = try self.cloneNode(ifs.condition, hygiene_id, locals),
                    .then_branch = try self.cloneNode(ifs.then_branch, hygiene_id, locals),
                    .else_branch = if (ifs.else_branch) |eb| try self.cloneNode(eb, hygiene_id, locals) else null,
                } };
            },
            .WithStmt => |w| {
                cloned.data = .{ .WithStmt = .{
                    .expr = try self.cloneNode(w.expr, hygiene_id, locals),
                    .var_name = w.var_name,
                    .body = try self.cloneNode(w.body, hygiene_id, locals),
                    .auto_drops = null, // Re-analyzed by borrowck
                } };
            },
            .ForStmt => |forstmt| {
                cloned.data = .{ .ForStmt = .{
                    .iterator = forstmt.iterator,
                    .type_annot = forstmt.type_annot,
                    .iterable = try self.cloneNode(forstmt.iterable, hygiene_id, locals),
                    .body = try self.cloneNode(forstmt.body, hygiene_id, locals),
                    .is_parallel = forstmt.is_parallel,
                    .is_vectorized = forstmt.is_vectorized,
                } };
            },
            .WhileStmt => |wh| {
                cloned.data = .{ .WhileStmt = .{
                    .condition = try self.cloneNode(wh.condition, hygiene_id, locals),
                    .body = try self.cloneNode(wh.body, hygiene_id, locals),
                } };
            },
            .BreakStmt => {
                cloned.data = .{ .BreakStmt = .{} };
            },
            .ContinueStmt => {
                cloned.data = .{ .ContinueStmt = .{} };
            },
            .PassStmt => {
                cloned.data = .{ .PassStmt = .{} };
            },
            .ReturnStmt => |ret| {
                var values: ?[]*ast.Node = null;
                if (ret.values) |vals| {
                    var new_vals = try self.allocator.alloc(*ast.Node, vals.len);
                    for (vals, 0..) |v, i| {
                        new_vals[i] = try self.cloneNode(v, hygiene_id, locals);
                    }
                    values = new_vals;
                }
                cloned.data = .{ .ReturnStmt = .{ .values = values } };
            },
            .BlockStmt => |blk| {
                var stmts = try self.allocator.alloc(*ast.Node, blk.statements.len);
                for (blk.statements, 0..) |stmt, i| {
                    stmts[i] = try self.cloneNode(stmt, hygiene_id, locals);
                }
                cloned.data = .{ .BlockStmt = .{ .statements = stmts } };
            },
            .ParamBlockStmt => |pb| {
                var params = try self.allocator.alloc(*ast.Node, pb.params.len);
                for (pb.params, 0..) |p, i| {
                    params[i] = try self.cloneNode(p, hygiene_id, locals);
                }
                cloned.data = .{ .ParamBlockStmt = .{
                    .params = params,
                    .param_types = pb.param_types,
                    .return_names = pb.return_names,
                    .return_types = pb.return_types,
                    .body = try self.cloneNode(pb.body, hygiene_id, locals),
                } };
            },
            .SpawnStmt => |sp| {
                cloned.data = .{ .SpawnStmt = .{ .call_expr = try self.cloneNode(sp.call_expr, hygiene_id, locals) } };
            },
            .TryStmt => |ts| {
                cloned.data = .{ .TryStmt = .{
                    .body = try self.cloneNode(ts.body, hygiene_id, locals),
                    .catch_binding = ts.catch_binding,
                    .catch_body = if (ts.catch_body) |cb| try self.cloneNode(cb, hygiene_id, locals) else null,
                } };
            },
            .ThrowStmt => |th| {
                cloned.data = .{ .ThrowStmt = .{ .value = try self.cloneNode(th.value, hygiene_id, locals) } };
            },
            .BinaryExpr => |b| {
                cloned.data = .{ .BinaryExpr = .{
                    .left = try self.cloneNode(b.left, hygiene_id, locals),
                    .right = try self.cloneNode(b.right, hygiene_id, locals),
                    .operator = b.operator,
                } };
            },
            .UnaryExpr => |u| {
                cloned.data = .{ .UnaryExpr = .{
                    .operand = try self.cloneNode(u.operand, hygiene_id, locals),
                    .operator = u.operator,
                } };
            },
            .CastExpr => |cast_expr| {
                cloned.data = .{ .CastExpr = .{
                    .operand = try self.cloneNode(cast_expr.operand, hygiene_id, locals),
                    .target_type = cast_expr.target_type,
                } };
            },
            .CallExpr => |call_expr| {
                var arguments = try self.allocator.alloc(*ast.Node, call_expr.arguments.len);
                for (call_expr.arguments, 0..) |arg, i| {
                    arguments[i] = try self.cloneNode(arg, hygiene_id, locals);
                }
                cloned.data = .{ .CallExpr = .{
                    .callee = try self.cloneNode(call_expr.callee, hygiene_id, locals),
                    .arguments = arguments,
                    .generic_args = call_expr.generic_args,
                } };
            },
            .MethodCallExpr => |mc| {
                var arguments = try self.allocator.alloc(*ast.Node, mc.arguments.len);
                for (mc.arguments, 0..) |arg, i| {
                    arguments[i] = try self.cloneNode(arg, hygiene_id, locals);
                }
                cloned.data = .{ .MethodCallExpr = .{
                    .receiver = try self.cloneNode(mc.receiver, hygiene_id, locals),
                    .method_name = mc.method_name,
                    .arguments = arguments,
                    .is_dynamic = mc.is_dynamic,
                } };
            },
            .MemberExpr => |me| {
                cloned.data = .{ .MemberExpr = .{
                    .object = try self.cloneNode(me.object, hygiene_id, locals),
                    .property = me.property,
                } };
            },
            .ClosureExpr => |cl| {
                var params = try self.allocator.alloc(*ast.Node, cl.params.len);
                for (cl.params, 0..) |p, i| {
                    params[i] = try self.cloneNode(p, hygiene_id, locals);
                }
                const param_types = try self.allocator.alloc(?ast.TypeAnnotation, cl.param_types.len);
                @memcpy(param_types, cl.param_types);
                cloned.data = .{ .ClosureExpr = .{
                    .params = params,
                    .param_types = param_types,
                    .body = try self.cloneNode(cl.body, hygiene_id, locals),
                    .return_type = cl.return_type,
                    .captured_vars = cl.captured_vars,
                } };
            },
            .Identifier => |id| {
                if (self.macro_args.get(id.name)) |arg_node| {
                    return try self.cloneNode(arg_node, null, null);
                }
                cloned.data = .{ .Identifier = .{
                    .name = try self.mangleName(id.name, hygiene_id, locals),
                    .resolved_symbol = id.resolved_symbol,
                } };
            },
            .NumberLiteral => |num| {
                cloned.data = .{ .NumberLiteral = .{ .value = num.value } };
            },
            .StringLiteral => |str| {
                cloned.data = .{ .StringLiteral = .{ .value = str.value } };
            },
            .BooleanLiteral => |b| {
                cloned.data = .{ .BooleanLiteral = .{ .value = b.value } };
            },
            .KeywordArg => |k| {
                cloned.data = .{ .KeywordArg = .{
                    .name = k.name,
                    .value = try self.cloneNode(k.value, hygiene_id, locals),
                } };
            },
            .ListLiteral => |l| {
                var elements = try self.allocator.alloc(*ast.Node, l.elements.len);
                for (l.elements, 0..) |el, i| {
                    elements[i] = try self.cloneNode(el, hygiene_id, locals);
                }
                cloned.data = .{ .ListLiteral = .{ .elements = elements } };
            },
            .AwaitExpr => |aw| {
                cloned.data = .{ .AwaitExpr = .{ .task_expr = try self.cloneNode(aw.task_expr, hygiene_id, locals) } };
            },
            .SpreadExpr => |sp| {
                cloned.data = .{ .SpreadExpr = .{ .iterable = try self.cloneNode(sp.iterable, hygiene_id, locals) } };
            },
            .MatchStmt => |m| {
                var cases = try self.allocator.alloc(ast.MatchCase, m.cases.len);
                for (m.cases, 0..) |case_val, i| {
                    cases[i] = .{
                        .pattern = try self.cloneNode(case_val.pattern, hygiene_id, locals),
                        .guard = if (case_val.guard) |g| try self.cloneNode(g, hygiene_id, locals) else null,
                        .body = try self.cloneNode(case_val.body, hygiene_id, locals),
                    };
                }
                cloned.data = .{ .MatchStmt = .{
                    .subject = try self.cloneNode(m.subject, hygiene_id, locals),
                    .cases = cases,
                } };
            },
            .UnsafeBlock => |u| {
                cloned.data = .{ .UnsafeBlock = .{ .body = try self.cloneNode(u.body, hygiene_id, locals) } };
            },
            else => {
                return error.UnsupportedNode;
            },
        }
        return cloned;
    }
    fn collectMacroLocals(self: *Lowerer, node: *ast.Node, locals: *std.StringHashMap(void)) LowerError!void {
        switch (node.data) {
            .Program => |n| {
                for (n.declarations) |child| try self.collectMacroLocals(child, locals);
            },
            .ImportDecl => |n| {
                if (n.module_ast) |child| try self.collectMacroLocals(child, locals);
            },
            .LinkDecl => {},
            .FunDecl => |n| {
                try locals.put(n.name, {});
                for (n.param_names) |p_name| try locals.put(p_name, {});
                for (n.params) |child| try self.collectMacroLocals(child, locals);
                for (n.default_values) |child| {
                    if (child) |dv| try self.collectMacroLocals(dv, locals);
                }
                try self.collectMacroLocals(n.body, locals);
            },
            .VarDecl => |n| {
                for (n.names) |name| try locals.put(name, {});
                if (n.initializers) |child_arr| {
                    for (child_arr) |child| try self.collectMacroLocals(child, locals);
                }
            },
            .ClassDecl => |decl| {
                try locals.put(decl.name, {});
                for (decl.fields) |child| try self.collectMacroLocals(child, locals);
                for (decl.methods) |child| try self.collectMacroLocals(child, locals);
            },
            .StructDecl => |decl| {
                try locals.put(decl.name, {});
                for (decl.fields) |child| try self.collectMacroLocals(child, locals);
                for (decl.methods) |child| try self.collectMacroLocals(child, locals);
            },
            .UnionDecl => |n| {
                for (n.fields) |child| try self.collectMacroLocals(child, locals);
                for (n.methods) |child| try self.collectMacroLocals(child, locals);
            },
            .InterfaceDecl => |decl| {
                try locals.put(decl.name, {});
                for (decl.methods) |child| try self.collectMacroLocals(child, locals);
            },
            .FieldDecl => |n| {
                if (n.default_value) |child| try self.collectMacroLocals(child, locals);
            },
            .EnumDecl => |decl| {
                try locals.put(decl.name, {});
                for (decl.variants) |child| try self.collectMacroLocals(child, locals);
            },
            .EnumVariant => |n| {
                if (n.value) |child| try self.collectMacroLocals(child, locals);
            },
            .IfStmt => |n| {
                try self.collectMacroLocals(n.condition, locals);
                try self.collectMacroLocals(n.then_branch, locals);
                if (n.else_branch) |child| try self.collectMacroLocals(child, locals);
            },
            .ForStmt => |n| {
                try self.collectMacroLocals(n.iterable, locals);
                try self.collectMacroLocals(n.body, locals);
            },
            .WhileStmt => |n| {
                try self.collectMacroLocals(n.condition, locals);
                try self.collectMacroLocals(n.body, locals);
            },
            .BreakStmt => {},
            .ContinueStmt => {},
            .PassStmt => {},
            .ReturnStmt => |n| {
                if (n.values) |vals| {
                    for (vals) |child| try self.collectMacroLocals(child, locals);
                }
            },
            .BlockStmt => |n| {
                for (n.statements) |child| try self.collectMacroLocals(child, locals);
            },
            .ParamBlockStmt => |n| {
                for (n.params) |child| try self.collectMacroLocals(child, locals);
                try self.collectMacroLocals(n.body, locals);
            },
            .SpawnStmt => |n| {
                try self.collectMacroLocals(n.call_expr, locals);
            },
            .TryStmt => |n| {
                try self.collectMacroLocals(n.body, locals);
                if (n.catch_body) |child| try self.collectMacroLocals(child, locals);
            },
            .ThrowStmt => |n| {
                try self.collectMacroLocals(n.value, locals);
            },
            .BinaryExpr => |n| {
                try self.collectMacroLocals(n.left, locals);
                try self.collectMacroLocals(n.right, locals);
            },
            .UnaryExpr => |n| {
                try self.collectMacroLocals(n.operand, locals);
            },
            .CastExpr => |n| {
                try self.collectMacroLocals(n.operand, locals);
            },
            .CallExpr => |n| {
                try self.collectMacroLocals(n.callee, locals);
                for (n.arguments) |child| try self.collectMacroLocals(child, locals);
            },
            .MethodCallExpr => |n| {
                try self.collectMacroLocals(n.receiver, locals);
                for (n.arguments) |child| try self.collectMacroLocals(child, locals);
            },
            .MemberExpr => |n| {
                try self.collectMacroLocals(n.object, locals);
            },
            .ClosureExpr => |n| {
                for (n.params) |child| try self.collectMacroLocals(child, locals);
                try self.collectMacroLocals(n.body, locals);
            },
            .Identifier => {},
            .NumberLiteral => {},
            .StringLiteral => {},
            .InterpolatedString => |n| {
                for (n.parts) |child| try self.collectMacroLocals(child, locals);
            },
            .BooleanLiteral => {},
            .KeywordArg => |n| {
                try self.collectMacroLocals(n.value, locals);
            },
            .ListLiteral => |n| {
                for (n.elements) |child| try self.collectMacroLocals(child, locals);
            },
            .DictLiteral => |n| {
                for (n.keys) |child| try self.collectMacroLocals(child, locals);
                for (n.values) |child| try self.collectMacroLocals(child, locals);
            },
            .IndexExpr => |n| {
                try self.collectMacroLocals(n.object, locals);
                try self.collectMacroLocals(n.index, locals);
            },
            .AwaitExpr => |n| {
                try self.collectMacroLocals(n.task_expr, locals);
            },
            .SpreadExpr => |n| {
                try self.collectMacroLocals(n.iterable, locals);
            },
            .MatchStmt => |n| {
                try self.collectMacroLocals(n.subject, locals);
                for (n.cases) |case_val| {
                    try self.collectMacroLocals(case_val.pattern, locals);
                    if (case_val.guard) |g| try self.collectMacroLocals(g, locals);
                    try self.collectMacroLocals(case_val.body, locals);
                }
            },
            .UnsafeBlock => |n| {
                try self.collectMacroLocals(n.body, locals);
            },
            .MacroDecl => |n| {
                for (n.params) |child| try self.collectMacroLocals(child, locals);
                try self.collectMacroLocals(n.body, locals);
            },
            .MacroInvocation => |n| {
                for (n.arguments) |child| try self.collectMacroLocals(child, locals);
            },
            .WithStmt => |n| {
                try self.collectMacroLocals(n.expr, locals);
                try self.collectMacroLocals(n.body, locals);
            },
        }
    }
};
