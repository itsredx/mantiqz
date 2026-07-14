//! Semantic analysis — two-pass name resolution and scope construction.
//!
//! First pass (`declarePass1`) registers every declaration in its enclosing scope.
//! Second pass (`resolvePass2`) resolves identifier references, loads modules
//! recursively, injects built-in symbols, manages closure capture analysis,
//! and verifies that every name refers to a known declaration. Runs before
//! `typecheck.zig` and `borrowck.zig`.
//!
//! Key responsibilities:
//! - `findProjectRoot` — locate the project root from CWD markers
//! - `mangleModuleName` — create `mantiq_`-prefixed LLVM-safe names
//! - `resolveModulePath` — file lookup across multiple search roots
//! - Module loading — parse, lower, analyse, type-check, cache imported modules
//! - Built-in injection — `std.*` modules inject directly without file I/O
//! - `pushScope` / `popScope` — lexical scope lifetime management
//! - Closure capture tracking via `Scope.closure_node`

const std = @import("std");
const ast = @import("ast.zig");
const symbols = @import("symbols.zig");
const parser = @import("parser.zig");
const lower = @import("lower.zig");
const typecheck = @import("typecheck.zig");

fn isSymbolImported(imported_symbols: []const []const u8, name: []const u8) bool {
    if (imported_symbols.len == 0) return true;
    for (imported_symbols) |imp| {
        if (std.mem.eql(u8, imp, name)) return true;
    }
    return false;
}


pub const SemanticError = error{
    Redeclaration,
    UndefinedVariable,
    OutOfMemory,
};

pub const SemanticAnalyzer = struct {
    allocator: std.mem.Allocator,
    global_scope: *symbols.Scope,
    current_scope: *symbols.Scope,
    loaded_modules: std.StringHashMap(*symbols.Scope),

    fn findProjectRoot(allocator: std.mem.Allocator) ![]const u8 {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        
        var current_path = cwd;
        while (true) {
            var dir = std.fs.openDirAbsolute(current_path, .{}) catch break;
            defer dir.close();
            if (dir.access("nmproject.toml", .{})) |_| {
                return try allocator.dupe(u8, current_path);
            } else |_| {}
            
            if (dir.access("mantiq.toml", .{})) |_| {
                return try allocator.dupe(u8, current_path);
            } else |_| {}
            
            if (dir.access("nizam.toml", .{})) |_| {
                return try allocator.dupe(u8, current_path);
            } else |_| {}

            if (dir.access("project.toml", .{})) |_| {
                return try allocator.dupe(u8, current_path);
            } else |_| {}
            
            if (dir.access("mantiq-compiler", .{})) |_| {
                return try allocator.dupe(u8, current_path);
            } else |_| {}

            if (dir.access("std", .{})) |_| {
                return try allocator.dupe(u8, current_path);
            } else |_| {}
            
            if (std.mem.lastIndexOfScalar(u8, current_path, '/')) |idx| {
                if (idx == 0) break; // Reached root '/'
                current_path = current_path[0..idx];
            } else {
                break;
            }
        }
        
        // Fallback to cwd
        return try allocator.dupe(u8, ".");
    }

    fn mangleModuleName(allocator: std.mem.Allocator, target: []const u8) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        
        try buf.appendSlice("mantiq_");
        for (target) |c| {
            if (c == '/') {
                try buf.appendSlice("__");
            } else if (c == '.') {
                try buf.appendSlice("_");
            } else {
                try buf.append(c);
            }
        }
        return buf.toOwnedSlice();
    }

    fn resolveModulePath(self: *SemanticAnalyzer, module_path: []const u8, kind: ast.ImportKind) !struct { filename: []const u8, mode: ast.LanguageMode } {
        if (kind == .path) {
            const nz_path = try std.fmt.allocPrint(self.allocator, "{s}.nz", .{module_path});
            if (std.fs.cwd().access(nz_path, .{})) |_| return .{ .filename = nz_path, .mode = .Nizam } else |_| self.allocator.free(nz_path);
            
            const mq_path = try std.fmt.allocPrint(self.allocator, "{s}.mq", .{module_path});
            if (std.fs.cwd().access(mq_path, .{})) |_| return .{ .filename = mq_path, .mode = .Mantiq } else |_| self.allocator.free(mq_path);
            return error.FileNotFound;
        }

        var proj_root_to_free: ?[]const u8 = null;
        defer if (proj_root_to_free) |p| self.allocator.free(p);

        const path_buf = try self.allocator.alloc(u8, module_path.len);
        defer self.allocator.free(path_buf);
        @memcpy(path_buf, module_path);
        for (path_buf) |*c_ptr| {
            if (c_ptr.* == '.') c_ptr.* = '/';
        }

        var search_roots = std.ArrayList([]const u8).init(self.allocator);
        defer search_roots.deinit();

        if (kind == .vendor) {
            const proj_root = try findProjectRoot(self.allocator);
            defer self.allocator.free(proj_root);
            
            const root_vendor = try std.fmt.allocPrint(self.allocator, "{s}/vendor/", .{proj_root});
            try search_roots.append(root_vendor);
            
            if (std.posix.getenv("MANTIQ_VENDOR_PATH")) |env_path| {
                try search_roots.append(env_path);
            }
            if (std.posix.getenv("HOME")) |home| {
                const home_vendor = try std.fmt.allocPrint(self.allocator, "{s}/.mantiq/vendor/", .{home});
                try search_roots.append(home_vendor);
            }
            try search_roots.append("/usr/lib/mantiq/vendor/");
        } else {
            try search_roots.append("./");
            if (std.mem.startsWith(u8, module_path, "std.")) {
                const proj_root = try findProjectRoot(self.allocator);
                proj_root_to_free = proj_root;
                try search_roots.append(proj_root);
            }
        }

        for (search_roots.items) |root| {
            const root_with_slash = if (std.mem.endsWith(u8, root, "/")) root else try std.fmt.allocPrint(self.allocator, "{s}/", .{root});
            defer if (!std.mem.endsWith(u8, root, "/")) self.allocator.free(root_with_slash);
            
            const base_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{root_with_slash, path_buf});
            defer self.allocator.free(base_path);
            
            const nz_path = try std.fmt.allocPrint(self.allocator, "{s}.nz", .{base_path});
            if (std.fs.cwd().access(nz_path, .{})) |_| return .{ .filename = nz_path, .mode = .Nizam } else |_| self.allocator.free(nz_path);

            const mq_path = try std.fmt.allocPrint(self.allocator, "{s}.mq", .{base_path});
            if (std.fs.cwd().access(mq_path, .{})) |_| return .{ .filename = mq_path, .mode = .Mantiq } else |_| self.allocator.free(mq_path);
            
            if (kind == .vendor) {
                const dir_nz_path = try std.fmt.allocPrint(self.allocator, "{s}/main.nz", .{base_path});
                if (std.fs.cwd().access(dir_nz_path, .{})) |_| return .{ .filename = dir_nz_path, .mode = .Nizam } else |_| self.allocator.free(dir_nz_path);
                
                const dir_mq_path = try std.fmt.allocPrint(self.allocator, "{s}/main.mq", .{base_path});
                if (std.fs.cwd().access(dir_mq_path, .{})) |_| return .{ .filename = dir_mq_path, .mode = .Mantiq } else |_| self.allocator.free(dir_mq_path);
            }
        }

        return error.FileNotFound;
    }
    
    // In a real compiler we would accumulate errors instead of failing immediately on the first one,
    // but for our early stage we return the first error.

    pub fn init(allocator: std.mem.Allocator, mode: ast.LanguageMode) !SemanticAnalyzer {
        const global_scope = try symbols.Scope.create(allocator, null);
        
        // Register built-ins
        const builtins = [_][]const u8{ "make", "drop", "range", "print", "Some", "Empty", "None", "Ok", "Err" };
        for (builtins) |b| {
            const sym = try allocator.create(symbols.Symbol);
            sym.* = .{ .name = b, .kind = .Function, .decl_node = null };
            try global_scope.define(sym);
        }
        
        if (mode == .Mantiq) {
            const mantiq_builtins = [_][]const u8{ 
                "String", "List", "Any",
                "webstr", "utf16str", "rangestr", "utf32str" 
            };
            for (mantiq_builtins) |b| {
                const sym = try allocator.create(symbols.Symbol);
                sym.* = .{ .name = b, .kind = .Class, .decl_node = null }; // Using Class for generic object types
                try global_scope.define(sym);
            }
        }

        return .{
            .allocator = allocator,
            .global_scope = global_scope,
            .current_scope = global_scope,
            .loaded_modules = std.StringHashMap(*symbols.Scope).init(allocator),
        };
    }

    fn pushScope(self: *SemanticAnalyzer) !void {
        self.current_scope = try symbols.Scope.create(self.allocator, self.current_scope);
    }

    fn popScope(self: *SemanticAnalyzer) void {
        if (self.current_scope.parent) |p| {
            self.current_scope = p;
        }
    }

    /// Declare a symbol in the current scope, returning Redeclaration if already defined.
    /// Consolidates the repeated resolveLocal + print + define pattern.
    fn declareSymbol(self: *SemanticAnalyzer, name: []const u8, kind: symbols.SymbolType, decl_node: ?*ast.Node) !*symbols.Symbol {
        if (self.current_scope.resolveLocal(name)) |existing| {
            if (existing.decl_node != null) {
                const kind_str = switch (kind) {
                    .Variable => "variable",
                    .Function => "function",
                    .Class => "class",
                    .Interface => "interface",
                    .Struct => "struct",
                    .Enum => "enum",
                    .Union => "union",
                    .Module => "module",
                };
                std.debug.print("Semantic Error: Redeclaration of {s} '{s}'\n", .{ kind_str, name });
                return error.Redeclaration;
            }
        }
        const sym = try self.allocator.create(symbols.Symbol);
        sym.* = .{ .name = name, .kind = kind, .decl_node = decl_node };
        try self.current_scope.define(sym);
        return sym;
    }

    pub fn analyze(self: *SemanticAnalyzer, program: *ast.Node) anyerror!void {
        if (program.node_type != .Program) return;

        // Pass 1: Global Declarations
        for (program.data.Program.declarations) |decl| {
            try self.declarePass1(decl);
        }

        // Pass 2: Local Declarations and Identifier Resolution
        for (program.data.Program.declarations) |decl| {
            try self.resolvePass2(decl);
        }
    }

    pub fn declarePass1(self: *SemanticAnalyzer, node: *ast.Node) anyerror!void {
        switch (node.data) {
            .VarDecl => |*v| {
                for (v.names) |name| {
                    _ = try self.declareSymbol(name, .Variable, node);
                }
            },
            .FunDecl => |*f| {
                _ = try self.declareSymbol(f.name, .Function, node);
            },
            .ClassDecl => |*cl| {
                _ = try self.declareSymbol(cl.name, .Class, node);
            },
            .InterfaceDecl => |*iface| {
                _ = try self.declareSymbol(iface.name, .Interface, node);
            },
            .StructDecl => |*s| {
                _ = try self.declareSymbol(s.name, .Struct, node);
            },
            .EnumDecl => |*e| {
                _ = try self.declareSymbol(e.name, .Enum, node);
            },
            .UnionDecl => |*u| {
                _ = try self.declareSymbol(u.name, .Union, node);
            },
            .ImportDecl => |*i| {
                if (i.kind == .c) {
                    // Do not parse or load C files. They are just for codegen.
                    return;
                }

                if (std.mem.eql(u8, i.target, "std.quantum") or std.mem.eql(u8, i.target, "std.mem") or std.mem.eql(u8, i.target, "std.io") or std.mem.eql(u8, i.target, "std.fs") or std.mem.eql(u8, i.target, "std.process") or std.mem.eql(u8, i.target, "std.time") or std.mem.eql(u8, i.target, "std.sys") or std.mem.eql(u8, i.target, "std.option") or std.mem.eql(u8, i.target, "std.result")) {
                    if (std.mem.eql(u8, i.target, "std.quantum")) {
                        // Inject quantum builtins into scope
                        const builtins = [_][]const u8{ "qbit", "qreg", "H", "measure", "CNOT", "X", "Y", "Z" };
                        for (builtins) |b| {
                            if (!isSymbolImported(i.imported_symbols, b)) continue;
                            const sym = try self.allocator.create(symbols.Symbol);
                            const is_func = std.mem.eql(u8, b, "H") or std.mem.eql(u8, b, "measure") or std.mem.eql(u8, b, "CNOT") or std.mem.eql(u8, b, "qreg") or std.mem.eql(u8, b, "X") or std.mem.eql(u8, b, "Y") or std.mem.eql(u8, b, "Z");
                            sym.* = .{ .name = b, .kind = if (is_func) .Function else .Variable, .decl_node = node };
                            try self.current_scope.define(sym);
                        }

                    } else if (std.mem.eql(u8, i.target, "std.mem")) {
                        // Inject memory builtins into scope
                        const builtins = [_][]const u8{ "make", "drop", "resize" };
                        for (builtins) |b| {
                            if (!isSymbolImported(i.imported_symbols, b)) continue;
                            const sym = try self.allocator.create(symbols.Symbol);
                            sym.* = .{ .name = b, .kind = .Function, .decl_node = node };
                            try self.current_scope.define(sym);
                        }
                    } else if (std.mem.eql(u8, i.target, "std.io")) {
                        // Inject io builtins into scope
                        const builtins = [_][]const u8{ "print", "println", "stdin", "stdout", "stderr", "write", "read" };
                        for (builtins) |b| {
                            if (!isSymbolImported(i.imported_symbols, b)) continue;
                            const sym = try self.allocator.create(symbols.Symbol);
                            const is_func = std.mem.eql(u8, b, "print") or std.mem.eql(u8, b, "println") or std.mem.eql(u8, b, "write") or std.mem.eql(u8, b, "read");
                            sym.* = .{ .name = b, .kind = if (is_func) .Function else .Variable, .decl_node = node };
                            try self.current_scope.define(sym);
                        }
                    } else if (std.mem.eql(u8, i.target, "std.fs")) {
                        // Inject fs builtins into scope
                        const builtins = [_][]const u8{ "open", "close", "read", "write", "exists" };
                        for (builtins) |b| {
                            if (!isSymbolImported(i.imported_symbols, b)) continue;
                            const sym = try self.allocator.create(symbols.Symbol);
                            sym.* = .{ .name = b, .kind = .Function, .decl_node = node };
                            try self.current_scope.define(sym);
                        }
                    } else if (std.mem.eql(u8, i.target, "std.process")) {
                        // Inject process builtins into scope
                        const builtins = [_][]const u8{ "exit", "args" };
                        for (builtins) |b| {
                            if (!isSymbolImported(i.imported_symbols, b)) continue;
                            const sym = try self.allocator.create(symbols.Symbol);
                            sym.* = .{ .name = b, .kind = .Function, .decl_node = node };
                            try self.current_scope.define(sym);
                        }
                    } else if (std.mem.eql(u8, i.target, "std.time")) {
                        // Inject time builtins into scope
                        const builtins = [_][]const u8{ "now", "sleep" };
                        for (builtins) |b| {
                            if (!isSymbolImported(i.imported_symbols, b)) continue;
                            const sym = try self.allocator.create(symbols.Symbol);
                            sym.* = .{ .name = b, .kind = .Function, .decl_node = node };
                            try self.current_scope.define(sym);
                        }
                    } else if (std.mem.eql(u8, i.target, "std.sys")) {
                        // Inject sys builtins into scope
                        const builtins = [_][]const u8{ "os", "arch", "getenv", "setenv", "unsetenv" };
                        for (builtins) |b| {
                            if (!isSymbolImported(i.imported_symbols, b)) continue;
                            const sym = try self.allocator.create(symbols.Symbol);
                            sym.* = .{ .name = b, .kind = .Function, .decl_node = node };
                            try self.current_scope.define(sym);
                        }
                    } else if (std.mem.eql(u8, i.target, "std.option")) {
                        // Inject option builtins into scope
                        const builtins = [_][]const u8{ "Option", "Some", "Empty" };
                        for (builtins) |b| {
                            if (!isSymbolImported(i.imported_symbols, b)) continue;
                            const sym = try self.allocator.create(symbols.Symbol);
                            const is_func = std.mem.eql(u8, b, "Some") or std.mem.eql(u8, b, "Empty");
                            sym.* = .{ .name = b, .kind = if (is_func) .Function else .Struct, .decl_node = node };
                            try self.current_scope.define(sym);
                        }
                    } else if (std.mem.eql(u8, i.target, "std.result")) {
                        // Inject result builtins into scope
                        const builtins = [_][]const u8{ "Result", "Ok", "Err" };
                        for (builtins) |b| {
                            if (!isSymbolImported(i.imported_symbols, b)) continue;
                            const sym = try self.allocator.create(symbols.Symbol);
                            const is_func = std.mem.eql(u8, b, "Ok") or std.mem.eql(u8, b, "Err");
                            sym.* = .{ .name = b, .kind = if (is_func) .Function else .Struct, .decl_node = node };
                            try self.current_scope.define(sym);
                        }
                    }
                } else {
                    const module_info = self.resolveModulePath(i.target, i.kind) catch |err| {
                        std.debug.print("Semantic Error: Could not resolve module '{s}': {}\n", .{ i.target, err });
                        return err;
                    };

                    var mod_ns_name = i.target;
                    if (std.mem.lastIndexOfScalar(u8, i.target, '/')) |slash_idx| {
                        mod_ns_name = i.target[slash_idx + 1 ..];
                    } else if (std.mem.lastIndexOfScalar(u8, i.target, '.')) |dot_idx| {
                        mod_ns_name = i.target[dot_idx + 1 ..];
                    }
                    if (i.alias) |alias_name| {
                        mod_ns_name = alias_name;
                    }
                    
                    const llvm_ns_name = try mangleModuleName(self.allocator, i.target);

                    var target_scope: ?*symbols.Scope = null;
                    if (self.loaded_modules.get(i.target)) |scope| {
                        target_scope = scope;
                    } else {
                        var file = std.fs.cwd().openFile(module_info.filename, .{}) catch |err| {
                            std.debug.print("Semantic Error: Could not open module file '{s}': {}\n", .{ module_info.filename, err });
                            return err;
                        };
                        defer file.close();

                        const source_code = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
                        var p = try parser.Parser.init();
                        defer p.deinit();
                        const tree = try p.parseString(source_code);
                        defer parser.c.ts_tree_delete(tree);
                        const root_ts_node = parser.c.ts_tree_root_node(tree);

                        var macros = std.StringHashMap(lower.MacroDef).init(self.allocator);
                        defer macros.deinit();
                        var lowerer = lower.Lowerer.init(self.allocator, module_info.mode, source_code, &macros);
                        const ast_root = try lowerer.lowerProgram(root_ts_node);

                        // Recursively set module name on nodes BEFORE sema/typecheck using the LLVM flattened namespace
                        for (ast_root.data.Program.declarations) |sub_decl| {
                            sub_decl.module_name = llvm_ns_name;
                            if (sub_decl.node_type == .StructDecl) {
                                for (sub_decl.data.StructDecl.methods) |method| {
                                    method.module_name = llvm_ns_name;
                                }
                            } else if (sub_decl.node_type == .UnionDecl) {
                                for (sub_decl.data.UnionDecl.methods) |method| {
                                    method.module_name = llvm_ns_name;
                                }
                            } else if (sub_decl.node_type == .ClassDecl) {
                                for (sub_decl.data.ClassDecl.methods) |method| {
                                    method.module_name = llvm_ns_name;
                                }
                            }
                        }

                        var sa = try SemanticAnalyzer.init(self.allocator, module_info.mode);
                        sa.loaded_modules = self.loaded_modules;

                        if (std.mem.eql(u8, i.target, "std.collections")) {
                            // Inject collections builtins into the module's global scope before analysis
                            // so both the Nizam module code and the importer can access them
                            const builtins = [_][]const u8{ "List", "Dict", "String" };
                            for (builtins) |b| {
                                const sym = try self.allocator.create(symbols.Symbol);
                                sym.* = .{ .name = b, .kind = .Struct, .decl_node = node };
                                try sa.global_scope.define(sym);
                            }
                        }

                        try sa.analyze(ast_root);

                        self.loaded_modules = sa.loaded_modules;
                        try self.loaded_modules.put(i.target, sa.global_scope);
                        target_scope = sa.global_scope;

                        var tc = typecheck.TypeChecker.init(self.allocator, module_info.mode);
                        try tc.checkProgram(ast_root);

                        i.module_ast = ast_root;
                    }

                    const mod_sym = try self.allocator.create(symbols.Symbol);
                    mod_sym.* = .{
                        .name = mod_ns_name,
                        .kind = .Module,
                        .decl_node = node,
                        .module_scope = target_scope,
                    };
                    try self.current_scope.define(mod_sym);

                    if (i.imported_symbols.len > 0) {
                        for (i.imported_symbols) |sym_name| {
                            if (target_scope.?.resolveLocal(sym_name)) |orig_sym| {
                                const alias_sym = try self.allocator.create(symbols.Symbol);
                                alias_sym.* = orig_sym.*;
                                try self.current_scope.define(alias_sym);
                            } else {
                                std.debug.print("Semantic Error: Module '{s}' has no symbol named '{s}'\n", .{ i.target, sym_name });
                                return error.UndefinedVariable;
                            }
                        }
                    }
                }
            },
            .LinkDecl => {
                // Not fully modeled in sema yet; just passes through
            },
            else => {},
        }
    }

    pub fn resolvePass2(self: *SemanticAnalyzer, node: *ast.Node) anyerror!void {
        switch (node.data) {
            .InterpolatedString => |*is| {
                for (is.parts) |part| {
                    try self.resolvePass2(part);
                }
            },
            .DictLiteral => |*dl| {
                for (dl.keys) |k| try self.resolvePass2(k);
                for (dl.values) |v| try self.resolvePass2(v);
            },
            .IndexExpr => |*idx| {
                try self.resolvePass2(idx.object);
                try self.resolvePass2(idx.index);
            },
            .VarDecl => |*v| {
                if (v.initializers) |inits| {
                    for (inits) |init_node| {
                        try self.resolvePass2(init_node);
                    }
                }
                // If we are NOT in the global scope, we define it in pass 2 (local variable).
                // Pythonic shadowing: if it's already defined locally, it's a redeclaration.
                // If it's defined globally, we shadow it (by defining it locally).
                if (self.current_scope != self.global_scope) {
                    var r_syms = try self.allocator.alloc(*symbols.Symbol, v.names.len);
                    for (v.names, 0..) |name, idx| {
                        if (self.current_scope.resolveLocal(name) != null) {
                            std.debug.print("Semantic Error: Redeclaration of local variable '{s}'\n", .{name});
                            return error.Redeclaration;
                        }
                        const sym = try self.allocator.create(symbols.Symbol);
                        sym.* = .{ .name = name, .kind = .Variable, .decl_node = node };
                        try self.current_scope.define(sym);
                        r_syms[idx] = sym;
                    }
                    v.resolved_symbols = r_syms;
                } else {
                    var r_syms = try self.allocator.alloc(*symbols.Symbol, v.names.len);
                    for (v.names, 0..) |name, idx| {
                        if (self.current_scope.resolveLocal(name)) |res| {
                            r_syms[idx] = res;
                        }
                    }
                    v.resolved_symbols = r_syms;
                }
            },
            .FunDecl => |*f| {
                if (f.generic_params != null) return;
                
                const sym = try self.allocator.create(symbols.Symbol);
                sym.* = .{
                    .name = f.name,
                    .kind = .Function,
                    .decl_node = node,
                };
                try self.current_scope.define(sym);

                // Create a new scope for the function body
                const func_scope = try symbols.Scope.create(self.allocator, self.current_scope);
                self.current_scope = func_scope;
                
                // Add parameters to scope
                for (f.params) |param| {
                    ast.debugPrint("DEBUG: FunDecl '{s}' param node type: {}\n", .{f.name, param.node_type});
                    if (param.node_type == .Identifier) {
                        const p_name = param.data.Identifier.name;
                        ast.debugPrint("DEBUG: Adding param '{s}' to func_scope\n", .{p_name});
                        const p_sym = try self.allocator.create(symbols.Symbol);
                        p_sym.* = .{ .name = p_name, .kind = .Variable, .decl_node = param };
                        try self.current_scope.define(p_sym);
                        param.data.Identifier.resolved_symbol = p_sym;
                    }
                }
                
                try self.resolvePass2(f.body);
                self.current_scope = self.current_scope.parent.?;
            },
            .ClassDecl => |*c| {
                // Traverse methods
                const class_scope = try symbols.Scope.create(self.allocator, self.current_scope);
                self.current_scope = class_scope;
                for (c.methods) |method| {
                    try self.resolvePass2(method);
                }
                self.current_scope = self.current_scope.parent.?;
            },
            .InterfaceDecl => |*i| {
                const iface_scope = try symbols.Scope.create(self.allocator, self.current_scope);
                self.current_scope = iface_scope;
                for (i.methods) |method| {
                    try self.resolvePass2(method);
                }
                self.current_scope = self.current_scope.parent.?;
            },
            .StructDecl => |*s| {
                if (s.generic_params != null) return;
                try self.pushScope();
                for (s.fields) |field| {
                    try self.resolvePass2(field);
                }
                for (s.methods) |method| {
                    // Mangle method name for codegen: StructName_methodName
                    if (method.node_type == .FunDecl) {
                        const original_name = method.data.FunDecl.name;
                        method.data.FunDecl.name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{s.name, original_name});
                    }
                    try self.resolvePass2(method);
                }
                self.popScope();
            },
            .UnionDecl => |*u| {
                if (u.generic_params != null) return;
                try self.pushScope();
                for (u.fields) |field| {
                    try self.resolvePass2(field);
                }
                for (u.methods) |method| {
                    if (method.node_type == .FunDecl) {
                        const original_name = method.data.FunDecl.name;
                        method.data.FunDecl.name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{u.name, original_name});
                    }
                    try self.resolvePass2(method);
                }
                self.popScope();
            },
            .EnumDecl => |*e| {
                try self.pushScope();
                for (e.variants) |variant| {
                    try self.resolvePass2(variant);
                }
                self.popScope();
            },
            .EnumVariant => |*v| {
                if (v.value) |val| {
                    try self.resolvePass2(val);
                }
            },
            .FieldDecl => |*f| {
                if (f.default_value) |dv| {
                    try self.resolvePass2(dv);
                }
            },
            .UnsafeBlock => |*u| {
                try self.resolvePass2(u.body);
            },
            .BlockStmt => |*b| {
                try self.pushScope();
                for (b.statements) |stmt| {
                    try self.resolvePass2(stmt);
                }
                self.popScope();
            },
            .BreakStmt, .ContinueStmt, .PassStmt => {},
            .ParamBlockStmt => |*p| {
                // First pass: inject return variables into the current (parent) scope
                for (p.return_names) |name| {
                    if (self.current_scope.resolveLocal(name) != null) {
                        std.debug.print("Semantic Error: Redeclaration of return variable '{s}' in block\n", .{name});
                        return error.Redeclaration;
                    }
                    const sym = try self.allocator.create(symbols.Symbol);
                    sym.* = .{ .name = name, .kind = .Variable, .decl_node = node };
                    try self.current_scope.define(sym);
                }
                
                // Second pass: Create a new scope for the block's inner execution
                const block_scope = try symbols.Scope.create(self.allocator, self.current_scope);
                // We use closure_node here so that any captured variables from parent scope are marked 
                // in case we compile this block as an IIFE/Closure.
                block_scope.closure_node = node; 
                self.current_scope = block_scope;
                
                // Define parameters inside the inner block scope
                for (p.params) |param| {
                    if (param.node_type == .Identifier) {
                        const p_sym = try self.allocator.create(symbols.Symbol);
                        p_sym.* = .{ .name = param.data.Identifier.name, .kind = .Variable, .decl_node = param };
                        try self.current_scope.define(p_sym);
                        param.data.Identifier.resolved_symbol = p_sym;
                    }
                }
                
                try self.resolvePass2(p.body);
                self.current_scope = self.current_scope.parent.?;
            },
            .Identifier => |*id| {
                if (self.current_scope.resolve(id.name)) |resolved| {
                    id.resolved_symbol = resolved.sym;
                    
                    // Capture Analysis
                    if (resolved.sym.kind == .Variable and resolved.scope.parent != null) {
                        var s: ?*symbols.Scope = self.current_scope;
                        while (s != null and s != resolved.scope) : (s = s.?.parent) {
                            if (s.?.closure_node) |cl_node| {
                                var found = false;
                                var cl = &cl_node.data.ClosureExpr;
                                if (cl.captured_vars == null) {
                                    cl.captured_vars = &[_][]const u8{};
                                }
                                for (cl.captured_vars.?) |cv| {
                                    if (std.mem.eql(u8, cv, id.name)) found = true;
                                }
                                if (!found) {
                                    ast.debugPrint("CAPTURING {s} in closure!\n", .{id.name});
                                    var new_caps = std.ArrayList([]const u8).init(self.allocator);
                                    try new_caps.appendSlice(cl.captured_vars.?);
                                    try new_caps.append(id.name);
                                    cl.captured_vars = try new_caps.toOwnedSlice();
                                }
                            }
                        }
                    }
                } else {
                    std.debug.print("Semantic Error: Undefined identifier '{s}' at row {d}, col {d}\n", .{id.name, node.span.start_row, node.span.start_col});
                    ast.debugPrint("DEBUG: Scopes:\n", .{});
                    var s_ptr: ?*symbols.Scope = self.current_scope;
                    while (s_ptr) |s| {
                        ast.debugPrint("  Scope:\n", .{});
                        var it = s.symbols.iterator();
                        while (it.next()) |entry| {
                            ast.debugPrint("    '{s}'\n", .{entry.key_ptr.*});
                        }
                        s_ptr = s.parent;
                    }
                    return error.UndefinedVariable;
                }
            },
            .IfStmt => |*i| {
                try self.resolvePass2(i.condition);
                try self.resolvePass2(i.then_branch);
                if (i.else_branch) |eb| {
                    try self.resolvePass2(eb);
                }
            },
            .WithStmt => |*w| {
                try self.resolvePass2(w.expr);
                try self.pushScope();
                const name = w.var_name orelse try std.fmt.allocPrint(self.allocator, "_with_temp_{d}", .{node.span.start_byte});
                w.var_name = name;
                
                const sym = try self.allocator.create(symbols.Symbol);
                sym.* = .{ .name = name, .kind = .Variable, .decl_node = node, .is_context_manager = true };
                try self.current_scope.define(sym);
                w.resolved_symbol = sym;
                
                try self.resolvePass2(w.body);
                self.popScope();
            },
            .ForStmt => |*f| {
                try self.pushScope();
                // Iterator variable
                const sym = try self.allocator.create(symbols.Symbol);
                sym.* = .{ .name = f.iterator, .kind = .Variable, .decl_node = node };
                try self.current_scope.define(sym);
                
                try self.resolvePass2(f.iterable);
                try self.resolvePass2(f.body);
                self.popScope();
            },
            .WhileStmt => |*w| {
                try self.resolvePass2(w.condition);
                try self.resolvePass2(w.body);
            },
            .ReturnStmt => |*r| {
                if (r.values) |values| {
                    for (values) |v| {
                        try self.resolvePass2(v);
                    }
                }
            },
            .BinaryExpr => |*b| {
                try self.resolvePass2(b.left);
                try self.resolvePass2(b.right);
            },
            .UnaryExpr => |*u| {
                try self.resolvePass2(u.operand);
            },
            .CallExpr => |*c| {
                try self.resolvePass2(c.callee);
                for (c.arguments) |arg| {
                    try self.resolvePass2(arg);
                }
            },
            .KeywordArg => |*k| {
                try self.resolvePass2(k.value);
            },
            .MethodCallExpr => |*m| {
                try self.resolvePass2(m.receiver);
                for (m.arguments) |arg| {
                    try self.resolvePass2(arg);
                }
            },
            .MemberExpr => {
                try self.resolvePass2(node.data.MemberExpr.object);
            },
            .ImportDecl, .LinkDecl => {},
            .CastExpr => |*c| {
                try self.resolvePass2(c.operand);
            },
            .ClosureExpr => |*cl| {
                const closure_scope = try symbols.Scope.create(self.allocator, self.current_scope);
                closure_scope.closure_node = node;
                self.current_scope = closure_scope;
                for (cl.params) |param| {
                    if (param.node_type == .Identifier) {
                        const p_sym = try self.allocator.create(symbols.Symbol);
                        p_sym.* = .{ .name = param.data.Identifier.name, .kind = .Variable, .decl_node = param };
                        try self.current_scope.define(p_sym);
                        param.data.Identifier.resolved_symbol = p_sym;
                    }
                }
                try self.resolvePass2(cl.body);
                self.current_scope = self.current_scope.parent.?;
            },
            .ListLiteral => |*l| {
                for (l.elements) |element| {
                    try self.resolvePass2(element);
                }
            },
            .SpreadExpr => |*s| {
                try self.resolvePass2(s.iterable);
            },
            .SpawnStmt => |*s| {
                try self.resolvePass2(s.call_expr);
            },
            .AwaitExpr => |*a| {
                try self.resolvePass2(a.task_expr);
            },
            .MatchStmt => |*m| {
                try self.resolvePass2(m.subject);
                for (m.cases) |*case_node| {
                    const case_scope = try symbols.Scope.create(self.allocator, self.current_scope);
                    self.current_scope = case_scope;
                    
                    if (case_node.pattern.node_type == .Identifier) {
                        const name = case_node.pattern.data.Identifier.name;
                        if (!std.mem.eql(u8, name, "_")) {
                            const sym = try self.allocator.create(symbols.Symbol);
                            sym.* = .{ .name = name, .kind = .Variable, .decl_node = case_node.pattern };
                            try self.current_scope.define(sym);
                            case_node.pattern.data.Identifier.resolved_symbol = sym;
                        }
                    } else {
                        try self.resolvePass2(case_node.pattern);
                    }
                    
                    if (case_node.guard) |guard| {
                        try self.resolvePass2(guard);
                    }
                    try self.resolvePass2(case_node.body);
                    
                    self.current_scope = self.current_scope.parent.?;
                }
            },
            .TryStmt => |*ts| {
                try self.resolvePass2(ts.body);
                if (ts.catch_binding != null or ts.catch_body != null) {
                    try self.pushScope();
                    if (ts.catch_binding) |b| {
                        const sym = try self.allocator.create(symbols.Symbol);
                        sym.* = .{ .name = b, .kind = .Variable, .decl_node = node };
                        try self.current_scope.define(sym);
                    }
                    if (ts.catch_body) |cb| {
                        try self.resolvePass2(cb);
                    }
                    self.popScope();
                }
            },
            .ThrowStmt => |*th| {
                try self.resolvePass2(th.value);
            },
            .Program, .NumberLiteral, .StringLiteral, .BooleanLiteral, .MacroDecl, .MacroInvocation => {}, // Nothing to resolve
        }
    }
};
