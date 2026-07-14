//! Borrow checker — ownership state machine and automatic drop insertion.
//!
//! Tracks every variable through three states (`Owned` / `Moved` / `Dropped`)
//! and reports `UseAfterMove` / `UseAfterDrop` errors. On scope exit or function
//! return, variables still `Owned` that are move types (or context managers) are
//! collected into the node's `auto_drops` field for the codegen pass.
//!
//! Key responsibilities:
//! - `VariableState` / `ObjectState` — per-variable ownership tracking
//! - `handleMove` — transition `Owned → Moved` when a value is used by move
//! - Block-scope drop collection — collect owned move-types on scope exit
//! - Return-scope drop collection — collect owned move-types across all scopes
//! - Context manager `__exit__` injection via `is_context_manager` flag

const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");
const symbols = @import("symbols.zig");

pub const OwnershipError = error{
    UseAfterMove,
    UseAfterDrop,
    BorrowClash,
    InvalidDrop,
};

pub const ObjectState = enum {
    Owned,
    Moved,
    Dropped,
};

pub const VariableState = struct {
    state: ObjectState,
    shared_borrows: u32 = 0,
    mutable_borrows: u32 = 0,
    annotated_lifetime: ?[]const u8 = null,
};

pub const BorrowChecker = struct {
    allocator: std.mem.Allocator,
    states: std.AutoHashMap(*symbols.Symbol, VariableState),
    scopes: std.ArrayList(std.ArrayList(*symbols.Symbol)),

    pub fn init(allocator: std.mem.Allocator) BorrowChecker {
        return .{
            .allocator = allocator,
            .states = std.AutoHashMap(*symbols.Symbol, VariableState).init(allocator),
            .scopes = std.ArrayList(std.ArrayList(*symbols.Symbol)).init(allocator),
        };
    }

    pub fn checkProgram(self: *BorrowChecker, program: *ast.Node) !void {
        if (program.node_type != .Program) return;
        for (program.data.Program.declarations) |decl| {
            try self.checkNode(decl);
        }
    }

    fn checkNode(self: *BorrowChecker, node: *ast.Node) !void {
        switch (node.data) {
            .VarDecl => |*v| {
                if (v.initializers) |inits| {
                    for (inits) |init_expr| {
                        try self.checkNode(init_expr);
                        // Assignment is a Move for complex types
                        if (init_expr.node_type == .Identifier) {
                            try self.handleMove(init_expr);
                        }
                    }
                }
                if (v.resolved_symbols) |syms| {
                    for (syms) |sym| {
                        if (!self.states.contains(sym)) {
                            try self.states.put(sym, VariableState{ .state = .Owned });
                        }
                        if (self.scopes.items.len > 0) {
                            try self.scopes.items[self.scopes.items.len - 1].append(sym);
                        }
                    }
                }
            },
            .ParamBlockStmt => |*p| {
                const new_scope = std.ArrayList(*symbols.Symbol).init(self.allocator);
                try self.scopes.append(new_scope);
                
                for (p.params) |param| {
                    if (param.node_type == .Identifier) {
                        if (param.data.Identifier.resolved_symbol) |sym| {
                            if (!self.states.contains(sym)) {
                                try self.states.put(sym, VariableState{ .state = .Owned });
                            }
                            try self.scopes.items[self.scopes.items.len - 1].append(sym);
                        }
                    }
                }
                
                try self.checkNode(p.body);
                
                const popped_scope = self.scopes.pop();
                var drops = std.ArrayList(*symbols.Symbol).init(self.allocator);
                for (popped_scope.items) |sym| {
                    if (self.states.get(sym)) |st| {
                        if (st.state == .Owned) {
                            if (sym.decl_node) |decl| {
                                if (decl.inferred_type) |t| {
                                    if (types.isMoveType(t) or sym.is_context_manager) {
                                        try drops.append(sym);
                                        var new_st = st;
                                        new_st.state = .Dropped;
                                        try self.states.put(sym, new_st);
                                    }
                                }
                            }
                        }
                    }
                }
                popped_scope.deinit();
                if (drops.items.len > 0) {
                    p.auto_drops = try drops.toOwnedSlice();
                } else {
                    drops.deinit();
                }
            },
            .Identifier => |*id| {
                if (id.resolved_symbol) |sym| {
                    var state = self.states.get(sym);
                    if (state == null) {
                        var new_state = VariableState{ .state = .Owned };
                        if (sym.decl_node) |decl| {
                            if (decl.node_type == .VarDecl) {
                                for (decl.data.VarDecl.names, 0..) |vname, idx| {
                                    if (std.mem.eql(u8, vname, sym.name)) {
                                        if (idx < decl.data.VarDecl.type_annots.len) {
                                            if (decl.data.VarDecl.type_annots[idx]) |annot| {
                                                new_state.annotated_lifetime = annot.lifetime;
                                                if (annot.lifetime) |l| {
                                                    ast.debugPrint("Borrowck Info: Tracking explicit lifetime '{s}' for variable '{s}'\n", .{ l, sym.name });
                                                }
                                            }
                                        }
                                        break;
                                    }
                                }
                            }
                        }
                        try self.states.put(sym, new_state);
                        state = new_state;
                    }

                    const st = state.?;
                    if (st.state == .Moved) {
                        std.debug.print("Borrowck Error: Use of moved value '{s}' at row {d}, col {d}\n", .{ id.name, node.span.start_row, node.span.start_col });
                        return error.UseAfterMove;
                    }
                    if (st.state == .Dropped) {
                        std.debug.print("Borrowck Error: Use of dropped value '{s}' at row {d}, col {d}\n", .{ id.name, node.span.start_row, node.span.start_col });
                        return error.UseAfterDrop;
                    }
                }
            },
            .CallExpr => |*c| {
                try self.checkNode(c.callee);

                // Built-in `drop` detection
                if (c.callee.node_type == .Identifier) {
                    const name = c.callee.data.Identifier.name;
                    if (std.mem.eql(u8, name, "drop")) {
                        if (c.arguments.len != 1) return error.InvalidDrop;
                        const arg = c.arguments[0];
                        if (arg.node_type == .Identifier) {
                            if (arg.data.Identifier.resolved_symbol) |sym| {
                                var state = self.states.get(sym) orelse VariableState{ .state = .Owned };
                                state.state = .Dropped;
                                try self.states.put(sym, state);
                            }
                        }
                        return;
                    }
                }

                for (c.arguments) |arg| {
                    try self.checkNode(arg);
                    // Pass-by-value is a move for complex types
                    if (arg.node_type == .Identifier) {
                        try self.handleMove(arg);
                    }
                }
            },
            .FunDecl => |*f| {
                const new_scope = std.ArrayList(*symbols.Symbol).init(self.allocator);
                try self.scopes.append(new_scope);
                
                for (f.params) |param| {
                    if (param.node_type == .Identifier) {
                        if (param.data.Identifier.resolved_symbol) |sym| {
                            if (!self.states.contains(sym)) {
                                try self.states.put(sym, VariableState{ .state = .Owned });
                            }
                            try self.scopes.items[self.scopes.items.len - 1].append(sym);
                        }
                    }
                }
                
                try self.checkNode(f.body);
                
                const popped_scope = self.scopes.pop();
                var drops = std.ArrayList(*symbols.Symbol).init(self.allocator);
                for (popped_scope.items) |sym| {
                    if (self.states.get(sym)) |st| {
                        if (st.state == .Owned) {
                            if (sym.decl_node) |decl| {
                                if (decl.inferred_type) |t| {
                                    if (types.isMoveType(t) or sym.is_context_manager) {
                                        try drops.append(sym);
                                    }
                                }
                            }
                        }
                    }
                }
                popped_scope.deinit();
                if (drops.items.len > 0) {
                    f.auto_drops = try drops.toOwnedSlice();
                } else {
                    drops.deinit();
                }
            },
            .BlockStmt => |*b| {
                const new_scope = std.ArrayList(*symbols.Symbol).init(self.allocator);
                try self.scopes.append(new_scope);
                
                for (b.statements) |stmt| {
                    try self.checkNode(stmt);
                }
                
                const popped_scope = self.scopes.pop();
                var drops = std.ArrayList(*symbols.Symbol).init(self.allocator);
                for (popped_scope.items) |sym| {
                    if (self.states.get(sym)) |st| {
                        if (st.state == .Owned) {
                            if (sym.decl_node) |decl| {
                                if (decl.inferred_type) |t| {
                                    if (types.isMoveType(t) or sym.is_context_manager) {
                                        try drops.append(sym);
                                        var new_st = st;
                                        new_st.state = .Dropped;
                                        try self.states.put(sym, new_st);
                                    }
                                }
                            }
                        }
                    }
                }
                popped_scope.deinit();
                if (drops.items.len > 0) {
                    b.auto_drops = try drops.toOwnedSlice();
                } else {
                    drops.deinit();
                }
            },
            .IfStmt => |*i| {
                try self.checkNode(i.condition);
                try self.checkNode(i.then_branch);
                if (i.else_branch) |eb| {
                    try self.checkNode(eb);
                }
            },
            .WithStmt => |*w| {
                try self.checkNode(w.expr);
                
                const new_scope = std.ArrayList(*symbols.Symbol).init(self.allocator);
                try self.scopes.append(new_scope);
                
                if (w.resolved_symbol) |sym| {
                    if (!self.states.contains(sym)) {
                        try self.states.put(sym, VariableState{ .state = .Owned });
                    }
                    try self.scopes.items[self.scopes.items.len - 1].append(sym);
                }
                
                try self.checkNode(w.body);
                
                const popped_scope = self.scopes.pop();
                var drops = std.ArrayList(*symbols.Symbol).init(self.allocator);
                for (popped_scope.items) |sym| {
                    if (self.states.get(sym)) |st| {
                        if (st.state == .Owned) {
                            if (sym.decl_node) |decl| {
                                if (decl.inferred_type) |t| {
                                    if (types.isMoveType(t) or sym.is_context_manager) {
                                        try drops.append(sym);
                                        var new_st = st;
                                        new_st.state = .Dropped;
                                        try self.states.put(sym, new_st);
                                    }
                                }
                            }
                        }
                    }
                }
                popped_scope.deinit();
                if (drops.items.len > 0) {
                    w.auto_drops = try drops.toOwnedSlice();
                } else {
                    drops.deinit();
                }
            },
            .ForStmt => |*f| {
                try self.checkNode(f.iterable);
                try self.checkNode(f.body);
            },
            .WhileStmt => |*w| {
                try self.checkNode(w.condition);
                try self.checkNode(w.body);
            },
            .ReturnStmt => |*r| {
                if (r.values) |values| {
                    for (values) |v| {
                        try self.checkNode(v);
                        if (v.node_type == .Identifier) {
                            try self.handleMove(v);
                        }
                    }
                }
                
                var drops = std.ArrayList(*symbols.Symbol).init(self.allocator);
                var i: usize = self.scopes.items.len;
                while (i > 0) : (i -= 1) {
                    const scope = self.scopes.items[i - 1];
                    for (scope.items) |sym| {
                        if (self.states.get(sym)) |st| {
                            if (st.state == .Owned) {
                                if (sym.decl_node) |decl| {
                                    if (decl.inferred_type) |t| {
                                            if (types.isMoveType(t) or sym.is_context_manager) {
                                                var is_returned = false;
                                                if (r.values) |values| {
                                                    for (values) |v| {
                                                        if (v.node_type == .Identifier) {
                                                            if (v.data.Identifier.resolved_symbol) |ret_sym| {
                                                                if (ret_sym == sym) {
                                                                    is_returned = true;
                                                                    break;
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                                if (!is_returned) {
                                                    try drops.append(sym);
                                                }
                                            }
                                    }
                                }
                            }
                        }
                    }
                }
                if (drops.items.len > 0) {
                    r.auto_drops = try drops.toOwnedSlice();
                } else {
                    drops.deinit();
                }
            },
            .BinaryExpr => |*b| {
                try self.checkNode(b.left);
                try self.checkNode(b.right);
            },
            .UnaryExpr => |*u| {
                try self.checkNode(u.operand);
            },
            .ListLiteral => |*l| {
                for (l.elements) |element| {
                    try self.checkNode(element);
                    if (element.node_type == .Identifier) {
                        try self.handleMove(element);
                    }
                }
            },
            else => {},
        }
    }

    fn handleMove(self: *BorrowChecker, id_node: *ast.Node) !void {
        if (id_node.node_type != .Identifier) return;
        const id = id_node.data.Identifier;
        if (id.resolved_symbol) |sym| {
            if (sym.decl_node) |decl| {
                if (decl.inferred_type) |t| {
                    if (types.isMoveType(t)) {
                        var state = self.states.get(sym) orelse VariableState{ .state = .Owned };
                        state.state = .Moved;
                        try self.states.put(sym, state);
                    }
                }
            }
        }
    }
};
