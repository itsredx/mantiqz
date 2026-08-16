//! Type checker — the second semantic pass after `sema.zig`.
//!
//! Walks the AST and assigns a resolved `types.Type` to every expression node,
//! reporting `TypeMismatch`, `UnknownType`, or `ImplicitAllocationNotAllowed`
//! errors. Also handles generic instantiation (clone-and-recheck monomorphisation)
//! and closure type inference.
//!
//! Key responsibilities:
//! - `checkNode` — dispatch to per-variant type inference (3000+ lines)
//! - `validateType` — resolve a `TypeAnnotation` into a `Type` struct
//! - `inferGenericBindings` — match call-site argument types against generic
//!   parameters to deduce concrete type arguments
//! - `instantiateStruct` / generic function instantiation — template cloning
//!   via `deepCopyNode`, followed by re-analysis of the copy
//! - Nizam strict-mode enforcement: flags such as `is_string_imported` gate
//!   implicit heap allocation
//! - `in_unsafe_block` — tracks `unsafe` context for union field access checks
//! - Closure type building — creates `FunctionType` entries for closure literals
//!   and stores them in `closure_types`

const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");
const sema = @import("sema.zig");
const symbols = @import("symbols.zig");

pub const TypeError = error{
    TypeMismatch,
    UnknownType,
    ImplicitAllocationNotAllowed,
};

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    mode: ast.LanguageMode,
    current_func: ?*ast.Node = null,
    is_string_imported: bool = false,
    is_list_imported: bool = false,
    is_dict_imported: bool = false,
    is_option_imported: bool = false,
    is_result_imported: bool = false,
    program: ?*ast.Node = null,
    closure_counter: u32 = 0,
    closure_types: std.AutoHashMap(u32, *types.FunctionType),
    struct_types: std.StringHashMap(*types.StructType),
    class_types: std.StringHashMap(*types.ClassType),
    interface_types: std.StringHashMap(*types.InterfaceType),
    struct_templates: std.StringHashMap(*ast.Node),
    enum_types: std.StringHashMap(*types.EnumType),
    union_types: std.StringHashMap(*types.UnionType),
    in_unsafe_block: bool = false,
    typechecked_modules: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, mode: ast.LanguageMode) TypeChecker {
        return .{ 
            .allocator = allocator, 
            .mode = mode,
            .closure_types = std.AutoHashMap(u32, *types.FunctionType).init(allocator),
            .struct_types = std.StringHashMap(*types.StructType).init(allocator),
            .class_types = std.StringHashMap(*types.ClassType).init(allocator),
            .interface_types = std.StringHashMap(*types.InterfaceType).init(allocator),
            .struct_templates = std.StringHashMap(*ast.Node).init(allocator),
            .enum_types = std.StringHashMap(*types.EnumType).init(allocator),
            .union_types = std.StringHashMap(*types.UnionType).init(allocator),
            .typechecked_modules = std.StringHashMap(void).init(allocator),
        };
    }

    fn isTypeOrModuleNode(self: *TypeChecker, node: *const ast.Node) bool {
        switch (node.data) {
            .Identifier => |id| {
                if (id.resolved_symbol) |sym| {
                    switch (sym.kind) {
                        .Struct, .Union, .Class, .Enum, .Interface, .Module => return true,
                        else => return false,
                    }
                }
                return false;
            },
            .MemberExpr => |mem| {
                if (self.isTypeOrModuleNode(mem.object)) {
                    if (mem.object.inferred_type) |obj_t| {
                        if (obj_t.kind == .Module and obj_t.module_scope != null) {
                            const mod_scope = @as(*symbols.Scope, @ptrCast(@alignCast(obj_t.module_scope.?)));
                            if (mod_scope.resolveLocal(mem.property)) |sym| {
                                switch (sym.kind) {
                                    .Struct, .Union, .Class, .Enum, .Interface, .Module => return true,
                                    else => return false,
                                }
                            }
                        }
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn checkProgram(self: *TypeChecker, program: *ast.Node) !void {
        self.program = program;
        if (program.node_type != .Program) return;

        // If this module defines standard types, allow their use without imports
        for (program.data.Program.declarations) |decl| {
            if (decl.node_type == .StructDecl) {
                const s_name = decl.data.StructDecl.name;
                if (std.mem.eql(u8, s_name, "String") or std.mem.eql(u8, s_name, "StringBuilder")) {
                    self.is_string_imported = true;
                } else if (std.mem.eql(u8, s_name, "List")) {
                    self.is_list_imported = true;
                } else if (std.mem.eql(u8, s_name, "Dict")) {
                    self.is_dict_imported = true;
                } else if (std.mem.eql(u8, s_name, "Option")) {
                    self.is_option_imported = true;
                } else if (std.mem.eql(u8, s_name, "Result")) {
                    self.is_result_imported = true;
                }
            } else if (decl.node_type == .UnionDecl) {
                const u_name = decl.data.UnionDecl.name;
                if (std.mem.eql(u8, u_name, "Option")) {
                    self.is_option_imported = true;
                } else if (std.mem.eql(u8, u_name, "Result")) {
                    self.is_result_imported = true;
                }
            }
        }

        // Scan for imports to enforce Nizam rules and recursively typecheck modules
        for (program.data.Program.declarations) |decl| {
            if (decl.node_type == .ImportDecl) {
                const imp = decl.data.ImportDecl;
                if (std.mem.eql(u8, imp.target, "std.quantum") or std.mem.eql(u8, imp.target, "std.collections") or std.mem.eql(u8, imp.target, "std.option") or std.mem.eql(u8, imp.target, "std.result")) {
                    if (std.mem.eql(u8, imp.target, "std.collections")) {
                        if (imp.imported_symbols.len == 0) {
                            self.is_string_imported = true;
                            self.is_list_imported = true;
                            self.is_dict_imported = true;
                        } else {
                            for (imp.imported_symbols) |sym| {
                                if (std.mem.eql(u8, sym, "String")) self.is_string_imported = true;
                                if (std.mem.eql(u8, sym, "List")) self.is_list_imported = true;
                                if (std.mem.eql(u8, sym, "Dict")) self.is_dict_imported = true;
                            }
                        }
                    } else if (std.mem.eql(u8, imp.target, "std.option")) {
                        if (imp.imported_symbols.len == 0) {
                            self.is_option_imported = true;
                        } else {
                            for (imp.imported_symbols) |sym| {
                                if (std.mem.eql(u8, sym, "Option") or std.mem.eql(u8, sym, "Some") or std.mem.eql(u8, sym, "Empty")) {
                                    self.is_option_imported = true;
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, imp.target, "std.result")) {
                        if (imp.imported_symbols.len == 0) {
                            self.is_result_imported = true;
                        } else {
                            for (imp.imported_symbols) |sym| {
                                if (std.mem.eql(u8, sym, "Result") or std.mem.eql(u8, sym, "Ok") or std.mem.eql(u8, sym, "Err")) {
                                    self.is_result_imported = true;
                                }
                            }
                        }
                    }
                }
                
                if (std.mem.eql(u8, imp.target, "std.string")) {
                    if (imp.imported_symbols.len == 0) {
                        self.is_string_imported = true;
                    } else {
                        for (imp.imported_symbols) |sym| {
                            if (std.mem.eql(u8, sym, "String")) self.is_string_imported = true;
                        }
                    }
                }

                if (imp.module_ast) |sub_ast| {
                    if (!self.typechecked_modules.contains(imp.target)) {
                        try self.typechecked_modules.put(imp.target, {});
                        try self.checkProgram(sub_ast);
                    }
                }

                if (imp.imported_symbols.len > 0) {
                    for (imp.imported_symbols) |sym_name| {
                        var mangled_prefix = std.ArrayList(u8).init(self.allocator);
                        defer mangled_prefix.deinit();
                        try mangled_prefix.appendSlice("mantiq_");
                        for (imp.target) |c| {
                            if (c == '/') {
                                try mangled_prefix.appendSlice("__");
                            } else if (c == '.') {
                                try mangled_prefix.appendSlice("_");
                            } else {
                                try mangled_prefix.append(c);
                            }
                        }
                        const mangled = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mangled_prefix.items, sym_name });
                        defer self.allocator.free(mangled);

                        std.debug.print("Import lookup mangled: '{s}'\n", .{mangled});
                        if (self.struct_types.get(mangled)) |st| {
                            try self.struct_types.put(sym_name, st);
                        }
                        if (self.enum_types.get(mangled)) |et| {
                            try self.enum_types.put(sym_name, et);
                        }
                        if (self.union_types.get(mangled)) |ut| {
                            try self.union_types.put(sym_name, ut);
                        }
                    }
                }
            }
        }

        for (program.data.Program.declarations) |decl| {
            try self.checkNode(decl);
            
            // Top-level unhandled Result check
            const decl_type = decl.inferred_type orelse types.Type{ .kind = .Unknown };
            if (decl_type.kind == .Result or decl_type.kind == .Option) {
                if (decl.node_type == .CallExpr or decl.node_type == .MethodCallExpr) {
                    std.debug.print("Type Error: Ignored '{s}' value from top-level function call. Must be handled.\n", .{types.formatType(decl_type)});
                    return error.TypeMismatch;
                }
            }
        }
    }

    fn validateType(self: *TypeChecker, annot: ast.TypeAnnotation) anyerror!types.Type {
        const name = std.mem.trim(u8, annot.name, " \t\r\n");
        var type_kind: types.Type = .{ .kind = types.parseTypeString(name) };
        if (std.mem.eql(u8, name, "Tuple")) {
            type_kind.kind = .Tuple;
        } else if (type_kind.kind == .Unknown and std.mem.startsWith(u8, name, "Closure_")) {
            const id_str = name[8..];
            if (std.fmt.parseInt(u32, id_str, 10)) |cid| {
                type_kind.kind = .Closure;
                type_kind.closure_id = cid;
                if (self.closure_types.get(cid)) |fn_type| {
                    type_kind.function = fn_type;
                }
            } else |_| {
                std.debug.print("Type Error: Invalid closure ID in type annotation '{s}'\n", .{name});
                return error.UnknownType;
            }
        }
        
        if (self.mode == .Nizam) {
            const is_any_string = std.mem.eql(u8, name, "String") or
                std.mem.eql(u8, name, "webstr") or std.mem.eql(u8, name, "utf16str") or
                std.mem.eql(u8, name, "rangestr") or std.mem.eql(u8, name, "utf32str");
            if (is_any_string and !self.is_string_imported) {
                std.debug.print("Type Error: '{s}' requires an explicit import in Nizam (e.g. from std.string import String)\n", .{name});
                return error.ImplicitAllocationNotAllowed;
            }
            if (std.mem.eql(u8, name, "List") and !self.is_list_imported) {
                const is_fixed_size = if (annot.generics) |gens| gens.len == 2 else false;
                if (!is_fixed_size) {
                    std.debug.print("Type Error: 'List' requires an explicit import in Nizam (e.g. from std.collections import List)\n", .{});
                    return error.ImplicitAllocationNotAllowed;
                }
            }
            if (std.mem.eql(u8, name, "Dict") and !self.is_dict_imported) {
                std.debug.print("Type Error: 'Dict' requires an explicit import in Nizam (e.g. from std.collections import Dict)\n", .{});
                return error.ImplicitAllocationNotAllowed;
            }
            if (std.mem.eql(u8, name, "Option") and !self.is_option_imported) {
                std.debug.print("Type Error: 'Option' requires an explicit import in Nizam (e.g. from std.option import Option)\n", .{});
                return error.ImplicitAllocationNotAllowed;
            }
            if (std.mem.eql(u8, name, "Result") and !self.is_result_imported) {
                std.debug.print("Type Error: 'Result' requires an explicit import in Nizam (e.g. from std.result import Result)\n", .{});
                return error.ImplicitAllocationNotAllowed;
            }
        }

        if (self.struct_types.get(name)) |st| {
            return types.Type{ .kind = .Struct, .struct_type = st };
        }
        
        if (self.class_types.get(name)) |cls| {
            return types.Type{ .kind = .Class, .class_type = cls };
        }
        
        if (self.interface_types.get(name)) |iface| {
            return types.Type{ .kind = .Interface, .interface_type = iface };
        }

        if (self.union_types.get(name)) |ut| {
            return types.Type{ .kind = .Union, .union_type = ut };
        }

        if (self.enum_types.get(name)) |et| {
            return types.Type{ .kind = .Enum, .enum_type = et };
        }
        
        if (self.struct_templates.get(name)) |tmpl| {
            if (annot.generics) |gens| {
                var t_types = std.ArrayList(types.Type).init(self.allocator);
                for (gens) |gen| {
                    try t_types.append(try self.validateType(gen));
                }
                const st = try self.instantiateStruct(tmpl, try t_types.toOwnedSlice());
                return types.Type{ .kind = .Struct, .struct_type = st };
            } else {
                std.debug.print("Type Error: Struct '{s}' requires generic arguments\n", .{name});
                return error.TypeMismatch;
            }
        }

        if (annot.generics) |gens| {
            if (type_kind.kind == .Tuple) {
                var t_types = std.ArrayList(types.Type).init(self.allocator);
                for (gens) |gen| {
                    try t_types.append(try self.validateType(gen));
                }
                type_kind.tuple_types = try t_types.toOwnedSlice();
            } else if (type_kind.kind == .List and gens.len == 2) {
                const inner_t = try self.validateType(gens[0]);
                const payload_ptr = try self.allocator.create(types.Type);
                payload_ptr.* = inner_t;
                type_kind.payload = payload_ptr;
                
                var array_len: ?usize = null;
                const n_name = gens[1].name;
                if (std.fmt.parseInt(usize, n_name, 10)) |val| {
                    array_len = val;
                } else |_| {
                    std.debug.print("Type Error: Invalid array size '{s}' in List type annotation — expected an integer literal\n", .{n_name});
                    return error.TypeMismatch;
                }
                type_kind.array_len = array_len;
            } else if (type_kind.kind == .Dict and gens.len == 2) {
                var kv_types = try self.allocator.alloc(types.Type, 2);
                kv_types[0] = try self.validateType(gens[0]);
                kv_types[1] = try self.validateType(gens[1]);
                type_kind.tuple_types = kv_types;
            } else if (type_kind.kind == .Result and gens.len >= 1) {
                const inner_t = try self.validateType(gens[0]);
                const payload_ptr = try self.allocator.create(types.Type);
                payload_ptr.* = inner_t;
                type_kind.payload = payload_ptr;
            } else if (gens.len == 1) {
                const inner_t = try self.validateType(gens[0]);
                const payload_ptr = try self.allocator.create(types.Type);
                payload_ptr.* = inner_t;
                type_kind.payload = payload_ptr;
            } else {
                for (gens) |gen| {
                    _ = try self.validateType(gen);
                }
            }
        }
        
        if (std.mem.eql(u8, annot.name, "fn")) {
            type_kind.kind = .Function;
            var func_type = try self.allocator.create(types.FunctionType);
            func_type.* = types.FunctionType{
                .param_types = &[_]types.Type{},
                .return_type = undefined,
                .is_variadic = false,
                .is_async = false,
                .is_inline = false,
                .param_names = null,
                .default_values = null,
            };
            
            var p_types = std.ArrayList(types.Type).init(self.allocator);
            if (annot.params) |params| {
                for (params) |p_annot| {
                    try p_types.append(try self.validateType(p_annot));
                }
            }
            func_type.param_types = try p_types.toOwnedSlice();
            
            func_type.return_type = try self.allocator.create(types.Type);
            if (annot.return_type) |rt| {
                func_type.return_type.* = try self.validateType(rt.*);
            } else {
                func_type.return_type.* = .{ .kind = .Void };
            }
            
            type_kind.function = func_type;
        }

        return type_kind;
    }

    fn instantiateStruct(self: *TypeChecker, template: *ast.Node, type_args: []types.Type) anyerror!*types.StructType {
        const d = template.data.StructDecl;
        if (d.generic_params == null or d.generic_params.?.len != type_args.len) {
            std.debug.print("Type Error: Mismatched number of generic arguments for struct '{s}'\n", .{d.name});
            return error.TypeMismatch;
        }

        var mangled_name_buf = std.ArrayList(u8).init(self.allocator);
        try mangled_name_buf.appendSlice(d.name);
        for (type_args) |t| {
            try mangled_name_buf.appendSlice("_");
            try mangled_name_buf.appendSlice(types.formatType(t));
        }
        const mangled_name = try mangled_name_buf.toOwnedSlice();

        if (self.struct_types.get(mangled_name)) |st| {
            return st;
        }

        var bindings = std.StringHashMap(types.Type).init(self.allocator);
        for (d.generic_params.?, 0..) |gp, i| {
            try bindings.put(gp, type_args[i]);
        }

        var cloned = try cloneNode(self.allocator, template, bindings);
        cloned.data.StructDecl.name = mangled_name;
        cloned.data.StructDecl.generic_params = null;

        if (self.program) |prog| {
            var new_decls = std.ArrayList(*ast.Node).init(self.allocator);
            for (prog.data.Program.declarations) |decl| {
                try new_decls.append(decl);
            }
            try new_decls.append(cloned);
            prog.data.Program.declarations = try new_decls.toOwnedSlice();
        }

        var analyzer = try sema.SemanticAnalyzer.init(self.allocator, self.mode);

        const old_list = self.is_list_imported;
        const old_dict = self.is_dict_imported;
        const old_str = self.is_string_imported;

        if (template.module_name) |m_name| {
            if (std.mem.eql(u8, m_name, "mantiq_std_collections")) {
                self.is_list_imported = true;
                self.is_dict_imported = true;
                self.is_string_imported = true;
                const builtins = [_][]const u8{ "List", "Dict", "String" };
                for (builtins) |b| {
                    const sym = try self.allocator.create(symbols.Symbol);
                    sym.* = .{ .name = b, .kind = .Struct, .decl_node = template };
                    try analyzer.global_scope.define(sym);
                }
            }
        }

        try analyzer.declarePass1(cloned);
        try analyzer.resolvePass2(cloned);

        try self.checkNode(cloned);
        
        self.is_list_imported = old_list;
        self.is_dict_imported = old_dict;
        self.is_string_imported = old_str;

        if (self.struct_types.get(mangled_name)) |st| {
            return st;
        }
        return error.TypeMismatch;
    }

    fn checkNode(self: *TypeChecker, node: *ast.Node) !void {
        switch (node.data) {
            .NumberLiteral => {
                // Simplified inference: if no fractional part, treat as i32, otherwise f32.
                // Mantiq parser might eventually pass exact string or type tag.
                const val = node.data.NumberLiteral.value;
                if (@trunc(val) == val) {
                    node.inferred_type = .{ .kind = .I32 };
                } else {
                    node.inferred_type = .{ .kind = .F32 };
                }
            },
            .StringLiteral => {
                node.inferred_type = .{ .kind = .AsciiStr };
            },
            .InterpolatedString => |*is| {
                for (is.parts) |part| {
                    try self.checkNode(part);
                }
                node.inferred_type = .{ .kind = .String };
            },
            .BooleanLiteral => {
                node.inferred_type = .{ .kind = .Boolean };
            },
            .KeywordArg => |*k| {
                try self.checkNode(k.value);
                node.inferred_type = k.value.inferred_type;
            },
            .Identifier => |*id| {
                if (std.mem.eql(u8, id.name, "Empty")) {
                    if (self.mode == .Nizam and !self.is_option_imported) {
                        std.debug.print("Type Error: 'Empty' requires an explicit import in Nizam (e.g. from std.option import Empty)\n", .{});
                        return error.ImplicitAllocationNotAllowed;
                    }
                    node.inferred_type = .{ .kind = .Option };
                } else if (std.mem.eql(u8, id.name, "None")) {
                    const any_t = try self.allocator.create(types.Type);
                    any_t.* = .{ .kind = .Any };
                    node.inferred_type = .{ .kind = .RawPointer, .payload = any_t };
                } else if (std.mem.eql(u8, id.name, "stdin") or std.mem.eql(u8, id.name, "stdout") or std.mem.eql(u8, id.name, "stderr")) {
                    // Mapped to raw file descriptors (0, 1, 2)
                    node.inferred_type = .{ .kind = .I32 };
                } else if (id.resolved_symbol) |sym| {
                    if (sym.kind == .Module) {
                        node.inferred_type = .{ .kind = .Module, .module_scope = sym.module_scope };
                    } else if (sym.decl_node) |decl| {
                        if (decl.node_type == .TryStmt) {
                            node.inferred_type = types.Type{ .kind = .I32 };
                        } else {
                            node.inferred_type = decl.inferred_type;
                        }
                    }
                } else {
                    node.inferred_type = .{ .kind = .Error };
                }
            },
            .VarDecl => |*v| {
                if (v.names.len > 0) {
                    for (v.names, 0..) |name, i| {
                        var decl_type: types.Type = .{ .kind = .Unknown };
                        if (i < v.type_annots.len) {
                            if (v.type_annots[i]) |annot| {
                                decl_type = try self.validateType(annot);
                                if (decl_type.kind == .Unknown) {
                                    std.debug.print("Type Error: Unknown type annotation '{s}' at line {d}:{d}\n", .{annot.name, node.span.start_row + 1, node.span.start_col + 1});
                                    return error.UnknownType;
                                }
                            }
                        }

                        var has_initializer = false;
                        if (v.initializers) |inits| {
                            if (i < inits.len or inits.len == 1) {
                                has_initializer = true;
                            }
                        }
                        if (!has_initializer) {
                            std.debug.print("Type Error: Variable '{s}' must have an initializer\n", .{name});
                            return error.TypeMismatch;
                        }

                        var init_type: types.Type = .{ .kind = .Unknown };
                        if (v.initializers) |inits| {
                            if (i < inits.len) {
                                try self.checkNode(inits[i]);
                                init_type = inits[i].inferred_type orelse types.Type{ .kind = .Unknown };
                            } else if (inits.len == 1) {
                                try self.checkNode(inits[0]);
                                const tuple_val_type = inits[0].inferred_type orelse types.Type{ .kind = .Unknown };
                                if (tuple_val_type.kind == .Tuple and tuple_val_type.tuple_types != null) {
                                    if (i < tuple_val_type.tuple_types.?.len) {
                                        init_type = tuple_val_type.tuple_types.?[i];
                                    } else {
                                        std.debug.print("Type Error: Not enough values in tuple to destructure into '{s}'\n", .{name});
                                        return error.TypeMismatch;
                                    }
                                }
                            }
                        }

                        if (decl_type.kind != .Unknown) {
                            if (init_type.kind != .Unknown and !types.isImplicitlyConvertible(init_type, decl_type)) {
                                std.debug.print("Type Error: Cannot assign value of type '{s}' to variable '{s}' of type '{s}'\n", .{ types.formatType(init_type), name, types.formatType(decl_type) });
                                return error.TypeMismatch;
                            }
                            node.inferred_type = decl_type;
                        } else if (init_type.kind != .Unknown) {
                            node.inferred_type = init_type;
                        } else {
                            node.inferred_type = .{ .kind = .Any };
                        }
                    }
                }
            },
            .FunDecl => |*f| {
                const prev_func = self.current_func;
                self.current_func = node;

                if (f.generic_params != null) {
                    node.inferred_type = .{ .kind = .Unknown }; // Unresolved generic template
                    self.current_func = prev_func;
                    return;
                }

                for (f.params, 0..) |param, i| {
                    if (f.param_types[i]) |annot| {
                        param.inferred_type = try self.validateType(annot);
                    } else if (param.inferred_type == null) {
                        param.inferred_type = .{ .kind = .Any };
                    }
                }

                try self.checkNode(f.body);
                
                var ret_type: types.Type = .{ .kind = .Void };
                if (self.findReturnType(f.body)) |rt| {
                    ret_type = rt;
                }
                if (f.return_type) |annot| {
                    ret_type = try self.validateType(annot);
                }

                var func_type: *types.FunctionType = undefined;
                if (node.inferred_type != null and node.inferred_type.?.kind == .Function) {
                    func_type = node.inferred_type.?.function.?;
                } else {
                    func_type = try self.allocator.create(types.FunctionType);
                    func_type.return_type = try self.allocator.create(types.Type);
                    node.inferred_type = .{ .kind = .Function, .function = func_type };
                }

                func_type.is_variadic = f.is_variadic;
                func_type.is_async = f.is_async;
                func_type.is_inline = f.is_inline;
                
                var p_types = std.ArrayList(types.Type).init(self.allocator);
                for (f.params) |param| {
                    try p_types.append(param.inferred_type orelse .{ .kind = .Any });
                }
                func_type.param_types = try p_types.toOwnedSlice();
                func_type.param_names = f.param_names;
                
                var default_vals = std.ArrayList(?*anyopaque).init(self.allocator);
                for (f.default_values, 0..) |def_val, i| {
                    if (def_val) |dv| {
                        try self.checkNode(dv);
                        const dv_type = dv.inferred_type orelse types.Type{ .kind = .Unknown };
                        const p_type = func_type.param_types[i];
                        if (p_type.kind != .Any and p_type.kind != .Unknown and !types.isImplicitlyConvertible(dv_type, p_type)) {
                            std.debug.print("Type Error: Default value of type '{s}' cannot be assigned to parameter '{s}' of type '{s}'\n", .{types.formatType(dv_type), f.param_names[i], types.formatType(p_type)});
                            return error.TypeMismatch;
                        }
                        try default_vals.append(@ptrCast(dv));
                    } else {
                        try default_vals.append(null);
                    }
                }
                func_type.default_values = try default_vals.toOwnedSlice();
                
                func_type.return_type.* = ret_type;
                
                self.current_func = prev_func;
            },
            .BreakStmt, .ContinueStmt, .PassStmt => {
                node.inferred_type = .{ .kind = .Unknown };
            },
            .BlockStmt => |*b| {
                var last_type: types.Type = .{ .kind = .Unknown };
                for (b.statements, 0..) |stmt, i| {
                    try self.checkNode(stmt);
                    const stmt_type = stmt.inferred_type orelse types.Type{ .kind = .Unknown };
                    
                    if (i < b.statements.len - 1) {
                        if (stmt_type.kind == .Result or stmt_type.kind == .Option) {
                            if (stmt.node_type == .CallExpr or stmt.node_type == .MethodCallExpr) {
                                std.debug.print("Type Error: Ignored '{s}' value from function call. Must be handled with 'try' or explicitly assigned.\n", .{types.formatType(stmt_type)});
                                return error.TypeMismatch;
                            }
                        }
                    }
                    
                    if (i == b.statements.len - 1) {
                        last_type = stmt_type;
                    }
                }
                node.inferred_type = last_type;
            },
            .CallExpr => |*c| {
                try self.checkNode(c.callee);
                
                var is_builtin = false;
                if (c.callee.node_type == .Identifier) {
                    const func_name = c.callee.data.Identifier.name;
                    const is_user_func = if (c.callee.data.Identifier.resolved_symbol) |sym|
                        sym.kind == .Function and sym.decl_node != null and sym.decl_node.?.node_type == .FunDecl
                    else
                        false;
                    if (std.mem.eql(u8, func_name, "make")) {
                        if (c.generic_args) |gens| {
                            if (gens.len == 1) {
                                const base_type = try self.allocator.create(types.Type);
                                base_type.* = try self.validateType(gens[0]);
                                node.inferred_type = .{
                                    .kind = .RawPointer,
                                    .payload = base_type,
                                };
                            } else {
                                node.inferred_type = .{ .kind = .Any };
                            }
                        } else {
                            const any_type = try self.allocator.create(types.Type);
                            any_type.* = .{ .kind = .Any };
                            node.inferred_type = .{
                                .kind = .RawPointer,
                                .payload = any_type,
                            };
                        }
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "List")) {
                        if (self.mode == .Nizam and !self.is_list_imported) {
                            var is_fixed_size = false;
                            if (c.generic_args) |gens| {
                                if (gens.len == 2) is_fixed_size = true;
                            }
                            if (!is_fixed_size) {
                                std.debug.print("Type Error: 'List' requires an explicit import in Nizam (e.g. from std.collections import List)\n", .{});
                                return error.ImplicitAllocationNotAllowed;
                            }
                        }
                        if (c.generic_args) |gens| {
                            if (gens.len == 1) {
                                const base_type = try self.allocator.create(types.Type);
                                base_type.* = try self.validateType(gens[0]);
                                node.inferred_type = .{
                                    .kind = .List,
                                    .payload = base_type,
                                };
                            } else if (gens.len == 2) {
                                const base_type = try self.allocator.create(types.Type);
                                base_type.* = try self.validateType(gens[0]);
                                node.inferred_type = .{
                                    .kind = .List,
                                    .payload = base_type,
                                };
                            } else {
                                node.inferred_type = .{ .kind = .List };
                            }
                        } else {
                            node.inferred_type = .{ .kind = .List };
                        }
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "Dict")) {
                        if (self.mode == .Nizam and !self.is_dict_imported) {
                            std.debug.print("Type Error: 'Dict' requires an explicit import in Nizam (e.g. from std.collections import Dict)\n", .{});
                            return error.ImplicitAllocationNotAllowed;
                        }
                        if (c.generic_args) |gens| {
                            if (gens.len == 2) {
                                var kv_types = try self.allocator.alloc(types.Type, 2);
                                kv_types[0] = try self.validateType(gens[0]);
                                kv_types[1] = try self.validateType(gens[1]);
                                node.inferred_type = .{
                                    .kind = .Dict,
                                    .tuple_types = kv_types,
                                };
                            } else {
                                node.inferred_type = .{ .kind = .Dict };
                            }
                        } else {
                            node.inferred_type = .{ .kind = .Dict };
                        }
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "drop")) {
                        node.inferred_type = .{ .kind = .Void };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "Option")) {
                        if (self.mode == .Nizam and !self.is_option_imported) {
                            std.debug.print("Type Error: 'Option' requires an explicit import in Nizam (e.g. from std.option import Option)\n", .{});
                            return error.ImplicitAllocationNotAllowed;
                        }
                        if (c.generic_args) |gens| {
                            if (gens.len == 1) {
                                const base_type = try self.allocator.create(types.Type);
                                base_type.* = try self.validateType(gens[0]);
                                node.inferred_type = .{
                                    .kind = .Option,
                                    .payload = base_type,
                                };
                            } else {
                                node.inferred_type = .{ .kind = .Option };
                            }
                        } else {
                            node.inferred_type = .{ .kind = .Option };
                        }
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "Result")) {
                        if (self.mode == .Nizam and !self.is_result_imported) {
                            std.debug.print("Type Error: 'Result' requires an explicit import in Nizam (e.g. from std.result import Result)\n", .{});
                            return error.ImplicitAllocationNotAllowed;
                        }
                        if (c.generic_args) |gens| {
                            if (gens.len >= 1) {
                                const base_type = try self.allocator.create(types.Type);
                                base_type.* = try self.validateType(gens[0]);
                                node.inferred_type = .{
                                    .kind = .Result,
                                    .payload = base_type,
                                };
                            } else {
                                node.inferred_type = .{ .kind = .Result };
                            }
                        } else {
                            node.inferred_type = .{ .kind = .Result };
                        }
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "Some")) {
                        if (self.mode == .Nizam and !self.is_option_imported) {
                            std.debug.print("Type Error: 'Some' requires an explicit import in Nizam (e.g. from std.option import Option)\n", .{});
                            return error.ImplicitAllocationNotAllowed;
                        }
                        if (c.arguments.len == 1) {
                            try self.checkNode(c.arguments[0]);
                            const payload_type = c.arguments[0].inferred_type orelse types.Type{ .kind = .Any };
                            const payload_ptr = try self.allocator.create(types.Type);
                            payload_ptr.* = payload_type;
                            node.inferred_type = .{ .kind = .Option, .payload = payload_ptr };
                        } else {
                            node.inferred_type = .{ .kind = .Option };
                        }
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "Ok")) {
                        if (self.mode == .Nizam and !self.is_result_imported) {
                            std.debug.print("Type Error: 'Ok' requires an explicit import in Nizam (e.g. from std.result import Result)\n", .{});
                            return error.ImplicitAllocationNotAllowed;
                        }
                        if (c.arguments.len == 1) {
                            try self.checkNode(c.arguments[0]);
                            const payload_type = c.arguments[0].inferred_type orelse types.Type{ .kind = .Any };
                            const payload_ptr = try self.allocator.create(types.Type);
                            payload_ptr.* = payload_type;
                            node.inferred_type = .{ .kind = .Result, .payload = payload_ptr };
                        } else {
                            node.inferred_type = .{ .kind = .Result };
                        }
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "Err")) {
                        if (self.mode == .Nizam and !self.is_result_imported) {
                            std.debug.print("Type Error: 'Err' requires an explicit import in Nizam (e.g. from std.result import Result)\n", .{});
                            return error.ImplicitAllocationNotAllowed;
                        }
                        if (c.arguments.len == 1) {
                            try self.checkNode(c.arguments[0]);
                            const err_type = c.arguments[0].inferred_type orelse types.Type{ .kind = .Any };
                            if (err_type.kind != .I32 and err_type.kind != .Any) {
                                std.debug.print("Type Error: 'Err' payload must be an i32 error code, got {s}\n", .{@tagName(err_type.kind)});
                                return TypeError.TypeMismatch;
                            }
                        }
                        node.inferred_type = .{ .kind = .Result };
                        is_builtin = true;
                    } else if ((std.mem.eql(u8, func_name, "H") or std.mem.eql(u8, func_name, "X") or std.mem.eql(u8, func_name, "Y") or std.mem.eql(u8, func_name, "Z") or std.mem.eql(u8, func_name, "qbit")) and !is_user_func) {
                        node.inferred_type = .{ .kind = .QBit };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "qreg") and !is_user_func) {
                        node.inferred_type = .{ .kind = .QReg };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "resize")) {
                        const any_type = try self.allocator.create(types.Type);
                        any_type.* = .{ .kind = .Any };
                        node.inferred_type = .{ .kind = .RawPointer, .payload = any_type };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "write") and !is_user_func) {
                        node.inferred_type = .{ .kind = .Void };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "read") and !is_user_func) {
                        node.inferred_type = .{ .kind = .String };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "open") and !is_user_func) {
                        node.inferred_type = .{ .kind = .I32 };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "close") and !is_user_func) {
                        node.inferred_type = .{ .kind = .Void };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "exists") and !is_user_func) {
                        node.inferred_type = .{ .kind = .Boolean };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "exit") and !is_user_func) {
                        node.inferred_type = .{ .kind = .Void };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "args") and !is_user_func) {
                        const ascii_str_type = try self.allocator.create(types.Type);
                        ascii_str_type.* = .{ .kind = .AsciiStr };
                        node.inferred_type = .{ .kind = .List, .payload = ascii_str_type };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "now") and !is_user_func) {
                        node.inferred_type = .{ .kind = .I64 };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "sleep") and !is_user_func) {
                        node.inferred_type = .{ .kind = .Void };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "os") and !is_user_func) {
                        node.inferred_type = .{ .kind = .AsciiStr };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "arch") and !is_user_func) {
                        node.inferred_type = .{ .kind = .AsciiStr };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "getenv") and !is_user_func) {
                        node.inferred_type = .{ .kind = .AsciiStr };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "setenv") and !is_user_func) {
                        node.inferred_type = .{ .kind = .Void };
                        is_builtin = true;
                    } else if (std.mem.eql(u8, func_name, "unsetenv") and !is_user_func) {
                        node.inferred_type = .{ .kind = .Void };
                        is_builtin = true;
                    } else if ((std.mem.eql(u8, func_name, "print") or std.mem.eql(u8, func_name, "println") or std.mem.eql(u8, func_name, "measure") or std.mem.eql(u8, func_name, "CNOT")) and !is_user_func) {
                        node.inferred_type = .{ .kind = .Void };
                        is_builtin = true;
                    }
                }
                for (c.arguments, 0..) |arg, i| {
                    try self.checkNode(arg);

                    if (is_builtin) {
                        var is_print = false;
                        if (c.callee.node_type == .Identifier) {
                            const fn_name = c.callee.data.Identifier.name;
                            if (std.mem.eql(u8, fn_name, "print") or std.mem.eql(u8, fn_name, "println")) {
                                is_print = true;
                            }
                        }
                        if (is_print) {
                            const arg_type = arg.inferred_type orelse types.Type{ .kind = .Unknown };
                            if (arg_type.kind == .Class and arg_type.class_type != null) {
                                const ct = arg_type.class_type.?;
                                var method_name: ?[]const u8 = null;
                                var return_t: types.Type = .{ .kind = .Unknown };
                                
                                for (ct.methods) |meth| {
                                    if (std.mem.eql(u8, meth.name, "__str__")) {
                                        method_name = "__str__";
                                        if (meth.type_kind.kind == .Function and meth.type_kind.function != null) {
                                            return_t = meth.type_kind.function.?.return_type.*;
                                        }
                                        break;
                                    }
                                }
                                if (method_name == null) {
                                    for (ct.methods) |meth| {
                                        if (std.mem.eql(u8, meth.name, "__repr__")) {
                                            method_name = "__repr__";
                                            if (meth.type_kind.kind == .Function and meth.type_kind.function != null) {
                                                return_t = meth.type_kind.function.?.return_type.*;
                                            }
                                            break;
                                        }
                                    }
                                }
                                
                                if (method_name) |m_name| {
                                    const new_node = try self.allocator.create(ast.Node);
                                    new_node.* = .{
                                        .node_type = .MethodCallExpr,
                                        .span = arg.span,
                                        .data = .{
                                            .MethodCallExpr = .{
                                                .receiver = arg,
                                                .method_name = m_name,
                                                .arguments = &[_]*ast.Node{},
                                                .is_dynamic = true,
                                            }
                                        },
                                        .inferred_type = return_t,
                                    };
                                    c.arguments[i] = new_node;
                                }
                            }
                        }
                    }
                }
                if (!is_builtin) {
                    var callee_type = c.callee.inferred_type orelse types.Type{ .kind = .Any };
                    if (callee_type.kind == .Function and callee_type.function != null) {
                        node.inferred_type = callee_type.function.?.return_type.*;
                    } else {
                        node.inferred_type = callee_type;
                    }

                    if (c.callee.node_type == .Identifier) {
                        if (c.callee.data.Identifier.resolved_symbol) |sym| {
                            if (sym.kind == .Function and sym.decl_node != null) {
                                if (sym.decl_node.?.node_type == .FunDecl) {
                                    const orig_f = &sym.decl_node.?.data.FunDecl;
                                    if (orig_f.generic_params != null) {
                                        var bindings = std.StringHashMap(types.Type).init(self.allocator);
                                        
                                        // Infer bindings
                                        for (c.arguments, 0..) |arg, i| {
                                            if (i >= orig_f.param_types.len) break;
                                            if (orig_f.param_types[i]) |annot| {
                                                const actual: types.Type = arg.inferred_type orelse .{ .kind = .Any };
                                                try inferGenericBindings(annot, actual, orig_f.generic_params.?, &bindings);
                                            }
                                        }
                                        
                                        // Build mangled name
                                        var mangled_name = std.ArrayList(u8).init(self.allocator);
                                        try mangled_name.appendSlice(orig_f.name);
                                        for (orig_f.generic_params.?) |g| {
                                            if (bindings.get(g)) |t| {
                                                try mangled_name.appendSlice("_");
                                                if (t.kind == .Closure and t.closure_id != null) {
                                                    try std.fmt.format(mangled_name.writer(), "Closure_{d}", .{t.closure_id.?});
                                                } else {
                                                    try mangled_name.appendSlice(types.formatType(t));
                                                }
                                            } else {
                                                try mangled_name.appendSlice("_Any");
                                            }
                                        }
                                        const final_name = try mangled_name.toOwnedSlice();
                                        ast.debugPrint("Instantiating generic function {s} -> {s}\n", .{orig_f.name, final_name});
                                        
                                        var found = false;
                                        for (self.program.?.data.Program.declarations) |decl| {
                                            if (decl.node_type == .FunDecl) {
                                                if (std.mem.eql(u8, decl.data.FunDecl.name, final_name)) {
                                                    found = true;
                                                    break;
                                                }
                                            }
                                        }
                                        
                                        if (!found) {
                                            const cloned_f = try cloneNode(self.allocator, sym.decl_node.?, bindings);
                                            cloned_f.data.FunDecl.name = final_name;
                                            cloned_f.data.FunDecl.generic_params = null;
                                            
                                            // Append to declarations
                                            var new_decls = try self.allocator.alloc(*ast.Node, self.program.?.data.Program.declarations.len + 1);
                                            @memcpy(new_decls[0..self.program.?.data.Program.declarations.len], self.program.?.data.Program.declarations);
                                            new_decls[self.program.?.data.Program.declarations.len] = cloned_f;
                                            self.program.?.data.Program.declarations = new_decls;
                                            
                                            // Run semantic analysis to resolve symbols
                                            var analyzer = try sema.SemanticAnalyzer.init(self.allocator, self.mode);
                                            // Provide the global symtab to the analyzer! 
                                            // Wait, analyzer creates a new global scope by default.
                                            // Is there a way to pass the existing global scope?
                                            // Actually, we can just run it on the cloned_f directly. It will create a global scope, but we just need local variables resolved!
                                            // And then we can merge or just let them live in the local scope.
                                            try analyzer.declarePass1(cloned_f);
                                            try analyzer.resolvePass2(cloned_f);
                                            
                                            // Typecheck the instantiated function
                                            try self.checkNode(cloned_f);
                                        }
                                        
                                        for (self.program.?.data.Program.declarations) |decl| {
                                            if (decl.node_type == .FunDecl and std.mem.eql(u8, decl.data.FunDecl.name, final_name)) {
                                                const inst_type = decl.inferred_type orelse types.Type{ .kind = .Any };
                                                if (inst_type.kind == .Function and inst_type.function != null) {
                                                    node.inferred_type = inst_type.function.?.return_type.*;
                                                } else {
                                                    node.inferred_type = inst_type;
                                                }
                                                
                                                const new_sym = try self.allocator.create(symbols.Symbol);
                                                new_sym.* = sym.*;
                                                new_sym.name = final_name;
                                                new_sym.decl_node = decl;
                                                
                                                var id_data = c.callee.data.Identifier;
                                                id_data.name = final_name;
                                                id_data.resolved_symbol = new_sym;
                                                c.callee.data = .{ .Identifier = id_data };
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if (c.callee.node_type == .Identifier) {
                        const name = c.callee.data.Identifier.name;
                        if (self.struct_templates.get(name)) |tmpl| {
                            if (c.generic_args) |gargs| {
                                var t_types = std.ArrayList(types.Type).init(self.allocator);
                                for (gargs) |gen| {
                                    try t_types.append(try self.validateType(gen));
                                }
                                const st = try self.instantiateStruct(tmpl, try t_types.toOwnedSlice());
                                
                                var id_data = c.callee.data.Identifier;
                                id_data.name = st.name;
                                c.callee.data = .{ .Identifier = id_data };
                                callee_type = types.Type{ .kind = .Struct, .struct_type = st };
                                c.callee.inferred_type = callee_type;
                            } else {
                                std.debug.print("Type Error: Struct '{s}' requires generic arguments\n", .{name});
                                return error.TypeMismatch;
                            }
                        }
                    }

                    if ((callee_type.kind == .Function or callee_type.kind == .Closure) and callee_type.function != null) {
                        const ft = callee_type.function.?;
                        
                        var has_spread = false;
                        for (c.arguments) |arg| {
                            if (arg.node_type == .SpreadExpr) has_spread = true;
                        }

                        // Normalize keyword arguments and default values
                        if (ft.param_names) |pnames| {
                            var new_args = std.ArrayList(*ast.Node).init(self.allocator);
                            try new_args.appendNTimes(undefined, pnames.len);
                            var filled = std.ArrayList(bool).init(self.allocator);
                            try filled.appendNTimes(false, pnames.len);
                            
                            var seen_keyword = false;
                            
                            for (c.arguments, 0..) |arg, arg_idx| {
                                if (arg.node_type == .KeywordArg) {
                                    seen_keyword = true;
                                    const kw_name = arg.data.KeywordArg.name;
                                    var found_idx: ?usize = null;
                                    for (pnames, 0..) |pn, p_i| {
                                        if (std.mem.eql(u8, pn, kw_name)) {
                                            found_idx = p_i;
                                            break;
                                        }
                                    }
                                    if (found_idx) |idx| {
                                        if (filled.items[idx]) {
                                            std.debug.print("Type Error: Multiple values for argument '{s}'\n", .{kw_name});
                                            return error.TypeMismatch;
                                        }
                                        new_args.items[idx] = arg.data.KeywordArg.value;
                                        filled.items[idx] = true;
                                    } else {
                                        std.debug.print("Type Error: Unexpected keyword argument '{s}'\n", .{kw_name});
                                        return error.TypeMismatch;
                                    }
                                } else {
                                    if (seen_keyword) {
                                        std.debug.print("Type Error: Positional argument follows keyword argument\n", .{});
                                        return error.TypeMismatch;
                                    }
                                    if (arg_idx < pnames.len) {
                                        new_args.items[arg_idx] = arg;
                                        filled.items[arg_idx] = true;
                                    } else if (ft.is_variadic) {
                                        try new_args.append(arg);
                                        try filled.append(true);
                                    } else {
                                        std.debug.print("Type Error: Too many positional arguments\n", .{});
                                        return error.TypeMismatch;
                                    }
                                }
                            }
                            
                            for (filled.items, 0..) |is_filled, i| {
                                if (!is_filled and i < pnames.len) {
                                    if (ft.default_values != null and ft.default_values.?[i] != null) {
                                        new_args.items[i] = @ptrCast(@alignCast(ft.default_values.?[i].?));
                                    } else if (!ft.is_variadic or i < pnames.len - 1) {
                                        std.debug.print("Type Error: Missing required argument '{s}'\n", .{pnames[i]});
                                        return error.TypeMismatch;
                                    }
                                }
                            }
                            
                            if (ft.is_variadic and !filled.items[pnames.len - 1]) {
                                if (new_args.items.len == pnames.len) {
                                    _ = new_args.pop();
                                }
                            }
                            
                            c.arguments = try new_args.toOwnedSlice();
                        }

                        // Validate parameter count
                        if (!has_spread) {
                            if (ft.is_variadic) {
                                if (c.arguments.len < ft.param_types.len - 1) {
                                    std.debug.print("Type Error: Variadic function expects at least {d} arguments, but got {d}\n", .{ ft.param_types.len - 1, c.arguments.len });
                                    return error.TypeMismatch;
                                }
                            } else if (c.arguments.len != ft.param_types.len) {
                                std.debug.print("Type Error: Function expects {d} arguments, but got {d}\n", .{ ft.param_types.len, c.arguments.len });
                                return error.TypeMismatch;
                            }
                        }

                        // Validate parameter types
                        for (c.arguments, 0..) |arg, i| {
                            const param_idx = if (ft.is_variadic and i >= ft.param_types.len - 1) ft.param_types.len - 1 else i;
                            if (param_idx >= ft.param_types.len) break;
                            
                            var expected_type = ft.param_types[param_idx];
                            if (ft.is_variadic and param_idx == ft.param_types.len - 1) {
                                if (expected_type.kind == .List) {
                                    if (expected_type.payload) |p| {
                                        expected_type = p.*;
                                    }
                                }
                            }

                            var actual_arg_type = arg.inferred_type orelse types.Type{ .kind = .Unknown };

                            if (arg.node_type == .SpreadExpr and actual_arg_type.kind == .List) {
                                if (actual_arg_type.payload) |p| {
                                    actual_arg_type = p.*;
                                } else {
                                    actual_arg_type = .{ .kind = .Any };
                                }
                            }
                            
                            if (expected_type.kind != .Any and expected_type.kind != .Unknown) {
                                if (actual_arg_type.kind != .Unknown and !types.isImplicitlyConvertible(actual_arg_type, expected_type)) {
                                    std.debug.print("Type Error: Argument {d} expects type '{s}', but got '{s}'\n", .{ i + 1, types.formatType(expected_type), types.formatType(actual_arg_type) });
                                    return error.TypeMismatch;
                                }
                            }
                        }
                        node.inferred_type = ft.return_type.*;
                    } else if (callee_type.kind == .Struct and callee_type.struct_type != null) {
                        const st = callee_type.struct_type.?;
                        
                        const is_constructor = if (c.callee.node_type == .Identifier)
                            (if (c.callee.data.Identifier.resolved_symbol) |sym| sym.kind == .Struct else false)
                        else
                            false;

                        var init_method: ?*types.FunctionType = null;
                        if (is_constructor) {
                            for (st.methods) |cm| {
                                if (std.mem.endsWith(u8, cm.name, "___init__")) {
                                    init_method = cm.type_kind.function;
                                    break;
                                }
                            }
                        }

                        if (init_method) |init_fn| {
                            // Validate arguments against __init__ (skipping 'self')
                            const pnames = init_fn.param_names orelse &[_][]const u8{};
                            const ptypes = init_fn.param_types;
                            const has_self = ptypes.len > 0;
                            const expected_len = if (has_self) ptypes.len - 1 else 0;

                            var new_args = std.ArrayList(*ast.Node).init(self.allocator);
                            try new_args.appendNTimes(undefined, expected_len);
                            var filled = std.ArrayList(bool).init(self.allocator);
                            try filled.appendNTimes(false, expected_len);
                            
                            var seen_keyword = false;
                            for (c.arguments, 0..) |arg, arg_idx| {
                                if (arg.node_type == .KeywordArg) {
                                    seen_keyword = true;
                                    const kw_name = arg.data.KeywordArg.name;
                                    var found_idx: ?usize = null;
                                    for (pnames, 0..) |pn, p_i| {
                                        if (p_i == 0 and has_self) continue; // skip self
                                        if (std.mem.eql(u8, pn, kw_name)) {
                                            found_idx = p_i - 1;
                                            break;
                                        }
                                    }
                                    if (found_idx) |idx| {
                                        if (filled.items[idx]) {
                                            std.debug.print("Type Error: Multiple values for argument '{s}' in __init__\n", .{kw_name});
                                            return error.TypeMismatch;
                                        }
                                        new_args.items[idx] = arg.data.KeywordArg.value;
                                        filled.items[idx] = true;
                                    } else {
                                        std.debug.print("Type Error: Unexpected keyword argument '{s}' for __init__\n", .{kw_name});
                                        return error.TypeMismatch;
                                    }
                                } else {
                                    if (seen_keyword) {
                                        std.debug.print("Type Error: Positional argument follows keyword argument\n", .{});
                                        return error.TypeMismatch;
                                    }
                                    if (arg_idx < expected_len) {
                                        new_args.items[arg_idx] = arg;
                                        filled.items[arg_idx] = true;
                                    } else {
                                        std.debug.print("Type Error: Too many positional arguments for __init__\n", .{});
                                        return error.TypeMismatch;
                                    }
                                }
                            }
                            
                            for (filled.items, 0..) |is_filled, i| {
                                if (!is_filled) {
                                    const actual_p_idx = if (has_self) i + 1 else i;
                                    if (init_fn.default_values != null and init_fn.default_values.?[actual_p_idx] != null) {
                                        new_args.items[i] = @ptrCast(@alignCast(init_fn.default_values.?[actual_p_idx].?));
                                    } else {
                                        const p_name = if (actual_p_idx < pnames.len) pnames[actual_p_idx] else "unknown";
                                        std.debug.print("Type Error: Missing required argument '{s}' for __init__\n", .{p_name});
                                        return error.TypeMismatch;
                                    }
                                }
                            }

                            // Validate parameter types
                            for (new_args.items, 0..) |arg, i| {
                                const expected_type = ptypes[if (has_self) i + 1 else i];
                                const actual_arg_type = arg.inferred_type orelse types.Type{ .kind = .Unknown };
                                if (expected_type.kind != .Any and expected_type.kind != .Unknown) {
                                    if (actual_arg_type.kind != .Unknown and !types.isImplicitlyConvertible(actual_arg_type, expected_type)) {
                                        std.debug.print("Type Error: Argument {d} expects type '{s}', but got '{s}' in __init__\n", .{ i + 1, types.formatType(expected_type), types.formatType(actual_arg_type) });
                                        return error.TypeMismatch;
                                    }
                                }
                            }
                            
                            c.arguments = try new_args.toOwnedSlice();
                            node.inferred_type = callee_type;
                        } else {
                            var new_args = std.ArrayList(*ast.Node).init(self.allocator);
                            try new_args.appendNTimes(undefined, st.fields.len);
                            var filled = std.ArrayList(bool).init(self.allocator);
                            try filled.appendNTimes(false, st.fields.len);
                            
                            var seen_keyword = false;
                            
                            for (c.arguments, 0..) |arg, arg_idx| {
                                if (arg.node_type == .KeywordArg) {
                                    seen_keyword = true;
                                    const kw_name = arg.data.KeywordArg.name;
                                    var found_idx: ?usize = null;
                                    for (st.fields, 0..) |sf, f_i| {
                                        if (std.mem.eql(u8, sf.name, kw_name)) {
                                            found_idx = f_i;
                                            break;
                                        }
                                    }
                                    if (found_idx) |idx| {
                                        if (filled.items[idx]) {
                                            std.debug.print("Type Error: Multiple values for struct field '{s}'\n", .{kw_name});
                                            return error.TypeMismatch;
                                        }
                                        new_args.items[idx] = arg.data.KeywordArg.value;
                                        filled.items[idx] = true;
                                    } else {
                                        std.debug.print("Type Error: Unexpected field '{s}' in struct initialization\n", .{kw_name});
                                        return error.TypeMismatch;
                                    }
                                } else {
                                    if (seen_keyword) {
                                        std.debug.print("Type Error: Positional argument follows keyword argument in struct initialization\n", .{});
                                        return error.TypeMismatch;
                                    }
                                    if (arg_idx < st.fields.len) {
                                        new_args.items[arg_idx] = arg;
                                        filled.items[arg_idx] = true;
                                    } else {
                                        std.debug.print("Type Error: Too many positional arguments for struct initialization\n", .{});
                                        return error.TypeMismatch;
                                    }
                                }
                            }
                            
                            for (filled.items, 0..) |is_filled, i| {
                                if (!is_filled) {
                                    if (st.fields[i].default_value) |dv| {
                                        new_args.items[i] = @ptrCast(@alignCast(dv));
                                    } else {
                                        std.debug.print("Type Error: Missing required field '{s}' in struct '{s}' initialization\n", .{st.fields[i].name, st.name});
                                        return error.TypeMismatch;
                                    }
                                }
                            }
                            
                            c.arguments = try new_args.toOwnedSlice();
                            node.inferred_type = callee_type;
                        }
                    } else if (callee_type.kind == .Class and callee_type.class_type != null) {
                        const ct = callee_type.class_type.?;
                        
                        const is_constructor = if (c.callee.node_type == .Identifier)
                            (if (c.callee.data.Identifier.resolved_symbol) |sym| sym.kind == .Class else false)
                        else
                            false;

                        if (is_constructor) {
                            var init_method: ?*types.FunctionType = null;
                            for (ct.methods) |cm| {
                                if (std.mem.eql(u8, cm.name, "__init__")) {
                                    init_method = cm.type_kind.function;
                                    break;
                                }
                            }

                            if (init_method) |init_fn| {
                                // Validate arguments against __init__ (skipping 'self')
                                const pnames = init_fn.param_names orelse &[_][]const u8{};
                                const ptypes = init_fn.param_types;
                                const has_self = ptypes.len > 0;
                                const expected_len = if (has_self) ptypes.len - 1 else 0;

                                var new_args = std.ArrayList(*ast.Node).init(self.allocator);
                                try new_args.appendNTimes(undefined, expected_len);
                                var filled = std.ArrayList(bool).init(self.allocator);
                                try filled.appendNTimes(false, expected_len);
                                
                                var seen_keyword = false;
                                for (c.arguments, 0..) |arg, arg_idx| {
                                    if (arg.node_type == .KeywordArg) {
                                        seen_keyword = true;
                                        const kw_name = arg.data.KeywordArg.name;
                                        var found_idx: ?usize = null;
                                        for (pnames, 0..) |pn, p_i| {
                                            if (p_i == 0 and has_self) continue; // skip self
                                            if (std.mem.eql(u8, pn, kw_name)) {
                                                found_idx = p_i - 1;
                                                break;
                                            }
                                        }
                                        if (found_idx) |idx| {
                                            if (filled.items[idx]) {
                                                std.debug.print("Type Error: Multiple values for argument '{s}' in __init__\n", .{kw_name});
                                                return error.TypeMismatch;
                                            }
                                            new_args.items[idx] = arg.data.KeywordArg.value;
                                            filled.items[idx] = true;
                                        } else {
                                            std.debug.print("Type Error: Unexpected keyword argument '{s}' for __init__\n", .{kw_name});
                                            return error.TypeMismatch;
                                        }
                                    } else {
                                        if (seen_keyword) {
                                            std.debug.print("Type Error: Positional argument follows keyword argument\n", .{});
                                            return error.TypeMismatch;
                                        }
                                        if (arg_idx < expected_len) {
                                            new_args.items[arg_idx] = arg;
                                            filled.items[arg_idx] = true;
                                        } else {
                                            std.debug.print("Type Error: Too many positional arguments for __init__\n", .{});
                                            return error.TypeMismatch;
                                        }
                                    }
                                }
                                
                                for (filled.items, 0..) |is_filled, i| {
                                    if (!is_filled) {
                                        const actual_p_idx = if (has_self) i + 1 else i;
                                        if (init_fn.default_values != null and init_fn.default_values.?[actual_p_idx] != null) {
                                            new_args.items[i] = @ptrCast(@alignCast(init_fn.default_values.?[actual_p_idx].?));
                                        } else {
                                            const p_name = if (actual_p_idx < pnames.len) pnames[actual_p_idx] else "unknown";
                                            std.debug.print("Type Error: Missing required argument '{s}' for __init__\n", .{p_name});
                                            return error.TypeMismatch;
                                        }
                                    }
                                }

                                // Validate parameter types
                                for (new_args.items, 0..) |arg, i| {
                                    const expected_type = ptypes[if (has_self) i + 1 else i];
                                    const actual_arg_type = arg.inferred_type orelse types.Type{ .kind = .Unknown };
                                    if (expected_type.kind != .Any and expected_type.kind != .Unknown) {
                                        if (actual_arg_type.kind != .Unknown and !types.isImplicitlyConvertible(actual_arg_type, expected_type)) {
                                            std.debug.print("Type Error: Argument {d} expects type '{s}', but got '{s}' in __init__\n", .{ i + 1, types.formatType(expected_type), types.formatType(actual_arg_type) });
                                            return error.TypeMismatch;
                                        }
                                    }
                                }
                                
                                c.arguments = try new_args.toOwnedSlice();
                                node.inferred_type = callee_type;
                            } else {
                                var new_args = std.ArrayList(*ast.Node).init(self.allocator);
                                try new_args.appendNTimes(undefined, ct.fields.len);
                                var filled = std.ArrayList(bool).init(self.allocator);
                                try filled.appendNTimes(false, ct.fields.len);
                            
                                var seen_keyword = false;
                                
                                for (c.arguments, 0..) |arg, arg_idx| {
                                    if (arg.node_type == .KeywordArg) {
                                        seen_keyword = true;
                                        const kw_name = arg.data.KeywordArg.name;
                                        var found_idx: ?usize = null;
                                        for (ct.fields, 0..) |cf, f_i| {
                                            if (std.mem.eql(u8, cf.name, kw_name)) {
                                                found_idx = f_i;
                                                break;
                                            }
                                        }
                                        if (found_idx) |idx| {
                                            if (filled.items[idx]) {
                                                std.debug.print("Type Error: Multiple values for class field '{s}'\n", .{kw_name});
                                                return error.TypeMismatch;
                                            }
                                            new_args.items[idx] = arg.data.KeywordArg.value;
                                            filled.items[idx] = true;
                                        } else {
                                            std.debug.print("Type Error: Unexpected field '{s}' in class initialization\n", .{kw_name});
                                            return error.TypeMismatch;
                                        }
                                    } else {
                                        if (seen_keyword) {
                                            std.debug.print("Type Error: Positional argument follows keyword argument in class initialization\n", .{});
                                            return error.TypeMismatch;
                                        }
                                        if (arg_idx < ct.fields.len) {
                                            new_args.items[arg_idx] = arg;
                                            filled.items[arg_idx] = true;
                                        } else {
                                            std.debug.print("Type Error: Too many positional arguments for class initialization\n", .{});
                                            return error.TypeMismatch;
                                        }
                                    }
                                }
                                
                                for (filled.items, 0..) |is_filled, i| {
                                    if (!is_filled) {
                                        std.debug.print("Type Error: Missing required field '{s}' in class initialization\n", .{ct.fields[i].name});
                                        return error.TypeMismatch;
                                    }
                                }
                                
                                c.arguments = try new_args.toOwnedSlice();
                                node.inferred_type = callee_type;
                            }
                        } else {
                            // Call on instance! Look up __call__ magic method
                            var call_method: ?*types.FunctionType = null;
                            for (ct.methods) |cm| {
                                if (std.mem.eql(u8, cm.name, "__call__")) {
                                    call_method = cm.type_kind.function;
                                    break;
                                }
                            }

                            if (call_method) |call_fn| {
                                // Validate arguments against __call__ (skipping 'self' if present)
                                const pnames = call_fn.param_names orelse &[_][]const u8{};
                                const ptypes = call_fn.param_types;
                                const has_self = ptypes.len > 0;
                                const expected_len = if (has_self) ptypes.len - 1 else 0;

                                var new_args = std.ArrayList(*ast.Node).init(self.allocator);
                                try new_args.appendNTimes(undefined, expected_len);
                                var filled = std.ArrayList(bool).init(self.allocator);
                                try filled.appendNTimes(false, expected_len);
                                
                                var seen_keyword = false;
                                for (c.arguments, 0..) |arg, arg_idx| {
                                    if (arg.node_type == .KeywordArg) {
                                        seen_keyword = true;
                                        const kw_name = arg.data.KeywordArg.name;
                                        var found_idx: ?usize = null;
                                        for (pnames, 0..) |pn, p_i| {
                                            if (p_i == 0 and has_self) continue; // skip self
                                            if (std.mem.eql(u8, pn, kw_name)) {
                                                found_idx = p_i - 1;
                                                break;
                                            }
                                        }
                                        if (found_idx) |idx| {
                                            if (filled.items[idx]) {
                                                std.debug.print("Type Error: Multiple values for argument '{s}' in __call__\n", .{kw_name});
                                                return error.TypeMismatch;
                                            }
                                            new_args.items[idx] = arg.data.KeywordArg.value;
                                            filled.items[idx] = true;
                                        } else {
                                            std.debug.print("Type Error: Unexpected keyword argument '{s}' for __call__\n", .{kw_name});
                                            return error.TypeMismatch;
                                        }
                                    } else {
                                        if (seen_keyword) {
                                            std.debug.print("Type Error: Positional argument follows keyword argument\n", .{});
                                            return error.TypeMismatch;
                                        }
                                        if (arg_idx < expected_len) {
                                            new_args.items[arg_idx] = arg;
                                            filled.items[arg_idx] = true;
                                        } else {
                                            std.debug.print("Type Error: Too many positional arguments for __call__\n", .{});
                                            return error.TypeMismatch;
                                        }
                                    }
                                }
                                
                                for (filled.items, 0..) |is_filled, i| {
                                    if (!is_filled) {
                                        const actual_p_idx = if (has_self) i + 1 else i;
                                        if (call_fn.default_values != null and call_fn.default_values.?[actual_p_idx] != null) {
                                            new_args.items[i] = @ptrCast(@alignCast(call_fn.default_values.?[actual_p_idx].?));
                                        } else {
                                            const p_name = if (actual_p_idx < pnames.len) pnames[actual_p_idx] else "unknown";
                                            std.debug.print("Type Error: Missing required argument '{s}' for __call__\n", .{p_name});
                                            return error.TypeMismatch;
                                        }
                                    }
                                }

                                // Validate parameter types
                                for (new_args.items, 0..) |arg, i| {
                                    const expected_type = ptypes[if (has_self) i + 1 else i];
                                    const actual_arg_type = arg.inferred_type orelse types.Type{ .kind = .Unknown };
                                    if (expected_type.kind != .Any and expected_type.kind != .Unknown) {
                                        if (actual_arg_type.kind != .Unknown and !types.isImplicitlyConvertible(actual_arg_type, expected_type)) {
                                            std.debug.print("Type Error: Argument {d} expects type '{s}', but got '{s}' in __call__\n", .{ i + 1, types.formatType(expected_type), types.formatType(actual_arg_type) });
                                            return error.TypeMismatch;
                                        }
                                    }
                                }
                                
                                // Rewrite to MethodCallExpr
                                node.node_type = .MethodCallExpr;
                                node.data = .{
                                    .MethodCallExpr = .{
                                        .receiver = c.callee,
                                        .method_name = "__call__",
                                        .arguments = try new_args.toOwnedSlice(),
                                        .is_dynamic = true,
                                    }
                                };
                                node.inferred_type = call_fn.return_type.*;
                                return;
                            } else {
                                std.debug.print("Type Error: Class instance is not callable (no __call__ method defined)\n", .{});
                                return error.TypeMismatch;
                            }
                        }
                    } else if (callee_type.kind == .Union and callee_type.union_type != null) {
                        const ut = callee_type.union_type.?;
                        if (c.arguments.len != 1) {
                            std.debug.print("Type Error: Union '{s}' must be initialized with exactly one keyword argument\n", .{ut.name});
                            return error.TypeMismatch;
                        }
                        
                        const arg = c.arguments[0];
                        if (arg.node_type != .KeywordArg) {
                            std.debug.print("Type Error: Union '{s}' initialization requires a keyword argument to specify the active field\n", .{ut.name});
                            return error.TypeMismatch;
                        }
                        
                        const kw_name = arg.data.KeywordArg.name;
                        var found_idx: ?usize = null;
                        for (ut.fields, 0..) |uf, f_i| {
                            if (std.mem.eql(u8, uf.name, kw_name)) {
                                found_idx = f_i;
                                break;
                            }
                        }
                        
                        if (found_idx) |idx| {
                            const expected_type = ut.fields[idx].type_kind;
                            const actual_type: types.Type = arg.data.KeywordArg.value.inferred_type orelse .{ .kind = .Any };
                            if (expected_type.kind != .Any and expected_type.kind != .Unknown) {
                                if (actual_type.kind != .Unknown and !types.isImplicitlyConvertible(actual_type, expected_type)) {
                                    std.debug.print("Type Error: Union field '{s}' expects type '{s}', but got '{s}'\n", .{ kw_name, types.formatType(expected_type), types.formatType(actual_type) });
                                    return error.TypeMismatch;
                                }
                            }
                            node.inferred_type = callee_type;
                        } else {
                            std.debug.print("Type Error: Unknown field '{s}' in union initialization for '{s}'\n", .{kw_name, ut.name});
                            return error.TypeMismatch;
                        }
                    }
                }
            },
            .IfStmt => |*i| {
                try self.checkNode(i.condition);
                try self.checkNode(i.then_branch);
                const then_type: types.Type = i.then_branch.inferred_type orelse .{ .kind = .Any };
                
                if (i.else_branch) |eb| {
                    try self.checkNode(eb);
                    const else_type: types.Type = eb.inferred_type orelse .{ .kind = .Any };
                    
                    if (then_type.kind == else_type.kind) {
                        node.inferred_type = then_type;
                    } else if (then_type.kind == .Unknown or else_type.kind == .Unknown) {
                        node.inferred_type = .{ .kind = .Unknown };
                    } else if (then_type.kind == .Void or else_type.kind == .Void) {
                        node.inferred_type = .{ .kind = .Void };
                    } else if (then_type.kind == .Any or else_type.kind == .Any) {
                        node.inferred_type = .{ .kind = .Any };
                    } else {
                        // Since types diverge, this if statement doesn't have a coherent expression type
                        node.inferred_type = .{ .kind = .Void };
                    }
                } else {
                    node.inferred_type = .{ .kind = .Unknown };
                }
            },
            .WithStmt => |*w| {
                try self.checkNode(w.expr);
                const resource_type = w.expr.inferred_type orelse types.Type{ .kind = .Any };
                node.inferred_type = resource_type;
                
                try self.checkNode(w.body);
                node.inferred_type = w.body.inferred_type orelse types.Type{ .kind = .Unknown };
            },
            .ForStmt => |*f| {
                var iter_type: types.Type = .{ .kind = .I32 }; // default
                if (f.type_annot) |annot| {
                    iter_type = try self.validateType(annot);
                }
                node.inferred_type = iter_type; // the iterator symbol will look up this decl_node
                
                try self.checkNode(f.iterable);
                try self.checkNode(f.body);
            },
            .WhileStmt => |*w| {
                try self.checkNode(w.condition);
                try self.checkNode(w.body);
            },
            .ReturnStmt => |*r| {
                var ret_val_type: types.Type = .{ .kind = .Void };
                if (r.values) |values| {
                    if (values.len == 1) {
                        try self.checkNode(values[0]);
                        ret_val_type = values[0].inferred_type orelse .{ .kind = .Unknown };
                    } else {
                        var tuple_types = std.ArrayList(types.Type).init(self.allocator);
                        for (values) |v| { 
                            try self.checkNode(v); 
                            try tuple_types.append(v.inferred_type orelse .{ .kind = .Unknown });
                        }
                        ret_val_type = .{ .kind = .Tuple, .tuple_types = try tuple_types.toOwnedSlice() };
                    }
                }

                if (self.current_func) |f_node| {
                    if (f_node.node_type == .FunDecl) {
                        const f = &f_node.data.FunDecl;
                        var expected_type: types.Type = .{ .kind = .Any };
                        if (f.return_type) |annot| {
                            expected_type = try self.validateType(annot);
                        }

                        if (expected_type.kind != .Any and expected_type.kind != .Unknown) {
                            if (!types.isImplicitlyConvertible(ret_val_type, expected_type)) {
                                std.debug.print("Type Error: Return type mismatch in function '{s}'. Expected '{s}', got '{s}'\n", .{ f.name, types.formatType(expected_type), types.formatType(ret_val_type) });
                                return error.TypeMismatch;
                            }
                        }
                    }
                }
                node.inferred_type = .{ .kind = .Unknown };
            },
            .BinaryExpr => |*b| {
                if (std.mem.eql(u8, b.operator, "=") and b.left.node_type == .IndexExpr) {
                    const idx = &b.left.data.IndexExpr;
                    try self.checkNode(idx.object);
                    const obj_type = idx.object.inferred_type orelse types.Type{ .kind = .Any };
                    
                    var resolved_obj_type = obj_type;
                    if (resolved_obj_type.kind == .RawPointer and resolved_obj_type.payload != null) {
                        resolved_obj_type = resolved_obj_type.payload.?.*;
                    }
                    const is_class = resolved_obj_type.kind == .Class and resolved_obj_type.class_type != null;
                    const is_struct = resolved_obj_type.kind == .Struct and resolved_obj_type.struct_type != null;
                    if (is_class or is_struct) {
                        const methods = if (is_class) resolved_obj_type.class_type.?.methods else resolved_obj_type.struct_type.?.methods;
                        var has_setitem = false;
                        var return_t: types.Type = .{ .kind = .Unknown };
                        for (methods) |meth| {
                            const match = if (is_class) std.mem.eql(u8, meth.name, "__setitem__") else std.mem.endsWith(u8, meth.name, "___setitem__");
                            if (match) {
                                has_setitem = true;
                                if (meth.type_kind.kind == .Function and meth.type_kind.function != null) {
                                    return_t = meth.type_kind.function.?.return_type.*;
                                }
                                break;
                            }
                        }
                        if (has_setitem) {
                            try self.checkNode(idx.index);
                            try self.checkNode(b.right);
                            
                            var args = try self.allocator.alloc(*ast.Node, 2);
                            args[0] = idx.index;
                            args[1] = b.right;
                            
                            node.node_type = .MethodCallExpr;
                            node.data = .{
                                .MethodCallExpr = .{
                                    .receiver = idx.object,
                                    .method_name = "__setitem__",
                                    .arguments = args,
                                    .is_dynamic = is_class,
                                }
                            };
                            node.inferred_type = return_t;
                            return;
                        }
                    }
                }
                
                try self.checkNode(b.left);
                try self.checkNode(b.right);
                
                if (std.mem.eql(u8, b.operator, "=")) {
                    if (b.left.node_type == .MemberExpr) {
                        const obj_type: types.Type = b.left.data.MemberExpr.object.inferred_type orelse .{ .kind = .Any };
                        if (obj_type.kind == .Struct and obj_type.struct_type != null) {
                            const st = obj_type.struct_type.?;
                            for (st.fields) |sf| {
                                if (std.mem.eql(u8, sf.name, b.left.data.MemberExpr.property)) {
                                    if (!sf.is_mutable) {
                                        std.debug.print("Type Error: Cannot assign to immutable struct field '{s}' declared with 'let'\n", .{sf.name});
                                        return error.TypeMismatch;
                                    }
                                    break;
                                }
                            }
                        }
                    }
                }
                
                const left_type = b.left.inferred_type orelse types.Type{ .kind = .Unknown };
                const right_type = b.right.inferred_type orelse types.Type{ .kind = .Unknown };

                // Operator Overloading for Classes and Structs
                var resolved_left_type = left_type;
                if (resolved_left_type.kind == .RawPointer and resolved_left_type.payload != null) {
                    resolved_left_type = resolved_left_type.payload.?.*;
                }
                const is_class = resolved_left_type.kind == .Class and resolved_left_type.class_type != null;
                const is_struct = resolved_left_type.kind == .Struct and resolved_left_type.struct_type != null;
                if (is_class or is_struct) {
                    var method_name: ?[]const u8 = null;
                    if (std.mem.eql(u8, b.operator, "+")) { method_name = "__add__"; }
                    else if (std.mem.eql(u8, b.operator, "-")) { method_name = "__sub__"; }
                    else if (std.mem.eql(u8, b.operator, "*")) { method_name = "__mul__"; }
                    else if (std.mem.eql(u8, b.operator, "==")) { method_name = "__eq__"; }
                    else if (std.mem.eql(u8, b.operator, "!=")) { method_name = "__ne__"; }
                    else if (std.mem.eql(u8, b.operator, "<")) { method_name = "__lt__"; }
                    else if (std.mem.eql(u8, b.operator, "<=")) { method_name = "__le__"; }
                    else if (std.mem.eql(u8, b.operator, ">")) { method_name = "__gt__"; }
                    else if (std.mem.eql(u8, b.operator, ">=")) { method_name = "__ge__"; }
                    
                    if (method_name) |m_name| {
                        var has_method = false;
                        var return_t: types.Type = .{ .kind = .Unknown };
                        const methods = if (is_class) resolved_left_type.class_type.?.methods else resolved_left_type.struct_type.?.methods;
                        const search_suffix = try std.fmt.allocPrint(self.allocator, "_{s}", .{m_name});
                        for (methods) |meth| {
                            const match = if (is_class) std.mem.eql(u8, meth.name, m_name) else std.mem.endsWith(u8, meth.name, search_suffix);
                            if (match) {
                                has_method = true;
                                if (meth.type_kind.kind == .Function and meth.type_kind.function != null) {
                                    return_t = meth.type_kind.function.?.return_type.*;
                                }
                                break;
                            }
                        }
                        if (has_method) {
                            var args = try self.allocator.alloc(*ast.Node, 1);
                            args[0] = b.right;
                            
                            node.node_type = .MethodCallExpr;
                            node.data = .{
                                .MethodCallExpr = .{
                                    .receiver = b.left,
                                    .method_name = m_name,
                                    .arguments = args,
                                    .is_dynamic = is_class,
                                }
                            };
                            node.inferred_type = return_t;
                            return;
                        }
                    }
                }
                
                var common_type = left_type;
                if (left_type.kind == .F64 or right_type.kind == .F64) {
                    common_type = .{ .kind = .F64 };
                } else if (left_type.kind == .F32 or right_type.kind == .F32) {
                    common_type = .{ .kind = .F32 };
                } else if (left_type.kind == .Unknown and right_type.kind != .Unknown) {
                    common_type = right_type;
                }
                
                b.left.inferred_type = common_type;
                b.right.inferred_type = common_type;
                
                if (std.mem.eql(u8, b.operator, "==") or std.mem.eql(u8, b.operator, "!=") or
                    std.mem.eql(u8, b.operator, "<") or std.mem.eql(u8, b.operator, ">") or
                    std.mem.eql(u8, b.operator, "<=") or std.mem.eql(u8, b.operator, ">=") or
                    std.mem.eql(u8, b.operator, "and") or std.mem.eql(u8, b.operator, "or")) {
                    node.inferred_type = .{ .kind = .Boolean };
                } else {
                    node.inferred_type = common_type;
                }
            },
            .UnaryExpr => |*u| {
                try self.checkNode(u.operand);
                
                const operand_type = u.operand.inferred_type orelse types.Type{ .kind = .Unknown };
                
                // Operator Overloading for Classes and Structs (Unary)
                var resolved_operand_type = operand_type;
                if (resolved_operand_type.kind == .RawPointer and resolved_operand_type.payload != null) {
                    resolved_operand_type = resolved_operand_type.payload.?.*;
                }
                const is_class = resolved_operand_type.kind == .Class and resolved_operand_type.class_type != null;
                const is_struct = resolved_operand_type.kind == .Struct and resolved_operand_type.struct_type != null;
                if (is_class or is_struct) {
                    var method_name: ?[]const u8 = null;
                    if (std.mem.eql(u8, u.operator, "-")) { method_name = "__neg__"; }
                    
                    if (method_name) |m_name| {
                        var has_method = false;
                        var return_t: types.Type = .{ .kind = .Unknown };
                        const methods = if (is_class) resolved_operand_type.class_type.?.methods else resolved_operand_type.struct_type.?.methods;
                        const search_suffix = try std.fmt.allocPrint(self.allocator, "_{s}", .{m_name});
                        for (methods) |meth| {
                            const match = if (is_class) std.mem.eql(u8, meth.name, m_name) else std.mem.endsWith(u8, meth.name, search_suffix);
                            if (match) {
                                has_method = true;
                                if (meth.type_kind.kind == .Function and meth.type_kind.function != null) {
                                    return_t = meth.type_kind.function.?.return_type.*;
                                }
                                break;
                            }
                        }
                        if (has_method) {
                            node.node_type = .MethodCallExpr;
                            node.data = .{
                                .MethodCallExpr = .{
                                    .receiver = u.operand,
                                    .method_name = m_name,
                                    .arguments = &[_]*ast.Node{},
                                    .is_dynamic = is_class,
                                }
                            };
                            node.inferred_type = return_t;
                            return;
                        }
                    }
                }
                
                if (std.mem.eql(u8, u.operator, "not")) {
                    node.inferred_type = .{ .kind = .Boolean };
                } else if (std.mem.eql(u8, u.operator, "ref") or std.mem.eql(u8, u.operator, "ref mut")) {
                    // ref expr => RawPointer wrapping the operand's type
                    const payload_ptr = try self.allocator.create(types.Type);
                    payload_ptr.* = operand_type;
                    node.inferred_type = types.Type{ .kind = .RawPointer, .payload = payload_ptr };
                } else if (std.mem.eql(u8, u.operator, "deref")) {
                    // deref expr => unwrap the pointer's payload type
                    if (operand_type.kind == .RawPointer) {
                        if (operand_type.payload) |p| {
                            node.inferred_type = p.*;
                        } else {
                            node.inferred_type = .{ .kind = .Unknown };
                        }
                    } else {
                        std.debug.print("Type Error: Cannot dereference non-pointer type '{s}'\n", .{types.formatType(operand_type)});
                        return error.TypeMismatch;
                    }
                } else {
                    node.inferred_type = u.operand.inferred_type orelse .{ .kind = .Unknown };
                }
            },
            .StructDecl => |*s| {
                if (s.generic_params != null) {
                    try self.struct_templates.put(s.name, node);
                    return;
                }
                const st = try self.allocator.create(types.StructType);
                var struct_name = s.name;
                if (node.module_name) |mod_name| {
                    struct_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, s.name });
                }
                st.* = .{
                    .name = struct_name,
                    .fields = &[_]types.StructField{},
                    .methods = &[_]types.StructMethod{},
                };
                // Assign early for recursive references (like self as Vector2)
                node.inferred_type = .{ .kind = .Struct, .struct_type = st };
                std.debug.print("Registering struct: '{s}'\n", .{struct_name});
                try self.struct_types.put(struct_name, st);
                if (node.module_name) |_| {
                    try self.struct_types.put(s.name, st);
                }
                
                // Pass 1: Pre-populate st.methods with signatures
                var methods = std.ArrayList(types.StructMethod).init(self.allocator);
                for (s.methods) |method| {
                    if (method.node_type == .FunDecl) {
                        const f = &method.data.FunDecl;
                        var m_name = f.name;
                        if (method.module_name) |mod_name| {
                            m_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, m_name });
                        }
                        
                        if (f.generic_params != null) {
                            method.inferred_type = .{ .kind = .Unknown };
                            try methods.append(.{
                                .name = m_name,
                                .type_kind = method.inferred_type.?,
                            });
                        } else {
                            var p_types = std.ArrayList(types.Type).init(self.allocator);
                            for (f.params, 0..) |param, p_i| {
                                if (f.param_types[p_i]) |annot| {
                                    param.inferred_type = try self.validateType(annot);
                                } else {
                                    if (p_i == 0 and std.mem.eql(u8, f.param_names[p_i], "self")) {
                                        param.inferred_type = node.inferred_type.?;
                                    } else {
                                        param.inferred_type = .{ .kind = .Any };
                                    }
                                }
                                try p_types.append(param.inferred_type.?);
                            }
                            
                            var ret_type: types.Type = .{ .kind = .Void };
                            if (f.return_type) |annot| {
                                ret_type = try self.validateType(annot);
                            } else if (self.findReturnType(f.body)) |rt| {
                                ret_type = rt;
                            }
                            
                            var func_type = try self.allocator.create(types.FunctionType);
                            func_type.is_variadic = f.is_variadic;
                            func_type.is_async = f.is_async;
                            func_type.param_types = try p_types.toOwnedSlice();
                            func_type.param_names = f.param_names;
                            func_type.return_type = try self.allocator.create(types.Type);
                            func_type.return_type.* = ret_type;
                            func_type.default_values = &[_]?*anyopaque{};
                            
                            method.inferred_type = .{ .kind = .Function, .function = func_type };
                            try methods.append(.{
                                .name = m_name,
                                .type_kind = method.inferred_type.?,
                            });
                        }
                    }
                }
                st.methods = try methods.toOwnedSlice();
                
                // Pass 2: Typecheck fields and method bodies
                var fields = std.ArrayList(types.StructField).init(self.allocator);
                for (s.fields) |field| {
                    try self.checkNode(field);
                    const f_decl = field.data.FieldDecl;
                    const f_type = try self.validateType(f_decl.type_annot);
                    try fields.append(.{
                        .name = f_decl.name,
                        .type_kind = f_type,
                        .access_modifier = f_decl.access_modifier,
                        .is_mutable = f_decl.is_mutable,
                        .default_value = if (f_decl.default_value) |dv| @ptrCast(dv) else null,
                    });
                }
                st.fields = try fields.toOwnedSlice();
                if (std.mem.endsWith(u8, struct_name, "Symbol")) {
                    std.debug.print("Symbol fields count: {d}, total size: {d}\n", .{ st.fields.len, types.getTypeSize(.{ .kind = .Struct, .struct_type = st }) });
                    for (st.fields) |f| {
                        std.debug.print("  field '{s}': size {d}\n", .{ f.name, types.getTypeSize(f.type_kind) });
                    }
                }
                
                for (s.methods) |method| {
                    try self.checkNode(method);
                }
            },
            .UnionDecl => |*u| {
                if (u.generic_params != null) {
                    // No generic template caching for unions yet
                    return;
                }
                const ut = try self.allocator.create(types.UnionType);
                var union_name = u.name;
                if (node.module_name) |mod_name| {
                    union_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, u.name });
                }
                ut.* = .{
                    .name = union_name,
                    .fields = &[_]types.StructField{},
                    .methods = &[_]types.StructMethod{},
                    .tag_type = null,
                };
                
                var tag_t: ?types.Type = null;
                if (u.tag_type) |tt| {
                    const resolved = try self.validateType(tt);
                    if (resolved.kind != .Enum) {
                        std.debug.print("Type Error: Tag type for union '{s}' must be an Enum\n", .{u.name});
                        return error.TypeMismatch;
                    }
                    tag_t = resolved;
                    ut.tag_type = resolved;
                }

                node.inferred_type = .{ .kind = .Union, .union_type = ut };
                try self.union_types.put(union_name, ut);
                if (node.module_name) |_| {
                    try self.union_types.put(u.name, ut);
                }
                
                // Pass 1: Pre-populate ut.methods with signatures
                var methods = std.ArrayList(types.StructMethod).init(self.allocator);
                for (u.methods) |method| {
                    if (method.node_type == .FunDecl) {
                        const f = &method.data.FunDecl;
                        var m_name = f.name;
                        if (method.module_name) |mod_name| {
                            m_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, m_name });
                        }
                        
                        if (f.generic_params != null) {
                            method.inferred_type = .{ .kind = .Unknown };
                            try methods.append(.{
                                .name = m_name,
                                .type_kind = method.inferred_type.?,
                            });
                        } else {
                            var p_types = std.ArrayList(types.Type).init(self.allocator);
                            for (f.params, 0..) |param, p_i| {
                                if (f.param_types[p_i]) |annot| {
                                    param.inferred_type = try self.validateType(annot);
                                } else {
                                    if (p_i == 0 and std.mem.eql(u8, f.param_names[p_i], "self")) {
                                        param.inferred_type = node.inferred_type.?;
                                    } else {
                                        param.inferred_type = .{ .kind = .Any };
                                    }
                                }
                                try p_types.append(param.inferred_type.?);
                            }
                            
                            var ret_type: types.Type = .{ .kind = .Void };
                            if (f.return_type) |annot| {
                                ret_type = try self.validateType(annot);
                            } else if (self.findReturnType(f.body)) |rt| {
                                ret_type = rt;
                            }
                            
                            var func_type = try self.allocator.create(types.FunctionType);
                            func_type.is_variadic = f.is_variadic;
                            func_type.is_async = f.is_async;
                            func_type.param_types = try p_types.toOwnedSlice();
                            func_type.param_names = f.param_names;
                            func_type.return_type = try self.allocator.create(types.Type);
                            func_type.return_type.* = ret_type;
                            func_type.default_values = &[_]?*anyopaque{};
                            
                            method.inferred_type = .{ .kind = .Function, .function = func_type };
                            try methods.append(.{
                                .name = m_name,
                                .type_kind = method.inferred_type.?,
                            });
                        }
                    }
                }
                ut.methods = try methods.toOwnedSlice();

                // Pass 2: Typecheck fields and method bodies
                var fields = std.ArrayList(types.StructField).init(self.allocator);
                for (u.fields) |field| {
                    try self.checkNode(field);
                    const f_decl = field.data.FieldDecl;
                    const f_type = try self.validateType(f_decl.type_annot);
                    try fields.append(.{
                        .name = f_decl.name,
                        .type_kind = f_type,
                        .access_modifier = f_decl.access_modifier,
                        .is_mutable = f_decl.is_mutable,
                        .default_value = if (f_decl.default_value) |dv| @ptrCast(dv) else null,
                    });
                }
                ut.fields = try fields.toOwnedSlice();

                if (tag_t) |tt| {
                    const et = tt.enum_type.?;
                    if (et.variants.len != ut.fields.len) {
                        std.debug.print("Type Error: Tagged union '{s}' has {d} fields but tag enum '{s}' has {d} variants. They must match 1-to-1.\n", .{ u.name, ut.fields.len, et.name, et.variants.len });
                        return error.TypeMismatch;
                    }
                }
                
                for (u.methods) |method| {
                    try self.checkNode(method);
                }
            },
            .UnsafeBlock => |*u| {
                const prev_unsafe = self.in_unsafe_block;
                self.in_unsafe_block = true;
                try self.checkNode(u.body);
                node.inferred_type = u.body.inferred_type orelse .{ .kind = .Void };
                self.in_unsafe_block = prev_unsafe;
            },
            .EnumDecl => |*e| {
                const et = try self.allocator.create(types.EnumType);
                var enum_name = e.name;
                if (node.module_name) |mod_name| {
                    enum_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, e.name });
                }
                et.* = .{
                    .name = enum_name,
                    .variants = &[_]types.EnumVariantType{},
                };
                node.inferred_type = .{ .kind = .Enum, .enum_type = et };
                try self.enum_types.put(enum_name, et);
                if (node.module_name) |_| {
                    try self.enum_types.put(e.name, et);
                }
                
                var variants = std.ArrayList(types.EnumVariantType).init(self.allocator);
                var implicit_val: u32 = 0;
                for (e.variants) |variant| {
                    try self.checkNode(variant);
                    const v_data = variant.data.EnumVariant;
                    
                    var actual_val = implicit_val;
                    if (v_data.value) |val_node| {
                        if (val_node.node_type == .NumberLiteral) {
                            actual_val = @intFromFloat(val_node.data.NumberLiteral.value);
                        } else {
                            std.debug.print("Type Error: Explicit enum variant value must be a constant integer\n", .{});
                            return error.TypeMismatch;
                        }
                    }
                    
                    var p_types: ?[]const types.Type = null;
                    if (v_data.payload_types) |pts| {
                        var pts_arr = std.ArrayList(types.Type).init(self.allocator);
                        for (pts) |pt| {
                            try pts_arr.append(try self.validateType(pt));
                        }
                        p_types = try pts_arr.toOwnedSlice();
                    }
                    
                    try variants.append(.{
                        .name = v_data.name,
                        .value = actual_val,
                        .payload_types = p_types,
                    });
                    
                    implicit_val = actual_val + 1;
                }
                et.variants = try variants.toOwnedSlice();
            },
            .EnumVariant => |*v| {
                if (v.value) |val| {
                    try self.checkNode(val);
                }
                node.inferred_type = .{ .kind = .Void };
            },
            .FieldDecl => |*f| {
                const t = try self.validateType(f.type_annot);
                if (f.default_value) |dv| {
                    try self.checkNode(dv);
                    if (dv.inferred_type) |dv_t| {
                        if (!types.isImplicitlyConvertible(dv_t, t)) {
                            std.debug.print("Type Error: Default value for field '{s}' is incompatible with type '{s}'\n", .{f.name, types.formatType(t)});
                            return error.TypeMismatch;
                        }
                    }
                }
                node.inferred_type = t;
            },
            .ClassDecl => |*c| {
                const ct = try self.allocator.create(types.ClassType);
                ct.* = .{
                    .name = c.name,
                    .base_class = null,
                    .interfaces = &[_]*types.InterfaceType{},
                    .fields = &[_]types.StructField{},
                    .methods = &[_]types.StructMethod{},
                };
                
                // Assign early for recursive references (like self as Shape)
                node.inferred_type = .{ .kind = .Class, .class_type = ct };
                try self.class_types.put(c.name, ct);

                var ifaces = std.ArrayList(*types.InterfaceType).init(self.allocator);

                if (c.base_class) |bc| {
                    if (self.class_types.get(bc)) |base| {
                        ct.base_class = base;
                    } else if (self.interface_types.get(bc)) |iface| {
                        ct.base_class = null;
                        try ifaces.append(iface);
                    } else {
                        std.debug.print("Type Error: Base class or interface '{s}' not found for '{s}'\n", .{bc, c.name});
                        ct.base_class = null;
                    }
                } else {
                    ct.base_class = null;
                }

                for (c.interfaces) |iface_name| {  
                    if (self.interface_types.get(iface_name)) |iface| {
                        try ifaces.append(iface);
                    } else {
                        std.debug.print("Type Error: Interface '{s}' not found for '{s}'\n", .{iface_name, c.name});
                    }
                }
                ct.interfaces = try ifaces.toOwnedSlice();

                var fields = std.ArrayList(types.StructField).init(self.allocator);
                if (ct.base_class) |base| {
                    for (base.fields) |bf| {
                        try fields.append(bf);
                    }
                }
                for (c.fields) |field| {
                    try self.checkNode(field);
                    const fd = field.data.FieldDecl;
                    try fields.append(.{
                        .name = fd.name,
                        .type_kind = field.inferred_type.?,
                        .access_modifier = fd.access_modifier,
                        .is_mutable = fd.is_mutable,
                    });
                }
                ct.fields = try fields.toOwnedSlice();
                
                var methods = std.ArrayList(types.StructMethod).init(self.allocator);
                if (ct.base_class) |base| {
                    for (base.methods) |bm| {
                        try methods.append(bm);
                    }
                }
                for (c.methods) |method| {
                    try self.checkNode(method);
                    const md = method.data.FunDecl;
                    var overridden = false;
                    for (methods.items) |*existing| {
                        if (std.mem.eql(u8, existing.name, md.name)) {
                            existing.type_kind = method.inferred_type.?;
                            existing.defining_class_name = c.name;
                            overridden = true;
                            break;
                        }
                    }
                    if (!overridden) {
                        try methods.append(.{
                            .name = md.name,
                            .type_kind = method.inferred_type.?,
                            .defining_class_name = c.name,
                        });
                    }
                }
                ct.methods = try methods.toOwnedSlice();
                
                for (ct.interfaces) |iface| {
                    for (iface.methods) |im| {
                        var found = false;
                        for (ct.methods) |cm| {
                            if (std.mem.eql(u8, cm.name, im.name)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            std.debug.print("Type Error: Class '{s}' does not implement method '{s}' required by interface '{s}'\n", .{c.name, im.name, iface.name});
                        }
                    }
                }
            },
            .InterfaceDecl => |*i| {
                const it = try self.allocator.create(types.InterfaceType);
                it.name = i.name;
                
                var supers = std.ArrayList(*types.InterfaceType).init(self.allocator);
                for (i.super_interfaces) |sup_name| {
                    if (self.interface_types.get(sup_name)) |sup| {
                        try supers.append(sup);
                    } else {
                        std.debug.print("Type Error: Super interface '{s}' not found for '{s}'\n", .{sup_name, i.name});
                    }
                }
                it.super_interfaces = try supers.toOwnedSlice();

                var methods = std.ArrayList(types.StructMethod).init(self.allocator);
                for (i.methods) |method| {
                    try self.checkNode(method);
                    const md = method.data.FunDecl;
                    try methods.append(.{
                        .name = md.name,
                        .type_kind = method.inferred_type.?,
                    });
                }
                it.methods = try methods.toOwnedSlice();

                try self.interface_types.put(i.name, it);
                node.inferred_type = .{ .kind = .Interface, .interface_type = it };
            },
            .MemberExpr => |*m| {
                try self.checkNode(m.object);
                const obj_type: types.Type = m.object.inferred_type orelse .{ .kind = .Any };
                if (obj_type.kind == .Module and obj_type.module_scope != null) {
                    const mod_scope = @as(*symbols.Scope, @ptrCast(@alignCast(obj_type.module_scope.?)));
                    if (mod_scope.resolveLocal(m.property)) |sym| {
                        if (sym.decl_node) |decl| {
                            node.inferred_type = decl.inferred_type;
                        } else {
                            node.inferred_type = .{ .kind = .Any };
                        }
                    } else {
                        std.debug.print("Type Error: Module has no member named '{s}'\n", .{m.property});
                        return error.TypeMismatch;
                    }
                } else if (obj_type.kind == .Enum and obj_type.enum_type != null) {
                    const et = obj_type.enum_type.?;
                    var found = false;
                    for (et.variants) |ev| {
                        if (std.mem.eql(u8, ev.name, m.property)) {
                            // If it has payload types, it returns a constructor FunctionType
                            if (ev.payload_types) |pts| {
                                var func_type = try self.allocator.create(types.FunctionType);
                                func_type.is_variadic = false;
                                func_type.is_async = false;
                                func_type.param_types = pts;
                                func_type.return_type = try self.allocator.create(types.Type);
                                func_type.return_type.* = obj_type; // Returns the Enum type
                                node.inferred_type = .{ .kind = .Function, .function = func_type };
                            } else {
                                node.inferred_type = obj_type;
                            }
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        std.debug.print("Type Error: Enum '{s}' has no variant named '{s}'\n", .{et.name, m.property});
                        return error.TypeMismatch;
                    }
                } else if (obj_type.kind == .Struct and obj_type.struct_type != null) {
                    const st = obj_type.struct_type.?;
                    var found = false;
                    for (st.fields) |sf| {
                        if (std.mem.eql(u8, sf.name, m.property)) {
                            node.inferred_type = sf.type_kind;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        std.debug.print("Type Error: Struct '{s}' has no field named '{s}'\n", .{st.name, m.property});
                        return error.TypeMismatch;
                    }
                } else if (obj_type.kind == .Union and obj_type.union_type != null) {
                    const ut = obj_type.union_type.?;
                    if (ut.tag_type == null and !self.in_unsafe_block) {
                        std.debug.print("Safety Error: Accessing union field '{s}' is unsafe and requires an 'unsafe' block\n", .{m.property});
                        return error.TypeMismatch;
                    }
                    if (ut.tag_type != null and (std.mem.eql(u8, m.property, "tag") or std.mem.eql(u8, m.property, "active_tag"))) {
                        node.inferred_type = ut.tag_type.?;
                        return;
                    }
                    var found = false;
                    for (ut.fields) |uf| {
                        if (std.mem.eql(u8, uf.name, m.property)) {
                            node.inferred_type = uf.type_kind;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        std.debug.print("Type Error: Union '{s}' has no field named '{s}'\n", .{ut.name, m.property});
                        return error.TypeMismatch;
                    }
                } else if (obj_type.kind == .Class and obj_type.class_type != null) {
                    const ct = obj_type.class_type.?;
                    var found = false;
                    for (ct.fields) |cf| {
                        if (std.mem.eql(u8, cf.name, m.property)) {
                            node.inferred_type = cf.type_kind;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        std.debug.print("Type Error: Class '{s}' has no field named '{s}'\n", .{ct.name, m.property});
                        return error.TypeMismatch;
                    }
                } else {
                    node.inferred_type = .{ .kind = .Any };
                }
            },
            .MethodCallExpr => |*m| {
                try self.checkNode(m.receiver);
                
                // Dynamic Dispatch Resolution
                var rec_type: types.Type = m.receiver.inferred_type orelse .{ .kind = .Any };
                if (rec_type.kind == .RawPointer and rec_type.payload != null) {
                    rec_type = rec_type.payload.?.*;
                }
                if (rec_type.kind == .Module) {
                    m.is_dynamic = false;
                    if (rec_type.module_scope) |scope_ptr| {
                        const mod_scope = @as(*symbols.Scope, @ptrCast(@alignCast(scope_ptr)));
                        if (mod_scope.resolveLocal(m.method_name)) |sym| {
                            if (sym.decl_node) |decl| {
                                const decl_type = decl.inferred_type orelse types.Type{ .kind = .Any };
                                if (decl_type.kind == .Function and decl_type.function != null) {
                                    const ft = decl_type.function.?;
                                    node.inferred_type = ft.return_type.*;
                                    
                                    if (m.arguments.len != ft.param_types.len) {
                                        std.debug.print("Type Error: Function '{s}' expects {d} arguments, but got {d}\n", .{ m.method_name, ft.param_types.len, m.arguments.len });
                                        return error.TypeMismatch;
                                    }
                                    for (m.arguments, 0..) |arg, i| {
                                        try self.checkNode(arg);
                                        const expected_type = ft.param_types[i];
                                        const actual_arg_type = arg.inferred_type orelse types.Type{ .kind = .Unknown };
                                        if (expected_type.kind != .Any and expected_type.kind != .Unknown) {
                                            if (actual_arg_type.kind != .Unknown and !types.isImplicitlyConvertible(actual_arg_type, expected_type)) {
                                                std.debug.print("Type Error: Argument {d} expects type '{s}', but got '{s}'\n", .{ i + 1, types.formatType(expected_type), types.formatType(actual_arg_type) });
                                                return error.TypeMismatch;
                                            }
                                        }
                                    }
                                } else {
                                    node.inferred_type = decl_type;
                                }
                            } else {
                                node.inferred_type = .{ .kind = .Any };
                            }
                        } else {
                            std.debug.print("Type Error: Module has no member named '{s}'\n", .{m.method_name});
                            return error.TypeMismatch;
                        }
                    } else {
                        node.inferred_type = .{ .kind = .Any };
                    }
                } else if (rec_type.kind == .Class and rec_type.class_type != null) {
                    m.is_dynamic = true;
                    const ct = rec_type.class_type.?;
                    var found = false;
                    for (ct.methods) |sm| {
                        if (std.mem.eql(u8, sm.name, m.method_name)) {
                            found = true;
                            if (sm.type_kind.kind == .Function and sm.type_kind.function != null) {
                                const ft = sm.type_kind.function.?;
                                node.inferred_type = ft.return_type.*;
                                // Note: we should check argument types here, but skipping for brevity
                                for (m.arguments) |arg| {
                                    try self.checkNode(arg);
                                }
                            } else {
                                node.inferred_type = .{ .kind = .Any };
                            }
                            break;
                        }
                    }
                    if (!found) {
                        std.debug.print("Type Error: Class '{s}' has no method named '{s}'\n", .{ct.name, m.method_name});
                        return error.TypeMismatch;
                    }
                } else if (rec_type.kind == .Any or rec_type.kind == .Interface) {
                    m.is_dynamic = true;
                    if (rec_type.kind == .Any) {
                        std.debug.print("Type Warning: Dynamic dispatch on type 'Any' for method '{s}()'. This is allowed in Mantiq but may fail at runtime.\n", .{m.method_name});
                    }
                    node.inferred_type = .{ .kind = .Any };
                } else if ((rec_type.kind == .Struct and rec_type.struct_type != null) or (rec_type.kind == .Union and rec_type.union_type != null)) {
                    m.is_dynamic = false;
                    const name = if (rec_type.kind == .Struct) rec_type.struct_type.?.name else rec_type.union_type.?.name;
                    const methods = if (rec_type.kind == .Struct) rec_type.struct_type.?.methods else rec_type.union_type.?.methods;
                    var found = false;
                    const mangled_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{name, m.method_name});
                    for (methods) |sm| {
                        if (std.mem.eql(u8, sm.name, mangled_name)) {
                            found = true;
                            if (sm.type_kind.kind == .Function and sm.type_kind.function != null) {
                                const ft = sm.type_kind.function.?;
                                node.inferred_type = ft.return_type.*;
                                
                                const is_static = self.isTypeOrModuleNode(m.receiver);
                                const expected_param_count = if (is_static) ft.param_types.len else ft.param_types.len - 1;
                                if (m.arguments.len != expected_param_count) {
                                    std.debug.print("Type Error: Method '{s}' expects {d} arguments, but got {d}\n", .{ m.method_name, expected_param_count, m.arguments.len });
                                    return error.TypeMismatch;
                                }
                                for (m.arguments, 0..) |arg, i| {
                                    try self.checkNode(arg);
                                    const param_idx = if (is_static) i else i + 1;
                                    const expected_type = ft.param_types[param_idx];
                                    const actual_arg_type = arg.inferred_type orelse types.Type{ .kind = .Unknown };
                                    if (expected_type.kind != .Any and expected_type.kind != .Unknown) {
                                        if (actual_arg_type.kind != .Unknown and !types.isImplicitlyConvertible(actual_arg_type, expected_type)) {
                                            std.debug.print("Type Error: Argument {d} expects type '{s}', but got '{s}'\n", .{ i + 1, types.formatType(expected_type), types.formatType(actual_arg_type) });
                                            return error.TypeMismatch;
                                        }
                                    }
                                }
                            } else {
                                node.inferred_type = .{ .kind = .Any };
                            }
                            break;
                        }
                    }
                    if (!found) {
                        const kind_name = if (rec_type.kind == .Struct) "Struct" else "Union";
                        std.debug.print("Type Error: {s} '{s}' has no method named '{s}'\n", .{kind_name, name, m.method_name});
                        return error.TypeMismatch;
                    }
                } else if (rec_type.kind == .Enum and rec_type.enum_type != null) {
                    m.is_dynamic = false;
                    const et = rec_type.enum_type.?;
                    var found = false;
                    for (et.variants) |ev| {
                        if (std.mem.eql(u8, ev.name, m.method_name)) {
                            found = true;
                            if (ev.payload_types) |pts| {
                                if (m.arguments.len != pts.len) {
                                    std.debug.print("Type Error: Enum variant '{s}' expects {d} arguments, got {d}\n", .{m.method_name, pts.len, m.arguments.len});
                                    return error.TypeMismatch;
                                }
                                node.inferred_type = rec_type;
                            } else {
                                std.debug.print("Type Error: Enum variant '{s}' does not take arguments\n", .{m.method_name});
                                return error.TypeMismatch;
                            }
                            break;
                        }
                    }
                    if (!found) {
                        std.debug.print("Type Error: Enum '{s}' has no variant named '{s}'\n", .{et.name, m.method_name});
                        return error.TypeMismatch;
                    }
                } else if ((rec_type.kind == .AsciiStr or rec_type.kind == .Utf8Str or rec_type.kind == .WebStr or rec_type.kind == .RangeStr) and std.mem.eql(u8, m.method_name, "to_string")) {
                    m.is_dynamic = false;
                    node.inferred_type = .{ .kind = .String };
                } else if (rec_type.kind == .List) {
                    m.is_dynamic = false;
                    if (std.mem.eql(u8, m.method_name, "append")) {
                        if (m.arguments.len != 1) {
                            std.debug.print("Type Error: List.append expects 1 argument, got {d}\n", .{m.arguments.len});
                            return error.TypeMismatch;
                        }
                        try self.checkNode(m.arguments[0]);
                        const arg_t = m.arguments[0].inferred_type orelse types.Type{ .kind = .Any };
                        const inner_t = if (rec_type.payload) |p| p.* else types.Type{ .kind = .Any };
                        if (inner_t.kind != .Any and arg_t.kind != .Any and !types.isImplicitlyConvertible(arg_t, inner_t)) {
                            std.debug.print("Type Error: List.append argument type mismatch. Expected {s}, got {s}\n", .{types.formatType(inner_t), types.formatType(arg_t)});
                            return error.TypeMismatch;
                        }
                        node.inferred_type = .{ .kind = .Void };
                    } else if (std.mem.eql(u8, m.method_name, "length") or std.mem.eql(u8, m.method_name, "len")) {
                        if (m.arguments.len != 0) {
                            std.debug.print("Type Error: List.length expects 0 arguments, got {d}\n", .{m.arguments.len});
                            return error.TypeMismatch;
                        }
                        node.inferred_type = .{ .kind = .I64 };
                    } else if (std.mem.eql(u8, m.method_name, "clear")) {
                        if (m.arguments.len != 0) {
                            std.debug.print("Type Error: List.clear expects 0 arguments, got {d}\n", .{m.arguments.len});
                            return error.TypeMismatch;
                        }
                        node.inferred_type = .{ .kind = .Void };
                    } else {
                        std.debug.print("Type Error: List has no method named '{s}'\n", .{m.method_name});
                        return error.TypeMismatch;
                    }
                } else if (rec_type.kind == .Dict) {
                    m.is_dynamic = false;
                    if (std.mem.eql(u8, m.method_name, "length") or std.mem.eql(u8, m.method_name, "len")) {
                        if (m.arguments.len != 0) {
                            std.debug.print("Type Error: Dict.length expects 0 arguments, got {d}\n", .{m.arguments.len});
                            return error.TypeMismatch;
                        }
                        node.inferred_type = .{ .kind = .I64 };
                    } else if (std.mem.eql(u8, m.method_name, "clear")) {
                        if (m.arguments.len != 0) {
                            std.debug.print("Type Error: Dict.clear expects 0 arguments, got {d}\n", .{m.arguments.len});
                            return error.TypeMismatch;
                        }
                        node.inferred_type = .{ .kind = .Void };
                    } else if (std.mem.eql(u8, m.method_name, "has")) {
                        if (m.arguments.len != 1) {
                            std.debug.print("Type Error: Dict.has expects 1 argument, got {d}\n", .{m.arguments.len});
                            return error.TypeMismatch;
                        }
                        try self.checkNode(m.arguments[0]);
                        const arg_t = m.arguments[0].inferred_type orelse types.Type{ .kind = .Any };
                        var key_t = types.Type{ .kind = .Any };
                        if (rec_type.tuple_types) |tt| {
                            if (tt.len == 2) key_t = tt[0];
                        }
                        if (key_t.kind != .Any and arg_t.kind != .Any and !types.isImplicitlyConvertible(arg_t, key_t)) {
                            std.debug.print("Type Error: Dict.has key type mismatch. Expected {s}, got {s}\n", .{types.formatType(key_t), types.formatType(arg_t)});
                            return error.TypeMismatch;
                        }
                        node.inferred_type = .{ .kind = .Boolean };
                    } else if (std.mem.eql(u8, m.method_name, "remove")) {
                        if (m.arguments.len != 1) {
                            std.debug.print("Type Error: Dict.remove expects 1 argument, got {d}\n", .{m.arguments.len});
                            return error.TypeMismatch;
                        }
                        try self.checkNode(m.arguments[0]);
                        const arg_t = m.arguments[0].inferred_type orelse types.Type{ .kind = .Any };
                        var key_t = types.Type{ .kind = .Any };
                        if (rec_type.tuple_types) |tt| {
                            if (tt.len == 2) key_t = tt[0];
                        }
                        if (key_t.kind != .Any and arg_t.kind != .Any and !types.isImplicitlyConvertible(arg_t, key_t)) {
                            std.debug.print("Type Error: Dict.remove key type mismatch. Expected {s}, got {s}\n", .{types.formatType(key_t), types.formatType(arg_t)});
                            return error.TypeMismatch;
                        }
                        node.inferred_type = .{ .kind = .Boolean }; // Returns bool if removed successfully
                    } else if (std.mem.eql(u8, m.method_name, "keys")) {
                        if (m.arguments.len != 0) {
                            std.debug.print("Type Error: Dict.keys expects 0 arguments, got {d}\n", .{m.arguments.len});
                            return error.TypeMismatch;
                        }
                        var key_t = types.Type{ .kind = .Any };
                        if (rec_type.tuple_types) |tt| {
                            if (tt.len == 2) key_t = tt[0];
                        }
                        const payload_ptr = try self.allocator.create(types.Type);
                        payload_ptr.* = key_t;
                        node.inferred_type = .{ .kind = .List, .payload = payload_ptr };
                    } else {
                        std.debug.print("Type Error: Dict has no method named '{s}'\n", .{m.method_name});
                        return error.TypeMismatch;
                    }
                } else {
                    m.is_dynamic = false;
                    node.inferred_type = .{ .kind = .Any };
                }
                
                for (m.arguments) |arg| {
                    try self.checkNode(arg);
                }
            },
            .CastExpr => |*c| {
                try self.checkNode(c.operand);
                const target_type = try self.validateType(c.target_type);
                if (target_type.kind == .Unknown) {
                    std.debug.print("Type Error: Unknown target type '{s}' in cast expression\n", .{c.target_type.name});
                    return error.UnknownType;
                }
                node.inferred_type = target_type;
            },
            .ClosureExpr => |*cl| {
                const cid = self.closure_counter;
                self.closure_counter += 1;
                
                // Apply param type annotations before checking body
                for (cl.params, cl.param_types) |param, annot| {
                    if (annot) |a| {
                        if (self.validateType(a)) |pt| {
                            param.inferred_type = pt;
                        } else |_| {}
                    }
                }
                
                var param_types = std.ArrayList(types.Type).init(self.allocator);
                for (cl.params) |param| {
                    try self.checkNode(param);
                    try param_types.append(param.inferred_type orelse .{ .kind = .Any });
                }
                try self.checkNode(cl.body);
                
                const ret_type = try self.allocator.create(types.Type);
                ret_type.* = cl.body.inferred_type orelse .{ .kind = .Any };
                
                const fn_type = try self.allocator.create(types.FunctionType);
                fn_type.* = .{
                    .param_types = try param_types.toOwnedSlice(),
                    .return_type = ret_type,
                    .is_variadic = false,
                    .is_async = false,
                };
                
                try self.closure_types.put(cid, fn_type);
                node.inferred_type = .{ .kind = .Closure, .closure_id = cid, .function = fn_type };
            },
            .ListLiteral => |*l| {
                for (l.elements) |element| {
                    try self.checkNode(element);
                }
                const inner = try self.allocator.create(types.Type);
                inner.* = if (l.elements.len > 0) l.elements[0].inferred_type orelse .{ .kind = .Any } else .{ .kind = .Any };
                node.inferred_type = .{ .kind = .List, .payload = inner };
            },
            .DictLiteral => |*d| {
                for (d.keys) |k| try self.checkNode(k);
                for (d.values) |v| try self.checkNode(v);
                
                // Collect tuple_types to represent K, V
                var kv_types = try self.allocator.alloc(types.Type, 2);
                kv_types[0] = if (d.keys.len > 0) d.keys[0].inferred_type orelse .{ .kind = .Any } else .{ .kind = .Any };
                kv_types[1] = if (d.values.len > 0) d.values[0].inferred_type orelse .{ .kind = .Any } else .{ .kind = .Any };
                
                node.inferred_type = .{ .kind = .Dict, .tuple_types = kv_types };
            },
            .IndexExpr => |*idx| {
                try self.checkNode(idx.object);
                try self.checkNode(idx.index);
                
                const obj_type = idx.object.inferred_type orelse types.Type{ .kind = .Any };
                var resolved_obj_type = obj_type;
                if (resolved_obj_type.kind == .RawPointer and resolved_obj_type.payload != null) {
                    resolved_obj_type = resolved_obj_type.payload.?.*;
                }
                const is_class = resolved_obj_type.kind == .Class and resolved_obj_type.class_type != null;
                const is_struct = resolved_obj_type.kind == .Struct and resolved_obj_type.struct_type != null;
                if (is_class or is_struct) {
                    const methods = if (is_class) resolved_obj_type.class_type.?.methods else resolved_obj_type.struct_type.?.methods;
                    var has_getitem = false;
                    var return_t: types.Type = .{ .kind = .Unknown };
                    for (methods) |meth| {
                        const match = if (is_class) std.mem.eql(u8, meth.name, "__getitem__") else std.mem.endsWith(u8, meth.name, "___getitem__");
                        if (match) {
                            has_getitem = true;
                            if (meth.type_kind.kind == .Function and meth.type_kind.function != null) {
                                return_t = meth.type_kind.function.?.return_type.*;
                            }
                            break;
                        }
                    }
                    if (has_getitem) {
                        var args = try self.allocator.alloc(*ast.Node, 1);
                        args[0] = idx.index;
                        
                        node.node_type = .MethodCallExpr;
                        node.data = .{
                            .MethodCallExpr = .{
                                .receiver = idx.object,
                                .method_name = "__getitem__",
                                .arguments = args,
                                .is_dynamic = is_class,
                            }
                        };
                        node.inferred_type = return_t;
                        return;
                    }
                }
                if (obj_type.kind == .List) {
                    if (obj_type.payload) |p| {
                        node.inferred_type = p.*;
                    } else {
                        node.inferred_type = types.Type{ .kind = .Any };
                    }
                } else if (obj_type.kind == .Dict) {
                    if (obj_type.tuple_types) |tt| {
                        if (tt.len == 2) {
                            node.inferred_type = tt[1];
                        } else {
                            node.inferred_type = types.Type{ .kind = .Any };
                        }
                    } else {
                        node.inferred_type = types.Type{ .kind = .Any };
                    }
                } else if (obj_type.kind == .String or obj_type.kind == .AsciiStr or obj_type.kind == .Utf8Str or obj_type.kind == .WebStr or obj_type.kind == .RangeStr) {
                    node.inferred_type = types.Type{ .kind = .I8 };
                } else if (obj_type.kind == .RawPointer) {
                    if (obj_type.payload) |p| {
                        node.inferred_type = p.*;
                    } else {
                        node.inferred_type = types.Type{ .kind = .U8 };
                    }
                } else {
                    node.inferred_type = types.Type{ .kind = .Any };
                }
            },
            .SpreadExpr => |*s| {
                try self.checkNode(s.iterable);
                node.inferred_type = s.iterable.inferred_type orelse .{ .kind = .List };
            },
            .SpawnStmt => |*s| {
                try self.checkNode(s.call_expr);
                const payload_t = try self.allocator.create(types.Type);
                payload_t.* = s.call_expr.inferred_type orelse types.Type{ .kind = .Any };
                node.inferred_type = .{ .kind = .Task, .payload = payload_t };
            },
            .AwaitExpr => |*a| {
                try self.checkNode(a.task_expr);
                if (a.task_expr.inferred_type.?.kind != .Task and a.task_expr.inferred_type.?.kind != .Any) {
                    std.debug.print("Type Warning: Awaiting a non-task type '{s}'\n", .{types.formatType(a.task_expr.inferred_type orelse types.Type{ .kind = .Unknown })});
                }
                const task_t = a.task_expr.inferred_type orelse types.Type{ .kind = .Any };
                if (task_t.kind == .Task and task_t.payload != null) {
                    node.inferred_type = task_t.payload.?.*;
                } else {
                    node.inferred_type = types.Type{ .kind = .Any };
                }
            },
            .MatchStmt => |*m| {
                try self.checkNode(m.subject);
                for (m.cases) |*case_node| {
                    if (case_node.pattern.node_type == .Identifier) {
                        const name = case_node.pattern.data.Identifier.name;
                        if (!std.mem.eql(u8, name, "_")) {
                            case_node.pattern.inferred_type = m.subject.inferred_type;
                        }
                    } else {
                        try self.checkNode(case_node.pattern);
                    }
                    if (case_node.guard) |guard| {
                        try self.checkNode(guard);
                    }
                    try self.checkNode(case_node.body);
                }
            },
            .TryStmt => |*ts| {
                try self.checkNode(ts.body);
                const body_type = ts.body.inferred_type orelse types.Type{ .kind = .Unknown };
                
                if (body_type.kind == .Result) {
                    ts.unwrapped_type = if (body_type.payload) |p| p.* else types.Type{ .kind = .Any };
                } else if (body_type.kind == .Option) {
                    ts.unwrapped_type = if (body_type.payload) |p| p.* else types.Type{ .kind = .Any };
                } else {
                    std.debug.print("Type Error: 'try' block must evaluate to a Result or Option type, got '{s}'\n", .{types.formatType(body_type)});
                    return error.TypeMismatch;
                }
                
                if (ts.catch_body) |cb| {
                    try self.checkNode(cb);
                }
                node.inferred_type = ts.unwrapped_type;
            },
            .ThrowStmt => |*th| {
                try self.checkNode(th.value);
                // Validate against function's return type if we are in a function
                if (self.current_func) |f| {
                    if (f.node_type == .FunDecl) {
                        if (f.data.FunDecl.return_type) |ret_annot| {
                            const ret_t = try self.validateType(ret_annot);
                            if (ret_t.kind != .Result) {
                                std.debug.print("Type Error: Cannot 'raise' in a function that does not return a Result type\n", .{});
                                return error.TypeMismatch;
                            }
                        } else {
                            std.debug.print("Type Error: Cannot 'raise' in a function that does not return a Result type\n", .{});
                            return error.TypeMismatch;
                        }
                    }
                }
            },
            .ParamBlockStmt => |*p| {
                // Typecheck the parameters (they should have annotations from AST)
                for (p.params, 0..) |param, i| {
                    if (param.node_type == .Identifier) {
                        param.inferred_type = try self.validateType(p.param_types[i]);
                    }
                }
                try self.checkNode(p.body);
                // The return statement validation will need to check against p.return_types if implemented
                node.inferred_type = .{ .kind = .Any };
            },
            .MacroDecl => {
                node.inferred_type = .{ .kind = .Void };
            },
            .MacroInvocation => {
                node.inferred_type = .{ .kind = .Void };
            },
            else => {},
        }
    }

    fn findReturnType(self: *TypeChecker, node: *ast.Node) ?types.Type {
        if (node.node_type == .ReturnStmt) {
            if (node.data.ReturnStmt.values) |values| {
                if (values.len == 1) {
                    return values[0].inferred_type orelse .{ .kind = .Any };
                }
                return node.inferred_type;
            }
            return .{ .kind = .Void };
        }
        if (node.node_type == .BlockStmt) {
            for (node.data.BlockStmt.statements) |stmt| {
                if (self.findReturnType(stmt)) |rt| return rt;
            }
        }
        if (node.node_type == .IfStmt) {
            if (self.findReturnType(node.data.IfStmt.then_branch)) |rt| return rt;
            if (node.data.IfStmt.else_branch) |eb| {
                if (self.findReturnType(eb)) |rt| return rt;
            }
        }
        if (node.node_type == .WhileStmt) {
            if (self.findReturnType(node.data.WhileStmt.body)) |rt| return rt;
        }
        if (node.node_type == .ForStmt) {
            if (self.findReturnType(node.data.ForStmt.body)) |rt| return rt;
        }
        return null;
    }
};

pub fn cloneTypeAnnotation(allocator: std.mem.Allocator, annot: ast.TypeAnnotation, bindings: std.StringHashMap(types.Type)) !ast.TypeAnnotation {
    var cloned = annot;
    if (bindings.get(annot.name)) |t| {
        if (t.kind == .Closure and t.closure_id != null) {
            cloned.name = try std.fmt.allocPrint(allocator, "Closure_{d}", .{t.closure_id.?});
        } else {
            cloned.name = try std.fmt.allocPrint(allocator, "{s}", .{types.formatType(t)});
        }
    } else {
        cloned.name = try allocator.dupe(u8, annot.name);
    }
    if (annot.generics) |gens| {
        var new_gens = try allocator.alloc(ast.TypeAnnotation, gens.len);
        for (gens, 0..) |g, i| {
            new_gens[i] = try cloneTypeAnnotation(allocator, g, bindings);
        }
        cloned.generics = new_gens;
    }
    ast.debugPrint("cloneTypeAnnotation: {s} -> {s}, generics count: {any}\n", .{annot.name, cloned.name, if (cloned.generics) |g| g.len else 0});
    return cloned;
}

pub fn cloneNode(allocator: std.mem.Allocator, node: *ast.Node, bindings: std.StringHashMap(types.Type)) !*ast.Node {
    const cloned = try allocator.create(ast.Node);
    cloned.* = node.*;
    
    switch (node.node_type) {

        .Program => {
            var d = node.data.Program;
            var new_declarations = try allocator.alloc(*ast.Node, d.declarations.len);
            for (d.declarations, 0..) |c, i| new_declarations[i] = try cloneNode(allocator, c, bindings);
            d.declarations = new_declarations;
            cloned.data = .{ .Program = d };
        },
        .ImportDecl => {
            const d = node.data.ImportDecl;
            cloned.data = .{ .ImportDecl = d };
        },
        .LinkDecl => {
            const d = node.data.LinkDecl;
            cloned.data = .{ .LinkDecl = d };
        },
        .FunDecl => {
            var d = node.data.FunDecl;
            var new_params = try allocator.alloc(*ast.Node, d.params.len);
            for (d.params, 0..) |c, i| new_params[i] = try cloneNode(allocator, c, bindings);
            d.params = new_params;
            
            ast.debugPrint("CLONENODE FunDecl: param_types.len = {d}\n", .{d.param_types.len});
            var new_param_types = try allocator.alloc(?ast.TypeAnnotation, d.param_types.len);
            for (d.param_types, 0..) |a, i| {
                if (a) |annot| {
                    ast.debugPrint("CLONENODE FunDecl: param_types[{d}] is NOT null, name={s}\n", .{i, annot.name});
                    new_param_types[i] = try cloneTypeAnnotation(allocator, annot, bindings);
                } else {
                    ast.debugPrint("CLONENODE FunDecl: param_types[{d}] IS null\n", .{i});
                    new_param_types[i] = null;
                }
            }
            d.param_types = new_param_types;
            
            d.body = try cloneNode(allocator, d.body, bindings);
            if (d.return_type) |a| d.return_type = try cloneTypeAnnotation(allocator, a, bindings);
            cloned.data = .{ .FunDecl = d };
        },
        .VarDecl => {
            var d = node.data.VarDecl;
            var new_type_annots = try allocator.alloc(?ast.TypeAnnotation, d.type_annots.len);
            for (d.type_annots, 0..) |a, i| {
                if (a) |annot| new_type_annots[i] = try cloneTypeAnnotation(allocator, annot, bindings)
                else new_type_annots[i] = null;
            }
            d.type_annots = new_type_annots;
            if (d.initializers) |arr| {
                var new_initializers = try allocator.alloc(*ast.Node, arr.len);
                for (arr, 0..) |c, i| new_initializers[i] = try cloneNode(allocator, c, bindings);
                d.initializers = new_initializers;
            }
            cloned.data = .{ .VarDecl = d };
        },
        .ClassDecl => {
            var d = node.data.ClassDecl;
            var new_fields = try allocator.alloc(*ast.Node, d.fields.len);
            for (d.fields, 0..) |c, i| new_fields[i] = try cloneNode(allocator, c, bindings);
            d.fields = new_fields;
            var new_methods = try allocator.alloc(*ast.Node, d.methods.len);
            for (d.methods, 0..) |c, i| new_methods[i] = try cloneNode(allocator, c, bindings);
            d.methods = new_methods;
            cloned.data = .{ .ClassDecl = d };
        },
        .StructDecl => {
            var d = node.data.StructDecl;
            var new_fields = try allocator.alloc(*ast.Node, d.fields.len);
            for (d.fields, 0..) |c, i| new_fields[i] = try cloneNode(allocator, c, bindings);
            d.fields = new_fields;
            var new_methods = try allocator.alloc(*ast.Node, d.methods.len);
            for (d.methods, 0..) |c, i| new_methods[i] = try cloneNode(allocator, c, bindings);
            d.methods = new_methods;
            cloned.data = .{ .StructDecl = d };
        },
        .UnionDecl => {
            var d = node.data.UnionDecl;
            var new_fields = try allocator.alloc(*ast.Node, d.fields.len);
            for (d.fields, 0..) |c, i| new_fields[i] = try cloneNode(allocator, c, bindings);
            d.fields = new_fields;
            var new_methods = try allocator.alloc(*ast.Node, d.methods.len);
            for (d.methods, 0..) |c, i| new_methods[i] = try cloneNode(allocator, c, bindings);
            d.methods = new_methods;
            if (d.tag_type) |annot| {
                d.tag_type = try cloneTypeAnnotation(allocator, annot, bindings);
            }
            cloned.data = .{ .UnionDecl = d };
        },
        .UnsafeBlock => {
            var d = node.data.UnsafeBlock;
            d.body = try cloneNode(allocator, d.body, bindings);
            cloned.data = .{ .UnsafeBlock = d };
        },
        .EnumDecl => {
            var d = node.data.EnumDecl;
            var new_variants = try allocator.alloc(*ast.Node, d.variants.len);
            for (d.variants, 0..) |c, i| new_variants[i] = try cloneNode(allocator, c, bindings);
            d.variants = new_variants;
            cloned.data = .{ .EnumDecl = d };
        },
        .EnumVariant => {
            var d = node.data.EnumVariant;
            if (d.value) |v| d.value = try cloneNode(allocator, v, bindings);
            if (d.payload_types) |pts| {
                var new_pts = try allocator.alloc(ast.TypeAnnotation, pts.len);
                for (pts, 0..) |p, i| new_pts[i] = try cloneTypeAnnotation(allocator, p, bindings);
                d.payload_types = new_pts;
            }
            cloned.data = .{ .EnumVariant = d };
        },
        .FieldDecl => {
            var d = node.data.FieldDecl;
            d.type_annot = try cloneTypeAnnotation(allocator, d.type_annot, bindings);
            if (d.default_value) |dv| d.default_value = try cloneNode(allocator, dv, bindings);
            cloned.data = .{ .FieldDecl = d };
        },
        .InterfaceDecl => {
            var d = node.data.InterfaceDecl;
            var new_methods = try allocator.alloc(*ast.Node, d.methods.len);
            for (d.methods, 0..) |c, i| new_methods[i] = try cloneNode(allocator, c, bindings);
            d.methods = new_methods;
            cloned.data = .{ .InterfaceDecl = d };
        },
        .IfStmt => {
            var d = node.data.IfStmt;
            d.condition = try cloneNode(allocator, d.condition, bindings);
            d.then_branch = try cloneNode(allocator, d.then_branch, bindings);
            if (d.else_branch) |n| d.else_branch = try cloneNode(allocator, n, bindings);
            cloned.data = .{ .IfStmt = d };
        },
        .WithStmt => {
            var d = node.data.WithStmt;
            d.expr = try cloneNode(allocator, d.expr, bindings);
            d.body = try cloneNode(allocator, d.body, bindings);
            d.auto_drops = null;
            cloned.data = .{ .WithStmt = d };
        },
        .ForStmt => {
            var d = node.data.ForStmt;
            if (d.type_annot) |a| d.type_annot = try cloneTypeAnnotation(allocator, a, bindings);
            d.iterable = try cloneNode(allocator, d.iterable, bindings);
            d.body = try cloneNode(allocator, d.body, bindings);
            cloned.data = .{ .ForStmt = d };
        },
        .WhileStmt => {
            var d = node.data.WhileStmt;
            d.condition = try cloneNode(allocator, d.condition, bindings);
            d.body = try cloneNode(allocator, d.body, bindings);
            cloned.data = .{ .WhileStmt = d };
        },
        .BreakStmt => {
            const d = node.data.BreakStmt;
            cloned.data = .{ .BreakStmt = d };
        },
        .ContinueStmt => {
            const d = node.data.ContinueStmt;
            cloned.data = .{ .ContinueStmt = d };
        },
        .PassStmt => {
            const d = node.data.PassStmt;
            cloned.data = .{ .PassStmt = d };
        },
        .ReturnStmt => {
            var d = node.data.ReturnStmt;
            if (d.values) |arr| {
                var new_values = try allocator.alloc(*ast.Node, arr.len);
                for (arr, 0..) |c, i| new_values[i] = try cloneNode(allocator, c, bindings);
                d.values = new_values;
            }
            cloned.data = .{ .ReturnStmt = d };
        },
        .BlockStmt => {
            var d = node.data.BlockStmt;
            var new_statements = try allocator.alloc(*ast.Node, d.statements.len);
            for (d.statements, 0..) |c, i| new_statements[i] = try cloneNode(allocator, c, bindings);
            d.statements = new_statements;
            cloned.data = .{ .BlockStmt = d };
        },
        .ParamBlockStmt => {
            var d = node.data.ParamBlockStmt;
            var new_params = try allocator.alloc(*ast.Node, d.params.len);
            for (d.params, 0..) |c, i| new_params[i] = try cloneNode(allocator, c, bindings);
            d.params = new_params;
            d.body = try cloneNode(allocator, d.body, bindings);
            cloned.data = .{ .ParamBlockStmt = d };
        },
        .SpawnStmt => {
            var d = node.data.SpawnStmt;
            d.call_expr = try cloneNode(allocator, d.call_expr, bindings);
            cloned.data = .{ .SpawnStmt = d };
        },
        .TryStmt => {
            var d = node.data.TryStmt;
            d.body = try cloneNode(allocator, d.body, bindings);
            if (d.catch_body) |cb| d.catch_body = try cloneNode(allocator, cb, bindings);
            cloned.data = .{ .TryStmt = d };
        },
        .ThrowStmt => {
            var d = node.data.ThrowStmt;
            d.value = try cloneNode(allocator, d.value, bindings);
            cloned.data = .{ .ThrowStmt = d };
        },
        .BinaryExpr => {
            var d = node.data.BinaryExpr;
            d.left = try cloneNode(allocator, d.left, bindings);
            d.right = try cloneNode(allocator, d.right, bindings);
            cloned.data = .{ .BinaryExpr = d };
        },
        .UnaryExpr => {
            var d = node.data.UnaryExpr;
            d.operand = try cloneNode(allocator, d.operand, bindings);
            cloned.data = .{ .UnaryExpr = d };
        },
        .CastExpr => {
            var d = node.data.CastExpr;
            d.operand = try cloneNode(allocator, d.operand, bindings);
            d.target_type = try cloneTypeAnnotation(allocator, d.target_type, bindings);
            cloned.data = .{ .CastExpr = d };
        },
        .CallExpr => {
            var d = node.data.CallExpr;
            d.callee = try cloneNode(allocator, d.callee, bindings);
            var new_arguments = try allocator.alloc(*ast.Node, d.arguments.len);
            for (d.arguments, 0..) |c, i| new_arguments[i] = try cloneNode(allocator, c, bindings);
            d.arguments = new_arguments;
            
            if (d.generic_args) |gargs| {
                var new_gargs = try allocator.alloc(ast.TypeAnnotation, gargs.len);
                for (gargs, 0..) |g, i| new_gargs[i] = try cloneTypeAnnotation(allocator, g, bindings);
                d.generic_args = new_gargs;
            }
            cloned.data = .{ .CallExpr = d };
        },
        .KeywordArg => {
            var d = node.data.KeywordArg;
            d.value = try cloneNode(allocator, d.value, bindings);
            cloned.data = .{ .KeywordArg = d };
        },
        .MethodCallExpr => {
            var d = node.data.MethodCallExpr;
            d.receiver = try cloneNode(allocator, d.receiver, bindings);
            var new_arguments = try allocator.alloc(*ast.Node, d.arguments.len);
            for (d.arguments, 0..) |c, i| new_arguments[i] = try cloneNode(allocator, c, bindings);
            d.arguments = new_arguments;
            cloned.data = .{ .MethodCallExpr = d };
        },
        .MemberExpr => {
            var d = node.data.MemberExpr;
            d.object = try cloneNode(allocator, d.object, bindings);
            cloned.data = .{ .MemberExpr = d };
        },
        .IndexExpr => {
            var d = node.data.IndexExpr;
            d.object = try cloneNode(allocator, d.object, bindings);
            d.index = try cloneNode(allocator, d.index, bindings);
            cloned.data = .{ .IndexExpr = d };
        },
        .ClosureExpr => {
            var d = node.data.ClosureExpr;
            var new_params = try allocator.alloc(*ast.Node, d.params.len);
            for (d.params, 0..) |c, i| new_params[i] = try cloneNode(allocator, c, bindings);
            d.params = new_params;
            var new_param_types = try allocator.alloc(?ast.TypeAnnotation, d.param_types.len);
            for (d.param_types, 0..) |pt, i| {
                new_param_types[i] = if (pt) |a| try cloneTypeAnnotation(allocator, a, bindings) else null;
            }
            d.param_types = new_param_types;
            d.body = try cloneNode(allocator, d.body, bindings);
            if (d.return_type) |a| d.return_type = try cloneTypeAnnotation(allocator, a, bindings);
            cloned.data = .{ .ClosureExpr = d };
        },
        .Identifier => {
            const d = node.data.Identifier;
            cloned.data = .{ .Identifier = .{
                .name = try allocator.dupe(u8, d.name),
                .resolved_symbol = null,
            }};
        },
        .NumberLiteral => {
            const d = node.data.NumberLiteral;
            cloned.data = .{ .NumberLiteral = d };
        },
        .StringLiteral => {
            const d = node.data.StringLiteral;
            cloned.data = .{ .StringLiteral = d };
        },
        .InterpolatedString => {
            var d = node.data.InterpolatedString;
            var new_parts = try allocator.alloc(*ast.Node, d.parts.len);
            for (d.parts, 0..) |p, i| new_parts[i] = try cloneNode(allocator, p, bindings);
            d.parts = new_parts;
            cloned.data = .{ .InterpolatedString = d };
        },
        .BooleanLiteral => {
            const d = node.data.BooleanLiteral;
            cloned.data = .{ .BooleanLiteral = d };
        },
        .ListLiteral => {
            var d = node.data.ListLiteral;
            var new_elements = try allocator.alloc(*ast.Node, d.elements.len);
            for (d.elements, 0..) |c, i| new_elements[i] = try cloneNode(allocator, c, bindings);
            d.elements = new_elements;
            cloned.data = .{ .ListLiteral = d };
        },
        .DictLiteral => {
            var d = node.data.DictLiteral;
            var new_keys = try allocator.alloc(*ast.Node, d.keys.len);
            var new_values = try allocator.alloc(*ast.Node, d.values.len);
            for (d.keys, 0..) |k, i| new_keys[i] = try cloneNode(allocator, k, bindings);
            for (d.values, 0..) |v, i| new_values[i] = try cloneNode(allocator, v, bindings);
            d.keys = new_keys;
            d.values = new_values;
            cloned.data = .{ .DictLiteral = d };
        },
        .AwaitExpr => {
            var d = node.data.AwaitExpr;
            d.task_expr = try cloneNode(allocator, d.task_expr, bindings);
            cloned.data = .{ .AwaitExpr = d };
        },
        .SpreadExpr => {
            var d = node.data.SpreadExpr;
            d.iterable = try cloneNode(allocator, d.iterable, bindings);
            cloned.data = .{ .SpreadExpr = d };
        },
        .MatchStmt => {
            var d = node.data.MatchStmt;
            d.subject = try cloneNode(allocator, d.subject, bindings);
            var new_cases = try allocator.alloc(ast.MatchCase, d.cases.len);
            for (d.cases, 0..) |c, i| {
                var nc = c;
                nc.pattern = try cloneNode(allocator, c.pattern, bindings);
                nc.body = try cloneNode(allocator, c.body, bindings);
                new_cases[i] = nc;
            }
            d.cases = new_cases;
            cloned.data = .{ .MatchStmt = d };
        },
        .MacroDecl => {
            var d = node.data.MacroDecl;
            var new_params = try allocator.alloc(*ast.Node, d.params.len);
            for (d.params, 0..) |c, i| new_params[i] = try cloneNode(allocator, c, bindings);
            d.params = new_params;
            
            var new_types = try allocator.alloc(?ast.TypeAnnotation, d.param_types.len);
            for (d.param_types, 0..) |pt, i| {
                new_types[i] = if (pt) |annot| try cloneTypeAnnotation(allocator, annot, bindings) else null;
            }
            d.param_types = new_types;
            
            d.body = try cloneNode(allocator, d.body, bindings);
            cloned.data = .{ .MacroDecl = d };
        },
        .MacroInvocation => {
            var d = node.data.MacroInvocation;
            var new_args = try allocator.alloc(*ast.Node, d.arguments.len);
            for (d.arguments, 0..) |c, i| new_args[i] = try cloneNode(allocator, c, bindings);
            d.arguments = new_args;
            cloned.data = .{ .MacroInvocation = d };
        },
    }
    cloned.inferred_type = null; 
    return cloned;
}

pub fn inferGenericBindings(annot: ast.TypeAnnotation, actual: types.Type, generics: [][]const u8, bindings: *std.StringHashMap(types.Type)) !void {
    for (generics) |g| {
        if (std.mem.eql(u8, annot.name, g)) {
            if (!bindings.contains(g)) {
                try bindings.put(g, actual);
            }
            return;
        }
    }
    
    if (annot.generics != null and annot.generics.?.len > 0) {
        if (std.mem.eql(u8, annot.name, "List") and actual.kind == .List) {
            if (actual.payload) |p| {
                try inferGenericBindings(annot.generics.?[0], p.*, generics, bindings);
            }
        }
    }
}
