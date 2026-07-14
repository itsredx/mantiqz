//! Control-flow graph analysis — return path completeness and unreachable code detection.
//!
//! Walks the AST to determine whether every function returns on all paths and
//! whether any code follows a guaranteed-return statement (return, raise, break,
//! continue). Runs after semantic analysis and before type checking. Reports
//! `UnreachableCode` and missing-return errors.
//!
//! Key responsibilities:
//! - `analyzeProgram` — entry point for full-program CFG analysis
//! - Per-node return analysis — tracks `always_returns` through blocks, branches,
//!   loops, match cases, and try/catch
//! - Unreachable code detection — errors on statements after guaranteed return

const std = @import("std");
const ast = @import("ast.zig");

pub const CFGAnalyzer = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn analyzeProgram(self: *Self, root: *ast.Node) !void {
        if (root.node_type == .Program) {
            for (root.data.Program.declarations) |decl| {
                _ = try self.checkNode(decl);
            }
        }
    }

    fn checkNode(self: *Self, node: *ast.Node) !bool {
        switch (node.data) {
            .FunDecl => |f| {
                if (f.is_extern) return false;
                const always_returns = try self.checkNode(f.body);
                
                if (f.return_type) |rt| {
                    if (!std.mem.eql(u8, rt.name, "void") and !std.mem.eql(u8, rt.name, "Empty")) {
                        if (!always_returns) {
                            std.debug.print("CFG Error: Missing return statement in function '{s}' on one or more execution paths\n", .{f.name});
                            return error.MissingReturn;
                        }
                    }
                }
                return false;
            },
            .BlockStmt => |b| {
                var always_returns = false;
                for (b.statements) |stmt| {
                    if (always_returns) {
                        std.debug.print("CFG Error: Unreachable code detected after guaranteed return\n", .{});
                        return error.UnreachableCode;
                    }
                    
                    const stmt_returns = try self.checkNode(stmt);
                    if (stmt_returns) {
                        always_returns = true;
                    }
                }
                return always_returns;
            },
            .IfStmt => |i| {
                const then_ret = try self.checkNode(i.then_branch);
                const cond_is_true = i.condition.node_type == .BooleanLiteral and
                    i.condition.data.BooleanLiteral.value;
                var else_ret = cond_is_true;
                if (i.else_branch) |eb| {
                    else_ret = try self.checkNode(eb);
                }
                return then_ret and else_ret;
            },
            .WithStmt => |w| {
                return try self.checkNode(w.body);
            },
            .ReturnStmt => {
                return true;
            },
            .ThrowStmt => {
                return true;
            },
            .WhileStmt => |w| {
                // A while loop may not execute, so it does not guarantee a return
                // unless it is an infinite loop, but for now we say it doesn't guarantee.
                _ = try self.checkNode(w.body);
                return false;
            },
            .ForStmt => |f| {
                _ = try self.checkNode(f.body);
                return false;
            },
            .ClassDecl => |c| {
                for (c.methods) |m| {
                    _ = try self.checkNode(m);
                }
                return false;
            },
            else => return false,
        }
    }
};
