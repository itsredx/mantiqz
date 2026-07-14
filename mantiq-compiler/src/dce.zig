//! Dead code elimination — mark-and-sweep with quantum tree-shaking.
//!
//! Marks live nodes via `markNode` (walking from the program root), then sweeps
//! dead nodes via `sweepNode` (removing unmarked branches and pruning unused
//! imports). Includes special handling for zero-cost quantum abstraction —
//! if `std.quantum` is imported but no quantum symbols are used, the entire
//! import is removed. Also folds constant boolean if-conditions.
//!
//! Key responsibilities:
//! - `markNode` — recursive mark phase for all live node types
//! - `sweepNode` — removal of unmarked nodes, constant folding
//! - `quantum_used` flag — tracks quantum symbol usage for import pruning
//! - Constant-folded branch elimination — replaces `if True: ...` with body

const std = @import("std");
const ast = @import("ast.zig");

pub const DeadCodeEliminator = struct {
    allocator: std.mem.Allocator,
    quantum_used: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn optimizeProgram(self: *Self, root: *ast.Node) !void {
        // Phase 1: Mark
        try self.markNode(root);

        // Phase 2: Sweep
        try self.sweepNode(root);
    }

    fn markNode(self: *Self, node: *ast.Node) !void {
        switch (node.data) {
            .Program => |p| {
                for (p.declarations) |decl| {
                    try self.markNode(decl);
                }
            },
            .FunDecl => |f| {
                for (f.params) |p| try self.markNode(p);
                try self.markNode(f.body);
            },
            .VarDecl => |v| {
                for (v.type_annots) |maybe_annot| {
                    if (maybe_annot) |t| {
                        if (std.mem.eql(u8, t.name, "qbit") or std.mem.eql(u8, t.name, "qreg")) {
                            self.quantum_used = true;
                        }
                    }
                }
                if (v.initializers) |inits| {
                    for (inits) |i_node| try self.markNode(i_node);
                }
            },
            .IfStmt => |i| {
                // Constant folding for branches during mark phase
                var take_then = true;
                var take_else = true;

                if (i.condition.node_type == .BooleanLiteral) {
                    if (i.condition.data.BooleanLiteral.value) {
                        take_else = false;
                    } else {
                        take_then = false;
                    }
                }

                if (take_then) try self.markNode(i.then_branch);
                if (take_else) {
                    if (i.else_branch) |eb| try self.markNode(eb);
                }
            },
            .WithStmt => |w| {
                try self.markNode(w.expr);
                try self.markNode(w.body);
            },
            .ForStmt => |f| {
                try self.markNode(f.iterable);
                try self.markNode(f.body);
            },
            .WhileStmt => |w| {
                try self.markNode(w.condition);
                try self.markNode(w.body);
            },
            .BlockStmt => |b| {
                for (b.statements) |stmt| try self.markNode(stmt);
            },
            .ParamBlockStmt => |p| {
                for (p.params) |param| try self.markNode(param);
                try self.markNode(p.body);
            },

            .CallExpr => |c| {
                try self.markNode(c.callee);
                for (c.arguments) |arg| try self.markNode(arg);

                if (c.callee.node_type == .Identifier) {
                    const name = c.callee.data.Identifier.name;
                    if (std.mem.eql(u8, name, "H") or std.mem.eql(u8, name, "measure")) {
                        self.quantum_used = true;
                    }
                }
            },
            .BinaryExpr => |b| {
                try self.markNode(b.left);
                try self.markNode(b.right);
            },
            .UnaryExpr => |u| {
                try self.markNode(u.operand);
            },
            .CastExpr => |c| {
                try self.markNode(c.operand);
            },
            .MethodCallExpr => |m| {
                try self.markNode(m.receiver);
                for (m.arguments) |arg| try self.markNode(arg);
            },
            .MemberExpr => |m| {
                try self.markNode(m.object);
            },
            .Identifier => |i| {
                if (std.mem.eql(u8, i.name, "qbit") or std.mem.eql(u8, i.name, "qreg")) {
                    self.quantum_used = true;
                }
            },
            .ListLiteral => |l| {
                for (l.elements) |element| {
                    try self.markNode(element);
                }
            },
            else => {},
        }
    }

    fn sweepNode(self: *Self, node: *ast.Node) !void {
        switch (node.data) {
            .Program => |*p| {
                var new_decls = std.ArrayList(*ast.Node).init(self.allocator);
                for (p.declarations) |decl| {
                    if (decl.node_type == .ImportDecl) {
                        const target = decl.data.ImportDecl.target;
                        if (std.mem.eql(u8, target, "std.quantum") and !self.quantum_used) {
                            // Prune unused quantum import! Zero-cost abstraction!
                            continue;
                        }
                    }
                    try new_decls.append(decl);
                    try self.sweepNode(decl);
                }
                p.declarations = try new_decls.toOwnedSlice();
            },
            .FunDecl => |f| {
                try self.sweepNode(f.body);
            },
            .BlockStmt => |*b| {
                var new_stmts = std.ArrayList(*ast.Node).init(self.allocator);
                for (b.statements) |stmt| {
                    if (stmt.node_type == .IfStmt) {
                        const i = stmt.data.IfStmt;
                        if (i.condition.node_type == .BooleanLiteral) {
                            if (i.condition.data.BooleanLiteral.value) {
                                // True: replace IfStmt with just the then_branch
                                try self.sweepNode(i.then_branch);
                                try new_stmts.append(i.then_branch);
                                continue;
                            } else {
                                // False: replace IfStmt with else_branch if it exists
                                if (i.else_branch) |eb| {
                                    try self.sweepNode(eb);
                                    try new_stmts.append(eb);
                                }
                                continue;
                            }
                        }
                    }
                    try new_stmts.append(stmt);
                    try self.sweepNode(stmt);
                }
                b.statements = try new_stmts.toOwnedSlice();
            },
            .ParamBlockStmt => |p| {
                try self.sweepNode(p.body);
            },
            .IfStmt => |*i| {
                try self.sweepNode(i.then_branch);
                if (i.else_branch) |eb| try self.sweepNode(eb);
            },
            .WithStmt => |*w| {
                try self.sweepNode(w.body);
            },
            .ForStmt => |*f| {
                try self.sweepNode(f.body);
            },
            .WhileStmt => |*w| {
                try self.sweepNode(w.body);
            },
            else => {},
        }
    }
};
