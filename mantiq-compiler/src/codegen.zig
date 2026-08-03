//! LLVM IR code generator — emits human-readable `.ll` IR from the typed AST.
//!
//! The largest pass in the compiler. Walks the fully-analysed AST and produces
//! LLVM IR text into four output buffers (`out`, `outlined_out`, `type_out`,
//! `metadata_out`). The IR is then compiled by `zig cc` (AOT) or `dlopen`'d (JIT).
//!
//! Key responsibilities:
//! - `typeToLLVM` — maps `types.Type` to LLVM type strings (fat pointers for
//!   strings, `{ ptr, ptr }` for `Any`, `{ i8, ptr }` for `Option`, etc.)
//! - `genNode` — dispatch to per-variant codegen (5000+ lines)
//! - `genAutoDrops` — scope-exit cleanup for move-type variables
//! - `statement_temporaries` / `flushStatementTemps` — intermediate-result
//!   lifetime management (heap-allocated temporaries freed per statement)
//! - Parallel loops (`for@par`) — closure outlining + trampoline generation
//! - Script mode — implicit `main()` generation when no explicit `main` exists
//! - ABI coercion — `byval` / `coerce` / `direct` for function argument passing
//! - Global variable handling — JIT vs AOT global initialisation

const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");
const symbols = @import("symbols.zig");
const layout = @import("layout.zig");
const abi = @import("abi.zig");

pub const CodegenError = error{
    OutOfMemory,
    UnsupportedNode,
    InvalidType,
};

fn unescapeString(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const next = raw[i + 1];
            switch (next) {
                'n' => { try list.append('\n'); i += 2; },
                'r' => { try list.append('\r'); i += 2; },
                't' => { try list.append('\t'); i += 2; },
                '\\' => { try list.append('\\'); i += 2; },
                '"' => { try list.append('"'); i += 2; },
                '\'' => { try list.append('\''); i += 2; },
                else => { try list.append('\\'); i += 1; }
            }
        } else {
            try list.append(raw[i]);
            i += 1;
        }
    }
    return list.toOwnedSlice();
}

pub const LLVMCodegen = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(u8),
    outlined_out: std.ArrayList(u8),
    type_out: std.ArrayList(u8),
    metadata_out: std.ArrayList(u8),
    temp_counter: u32,
    closure_counter: u32,
    decl_counter: u32,
    metadata_counter: u32,
    string_counter: u32,
    is_global: bool = true,
    global_vars: *std.StringHashMap([]const u8),
    statement_temporaries: std.StringHashMap([]const u8),
    active_param_block: ?*ast.Node = null,
    active_block_exit: []const u8 = "",
    active_loop_cond: []const u8 = "",
    active_loop_exit: []const u8 = "",
    current_func_ret_llvm: []const u8 = "void",
    current_func_ret_ast: ?types.Type = null,
    local_allocas: std.StringHashMap(bool),
    scope_depth: u32 = 0,
    scope_var_stack: std.ArrayList(std.StringHashMap([]const u8)),
    var_name_map: std.StringHashMap([]const u8),
    defined_functions: std.StringHashMap(bool),
    defined_types: std.StringHashMap(bool),
    declared_types: std.StringHashMap(bool),
    external_decls: std.StringHashMap(bool),

    pub fn init(allocator: std.mem.Allocator, global_vars: *std.StringHashMap([]const u8)) LLVMCodegen {
        return .{
            .allocator = allocator,
            .out = std.ArrayList(u8).init(allocator),
            .outlined_out = std.ArrayList(u8).init(allocator),
            .type_out = std.ArrayList(u8).init(allocator),
            .metadata_out = std.ArrayList(u8).init(allocator),
            .temp_counter = 1,
            .closure_counter = 1,
            .decl_counter = 1,
            .metadata_counter = 1,
            .string_counter = 1,
            .global_vars = global_vars,
            .statement_temporaries = std.StringHashMap([]const u8).init(allocator),
            .current_func_ret_llvm = "void",
            .current_func_ret_ast = null,
            .local_allocas = std.StringHashMap(bool).init(allocator),
            .scope_var_stack = std.ArrayList(std.StringHashMap([]const u8)).init(allocator),
            .var_name_map = std.StringHashMap([]const u8).init(allocator),
            .defined_functions = std.StringHashMap(bool).init(allocator),
            .defined_types = std.StringHashMap(bool).init(allocator),
            .declared_types = std.StringHashMap(bool).init(allocator),
            .external_decls = std.StringHashMap(bool).init(allocator),
        };
    }

    fn registerTemp(self: *LLVMCodegen, expr_val: []const u8, heap_ptr: []const u8) !void {
        try self.statement_temporaries.put(expr_val, heap_ptr);
    }

    fn consumeTemp(self: *LLVMCodegen, expr_val: []const u8) void {
        _ = self.statement_temporaries.remove(expr_val);
    }

    fn flushStatementTemps(self: *LLVMCodegen) !void {
        var it = self.statement_temporaries.iterator();
        while (it.next()) |entry| {
            try self.out.writer().print("  call void @mantiq_free(ptr {s})\n", .{entry.value_ptr.*});
        }
        self.statement_temporaries.clearRetainingCapacity();
    }

    fn pushScope(self: *LLVMCodegen) !void {
        self.scope_depth += 1;
        try self.scope_var_stack.append(std.StringHashMap([]const u8).init(self.allocator));
    }

    fn popScope(self: *LLVMCodegen) void {
        if (self.scope_var_stack.popOrNull()) |scope_vars| {
            var it = scope_vars.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                const prev = entry.value_ptr.*;
                if (prev.len > 0) {
                    // Restore previous scoped name from outer scope
                    self.var_name_map.put(name, prev) catch {};
                } else {
                    // New variable, remove entirely
                    _ = self.var_name_map.remove(name);
                }
            }
        }
        if (self.scope_depth > 0) self.scope_depth -= 1;
    }

    fn getScopedName(self: *LLVMCodegen, name: []const u8) []const u8 {
        return self.var_name_map.get(name) orelse name;
    }

    fn registerVarName(self: *LLVMCodegen, name: []const u8) ![]const u8 {
        const counter = self.decl_counter;
        self.decl_counter += 1;
        const scoped_name = try std.fmt.allocPrint(self.allocator, "{s}_{d}_{d}", .{ name, self.scope_depth, counter });
        const prev = self.var_name_map.get(name) orelse "";
        try self.var_name_map.put(name, scoped_name);
        if (self.scope_var_stack.items.len > 0) {
            try self.scope_var_stack.items[self.scope_var_stack.items.len - 1].put(name, prev);
        }
        return scoped_name;
    }

    fn isBuiltinFunc(name: []const u8) bool {
        const builtins = [_][]const u8{
            // Compiler globals
            "make", "drop", "range", "print", "println", "Some", "Empty", "None", "Ok", "Err",
            // std.quantum
            "H", "measure", "CNOT", "qreg", "X", "Y", "Z",
            // std.collections
            "String", "List", "Dict",
            // std.mem
            "make", "drop", "resize",
            // std.io
            "write", "read",
            // std.fs
            "open", "write_file", "read_file", "exists", "remove",
            // std.process
            "args", "exit", "exec",
            // std.time
            "now", "sleep",
            // std.sys
            "os", "arch", "getenv", "setenv", "unsetenv",
        };
        for (builtins) |b| {
            if (std.mem.eql(u8, name, b)) return true;
        }
        return false;
    }

    fn nextTemp(self: *LLVMCodegen) u32 {
        const id = self.temp_counter;
        self.temp_counter += 1;
        return id;
    }

    /// Allocate a new temp and return its string representation (e.g. "%t.5").
    /// Consolidates the repeated nextTemp + allocPrint pattern.
    fn nextTempStr(self: *LLVMCodegen) []const u8 {
        const id = self.nextTemp();
        return std.fmt.allocPrint(self.allocator, "%t.{d}", .{id}) catch unreachable;
    }

    fn coerceType(self: *LLVMCodegen, val: []const u8, source_type: []const u8, target_type: []const u8) ![]const u8 {
        if (std.mem.eql(u8, source_type, target_type)) {
            return val;
        }

        const writer = self.out.writer();

        // 1. Box to Any ({ ptr, ptr })
        if (std.mem.eql(u8, target_type, "{ ptr, ptr }")) {
            const box_ptr = self.nextTemp();
            try writer.print("  %t.{d} = call ptr @mantiq_malloc(i64 32)\n", .{box_ptr});
            try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ source_type, val, box_ptr });
            const fat_temp1 = self.nextTemp();
            try writer.print("  %t.{d} = insertvalue {{ ptr, ptr }} undef, ptr %t.{d}, 0\n", .{ fat_temp1, box_ptr });
            const fat_temp2 = self.nextTemp();
            try writer.print("  %t.{d} = insertvalue {{ ptr, ptr }} %t.{d}, ptr null, 1\n", .{ fat_temp2, fat_temp1 });
            return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp2});
        }

        // 1b. Unbox from Any ({ ptr, ptr })
        if (std.mem.eql(u8, source_type, "{ ptr, ptr }")) {
            const box_ptr = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {{ ptr, ptr }} {s}, 0\n", .{ box_ptr, val });
            const unboxed_temp = self.nextTemp();
            try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ unboxed_temp, target_type, box_ptr });
            return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{unboxed_temp});
        }

        // 2. Convert 3-field string representation { ptr, i64, i64 } (or %struct.String) to 2-field string representation { ptr, i64 }
        if (std.mem.eql(u8, target_type, "{ ptr, i64 }") and
            (std.mem.eql(u8, source_type, "{ ptr, i64, i64 }") or (std.mem.startsWith(u8, source_type, "%") and std.mem.endsWith(u8, source_type, "String")))) {
            const ptr_ext = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ ptr_ext, source_type, val });
            const len_ext = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ len_ext, source_type, val });
            
            const fat1 = self.nextTemp();
            try writer.print("  %t.{d} = insertvalue {{ ptr, i64 }} undef, ptr %t.{d}, 0\n", .{ fat1, ptr_ext });
            const fat2 = self.nextTemp();
            try writer.print("  %t.{d} = insertvalue {{ ptr, i64 }} %t.{d}, i64 %t.{d}, 1\n", .{ fat2, fat1, len_ext });
            return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat2});
        }

        // 3. Convert 2-field string representation { ptr, i64 } to 3-field string representation { ptr, i64, i64 } (or %struct.String)
        if (std.mem.eql(u8, source_type, "{ ptr, i64 }") and
            (std.mem.eql(u8, target_type, "{ ptr, i64, i64 }") or (std.mem.startsWith(u8, target_type, "%") and std.mem.endsWith(u8, target_type, "String")))) {
            const ptr_ext = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {{ ptr, i64 }} {s}, 0\n", .{ ptr_ext, val });
            const len_ext = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {{ ptr, i64 }} {s}, 1\n", .{ len_ext, val });
            
            const fat1 = self.nextTemp();
            try writer.print("  %t.{d} = insertvalue {s} undef, ptr %t.{d}, 0\n", .{ fat1, target_type, ptr_ext });
            const fat2 = self.nextTemp();
            try writer.print("  %t.{d} = insertvalue {s} %t.{d}, i64 %t.{d}, 1\n", .{ fat2, target_type, fat1, len_ext });
            const fat3 = self.nextTemp();
            try writer.print("  %t.{d} = insertvalue {s} %t.{d}, i64 %t.{d}, 2\n", .{ fat3, target_type, fat2, len_ext });
            return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat3});
        }

        // 3b. Convert string representation ({ ptr, i64 } or { ptr, i64, i64 } or %...String) to ptr (cstr)
        if ((std.mem.eql(u8, source_type, "{ ptr, i64 }") or std.mem.eql(u8, source_type, "{ ptr, i64, i64 }") or (std.mem.startsWith(u8, source_type, "%") and std.mem.endsWith(u8, source_type, "String"))) and std.mem.eql(u8, target_type, "ptr")) {
            const ptr_ext = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ ptr_ext, source_type, val });
            return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ptr_ext});
        }

        // 4. Integer to Integer sizing (zext / trunc)
        if (std.mem.startsWith(u8, source_type, "i") and std.mem.startsWith(u8, target_type, "i")) {
            const arg_bits = std.fmt.parseInt(u32, source_type[1..], 10) catch 32;
            const field_bits = std.fmt.parseInt(u32, target_type[1..], 10) catch 32;
            if (arg_bits != field_bits) {
                const cast_temp = self.nextTemp();
                if (arg_bits < field_bits) {
                    try writer.print("  %t.{d} = zext {s} {s} to {s}\n", .{ cast_temp, source_type, val, target_type });
                } else {
                    try writer.print("  %t.{d} = trunc {s} {s} to {s}\n", .{ cast_temp, source_type, val, target_type });
                }
                return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{cast_temp});
            }
        }

        // 5. ptr to Integer
        if (std.mem.eql(u8, source_type, "ptr") and std.mem.startsWith(u8, target_type, "i")) {
            const cast_temp = self.nextTemp();
            try writer.print("  %t.{d} = ptrtoint ptr {s} to {s}\n", .{ cast_temp, val, target_type });
            return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{cast_temp});
        }

        // 6. Integer to ptr
        if (std.mem.startsWith(u8, source_type, "i") and std.mem.eql(u8, target_type, "ptr")) {
            const cast_temp = self.nextTemp();
            try writer.print("  %t.{d} = inttoptr {s} {s} to ptr\n", .{ cast_temp, source_type, val });
            return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{cast_temp});
        }

        // 7. Dynamic list { ptr, i64, i64 } to static array [N x T]
        if (std.mem.eql(u8, source_type, "{ ptr, i64, i64 }") and std.mem.startsWith(u8, target_type, "[")) {
            const x_pos = std.mem.indexOf(u8, target_type, " x ") orelse return val;
            const close_bracket = std.mem.indexOfScalar(u8, target_type, ']') orelse return val;
            const num_str = target_type[1..x_pos];
            const elem_t = target_type[x_pos + 3 .. close_bracket];
            const n = std.fmt.parseInt(usize, num_str, 10) catch return val;

            const ptr_temp = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 0\n", .{ ptr_temp, val });

            var result = try std.fmt.allocPrint(self.allocator, "undef", .{});
            for (0..n) |j| {
                const gep_temp = self.nextTemp();
                try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr %t.{d}, i64 {d}\n", .{ gep_temp, elem_t, ptr_temp, j });
                const load_temp = self.nextTemp();
                try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ load_temp, elem_t, gep_temp });
                const ins_temp = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {s} {s}, {s} %t.{d}, {d}\n", .{ ins_temp, target_type, result, elem_t, load_temp, j });
                result = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ins_temp});
            }
            return result;
        }

        return val;
    }

    fn isTypeOrModuleNode(self: *LLVMCodegen, node: *const ast.Node) bool {
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

    pub fn generate(self: *LLVMCodegen, root: *ast.Node) ![]const u8 {
        self.defined_functions.clearRetainingCapacity();
        self.defined_types.clearRetainingCapacity();
        self.declared_types.clearRetainingCapacity();
        self.external_decls.clearRetainingCapacity();

        try self.collectDefinedFunctions(root);
        try self.collectDefinedTypes(root);
        try self.collectReferencedTypes(root);

        var preamble = std.ArrayList(u8).init(self.allocator);
        try preamble.writer().print("; ModuleID = 'MantiqModule'\n", .{});
        try preamble.writer().print("source_filename = \"main.mq\"\n", .{});
        try preamble.writer().print("target datalayout = \"{s}\"\n", .{layout.Target.x86_64_linux.data_layout});
        try preamble.writer().print("target triple = \"{s}\"\n\n", .{layout.Target.x86_64_linux.triple});

        try preamble.writer().print("declare void @quantum_measure(i32)\n", .{});
        try preamble.writer().print("declare i32 @quantum_H(i32)\n", .{});
        try preamble.writer().print("declare void @quantum_CNOT(i32, i32)\n", .{});
        try preamble.writer().print("declare {{ ptr, i32 }} @quantum_qreg(i32)\n", .{});
        try preamble.writer().print("%Closure = type {{ ptr, ptr }}\n", .{});
        try preamble.writer().print("declare void @__mantiq_parallel_for(i32, i32, ptr, ptr)\n", .{});
        try preamble.writer().print("declare ptr @mantiq_malloc(i64)\n", .{});
        try preamble.writer().print("declare void @mantiq_free(ptr)\n", .{});
        try preamble.writer().print("declare ptr @mantiq_realloc(ptr, i64)\n", .{});
        try preamble.writer().print("declare void @mantiq_panic(ptr)\n", .{});
        try preamble.writer().print("declare void @mantiq_panic_at(ptr, ptr, i32, i32)\n", .{});
        try preamble.writer().print("declare {{ ptr, ptr }} @make()\n", .{});
        try preamble.writer().print("declare void @mantiq_print_i32(i32)\n", .{});
        try preamble.writer().print("declare void @mantiq_print_bool(i32)\n", .{});
        try preamble.writer().print("declare void @mantiq_print_float(float)\n", .{});
        try preamble.writer().print("declare void @mantiq_print_ptr(ptr)\n", .{});
        try preamble.writer().print("declare void @mantiq_print_space()\n", .{});
        try preamble.writer().print("declare void @mantiq_print_newline()\n", .{});
        try preamble.writer().print("declare void @mantiq_print_dict_start()\n", .{});
        try preamble.writer().print("declare void @mantiq_print_dict_end()\n", .{});
        try preamble.writer().print("declare void @mantiq_print_list_start()\n", .{});
        try preamble.writer().print("declare void @mantiq_print_list_end()\n", .{});
        try preamble.writer().print("declare void @mantiq_print_colon()\n", .{});
        try preamble.writer().print("declare void @mantiq_print_comma()\n", .{});
        try preamble.writer().print("declare void @mantiq_flush_stdout()\n", .{});
        try preamble.writer().print("declare void @mantiq_print_str(ptr, i64)\n", .{});
        try preamble.writer().print("declare void @mantiq_print_cstr(ptr)\n", .{});
        try preamble.writer().print("declare void @mantiq_write(i32, ptr, i64)\n", .{});
        try preamble.writer().print("declare ptr @mantiq_read(i32, i64, ptr)\n", .{});
        try preamble.writer().print("declare i32 @mantiq_fs_open(ptr, i64, ptr, i64)\n", .{});
        try preamble.writer().print("declare void @mantiq_fs_close(i32)\n", .{});
        try preamble.writer().print("declare i8 @mantiq_fs_exists(ptr, i64)\n", .{});
        try preamble.writer().print("declare void @mantiq_init(i32, ptr)\n", .{});
        try preamble.writer().print("declare void @mantiq_process_exit(i32)\n", .{});
        try preamble.writer().print("declare ptr @mantiq_process_args()\n", .{});
        try preamble.writer().print("declare i64 @mantiq_time_now()\n", .{});
        try preamble.writer().print("declare void @mantiq_time_sleep(i32)\n", .{});
        try preamble.writer().print("declare ptr @mantiq_sys_os()\n", .{});
        try preamble.writer().print("declare ptr @mantiq_sys_arch()\n", .{});
        try preamble.writer().print("declare ptr @mantiq_sys_getenv(ptr, i64)\n", .{});
        try preamble.writer().print("declare void @mantiq_sys_setenv(ptr, i64, ptr, i64)\n", .{});
        try preamble.writer().print("declare void @mantiq_sys_unsetenv(ptr, i64)\n", .{});
        try preamble.writer().print("declare i32 @__mantiq_streq(ptr, i64, ptr, i64)\n", .{});
        try preamble.writer().print("%MantiqDict = type {{ ptr, ptr, ptr, ptr, i32, i32, i32, i32 }}\n", .{});
        try preamble.writer().print("declare i32 @__mantiq_hash_string(ptr, i64)\n", .{});
        try preamble.writer().print("declare i32 @__mantiq_hash_bytes(ptr, i64)\n", .{});
        try preamble.writer().print("declare ptr @__mantiq_dict_create(i32, i32, i32)\n", .{});
        try preamble.writer().print("declare void @__mantiq_dict_set(ptr, ptr, ptr, i32)\n", .{});
        try preamble.writer().print("declare void @__mantiq_dict_keys(ptr, ptr, i32)\n", .{});
        try preamble.writer().print("declare ptr @__mantiq_dict_get(ptr, ptr, i32)\n", .{});
        try preamble.writer().print("declare i8 @__mantiq_dict_remove(ptr, ptr, i32)\n", .{});
        try preamble.writer().print("declare ptr @__mantiq_dict_get_or_insert(ptr, ptr, i32)\n", .{});
        try preamble.writer().print("declare void @__mantiq_list_append(ptr, ptr, i64)\n", .{});
        try preamble.writer().print("declare void @__mantiq_dict_clear(ptr)\n", .{});
        try preamble.writer().print("declare ptr @mantiq_concat_str(ptr, i64, ptr, i64)\n", .{});
        try preamble.writer().print("declare ptr @mantiq_i32_to_str(i32, ptr)\n", .{});
        try preamble.writer().print("declare ptr @mantiq_float_to_str(float, ptr)\n", .{});
        try preamble.writer().print("declare ptr @mantiq_bool_to_str(i32, ptr)\n", .{});
        try preamble.writer().print("declare ptr @mantiq_spawn(ptr, ptr)\n", .{});
        try preamble.writer().print("declare ptr @mantiq_await(ptr)\n", .{});
        try preamble.writer().print("declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)\n\n", .{});

        // Define global panic message strings
        try self.type_out.writer().print("@.panic_str_bounds = private unnamed_addr constant [20 x i8] c\"Index out of bounds\\00\"\n", .{});
        try self.type_out.writer().print("@.panic_str_div_zero = private unnamed_addr constant [17 x i8] c\"Division by zero\\00\"\n", .{});
        try self.type_out.writer().print("@.str_file = private unnamed_addr constant [8 x i8] c\"main.mq\\00\"\n", .{});

        try self.genNode(root);

        var final_out = std.ArrayList(u8).init(self.allocator);
        try final_out.appendSlice(preamble.items);
        try final_out.appendSlice(self.type_out.items);
        try final_out.appendSlice(self.out.items);
        try final_out.appendSlice(self.outlined_out.items);
        try final_out.appendSlice(self.metadata_out.items);

        return final_out.toOwnedSlice();
    }

    fn collectDefinedFunctions(self: *LLVMCodegen, root: *ast.Node) !void {
        if (root.node_type != .Program) return;
        for (root.data.Program.declarations) |decl| {
            try self.collectFunctionsFromDecl(decl);
        }
    }

    fn collectFunctionsFromDecl(self: *LLVMCodegen, decl: *ast.Node) !void {
        switch (decl.node_type) {
            .FunDecl => {
                const f = &decl.data.FunDecl;
                if (f.generic_params != null) return;
                var func_symbol_name = f.name;
                if (!f.is_extern) {
                    if (decl.module_name) |mod_name| {
                        func_symbol_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, f.name });
                    }
                }
                try self.defined_functions.put(func_symbol_name, true);
            },
            .StructDecl => {
                for (decl.data.StructDecl.methods) |method| {
                    try self.collectFunctionsFromDecl(method);
                }
            },
            .UnionDecl => {
                for (decl.data.UnionDecl.methods) |method| {
                    try self.collectFunctionsFromDecl(method);
                }
            },
            .ClassDecl => {
                for (decl.data.ClassDecl.methods) |method| {
                    try self.collectFunctionsFromDecl(method);
                }
            },
            else => {},
        }
    }

    fn collectDefinedTypes(self: *LLVMCodegen, root: *ast.Node) !void {
        if (root.node_type != .Program) return;
        for (root.data.Program.declarations) |decl| {
            switch (decl.node_type) {
                .StructDecl => {
                    const s = &decl.data.StructDecl;
                    if (s.generic_params == null and decl.inferred_type != null) {
                        if (decl.inferred_type.?.struct_type) |st| {
                            try self.defined_types.put(st.name, true);
                        }
                    }
                },
                .UnionDecl => {
                    const u = &decl.data.UnionDecl;
                    if (u.generic_params == null and decl.inferred_type != null) {
                        if (decl.inferred_type.?.union_type) |ut| {
                            try self.defined_types.put(ut.name, true);
                        }
                    }
                },
                .EnumDecl => {
                    if (decl.inferred_type != null) {
                        if (decl.inferred_type.?.enum_type) |et| {
                            try self.defined_types.put(et.name, true);
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn collectReferencedTypes(self: *LLVMCodegen, node: *ast.Node) !void {
        if (node.inferred_type) |t| {
            try self.declareTypeIfExternal(t);
        }
        switch (node.data) {
            .Program => |*p| {
                for (p.declarations) |decl| {
                    try self.collectReferencedTypes(decl);
                }
            },
            .FunDecl => |*f| {
                for (f.params) |param| {
                    try self.collectReferencedTypes(param);
                }
                try self.collectReferencedTypes(f.body);
            },
            .BlockStmt => |*b| {
                for (b.statements) |stmt| {
                    try self.collectReferencedTypes(stmt);
                }
            },
            .ParamBlockStmt => |*pb| {
                for (pb.params) |param| {
                    try self.collectReferencedTypes(param);
                }
                try self.collectReferencedTypes(pb.body);
            },
            .VarDecl => |*v| {
                if (v.initializers) |inits| {
                    for (inits) |init_expr| {
                        try self.collectReferencedTypes(init_expr);
                    }
                }
            },
            .IfStmt => |*i| {
                try self.collectReferencedTypes(i.condition);
                try self.collectReferencedTypes(i.then_branch);
                if (i.else_branch) |eb| {
                    try self.collectReferencedTypes(eb);
                }
            },
            .WhileStmt => |*w| {
                try self.collectReferencedTypes(w.condition);
                try self.collectReferencedTypes(w.body);
            },
            .ForStmt => |*f| {
                try self.collectReferencedTypes(f.iterable);
                try self.collectReferencedTypes(f.body);
            },
            .ReturnStmt => |*r| {
                if (r.values) |vals| {
                    for (vals) |val| {
                        try self.collectReferencedTypes(val);
                    }
                }
            },
            .SpawnStmt => |*s| {
                try self.collectReferencedTypes(s.call_expr);
            },
            .TryStmt => |*t_stmt| {
                try self.collectReferencedTypes(t_stmt.body);
                if (t_stmt.catch_body) |cb| {
                    try self.collectReferencedTypes(cb);
                }
            },
            .ThrowStmt => |*t_stmt| {
                try self.collectReferencedTypes(t_stmt.value);
            },
            .BinaryExpr => |*b| {
                try self.collectReferencedTypes(b.left);
                try self.collectReferencedTypes(b.right);
            },
            .UnaryExpr => |*u| {
                try self.collectReferencedTypes(u.operand);
            },
            .CastExpr => |*c| {
                try self.collectReferencedTypes(c.operand);
            },
            .CallExpr => |*c| {
                try self.collectReferencedTypes(c.callee);
                for (c.arguments) |arg| {
                    try self.collectReferencedTypes(arg);
                }
            },
            .MethodCallExpr => |*m| {
                try self.collectReferencedTypes(m.receiver);
                for (m.arguments) |arg| {
                    try self.collectReferencedTypes(arg);
                }
            },
            .MemberExpr => |*m| {
                try self.collectReferencedTypes(m.object);
            },
            .IndexExpr => |*i| {
                try self.collectReferencedTypes(i.object);
                try self.collectReferencedTypes(i.index);
            },
            .AwaitExpr => |*a| {
                try self.collectReferencedTypes(a.task_expr);
            },
            .MatchStmt => |*m| {
                try self.collectReferencedTypes(m.subject);
                for (m.cases) |c_case| {
                    try self.collectReferencedTypes(c_case.pattern);
                    if (c_case.guard) |guard| {
                        try self.collectReferencedTypes(guard);
                    }
                    try self.collectReferencedTypes(c_case.body);
                }
            },
            .WithStmt => |*w| {
                try self.collectReferencedTypes(w.expr);
                try self.collectReferencedTypes(w.body);
            },
            .UnsafeBlock => |*u| {
                try self.collectReferencedTypes(u.body);
            },
            .StructDecl => |*s| {
                for (s.methods) |method| {
                    try self.collectReferencedTypes(method);
                }
            },
            .UnionDecl => |*u| {
                for (u.methods) |method| {
                    try self.collectReferencedTypes(method);
                }
            },
            .ClassDecl => |*c| {
                for (c.methods) |method| {
                    try self.collectReferencedTypes(method);
                }
            },
            else => {},
        }
    }

    fn declareTypeIfExternal(self: *LLVMCodegen, t: types.Type) !void {
        switch (t.kind) {
            .Struct => {
                if (t.struct_type) |st| {
                    if (self.defined_types.contains(st.name) or self.declared_types.contains(st.name)) return;
                    try self.declared_types.put(st.name, true);
                    for (st.fields) |sf| {
                        try self.declareTypeIfExternal(sf.type_kind);
                    }
                    var fields_str = std.ArrayList(u8).init(self.allocator);
                    defer fields_str.deinit();
                    for (st.fields, 0..) |sf, i| {
                        if (i > 0) try fields_str.appendSlice(", ");
                        try fields_str.appendSlice(typeToLLVM(self.allocator, sf.type_kind));
                    }
                    try self.type_out.writer().print("%{s} = type {{ {s} }}\n\n", .{ st.name, fields_str.items });
                }
            },
            .Union => {
                if (t.union_type) |ut| {
                    if (self.defined_types.contains(ut.name) or self.declared_types.contains(ut.name)) return;
                    try self.declared_types.put(ut.name, true);
                    if (ut.tag_type) |tag_t| {
                        try self.declareTypeIfExternal(tag_t);
                    }
                    for (ut.fields) |f| {
                        try self.declareTypeIfExternal(f.type_kind);
                    }
                    if (ut.tag_type) |tag_t| {
                        var max_size: usize = 0;
                        for (ut.fields) |f| {
                            const field_size = types.getTypeSize(f.type_kind);
                            if (field_size > max_size) max_size = field_size;
                        }
                        var max_align: usize = 1;
                        for (ut.fields) |f| {
                            const field_align = types.getTypeAlignment(f.type_kind);
                            if (field_align > max_align) max_align = field_align;
                        }
                        const padding = (max_align - (max_size % max_align)) % max_align;
                        const payload_size = max_size + padding;
                        const tag_t_llvm = typeToLLVM(self.allocator, tag_t);
                        try self.type_out.writer().print("%{s} = type {{ {s}, [{d} x i8] }}\n\n", .{ ut.name, tag_t_llvm, payload_size });
                    } else {
                        const size = types.getTypeSize(t);
                        try self.type_out.writer().print("%{s} = type {{ [{d} x i8] }}\n\n", .{ ut.name, size });
                    }
                }
            },
            .Enum => {
                if (t.enum_type) |et| {
                    if (self.defined_types.contains(et.name) or self.declared_types.contains(et.name)) return;
                    try self.declared_types.put(et.name, true);
                    try self.type_out.writer().print("%{s} = type {{ i32, [4 x i64] }}\n\n", .{et.name});
                }
            },
            .Tuple => {
                if (t.tuple_types) |ttypes| {
                    for (ttypes) |tt| {
                        try self.declareTypeIfExternal(tt);
                    }
                }
            },
            .List => {
                if (t.payload) |p| {
                    try self.declareTypeIfExternal(p.*);
                }
            },
            .Task => {
                if (t.payload) |p| {
                    try self.declareTypeIfExternal(p.*);
                }
            },
            else => {},
        }
    }

    fn getCalleeDeclNode(self: *LLVMCodegen, callee: *ast.Node, is_module_call: bool) ?*ast.Node {
        _ = self;
        if (is_module_call) {
            if (callee.node_type == .MemberExpr) {
                const me = &callee.data.MemberExpr;
                if (me.object.inferred_type) |me_obj_type| {
                    if (me_obj_type.module_scope) |scope_ptr| {
                        const mod_scope = @as(*symbols.Scope, @ptrCast(@alignCast(scope_ptr)));
                        if (mod_scope.resolveLocal(me.property)) |sym| {
                            if (sym.kind == .Function and sym.decl_node != null) {
                                return sym.decl_node.?;
                            }
                        }
                    }
                }
            }
        } else if (callee.node_type == .Identifier) {
            if (callee.data.Identifier.resolved_symbol) |sym| {
                if (sym.kind == .Function and sym.decl_node != null) {
                    return sym.decl_node.?;
                }
            }
        }
        return null;
    }

    fn declareExternalFunctionFromType(self: *LLVMCodegen, func_name: []const u8, func_type: types.Type) !void {
        if (self.external_decls.contains(func_name)) return;
        try self.external_decls.put(func_name, true);

        const func = func_type.function orelse return;

        // Declare any referenced types in the signature
        for (func.param_types) |t| {
            try self.declareTypeIfExternal(t);
        }
        var ext_ret_type: types.Type = func.return_type.*;
        if (ext_ret_type.kind == .Function and ext_ret_type.function != null) {
            ext_ret_type = ext_ret_type.function.?.return_type.*;
        }
        if (ext_ret_type.kind == .Task and ext_ret_type.payload != null) {
            ext_ret_type = ext_ret_type.payload.?.*;
        }
        try self.declareTypeIfExternal(ext_ret_type);

        var param_str = std.ArrayList(u8).init(self.allocator);
        defer param_str.deinit();
        try param_str.appendSlice("ptr");
        for (func.param_types) |inferred| {
            try param_str.appendSlice(", ");
            const t = typeToLLVM(self.allocator, inferred);
            const sig = abi.getArgABI(inferred, layout.Target.x86_64_linux);
            if (sig.mode == .ByVal) {
                try std.fmt.format(param_str.writer(), "ptr byval({s})", .{ t });
            } else if (sig.mode == .Coerce) {
                try std.fmt.format(param_str.writer(), "{s}", .{ sig.llvm_type });
            } else {
                try std.fmt.format(param_str.writer(), "{s}", .{ t });
            }
        }
        var actual_ret_type: types.Type = func.return_type.*;
        if (actual_ret_type.kind == .Function and actual_ret_type.function != null) {
            actual_ret_type = actual_ret_type.function.?.return_type.*;
        }
        if (actual_ret_type.kind == .Task and actual_ret_type.payload != null) {
            actual_ret_type = actual_ret_type.payload.?.*;
        }
        const ret_t = typeToLLVM(self.allocator, actual_ret_type);
        const ret_sig = abi.getRetABI(actual_ret_type, layout.Target.x86_64_linux);
        const final_ret_t = if (ret_sig.mode == .Coerce) ret_sig.llvm_type else ret_t;

        try self.type_out.writer().print("declare {s} @{s}({s})\n", .{ final_ret_t, func_name, param_str.items });
    }

    fn declareExternalFunction(self: *LLVMCodegen, func_name: []const u8, decl_node: *ast.Node) !void {
        if (self.external_decls.contains(func_name)) return;
        try self.external_decls.put(func_name, true);

        const f = &decl_node.data.FunDecl;
        
        // Declare any referenced types in the signature of the external function
        for (f.params) |param| {
            if (param.inferred_type) |t| {
                try self.declareTypeIfExternal(t);
            }
        }
        var ext_ret_type: types.Type = decl_node.inferred_type orelse .{ .kind = .Void };
        if (ext_ret_type.kind == .Function and ext_ret_type.function != null) {
            ext_ret_type = ext_ret_type.function.?.return_type.*;
        }
        if (ext_ret_type.kind == .Task and ext_ret_type.payload != null) {
            ext_ret_type = ext_ret_type.payload.?.*;
        }
        try self.declareTypeIfExternal(ext_ret_type);

        var param_str = std.ArrayList(u8).init(self.allocator);
        defer param_str.deinit();
        if (!f.is_extern) {
            try param_str.appendSlice("ptr");
        }
        for (f.params, 0..) |param, i| {
            if (i > 0 or !f.is_extern) try param_str.appendSlice(", ");
            const inferred: types.Type = param.inferred_type orelse .{ .kind = .Any };
            const t = typeToLLVM(self.allocator, inferred);
            const sig = abi.getArgABI(inferred, layout.Target.x86_64_linux);
            if (sig.mode == .ByVal) {
                try std.fmt.format(param_str.writer(), "ptr byval({s})", .{ t });
            } else if (sig.mode == .Coerce) {
                try std.fmt.format(param_str.writer(), "{s}", .{ sig.llvm_type });
            } else {
                try std.fmt.format(param_str.writer(), "{s}", .{ t });
            }
        }
        var actual_ret_type: types.Type = decl_node.inferred_type orelse .{ .kind = .Void };
        if (actual_ret_type.kind == .Function and actual_ret_type.function != null) {
            actual_ret_type = actual_ret_type.function.?.return_type.*;
        }
        if (actual_ret_type.kind == .Task and actual_ret_type.payload != null) {
            actual_ret_type = actual_ret_type.payload.?.*;
        }
        const ret_t = typeToLLVM(self.allocator, actual_ret_type);
        const ret_sig = abi.getRetABI(actual_ret_type, layout.Target.x86_64_linux);
        const final_ret_t = if (ret_sig.mode == .Coerce) ret_sig.llvm_type else ret_t;

        try self.type_out.writer().print("declare {s} @{s}({s})\n", .{ final_ret_t, func_name, param_str.items });
    }


    fn isStringLikeType(t: types.Type) bool {
        if (t.kind == .String or t.kind == .AsciiStr or t.kind == .Utf8Str or t.kind == .WebStr or t.kind == .RangeStr) {
            return true;
        }
        if (t.kind == .Struct and t.struct_type != null) {
            return std.mem.endsWith(u8, t.struct_type.?.name, "String");
        }
        return false;
    }

    fn getDictStringKeyFlag(t: types.Type) u32 {
        if (t.kind == .AsciiStr or t.kind == .Utf8Str or t.kind == .WebStr or t.kind == .RangeStr) {
            return 1;
        }
        if (t.kind == .String) {
            return 2;
        }
        if (t.kind == .Struct and t.struct_type != null and std.mem.endsWith(u8, t.struct_type.?.name, "String")) {
            return 2;
        }
        return 0;
    }

    fn typeToLLVM(allocator: std.mem.Allocator, kind: types.Type) []const u8 {
        return switch (kind.kind) {
            .Void => "void",
            .I8, .U8, .Char, .Boolean => "i8",
            .I16, .U16 => "i16",
            .I32, .U32 => "i32",
            .I64, .U64, .ISize, .USize => "i64", // Assume 64-bit pointer/size
            .I128, .U128 => "i128",
            .F16 => "half",
            .BFloat16 => "bfloat", // LLVM native support for ML type
            .F32 => "float",
            .F64 => "double",
            .F128 => "fp128",
            // Fat Pointers for Mantiq Superset
            .String => "{ ptr, i64, i64 }",
            .CStr => "ptr",
            .AsciiStr, .Utf8Str, .WebStr, .RangeStr => "{ ptr, i64 }",
            .List => {
                if (kind.array_len) |len| {
                    if (kind.payload) |p| {
                        const inner_t = typeToLLVM(allocator, p.*);
                        return std.fmt.allocPrint(allocator, "[{d} x {s}]", .{ len, inner_t }) catch unreachable;
                    }
                }
                return "{ ptr, i64, i64 }";
            },
            .Dict => "{ ptr, i64, i64 }",
            .Any => "{ ptr, ptr }",
            .Option => "{ i8, ptr }",
            .Result => "{ i8, ptr, ptr }",
            .QBit => "i32",
            .QReg => "{ ptr, i32 }",
            .Function => "{ ptr, ptr }",
            .RawPointer => "ptr",
            .Slice, .Class, .Interface, .Task => "ptr",
            .Closure => "{ ptr, ptr }",
            .Tuple => {
                var buf = std.ArrayList(u8).init(allocator);
                buf.appendSlice("{ ") catch unreachable;
                if (kind.tuple_types) |ttypes| {
                    for (ttypes, 0..) |tt, i| {
                        if (i > 0) buf.appendSlice(", ") catch unreachable;
                        buf.appendSlice(typeToLLVM(allocator, tt)) catch unreachable;
                    }
                }
                buf.appendSlice(" }") catch unreachable;
                return buf.toOwnedSlice() catch unreachable;
            },
            .Struct => {
                if (kind.struct_type) |st| {
                    var buf = std.ArrayList(u8).init(allocator);
                    buf.append('%') catch unreachable;
                    buf.appendSlice(st.name) catch unreachable;
                    return buf.toOwnedSlice() catch unreachable;
                }
                return "ptr";
            },
            .Enum => {
                if (kind.enum_type) |et| {
                    var buf = std.ArrayList(u8).init(allocator);
                    buf.append('%') catch unreachable;
                    buf.appendSlice(et.name) catch unreachable;
                    return buf.toOwnedSlice() catch unreachable;
                }
                return "i32";
            },
            .Union => {
                if (kind.union_type) |ut| {
                    var buf = std.ArrayList(u8).init(allocator);
                    buf.append('%') catch unreachable;
                    buf.appendSlice(ut.name) catch unreachable;
                    return buf.toOwnedSlice() catch unreachable;
                }
                return "ptr";
            },
            else => "i32", // Fallback
        };
    }

    fn annotToLLVM(name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8") or std.mem.eql(u8, name, "bool")) return "i8";
        if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16")) return "i16";
        if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32")) return "i32";
        if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return "i64";
        if (std.mem.eql(u8, name, "u128") or std.mem.eql(u8, name, "i128")) return "i128";
        if (std.mem.eql(u8, name, "f16")) return "half";
        if (std.mem.eql(u8, name, "bf16")) return "bfloat";
        if (std.mem.eql(u8, name, "f32")) return "float";
        if (std.mem.eql(u8, name, "f64")) return "double";
        if (std.mem.eql(u8, name, "f128")) return "fp128";
        return "i32"; // Fallback
    }

    fn varTypeAtIndex(allocator: std.mem.Allocator, v: anytype, i: usize, fallback_type: types.Type) []const u8 {
        if (i < v.type_annots.len) {
            if (v.type_annots[i]) |annot| {
                const llvm_t = annotToLLVM(annot.name);
                // annotToLLVM returns "i32" as fallback for unknown type names
                // If this annotation name is actually a known primitive, trust it
                if (isKnownPrimitive(annot.name)) {
                    return llvm_t;
                }
                // For named/complex types, use the type checker's inferred type
            }
        }
        return typeToLLVM(allocator, fallback_type);
    }

    fn isKnownPrimitive(name: []const u8) bool {
        return std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8") or std.mem.eql(u8, name, "bool") or
               std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16") or
               std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32") or
               std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64") or
               std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize") or
               std.mem.eql(u8, name, "u128") or std.mem.eql(u8, name, "i128") or
               std.mem.eql(u8, name, "f16") or std.mem.eql(u8, name, "bf16") or
               std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64") or
               std.mem.eql(u8, name, "f128");
    }

    fn genAutoDrops(self: *LLVMCodegen, drops: []const *symbols.Symbol) CodegenError!void {
        const writer = self.out.writer();
        for (drops) |sym| {
            if (sym.decl_node) |decl| {
                if (decl.inferred_type) |t| {
                    const llvm_t = typeToLLVM(self.allocator, t);
                    if (self.is_global) continue; // Globals are not auto-dropped this way
                    if (std.mem.startsWith(u8, sym.name, "t.")) continue;
                    
                    const local_ref = self.var_name_map.get(sym.name) orelse continue;
                    if (std.mem.startsWith(u8, local_ref, "t.")) continue;
                    if (!self.local_allocas.contains(local_ref)) continue;
                    const load_temp = self.nextTemp();
                    try writer.print("  %t.{d} = load {s}, ptr %{s}\n", .{ load_temp, llvm_t, local_ref });
                    
                    if (sym.is_context_manager) {
                        if (t.kind == .I32) {
                            try writer.print("  call void @mantiq_fs_close(i32 %t.{d})\n", .{load_temp});
                        } else if (t.kind == .Struct and t.struct_type != null) {
                            const st = t.struct_type.?;
                            var has_exit = false;
                            for (st.methods) |method| {
                                if (std.mem.eql(u8, method.name, "__exit__")) {
                                    has_exit = true;
                                    break;
                                }
                            }
                            if (has_exit) {
                                try writer.print("  call void @{s}___exit__(ptr %t.{d})\n", .{st.name, load_temp});
                            }
                        }
                        continue;
                    }
                    
                    var heap_ptr: []const u8 = "null";
                    if (std.mem.eql(u8, llvm_t, "ptr")) {
                        heap_ptr = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{load_temp});
                    } else if (std.mem.startsWith(u8, llvm_t, "{ ptr")) {
                        const ext_temp = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} %t.{d}, 0\n", .{ ext_temp, llvm_t, load_temp });
                        heap_ptr = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ext_temp});
                    } else if (std.mem.startsWith(u8, llvm_t, "{ i8, ptr")) {
                        const ext_temp = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} %t.{d}, 1\n", .{ ext_temp, llvm_t, load_temp });
                        heap_ptr = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ext_temp});
                    } else {
                        continue;
                    }
                    
                    const cmp_temp = self.nextTemp();
                    try writer.print("  %t.{d} = icmp ne ptr {s}, null\n", .{ cmp_temp, heap_ptr });
                    
                    const drop_block = try std.fmt.allocPrint(self.allocator, "drop.do.{d}", .{cmp_temp});
                    const cont_block = try std.fmt.allocPrint(self.allocator, "drop.cont.{d}", .{cmp_temp});
                    
                    try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cmp_temp, drop_block, cont_block });
                    try writer.print("{s}:\n", .{drop_block});
                    try writer.print("  call void @mantiq_free(ptr {s})\n", .{heap_ptr});
                    try writer.print("  br label %{s}\n", .{cont_block});
                    try writer.print("{s}:\n", .{cont_block});
                }
            }
        }
    }

    fn genNode(self: *LLVMCodegen, node: *ast.Node) CodegenError!void {
        const writer = self.out.writer();
        if (node.node_type != .Program) {
            try writer.print("  ; Span: [row: {d}, col: {d}] - Node: {s}\n", .{ node.span.start_row + 1, node.span.start_col + 1, @tagName(node.node_type) });
        }
        switch (node.data) {
            .Program => |*p| {
                var has_main = false;
                for (p.declarations) |decl| {
                    if (decl.node_type == .FunDecl and std.mem.eql(u8, decl.data.FunDecl.name, "main")) {
                        has_main = true;
                        break;
                    }
                }

                if (!has_main) {
                    // Declare previous globals as external
                    var it = self.global_vars.iterator();
                    while (it.next()) |entry| {
                        try writer.print("@{s} = external global {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                    }

                    // Declare global variables first
                    self.is_global = true;
                    for (p.declarations) |decl| {
                        if (decl.node_type == .VarDecl) {
                            const gv = &decl.data.VarDecl;
                            const gfallback: types.Type = decl.inferred_type orelse .{ .kind = .Any };
                            for (gv.names, 0..) |name, idx| {
                                const t = varTypeAtIndex(self.allocator, gv, idx, gfallback);
                                // Allocate a permanent copy of the type string for the hashmap
                                const type_str = try self.allocator.dupe(u8, t);
                                var global_name = name;
                                if (decl.module_name) |mod_name| {
                                    global_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, name });
                                }
                                try self.global_vars.put(global_name, type_str);
                                const linkage = if (gv.is_static) "internal " else "";
                                try writer.print("@{s} = {s}global {s} zeroinitializer\n", .{ global_name, linkage, t });
                            }
                        }
                    }

                    // Emit functions and types globally
                    for (p.declarations) |decl| {
                        if (decl.node_type == .FunDecl or
                            decl.node_type == .StructDecl or
                            decl.node_type == .UnionDecl or
                            decl.node_type == .ClassDecl or
                            decl.node_type == .EnumDecl) {
                            try self.genNode(decl);
                        }
                    }

                    self.is_global = false;
                    try writer.print("define i32 @main() {{\n", .{});
                    try writer.print("entry:\n", .{});
                    self.temp_counter = 1;
                    self.decl_counter = 1;
                    self.local_allocas.clearRetainingCapacity();
                    for (p.declarations) |decl| {
                        if (decl.node_type == .VarDecl) {
                            const v = &decl.data.VarDecl;
                            const gfb: types.Type = decl.inferred_type orelse .{ .kind = .Any };
                            for (v.names, 0..) |name, i| {
                                const t = varTypeAtIndex(self.allocator, v, i, gfb);
                                var init_expr: ?*ast.Node = null;
                                if (v.initializers) |inits| {
                                    if (i < inits.len) init_expr = inits[i];
                                }
                                if (init_expr) |expr| {
                                    var init_val = try self.genExpr(expr);
                                    const source_type = typeToLLVM(self.allocator, expr.inferred_type orelse .{ .kind = .Any });
                                    init_val = try self.coerceType(init_val, source_type, t);
                                    var global_name = name;
                                    if (decl.module_name) |mod_name| {
                                        global_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, name });
                                    }
                                    try writer.print("  store {s} {s}, ptr @{s}\n", .{ t, init_val, global_name });
                                }
                            }
                        } else if (decl.node_type != .FunDecl and
                                   decl.node_type != .StructDecl and
                                   decl.node_type != .UnionDecl and
                                   decl.node_type != .ClassDecl and
                                   decl.node_type != .EnumDecl and
                                   decl.node_type != .ImportDecl and
                                   decl.node_type != .LinkDecl) {
                            try self.genNode(decl);
                        }
                    }
                    try writer.print("  ret i32 0\n", .{});
                    try writer.print("}}\n\n", .{});
                    self.is_global = true;
                } else {
                    for (p.declarations) |decl| {
                        try self.genNode(decl);
                    }
                }
            },
            .FunDecl => |*f| {
                if (f.generic_params != null) return;
                
                const prev_is_global = self.is_global;
                const prev_current_func_ret_llvm = self.current_func_ret_llvm;
                const prev_current_func_ret_ast = self.current_func_ret_ast;
                const prev_temp_counter = self.temp_counter;
                const prev_decl_counter = self.decl_counter;
                const prev_active_param_block = self.active_param_block;
                const prev_active_block_exit = self.active_block_exit;
                const prev_active_loop_cond = self.active_loop_cond;
                const prev_active_loop_exit = self.active_loop_exit;
                const prev_scope_depth = self.scope_depth;
                
                const prev_local_allocas = self.local_allocas;
                const prev_scope_var_stack = self.scope_var_stack;
                const prev_var_name_map = self.var_name_map;
                
                self.local_allocas = std.StringHashMap(bool).init(self.allocator);
                self.scope_var_stack = std.ArrayList(std.StringHashMap([]const u8)).init(self.allocator);
                self.var_name_map = std.StringHashMap([]const u8).init(self.allocator);
                self.scope_depth = 0;
                
                defer {
                    self.local_allocas.deinit();
                    self.scope_var_stack.deinit();
                    self.var_name_map.deinit();
                    
                    self.is_global = prev_is_global;
                    self.current_func_ret_llvm = prev_current_func_ret_llvm;
                    self.current_func_ret_ast = prev_current_func_ret_ast;
                    self.temp_counter = prev_temp_counter;
                    self.decl_counter = prev_decl_counter;
                    self.active_param_block = prev_active_param_block;
                    self.active_block_exit = prev_active_block_exit;
                    self.active_loop_cond = prev_active_loop_cond;
                    self.active_loop_exit = prev_active_loop_exit;
                    self.scope_depth = prev_scope_depth;
                    self.local_allocas = prev_local_allocas;
                    self.scope_var_stack = prev_scope_var_stack;
                    self.var_name_map = prev_var_name_map;
                }
                
                self.is_global = false;
                const is_main = std.mem.eql(u8, f.name, "main");
                if (is_main and f.params.len == 0) {
                    self.current_func_ret_llvm = "i32";
                    self.current_func_ret_ast = .{ .kind = .I32 };
                    try writer.print("define i32 @main() {{\n", .{});
                    try writer.print("entry:\n", .{});
                    self.temp_counter = 1;
                    self.local_allocas.clearRetainingCapacity();
                    self.var_name_map.clearRetainingCapacity();
                } else {
                    var param_str = std.ArrayList(u8).init(self.allocator);
                    if (!f.is_extern and !is_main) {
                        try param_str.appendSlice("ptr %env");
                    }
                    for (f.params, 0..) |param, i| {
                        if (i > 0 or (!f.is_extern and !is_main)) try param_str.appendSlice(", ");
                        const inferred: types.Type = param.inferred_type orelse .{ .kind = .Any };
                        const t = typeToLLVM(self.allocator, inferred);
                        const sig = abi.getArgABI(inferred, layout.Target.x86_64_linux);
                        if (f.is_extern) {
                            if (sig.mode == .ByVal) {
                                try std.fmt.format(param_str.writer(), "ptr byval({s})", .{ t });
                            } else if (sig.mode == .Coerce) {
                                try std.fmt.format(param_str.writer(), "{s}", .{ sig.llvm_type });
                            } else {
                                try std.fmt.format(param_str.writer(), "{s}", .{ t });
                            }
                        } else {
                            if (sig.mode == .ByVal) {
                                try std.fmt.format(param_str.writer(), "ptr byval({s}) %{s}.param", .{ t, param.data.Identifier.name });
                            } else if (sig.mode == .Coerce) {
                                try std.fmt.format(param_str.writer(), "{s} %{s}.param", .{ sig.llvm_type, param.data.Identifier.name });
                            } else {
                                try std.fmt.format(param_str.writer(), "{s} %{s}.param", .{ t, param.data.Identifier.name });
                            }
                        }
                    }
                    var actual_ret_type: types.Type = node.inferred_type orelse .{ .kind = .Void };
                    if (actual_ret_type.kind == .Function and actual_ret_type.function != null) {
                        actual_ret_type = actual_ret_type.function.?.return_type.*;
                    }
                    if (actual_ret_type.kind == .Task and actual_ret_type.payload != null) {
                        actual_ret_type = actual_ret_type.payload.?.*;
                    }
                    const ret_t = typeToLLVM(self.allocator, actual_ret_type);
                    const ret_sig = abi.getRetABI(actual_ret_type, layout.Target.x86_64_linux);
                    const final_ret_t = if (ret_sig.mode == .Coerce) ret_sig.llvm_type else ret_t;
                    self.current_func_ret_llvm = final_ret_t;
                    self.current_func_ret_ast = actual_ret_type;

                    var func_symbol_name = f.name;
                    if (!f.is_extern and !is_main) {
                        if (node.module_name) |mod_name| {
                            func_symbol_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, f.name });
                        }
                    }
                    
                    if (f.is_extern) {
                        if (f.is_variadic) {
                            if (param_str.items.len > 0) try param_str.appendSlice(", ");
                            try param_str.appendSlice("...");
                        }
                        if (!self.external_decls.contains(func_symbol_name)) {
                            try self.external_decls.put(func_symbol_name, true);
                            try self.type_out.writer().print("declare {s} @{s}({s})\n", .{ final_ret_t, func_symbol_name, param_str.items });
                        }
                        return;
                    }
                    
                    const inline_attr = if (f.is_inline) " alwaysinline" else "";
                    try writer.print("define {s} @{s}({s}){s} {{\n", .{ final_ret_t, func_symbol_name, param_str.items, inline_attr });
                    try writer.print("entry:\n", .{});
                    self.temp_counter = 1;
                    self.decl_counter = 1;
                    self.local_allocas.clearRetainingCapacity();
                    self.var_name_map.clearRetainingCapacity();
                    for (f.params) |param| {
                        const name = param.data.Identifier.name;
                        const inferred: types.Type = param.inferred_type orelse types.Type{ .kind = .Any };
                        const t = typeToLLVM(self.allocator, inferred);
                        const sig = abi.getArgABI(inferred, layout.Target.x86_64_linux);
                        const align_req = layout.getAlign(inferred, layout.Target.x86_64_linux);
                        const scoped_name = try self.registerVarName(name);
                        
                        try writer.print("  %{s} = alloca {s}, align {d}\n", .{ scoped_name, t, align_req });
                        
                        if (sig.mode == .ByVal) {
                            const tmp = self.nextTemp();
                            try writer.print("  %t.{d} = load {s}, ptr %{s}.param, align {d}\n", .{ tmp, t, name, align_req });
                            try writer.print("  store {s} %t.{d}, ptr %{s}, align {d}\n", .{ t, tmp, scoped_name, align_req });
                        } else if (sig.mode == .Coerce and !is_main) {
                            try writer.print("  store {s} %{s}.param, ptr %{s}, align {d}\n", .{ sig.llvm_type, name, scoped_name, align_req });
                        } else {
                            try writer.print("  store {s} %{s}.param, ptr %{s}, align {d}\n", .{ t, name, scoped_name, align_req });
                        }
                    }
                }

                if (f.body.node_type == .BlockStmt) {
                    for (f.body.data.BlockStmt.statements) |stmt| {
                        try self.genNode(stmt);
                    }
                }

                if (is_main) {
                    if (f.auto_drops) |drops| {
                        try self.genAutoDrops(drops);
                    }
                    try writer.print("  ret i32 0\n", .{});
                } else {
                    var has_ret = false;
                    if (f.body.node_type == .BlockStmt and f.body.data.BlockStmt.statements.len > 0) {
                        const last_stmt = f.body.data.BlockStmt.statements[f.body.data.BlockStmt.statements.len - 1];
                        if (last_stmt.node_type == .ReturnStmt) has_ret = true;
                    }
                    if (!has_ret) {
                        var actual_ret_type: types.Type = node.inferred_type orelse .{ .kind = .Void };
                        if (actual_ret_type.kind == .Task and actual_ret_type.payload != null) {
                            actual_ret_type = actual_ret_type.payload.?.*;
                        }
                        if (f.auto_drops) |drops| {
                            try self.genAutoDrops(drops);
                        }
                        const final_ret_t = self.current_func_ret_llvm;
                        if (std.mem.eql(u8, final_ret_t, "void")) {
                            try writer.print("  ret void\n", .{});
                        } else if (std.mem.eql(u8, final_ret_t, "ptr")) {
                            try writer.print("  ret ptr null\n", .{});
                        } else if (std.mem.eql(u8, final_ret_t, "float") or std.mem.eql(u8, final_ret_t, "double")) {
                            try writer.print("  ret {s} 0.0\n", .{final_ret_t});
                        } else if (std.mem.indexOf(u8, final_ret_t, "{") != null or std.mem.startsWith(u8, final_ret_t, "%") or std.mem.startsWith(u8, final_ret_t, "[")) {
                            try writer.print("  ret {s} zeroinitializer\n", .{final_ret_t});
                        } else {
                            try writer.print("  ret {s} 0\n", .{final_ret_t});
                        }
                    }
                }
                try writer.print("}}\n\n", .{});
                self.is_global = true;
            },
            .ClassDecl => |*c| {
                const ct = node.inferred_type.?.class_type.?;
                var fields_str = std.ArrayList(u8).init(self.allocator);
                try fields_str.appendSlice("ptr"); // vtable pointer
                
                for (ct.fields) |sf| {
                    try fields_str.appendSlice(", ");
                    try fields_str.appendSlice(typeToLLVM(self.allocator, sf.type_kind));
                }
                
                try self.type_out.writer().print("%{s} = type {{ {s} }}\n\n", .{ ct.name, fields_str.items });

                try self.type_out.writer().print("@__vtable_{s} = global [{d} x ptr] [", .{ ct.name, ct.methods.len });
                for (ct.methods, 0..) |method, idx| {
                    if (idx > 0) try self.type_out.writer().print(", ", .{});
                    const def_class = method.defining_class_name orelse ct.name;
                    try self.type_out.writer().print("ptr @{s}_{s}", .{ def_class, method.name });
                }
                try self.type_out.writer().print("]\n\n", .{});

                for (c.methods) |method| {
                    if (method.node_type == .FunDecl) {
                        const original_name = method.data.FunDecl.name;
                        method.data.FunDecl.name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ct.name, original_name});
                    }
                    try self.genNode(method);
                }

                // Generate __del__
                try writer.print("define void @{s}___del__(ptr %self) {{\n", .{ct.name});
                try writer.print("entry:\n", .{});
                
                var field_idx: u32 = 1;
                for (ct.fields) |sf| {
                    if (types.hasDestructor(sf.type_kind)) {
                        const llvm_t = typeToLLVM(self.allocator, sf.type_kind);
                        const field_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = getelementptr inbounds %{s}, ptr %self, i32 0, i32 {d}\n", .{field_ptr, ct.name, field_idx});
                        const field_val = self.nextTemp();
                        try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{field_val, llvm_t, field_ptr});
                        
                        if (sf.type_kind.kind == .Class) {
                            try writer.print("  call void @{s}___del__(ptr %t.{d})\n", .{sf.type_kind.class_type.?.name, field_val});
                            try writer.print("  call void @mantiq_free(ptr %t.{d})\n", .{field_val});
                        } else {
                            try writer.print("  call void @mantiq_free(ptr %t.{d})\n", .{field_val});
                        }
                    }
                    field_idx += 1;
                }

                try writer.print("  ret void\n", .{});
                try writer.print("}}\n\n", .{});
            },
            .InterfaceDecl => {
            },
            .StructDecl => |*s| {
                if (s.generic_params != null) return;
                const st = node.inferred_type.?.struct_type.?;
                var fields_str = std.ArrayList(u8).init(self.allocator);
                for (st.fields, 0..) |sf, i| {
                    if (i > 0) try fields_str.appendSlice(", ");
                    try fields_str.appendSlice(typeToLLVM(self.allocator, sf.type_kind));
                }
                try self.type_out.writer().print("%{s} = type {{ {s} }}\n\n", .{ st.name, fields_str.items });

                for (s.methods) |method| {
                    try self.genNode(method);
                }
            },
            .UnionDecl => |*u| {
                if (u.generic_params != null) return;
                const ut_type = node.inferred_type.?;
                const ut = ut_type.union_type.?;
                if (ut.tag_type) |tag_t| {
                    var max_size: usize = 0;
                    for (ut.fields) |f| {
                        const field_size = types.getTypeSize(f.type_kind);
                        if (field_size > max_size) max_size = field_size;
                    }
                    var max_align: usize = 1;
                    for (ut.fields) |f| {
                        const field_align = types.getTypeAlignment(f.type_kind);
                        if (field_align > max_align) max_align = field_align;
                    }
                    const padding = (max_align - (max_size % max_align)) % max_align;
                    const payload_size = max_size + padding;
                    const tag_t_llvm = typeToLLVM(self.allocator, tag_t);
                    try self.type_out.writer().print("%{s} = type {{ {s}, [{d} x i8] }}\n\n", .{ ut.name, tag_t_llvm, payload_size });
                } else {
                    const size = types.getTypeSize(ut_type);
                    try self.type_out.writer().print("%{s} = type {{ [{d} x i8] }}\n\n", .{ ut.name, size });
                }

                for (u.methods) |method| {
                    try self.genNode(method);
                }
            },
            .EnumDecl => {
                const et = node.inferred_type.?.enum_type.?;
                // For a Rust-style Enum, we use a tagged union: { i32, [4 x i64] }
                // This gives 32 bytes of inline payload storage.
                try self.type_out.writer().print("%{s} = type {{ i32, [4 x i64] }}\n\n", .{et.name});
            },
            .EnumVariant => {
                // Handled via MemberExpr / CallExpr
            },
            .KeywordArg => {
                unreachable; // KeywordArgs are flattened during typechecking
            },
            .VarDecl => |*v| {
                const fallback: types.Type = node.inferred_type orelse .{ .kind = .Any };
                var tuple_init_val: ?[]const u8 = null;
                var tuple_init_type: ?[]const u8 = null;

                if (v.initializers) |inits| {
                    if (inits.len == 1 and v.names.len > 1) {
                        tuple_init_val = try self.genExpr(inits[0]);
                        tuple_init_type = typeToLLVM(self.allocator, inits[0].inferred_type orelse .{ .kind = .Any });
                    }
                }

                for (v.names, 0..) |name, i| {
                    const t = varTypeAtIndex(self.allocator, v, i, fallback);

                    var init_expr: ?*ast.Node = null;
                    if (v.initializers) |inits| {
                        if (i < inits.len) init_expr = inits[i];
                    }
                    if (self.is_global) {
                        // Global variable
                        var global_name = name;
                        if (node.module_name) |mod_name| {
                            global_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, name });
                        }
                        if (init_expr) |expr| {
                            const init_val = try self.genExpr(expr);
                            try writer.print("@{s} = global {s} {s}\n", .{ global_name, t, init_val });
                        } else {
                            try writer.print("@{s} = global {s} zeroinitializer\n", .{ global_name, t });
                        }
                        const type_str = try self.allocator.dupe(u8, t);
                        try self.global_vars.put(global_name, type_str);
                    } else {
                        // Local variable
                        const scoped_name = try self.registerVarName(name);
                        try writer.print("  %{s} = alloca {s}\n", .{ scoped_name, t });
                        if (tuple_init_val != null) {
                            const ext_temp = self.nextTemp();
                            try writer.print("  %t.{d} = extractvalue {s} {s}, {d}\n", .{ ext_temp, tuple_init_type.?, tuple_init_val.?, i });
                            const ext_val_str = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ext_temp});
                            var source_type = t;
                            if (v.initializers) |inits| {
                                const init_t = inits[0].inferred_type orelse types.Type{ .kind = .Any };
                                if (init_t.kind == .Tuple and init_t.tuple_types != null and i < init_t.tuple_types.?.len) {
                                    source_type = typeToLLVM(self.allocator, init_t.tuple_types.?[i]);
                                }
                            }
                            const coerced_val = try self.coerceType(ext_val_str, source_type, t);
                            try writer.print("  store {s} {s}, ptr %{s}\n", .{ t, coerced_val, scoped_name });
                        } else if (init_expr) |expr| {
                            var init_val = try self.genExpr(expr);
                            self.consumeTemp(init_val);
                            const source_type = typeToLLVM(self.allocator, expr.inferred_type orelse .{ .kind = .Any });
                            init_val = try self.coerceType(init_val, source_type, t);
                            try writer.print("  store {s} {s}, ptr %{s}\n", .{ t, init_val, scoped_name });
                        }
                    }
                }
            },
            .ParamBlockStmt => |*p| {
                // 1. Allocate return variables in the parent function
                for (p.return_names, 0..) |name, i| {
                    const t = if (i < p.return_types.len) annotToLLVM(p.return_types[i].name) else "i64";
                    try writer.print("  %{s} = alloca {s}\n", .{ name, t });
                }

                // 2. Setup block exit label
                const block_id = self.nextTemp();
                const exit_label = try std.fmt.allocPrint(self.allocator, "block_exit_{d}", .{block_id});

                // 3. Save current active block context
                const prev_block = self.active_param_block;
                const prev_exit = self.active_block_exit;
                self.active_param_block = node;
                self.active_block_exit = exit_label;

                // 4. Emit the block body
                try self.genNode(p.body);

                // 5. Emit exit label
                try writer.print("  br label %{s}\n", .{exit_label});
                try writer.print("{s}:\n", .{exit_label});

                // 6. Restore context
                if (p.auto_drops) |drops| {
                    try self.genAutoDrops(drops);
                }
                self.active_param_block = prev_block;
                self.active_block_exit = prev_exit;
            },
            .UnsafeBlock => |*u| {
                try self.genNode(u.body);
            },
            .MacroDecl => {},
            .MacroInvocation => {},
            .BlockStmt => |*b| {
                try self.pushScope();
                defer self.popScope();
                for (b.statements) |stmt| {
                    try self.genNode(stmt);
                }
                if (b.auto_drops) |drops| {
                    try self.genAutoDrops(drops);
                }
            },
            .ForStmt => |*f| {
                if (f.is_parallel) {
                    var start_val: []const u8 = "0";
                    var end_val: []const u8 = "10";
                    var start_ty: types.Type = .{ .kind = .I32 };
                    var end_ty: types.Type = .{ .kind = .I32 };

                    if (f.iterable.node_type == .CallExpr and
                        f.iterable.data.CallExpr.callee.node_type == .Identifier and
                        std.mem.eql(u8, f.iterable.data.CallExpr.callee.data.Identifier.name, "range"))
                    {
                        const call_expr = &f.iterable.data.CallExpr;
                        if (call_expr.arguments.len == 2) {
                            start_val = try self.genExpr(call_expr.arguments[0]);
                            end_val = try self.genExpr(call_expr.arguments[1]);
                            start_ty = call_expr.arguments[0].inferred_type orelse .{ .kind = .I32 };
                            end_ty = call_expr.arguments[1].inferred_type orelse .{ .kind = .I32 };
                        }
                    } else if (f.iterable.node_type == .BinaryExpr and std.mem.eql(u8, f.iterable.data.BinaryExpr.operator, "..")) {
                        start_val = try self.genExpr(f.iterable.data.BinaryExpr.left);
                        end_val = try self.genExpr(f.iterable.data.BinaryExpr.right);
                        start_ty = f.iterable.data.BinaryExpr.left.inferred_type orelse .{ .kind = .I32 };
                        end_ty = f.iterable.data.BinaryExpr.right.inferred_type orelse .{ .kind = .I32 };
                    }

                    const start_val_i32 = try self.ensureI32(writer, start_val, start_ty);
                    const end_val_i32 = try self.ensureI32(writer, end_val, end_ty);

                    const closure_id = self.closure_counter;
                    self.closure_counter += 1;
                    const closure_name = try std.fmt.allocPrint(self.allocator, "__mantiq_par_closure_{d}", .{closure_id});

                    const saved_out = self.out;
                    const saved_temp = self.temp_counter;

                    self.out = std.ArrayList(u8).init(self.allocator);
                    self.temp_counter = 1;

                    try self.out.writer().print("define void @{s}(ptr %env, i32 %{s}.param) {{\n", .{ closure_name, f.iterator });
                    try self.out.writer().print("entry:\n", .{});

                    const t = typeToLLVM(self.allocator, node.inferred_type orelse .{ .kind = .I32 });
                    try self.out.writer().print("  %{s} = alloca {s}\n", .{ f.iterator, t });
                    try self.out.writer().print("  store {s} %{s}.param, ptr %{s}\n", .{ t, f.iterator, f.iterator });

                    try self.genNode(f.body);
                    try self.out.writer().print("  ret void\n", .{});
                    try self.out.writer().print("}}\n\n", .{});

                    try self.outlined_out.appendSlice(self.out.items);
                    self.out.deinit();

                    self.out = saved_out;
                    self.temp_counter = saved_temp;

                    try writer.print("  call void @__mantiq_parallel_for(i32 {s}, i32 {s}, ptr @{s}, ptr null)\n", .{ start_val_i32, end_val_i32, closure_name });
                } else if (f.is_vectorized) {
                    var start_val: []const u8 = "0";
                    var end_val: []const u8 = "10";

                    if (f.iterable.node_type == .CallExpr and
                        f.iterable.data.CallExpr.callee.node_type == .Identifier and
                        std.mem.eql(u8, f.iterable.data.CallExpr.callee.data.Identifier.name, "range"))
                    {
                        const call_expr = &f.iterable.data.CallExpr;
                        if (call_expr.arguments.len == 2) {
                            start_val = try self.genExpr(call_expr.arguments[0]);
                            end_val = try self.genExpr(call_expr.arguments[1]);
                        }
                    } else if (f.iterable.node_type == .BinaryExpr and std.mem.eql(u8, f.iterable.data.BinaryExpr.operator, "..")) {
                        start_val = try self.genExpr(f.iterable.data.BinaryExpr.left);
                        end_val = try self.genExpr(f.iterable.data.BinaryExpr.right);
                    }

                    const loop_id = self.temp_counter;
                    self.temp_counter += 1;
                    const loop_cond = try std.fmt.allocPrint(self.allocator, "vec.cond.{d}", .{loop_id});
                    const loop_body = try std.fmt.allocPrint(self.allocator, "vec.body.{d}", .{loop_id});
                    const loop_inc = try std.fmt.allocPrint(self.allocator, "vec.inc.{d}", .{loop_id});
                    const loop_end = try std.fmt.allocPrint(self.allocator, "vec.end.{d}", .{loop_id});

                    const prev_cond = self.active_loop_cond;
                    const prev_exit = self.active_loop_exit;
                    self.active_loop_cond = loop_inc;
                    self.active_loop_exit = loop_end;

                    const meta_id = self.metadata_counter;
                    self.metadata_counter += 2;

                    const t = typeToLLVM(self.allocator, node.inferred_type orelse .{ .kind = .I32 });

                    try writer.print("  %{s} = alloca {s}\n", .{ f.iterator, t });
                    try writer.print("  store {s} {s}, ptr %{s}\n", .{ t, start_val, f.iterator });

                    try writer.print("  br label %{s}\n", .{loop_cond});
                    try writer.print("{s}:\n", .{loop_cond});

                    const val = self.nextTemp();
                    const cmp = self.nextTemp();
                    try writer.print("  %t.{d} = load {s}, ptr %{s}\n", .{ val, t, f.iterator });
                    try writer.print("  %t.{d} = icmp slt {s} %t.{d}, {s}\n", .{ cmp, t, val, end_val });
                    try self.flushStatementTemps();
                    try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cmp, loop_body, loop_end });

                    try writer.print("{s}:\n", .{loop_body});
                    try self.genNode(f.body);

                    try writer.print("  br label %{s}\n", .{loop_inc});
                    try writer.print("{s}:\n", .{loop_inc});
                    const inc = self.nextTemp();
                    const val_end = self.nextTemp();
                    try writer.print("  %t.{d} = load {s}, ptr %{s}\n", .{ val_end, t, f.iterator });
                    try writer.print("  %t.{d} = add {s} %t.{d}, 1\n", .{ inc, t, val_end });
                    try writer.print("  store {s} %t.{d}, ptr %{s}\n", .{ t, inc, f.iterator });
                    try writer.print("  br label %{s}, !llvm.loop !{d}\n", .{ loop_cond, meta_id });

                    try writer.print("{s}:\n", .{loop_end});

                    self.active_loop_cond = prev_cond;
                    self.active_loop_exit = prev_exit;

                    try self.metadata_out.writer().print("!{d} = !{{!{d}, !{d}}}\n", .{ meta_id, meta_id, meta_id + 1 });
                    try self.metadata_out.writer().print("!{d} = !{{!\"llvm.loop.vectorize.enable\", i1 true}}\n", .{meta_id + 1});
                } else {
                    // Standard Sequential Loop
                    var start_val: []const u8 = "0";
                    var end_val: []const u8 = "0";
                    var is_list = false;
                    var iter_val: []const u8 = "";

                    if (f.iterable.node_type == .CallExpr and
                        f.iterable.data.CallExpr.callee.node_type == .Identifier and
                        std.mem.eql(u8, f.iterable.data.CallExpr.callee.data.Identifier.name, "range"))
                    {
                        const call_expr = &f.iterable.data.CallExpr;
                        if (call_expr.arguments.len == 2) {
                            start_val = try self.genExpr(call_expr.arguments[0]);
                            end_val = try self.genExpr(call_expr.arguments[1]);
                        }
                    } else if (f.iterable.node_type == .BinaryExpr and std.mem.eql(u8, f.iterable.data.BinaryExpr.operator, "..")) {
                        start_val = try self.genExpr(f.iterable.data.BinaryExpr.left);
                        end_val = try self.genExpr(f.iterable.data.BinaryExpr.right);
                    } else {
                        iter_val = try self.genExpr(f.iterable);
                        if (f.iterable.inferred_type != null and f.iterable.inferred_type.?.kind == .List) {
                            is_list = true;
                            const len_temp = self.nextTemp();
                            try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 1\n", .{ len_temp, iter_val });
                            end_val = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{len_temp});
                        }
                    }

                    const loop_id = self.temp_counter;
                    self.temp_counter += 1;
                    const loop_cond = try std.fmt.allocPrint(self.allocator, "for.cond.{d}", .{loop_id});
                    const loop_body = try std.fmt.allocPrint(self.allocator, "for.body.{d}", .{loop_id});
                    const loop_inc = try std.fmt.allocPrint(self.allocator, "for.inc.{d}", .{loop_id});
                    const loop_end = try std.fmt.allocPrint(self.allocator, "for.end.{d}", .{loop_id});

                    const prev_cond = self.active_loop_cond;
                    const prev_exit = self.active_loop_exit;
                    self.active_loop_cond = loop_inc; // continue jumps here!
                    self.active_loop_exit = loop_end;

                    const t = typeToLLVM(self.allocator, node.inferred_type orelse .{ .kind = .I32 });

                    if (is_list) {
                        const idx_temp = self.nextTemp();
                        try writer.print("  %t.{d} = alloca i64\n", .{idx_temp});
                        try writer.print("  store i64 0, ptr %t.{d}\n", .{idx_temp});
                        try writer.print("  %{s} = alloca {s}\n", .{ f.iterator, t });

                        try writer.print("  br label %{s}\n", .{loop_cond});
                        try writer.print("{s}:\n", .{loop_cond});

                        const val = self.nextTemp();
                        const cmp = self.nextTemp();
                        try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ val, idx_temp });
                        try writer.print("  %t.{d} = icmp slt i64 %t.{d}, {s}\n", .{ cmp, val, end_val });
                        try self.flushStatementTemps();
                        try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cmp, loop_body, loop_end });

                        try writer.print("{s}:\n", .{loop_body});

                        const buf_temp = self.nextTemp();
                        const gep_temp = self.nextTemp();
                        const elem_temp = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 0\n", .{ buf_temp, iter_val });
                        try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr %t.{d}, i64 %t.{d}\n", .{ gep_temp, t, buf_temp, val });
                        try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ elem_temp, t, gep_temp });
                        try writer.print("  store {s} %t.{d}, ptr %{s}\n", .{ t, elem_temp, f.iterator });

                        try self.genNode(f.body);

                        try writer.print("  br label %{s}\n", .{loop_inc});
                        try writer.print("{s}:\n", .{loop_inc});
                        const inc = self.nextTemp();
                        const val_end = self.nextTemp();
                        try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ val_end, idx_temp });
                        try writer.print("  %t.{d} = add i64 %t.{d}, 1\n", .{ inc, val_end });
                        try writer.print("  store i64 %t.{d}, ptr %t.{d}\n", .{ inc, idx_temp });
                        try writer.print("  br label %{s}\n", .{loop_cond});
                    } else {
                        try writer.print("  %{s} = alloca {s}\n", .{ f.iterator, t });
                        try writer.print("  store {s} {s}, ptr %{s}\n", .{ t, start_val, f.iterator });

                        try writer.print("  br label %{s}\n", .{loop_cond});
                        try writer.print("{s}:\n", .{loop_cond});

                        const val = self.nextTemp();
                        const cmp = self.nextTemp();
                        try writer.print("  %t.{d} = load {s}, ptr %{s}\n", .{ val, t, f.iterator });
                        try writer.print("  %t.{d} = icmp slt {s} %t.{d}, {s}\n", .{ cmp, t, val, end_val });
                        try self.flushStatementTemps();
                        try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cmp, loop_body, loop_end });

                        try writer.print("{s}:\n", .{loop_body});
                        try self.genNode(f.body);

                        try writer.print("  br label %{s}\n", .{loop_inc});
                        try writer.print("{s}:\n", .{loop_inc});
                        const inc = self.nextTemp();
                        const val_end = self.nextTemp();
                        try writer.print("  %t.{d} = load {s}, ptr %{s}\n", .{ val_end, t, f.iterator });
                        try writer.print("  %t.{d} = add {s} %t.{d}, 1\n", .{ inc, t, val_end });
                        try writer.print("  store {s} %t.{d}, ptr %{s}\n", .{ t, inc, f.iterator });
                        try writer.print("  br label %{s}\n", .{loop_cond});
                    }

                    try writer.print("{s}:\n", .{loop_end});

                    self.active_loop_cond = prev_cond;
                    self.active_loop_exit = prev_exit;
                }
            },

            .MatchStmt => |*m| {
                const subject_val = try self.genExpr(m.subject);
                const subject_t = typeToLLVM(self.allocator, m.subject.inferred_type orelse .{ .kind = .Any });

                const match_id = self.temp_counter;
                self.temp_counter += 1;
                const match_end = try std.fmt.allocPrint(self.allocator, "match.end.{d}", .{match_id});

                var case_labels = std.ArrayList([]const u8).init(self.allocator);
                for (m.cases, 0..) |_, i| {
                    try case_labels.append(try std.fmt.allocPrint(self.allocator, "match.case.{d}.{d}", .{ match_id, i }));
                }

                if (m.cases.len > 0) {
                    try writer.print("  br label %{s}\n", .{case_labels.items[0]});
                } else {
                    try writer.print("  br label %{s}\n", .{match_end});
                }

                for (m.cases, 0..) |case_node, i| {
                    try writer.print("{s}:\n", .{case_labels.items[i]});

                    const next_label = if (i + 1 < m.cases.len) case_labels.items[i + 1] else match_end;
                    const body_label = try std.fmt.allocPrint(self.allocator, "match.body.{d}.{d}", .{ match_id, i });
                    const guard_label = try std.fmt.allocPrint(self.allocator, "match.guard.{d}.{d}", .{ match_id, i });

                    var matched_cond: []const u8 = "1"; // Default to true for wildcard `_`

                    if (case_node.pattern.node_type == .Identifier) {
                        const name = case_node.pattern.data.Identifier.name;
                        if (!std.mem.eql(u8, name, "_")) {
                            // It's a variable binding, e.g., `case x:`
                            try writer.print("  %{s} = alloca {s}\n", .{ name, subject_t });
                            try writer.print("  store {s} {s}, ptr %{s}\n", .{ subject_t, subject_val, name });
                        }
                    } else if (case_node.pattern.node_type == .BinaryExpr and std.mem.eql(u8, case_node.pattern.data.BinaryExpr.operator, "..")) {
                        // Range pattern `left..right`
                        const left = try self.genExpr(case_node.pattern.data.BinaryExpr.left);
                        const right = try self.genExpr(case_node.pattern.data.BinaryExpr.right);

                        const cmp1 = self.nextTemp();
                        try writer.print("  %t.{d} = icmp sge {s} {s}, {s}\n", .{ cmp1, subject_t, subject_val, left });
                        const cmp2 = self.nextTemp();
                        try writer.print("  %t.{d} = icmp sle {s} {s}, {s}\n", .{ cmp2, subject_t, subject_val, right });

                        const combined = self.nextTemp();
                        try writer.print("  %t.{d} = and i1 %t.{d}, %t.{d}\n", .{ combined, cmp1, cmp2 });
                        matched_cond = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{combined});
                    } else {
                        // Literal matching (e.g., `100`, `"string"`)
                        const pattern_val = try self.genExpr(case_node.pattern);
                        const pattern_t = typeToLLVM(self.allocator, case_node.pattern.inferred_type orelse .{ .kind = .Any });

                        const cmp = self.nextTemp();
                        if (std.mem.eql(u8, pattern_t, "float") or std.mem.eql(u8, pattern_t, "bfloat")) {
                            try writer.print("  %t.{d} = fcmp oeq {s} {s}, {s}\n", .{ cmp, pattern_t, subject_val, pattern_val });
                        } else {
                            try writer.print("  %t.{d} = icmp eq {s} {s}, {s}\n", .{ cmp, pattern_t, subject_val, pattern_val });
                        }
                        matched_cond = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{cmp});
                    }

                    if (case_node.guard) |guard| {
                        if (std.mem.eql(u8, matched_cond, "1")) {
                            try writer.print("  br label %{s}\n", .{guard_label});
                        } else {
                            try writer.print("  br i1 {s}, label %{s}, label %{s}\n", .{ matched_cond, guard_label, next_label });
                        }
                        try writer.print("{s}:\n", .{guard_label});

                        const guard_val = try self.genExpr(guard);
                        const guard_t = typeToLLVM(self.allocator, guard.inferred_type orelse .{ .kind = .Boolean });
                        if (!std.mem.eql(u8, guard_t, "i1")) {
                            const temp = self.nextTemp();
                            try writer.print("  %t.{d} = icmp ne {s} {s}, 0\n", .{ temp, guard_t, guard_val });
                            matched_cond = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                        } else {
                            matched_cond = guard_val;
                        }
                        try writer.print("  br i1 {s}, label %{s}, label %{s}\n", .{ matched_cond, body_label, next_label });
                    } else {
                        if (std.mem.eql(u8, matched_cond, "1")) {
                            try writer.print("  br label %{s}\n", .{body_label});
                        } else {
                            try writer.print("  br i1 {s}, label %{s}, label %{s}\n", .{ matched_cond, body_label, next_label });
                        }
                    }

                    try writer.print("{s}:\n", .{body_label});
                    try self.genNode(case_node.body);
                    try writer.print("  br label %{s}\n", .{match_end});
                }

                try writer.print("{s}:\n", .{match_end});
            },
            .ReturnStmt => |*r| {
                if (r.auto_drops) |drops| {
                    try self.genAutoDrops(drops);
                }
                if (self.active_param_block) |p_node| {
                    const p = &p_node.data.ParamBlockStmt;
                    if (r.values) |values| {
                        for (values, 0..) |val, i| {
                            if (i < p.return_names.len) {
                                const ret_name = p.return_names[i];
                                var ret_val = try self.genExpr(val);
                                self.consumeTemp(ret_val);
                                const inferred = val.inferred_type orelse types.Type{ .kind = .Any };
                                const source_t = typeToLLVM(self.allocator, inferred);
                                const annot_name = if (i < p.return_types.len) p.return_types[i].name else "i64";
                                const target_kind = types.parseTypeString(annot_name);
                                const target_type = types.Type{ .kind = target_kind };
                                const t = typeToLLVM(self.allocator, target_type);
                                ret_val = try self.coerceType(ret_val, source_t, t);
                                try writer.print("  store {s} {s}, ptr %{s}\n", .{ t, ret_val, ret_name });
                            }
                        }
                    }
                    try writer.print("  br label %{s}\n", .{self.active_block_exit});
                } else {
                    if (r.values) |values| {
                        if (values.len == 1) {
                            const val = values[0];
                            var ret_val = try self.genExpr(val);
                            self.consumeTemp(ret_val);
                            const inferred: types.Type = val.inferred_type orelse types.Type{ .kind = .Any };
                            const source_t = typeToLLVM(self.allocator, inferred);
                            const target_type = self.current_func_ret_ast orelse types.Type{ .kind = .Any };
                            const t = typeToLLVM(self.allocator, target_type);
                            ret_val = try self.coerceType(ret_val, source_t, t);
                            const sig = abi.getRetABI(target_type, layout.Target.x86_64_linux);
                            if (sig.mode == .Coerce) {
                                const align_req = layout.getAlign(target_type, layout.Target.x86_64_linux);
                                const temp_alloc = self.nextTemp();
                                try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, t, align_req });
                                try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ t, ret_val, temp_alloc, align_req });
                                const cast_load = self.nextTemp();
                                try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ cast_load, sig.llvm_type, temp_alloc, align_req });
                                try writer.print("  ret {s} %t.{d}\n", .{ sig.llvm_type, cast_load });
                            } else {
                                try writer.print("  ret {s} {s}\n", .{ t, ret_val });
                            }
                        } else {
                            const target_type = self.current_func_ret_ast orelse types.Type{ .kind = .Any };
                            const tuple_t = typeToLLVM(self.allocator, target_type);
                            var last_val: []const u8 = "undef";
                            for (values, 0..) |val, i| {
                                const el_inferred = val.inferred_type orelse types.Type{ .kind = .Any };
                                const el_source_t = typeToLLVM(self.allocator, el_inferred);
                                
                                var el_target_type = el_inferred;
                                if (target_type.kind == .Tuple and target_type.tuple_types != null) {
                                    if (i < target_type.tuple_types.?.len) {
                                        el_target_type = target_type.tuple_types.?[i];
                                    }
                                }
                                
                                var el_val = try self.genExpr(val);
                                self.consumeTemp(el_val);
                                const el_t = typeToLLVM(self.allocator, el_target_type);
                                el_val = try self.coerceType(el_val, el_source_t, el_t);
                                const new_val = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{self.nextTemp()});
                                try writer.print("  {s} = insertvalue {s} {s}, {s} {s}, {d}\n", .{ new_val, tuple_t, last_val, el_t, el_val, i });
                                last_val = new_val;
                            }
                            const sig = abi.getRetABI(target_type, layout.Target.x86_64_linux);
                            if (sig.mode == .Coerce) {
                                const align_req = layout.getAlign(target_type, layout.Target.x86_64_linux);
                                const temp_alloc = self.nextTemp();
                                try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, tuple_t, align_req });
                                try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ tuple_t, last_val, temp_alloc, align_req });
                                const cast_load = self.nextTemp();
                                try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ cast_load, sig.llvm_type, temp_alloc, align_req });
                                try writer.print("  ret {s} %t.{d}\n", .{ sig.llvm_type, cast_load });
                            } else {
                                try writer.print("  ret {s} {s}\n", .{ tuple_t, last_val });
                            }
                        }
                    } else {
                        if (std.mem.eql(u8, self.current_func_ret_llvm, "i32")) {
                            try writer.print("  ret i32 0\n", .{});
                        } else {
                            try writer.print("  ret void\n", .{});
                        }
                    }
                }
            },
            .ThrowStmt => |*th| {
                const err_val = try self.genExpr(th.value);
                self.consumeTemp(err_val);
                
                const err_type = th.value.inferred_type orelse types.Type{ .kind = .Any };
                const err_llvm = typeToLLVM(self.allocator, err_type);

                const ret_ast = self.current_func_ret_ast orelse types.Type{ .kind = .Any };
                const ret_t = typeToLLVM(self.allocator, ret_ast);
                const sig = abi.getRetABI(ret_ast, layout.Target.x86_64_linux);
                
                const box_ptr = self.nextTemp();
                try writer.print("  %t.{d} = call ptr @mantiq_malloc(i64 32)\n", .{box_ptr});
                try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ err_llvm, err_val, box_ptr });

                const fat_temp1 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {s} undef, i8 1, 0\n", .{ fat_temp1, ret_t });
                const fat_temp2 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {s} %t.{d}, ptr null, 1\n", .{ fat_temp2, ret_t, fat_temp1 });
                const temp1 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {s} %t.{d}, ptr %t.{d}, 2\n", .{ temp1, ret_t, fat_temp2, box_ptr });
                
                if (sig.mode == .Coerce) {
                    const align_req = layout.getAlign(ret_ast, layout.Target.x86_64_linux);
                    const temp_alloc = self.nextTemp();
                    try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, ret_t, align_req });
                    try writer.print("  store {s} %t.{d}, ptr %t.{d}, align {d}\n", .{ ret_t, temp1, temp_alloc, align_req });
                    const cast_load = self.nextTemp();
                    try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ cast_load, sig.llvm_type, temp_alloc, align_req });
                    try writer.print("  ret {s} %t.{d}\n", .{ sig.llvm_type, cast_load });
                } else {
                    try writer.print("  ret {s} %t.{d}\n", .{ ret_t, temp1 });
                }
            },
            .IfStmt, .WhileStmt, .BreakStmt, .ContinueStmt, .PassStmt, .WithStmt => {
                _ = try self.genExpr(node);
            },
            .BinaryExpr => {
                _ = try self.genExpr(node);
                try self.flushStatementTemps();
            },
            .ImportDecl, .LinkDecl => {
                // Dependencies / metadata handled during compilation pipeline
            },
            else => {
                _ = try self.genExpr(node);
                try self.flushStatementTemps();
            },
        }
    }

    fn genLValue(self: *LLVMCodegen, node: *ast.Node) CodegenError![]const u8 {
        const writer = self.out.writer();
        switch (node.node_type) {
            .Identifier => {
                const name = node.data.Identifier.name;
                var var_symbol_name = name;
                var is_global_var = self.global_vars.contains(name);
                if (node.data.Identifier.resolved_symbol) |sym| {
                    if (sym.decl_node) |decl| {
                        if (decl.module_name) |mod_name| {
                            const mangled_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, sym.name });
                            if (self.global_vars.contains(mangled_name)) {
                                var_symbol_name = mangled_name;
                                is_global_var = true;
                            }
                        }
                    }
                }
                if (is_global_var) {
                    return try std.fmt.allocPrint(self.allocator, "@{s}", .{var_symbol_name});
                } else {
                    const local_ref = self.getScopedName(var_symbol_name);
                    return try std.fmt.allocPrint(self.allocator, "%{s}", .{local_ref});
                }
            },
            .MemberExpr => {
                const m = &node.data.MemberExpr;
                const base_ptr = try self.genLValue(m.object);
                const obj_type: types.Type = m.object.inferred_type orelse .{ .kind = .Any };

                if (obj_type.kind == .Struct and obj_type.struct_type != null) {
                    const st = obj_type.struct_type.?;
                    var field_idx: ?u32 = null;
                    for (st.fields, 0..) |sf, i| {
                        if (std.mem.eql(u8, sf.name, m.property)) {
                            field_idx = @as(u32, @intCast(i));
                            break;
                        }
                    }
                    if (field_idx) |idx| {
                        const ptr_temp = self.nextTemp();
                        const ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ptr_temp});
                        try writer.print("  {s} = getelementptr %{s}, ptr {s}, i32 0, i32 {d}\n", .{ ptr_name, st.name, base_ptr, idx });
                        return ptr_name;
                    }
                } else if (obj_type.kind == .Class and obj_type.class_type != null) {
                    const ct = obj_type.class_type.?;
                    var field_idx: ?u32 = null;
                    for (ct.fields, 0..) |cf, i| {
                        if (std.mem.eql(u8, cf.name, m.property)) {
                            field_idx = @intCast(i);
                            break;
                        }
                    }
                    if (field_idx) |idx| {
                        const loaded_ptr_temp = self.nextTemp();
                        const loaded_ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{loaded_ptr_temp});
                        try writer.print("  {s} = load ptr, ptr {s}\n", .{ loaded_ptr_name, base_ptr });

                        const ptr_temp = self.nextTemp();
                        const ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ptr_temp});
                        try writer.print("  {s} = getelementptr inbounds %{s}, ptr {s}, i32 0, i32 {d}\n", .{ ptr_name, ct.name, loaded_ptr_name, idx });
                        return ptr_name;
                    }
                }
                var fallback_s_name: ?[]const u8 = null;
                var fallback_f_idx: u32 = 0;
                if (m.object.node_type == .UnaryExpr and std.mem.eql(u8, m.object.data.UnaryExpr.operator, "deref")) {
                    const inner = m.object.data.UnaryExpr.operand;
                    if (inner.node_type == .CastExpr) {
                        var op_str = inner.data.CastExpr.target_type.name;
                        if (std.mem.eql(u8, op_str, "ptr")) {
                            if (inner.data.CastExpr.target_type.generics) |gens| {
                                if (gens.len > 0) {
                                    op_str = gens[0].name;
                                }
                            }
                        } else if (std.mem.startsWith(u8, op_str, "ptr[")) {
                            if (std.mem.indexOfScalar(u8, op_str, ']')) |end_idx| {
                                op_str = op_str[4..end_idx];
                            }
                        }
                        fallback_s_name = op_str;
                        if (std.mem.eql(u8, m.property, "cond")) fallback_f_idx = 0
                        else if (std.mem.eql(u8, m.property, "then_branch")) fallback_f_idx = 1
                        else if (std.mem.eql(u8, m.property, "else_branch")) fallback_f_idx = 2
                        else if (std.mem.eql(u8, m.property, "op")) fallback_f_idx = 0
                        else if (std.mem.eql(u8, m.property, "left")) fallback_f_idx = 1
                        else if (std.mem.eql(u8, m.property, "right")) fallback_f_idx = 2
                        else if (std.mem.eql(u8, m.property, "name")) fallback_f_idx = 0
                        else if (std.mem.eql(u8, m.property, "params")) fallback_f_idx = 1
                        else if (std.mem.eql(u8, m.property, "body")) fallback_f_idx = 2
                        else if (std.mem.eql(u8, m.property, "declarations")) fallback_f_idx = 0
                        else if (std.mem.eql(u8, m.property, "auto_drops")) fallback_f_idx = 1
                        else if (std.mem.eql(u8, m.property, "kind")) fallback_f_idx = 0
                        else if (std.mem.eql(u8, m.property, "span")) fallback_f_idx = 1
                        else if (std.mem.eql(u8, m.property, "module_name")) fallback_f_idx = 2
                        else if (std.mem.eql(u8, m.property, "inferred_type")) fallback_f_idx = 3
                        else if (std.mem.eql(u8, m.property, "data")) fallback_f_idx = 4;
                    }
                }
                if (fallback_s_name) |sname| {
                    const ptr_temp = self.nextTemp();
                    const ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ptr_temp});
                    try writer.print("  {s} = getelementptr inbounds %{s}, ptr {s}, i32 0, i32 {d}\n", .{ ptr_name, sname, base_ptr, fallback_f_idx });
                    return ptr_name;
                }
                std.debug.print("Unsupported left hand side for assignment: prop={s}, obj_type={any}\n", .{ m.property, obj_type.kind });
                return error.UnsupportedNode;
            },
            .UnaryExpr => {
                const u = &node.data.UnaryExpr;
                if (std.mem.eql(u8, u.operator, "deref")) {
                    // deref p => the pointer value IS the address to store into
                    const ptr_val = try self.genExpr(u.operand);
                    return ptr_val;
                }
                std.debug.print("Unsupported unary operator for LValue generation: {s}\n", .{u.operator});
                return error.UnsupportedNode;
            },
            .IndexExpr => {
                const idx = &node.data.IndexExpr;
                const obj_val = try self.genExpr(idx.object);
                const index_val = try self.genExpr(idx.index);

                const obj_type = idx.object.inferred_type orelse types.Type{ .kind = .Any };

                // Coerce index to i64 for GEP
                const index_t = idx.index.inferred_type orelse types.Type{ .kind = .I32 };
                const index_llvm = typeToLLVM(self.allocator, index_t);
                const index_i64 = try self.coerceType(index_val, index_llvm, "i64");

                if (obj_type.kind == .List) {
                    var inner_type = types.Type{ .kind = .Any };
                    if (obj_type.payload) |p| inner_type = p.*;
                    const inner_llvm = typeToLLVM(self.allocator, inner_type);
                    
                    const ptr_temp = self.nextTemp();
                    try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 0\n", .{ ptr_temp, obj_val });
                    
                    const elem_ptr = self.nextTemp();
                    try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr %t.{d}, i64 {s}\n", .{ elem_ptr, inner_llvm, ptr_temp, index_i64 });
                    
                    return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{elem_ptr});
                } else if (obj_type.kind == .String) {
                    const ptr_temp = self.nextTemp();
                    try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 0\n", .{ ptr_temp, obj_val });
                    
                    const elem_ptr = self.nextTemp();
                    try writer.print("  %t.{d} = getelementptr inbounds i8, ptr %t.{d}, i64 {s}\n", .{ elem_ptr, ptr_temp, index_i64 });
                    
                    return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{elem_ptr});
                } else if (obj_type.kind == .RawPointer) {
                    var inner_type = types.Type{ .kind = .U8 };
                    if (obj_type.payload) |p| inner_type = p.*;
                    const inner_llvm = typeToLLVM(self.allocator, inner_type);
                    
                    const elem_ptr = self.nextTemp();
                    try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr {s}, i64 {s}\n", .{ elem_ptr, inner_llvm, obj_val, index_i64 });
                    
                    return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{elem_ptr});
                } else if (obj_type.kind == .Dict) {
                    var k_type = types.Type{ .kind = .Any };
                    var v_type = types.Type{ .kind = .Any };
                    var k_kind: types.TypeKind = .I32;
                    if (obj_type.tuple_types) |tt| {
                        if (tt.len == 2) {
                            k_type = tt[0];
                            v_type = tt[1];
                            k_kind = tt[0].kind;
                        }
                    }
                    const k_llvm = typeToLLVM(self.allocator, k_type);
                    
                    const ptr_temp = self.nextTemp();
                    try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 0\n", .{ ptr_temp, obj_val });
                    
                    const k_size_ptr = self.nextTemp();
                    const k_size_int = self.nextTemp();
                    try writer.print("  %t.{d} = getelementptr {s}, ptr null, i32 1\n", .{ k_size_ptr, k_llvm });
                    try writer.print("  %t.{d} = ptrtoint ptr %t.{d} to i32\n", .{ k_size_int, k_size_ptr });
                    
                    const hash_temp = self.nextTemp();
                    const k_alloc = self.nextTemp();
                    try writer.print("  %t.{d} = alloca {s}\n", .{ k_alloc, k_llvm });
                    try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ k_llvm, index_val, k_alloc });
                    
                    if (isStringLikeType(k_type)) {
                        const str_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ str_ptr, k_llvm, index_val });
                        const str_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ str_len, k_llvm, index_val });
                        try writer.print("  %t.{d} = call i32 @__mantiq_hash_string(ptr %t.{d}, i64 %t.{d})\n", .{ hash_temp, str_ptr, str_len });
                    } else {
                        const byte_len = self.nextTemp();
                        try writer.print("  %t.{d} = zext i32 %t.{d} to i64\n", .{ byte_len, k_size_int });
                        try writer.print("  %t.{d} = call i32 @__mantiq_hash_bytes(ptr %t.{d}, i64 %t.{d})\n", .{ hash_temp, k_alloc, byte_len });
                    }
                    
                    const res_ptr = self.nextTemp();
                    try writer.print("  %t.{d} = call ptr @__mantiq_dict_get_or_insert(ptr %t.{d}, ptr %t.{d}, i32 %t.{d})\n", .{ res_ptr, ptr_temp, k_alloc, hash_temp });
                    return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{res_ptr});
                }
                
                return error.UnsupportedNode;
            },
            else => {
                std.debug.print("Unsupported node type for LValue generation: {}, span=({d}:{d})-({d}:{d})\n", .{node.node_type, node.span.start_row, node.span.start_col, node.span.end_row, node.span.end_col});
                if (node.node_type == .CallExpr) {
                    const c = &node.data.CallExpr;
                    std.debug.print("  CallExpr callee node_type: {}, arguments count: {d}\n", .{c.callee.node_type, c.arguments.len});
                    if (c.callee.node_type == .Identifier) {
                        std.debug.print("  Callee Identifier name: {s}\n", .{c.callee.data.Identifier.name});
                    } else if (c.callee.node_type == .MemberExpr) {
                        const m = &c.callee.data.MemberExpr;
                        std.debug.print("  Callee MemberExpr property: {s}, object node_type: {}\n", .{m.property, m.object.node_type});
                    }
                }
                return error.UnsupportedNode;
            },
        }
    }

    fn isFat3(self: *LLVMCodegen, ty: types.Type) bool {
        _ = self;
        if (ty.kind == .String or ty.kind == .List or ty.kind == .Dict) return true;
        if (ty.kind == .Struct and ty.struct_type != null) {
            if (std.mem.endsWith(u8, ty.struct_type.?.name, "String")) return true;
        }
        return false;
    }

    fn ensureI32(self: *LLVMCodegen, writer: anytype, val: []const u8, ty: types.Type) ![]const u8 {
        const llvm_t = typeToLLVM(self.allocator, ty);
        if (std.mem.eql(u8, llvm_t, "i32")) {
            return val;
        } else if (std.mem.eql(u8, llvm_t, "i64")) {
            const temp = self.nextTemp();
            try writer.print("  %t.{d} = trunc i64 {s} to i32\n", .{ temp, val });
            return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
        }
        return val;
    }

    fn printConstString(self: *LLVMCodegen, writer: anytype, str: []const u8) !void {
        const str_id = self.string_counter;
        self.string_counter += 1;
        const global_name = try std.fmt.allocPrint(self.allocator, "@.str.print.{d}", .{str_id});
        try self.type_out.writer().print("{s} = private unnamed_addr constant [{d} x i8] c\"{s}\\00\"\n", .{ global_name, str.len + 1, str });
        try writer.print("  call void @mantiq_print_cstr(ptr {s})\n", .{ global_name });
    }

    fn printValue(self: *LLVMCodegen, writer: anytype, val: []const u8, ty: types.Type) !void {
        const llvm_t = typeToLLVM(self.allocator, ty);
        if (ty.kind == .Enum) {
            const ext_temp = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ ext_temp, llvm_t, val });
            const temp_str = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ext_temp});
            try writer.print("  call void @mantiq_print_i32(i32 {s})\n", .{temp_str});
        } else if (std.mem.eql(u8, llvm_t, "i32")) {
            try writer.print("  call void @mantiq_print_i32(i32 {s})\n", .{val});
        } else if (std.mem.eql(u8, llvm_t, "i64")) {
            const temp = self.nextTemp();
            try writer.print("  %t.{d} = trunc i64 {s} to i32\n", .{ temp, val });
            const temp_str = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
            try writer.print("  call void @mantiq_print_i32(i32 {s})\n", .{temp_str});
        } else if (std.mem.eql(u8, llvm_t, "float")) {
            try writer.print("  call void @mantiq_print_float(float {s})\n", .{val});
        } else if (std.mem.eql(u8, llvm_t, "double")) {
            const temp = self.nextTemp();
            try writer.print("  %t.{d} = fptrunc double {s} to float\n", .{ temp, val });
            const temp_str = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
            try writer.print("  call void @mantiq_print_float(float {s})\n", .{temp_str});
        } else if (std.mem.eql(u8, llvm_t, "bfloat")) {
            const temp = self.nextTemp();
            try writer.print("  %t.{d} = fpext bfloat {s} to float\n", .{ temp, val });
            const temp_str = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
            try writer.print("  call void @mantiq_print_float(float {s})\n", .{temp_str});
        } else if (std.mem.eql(u8, llvm_t, "i8")) {
            const ext_temp = self.nextTemp();
            try writer.print("  %t.{d} = zext i8 {s} to i32\n", .{ ext_temp, val });
            try writer.print("  call void @mantiq_print_bool(i32 %t.{d})\n", .{ext_temp});
        } else if (ty.kind == .CStr) {
            try writer.print("  call void @mantiq_print_cstr(ptr {s})\n", .{val});
        } else if (ty.kind == .String or ty.kind == .Utf8Str or ty.kind == .AsciiStr or ty.kind == .WebStr or ty.kind == .RangeStr or ((ty.kind == .Struct and ty.struct_type != null and std.mem.endsWith(u8, ty.struct_type.?.name, "String")) or std.mem.endsWith(u8, llvm_t, "String") or std.mem.eql(u8, llvm_t, "%mantiq_std_string_String") or std.mem.eql(u8, llvm_t, "{ ptr, i64, i64 }")) and !std.mem.eql(u8, llvm_t, "ptr")) {
            const ptr_temp = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ ptr_temp, llvm_t, val });
            const len_temp = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ len_temp, llvm_t, val });
            try writer.print("  call void @mantiq_print_str(ptr %t.{d}, i64 %t.{d})\n", .{ ptr_temp, len_temp });
        } else if (ty.kind == .Dict) {
            var k_type = types.Type{ .kind = .Any };
            var v_type = types.Type{ .kind = .Any };
            if (ty.tuple_types) |tt| {
                if (tt.len == 2) {
                    k_type = tt[0];
                    v_type = tt[1];
                }
            }
            const k_llvm = typeToLLVM(self.allocator, k_type);
            const v_llvm = typeToLLVM(self.allocator, v_type);

            const ptr_temp = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ ptr_temp, llvm_t, val });
            
            const dict_struct = self.nextTemp();
            try writer.print("  %t.{d} = load %MantiqDict, ptr %t.{d}\n", .{ dict_struct, ptr_temp });
            const keys_ptr = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue %MantiqDict %t.{d}, 0\n", .{ keys_ptr, dict_struct });
            const values_ptr = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue %MantiqDict %t.{d}, 1\n", .{ values_ptr, dict_struct });
            const occ_ptr = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue %MantiqDict %t.{d}, 3\n", .{ occ_ptr, dict_struct });
            const capacity = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue %MantiqDict %t.{d}, 4\n", .{ capacity, dict_struct });
            const count = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue %MantiqDict %t.{d}, 5\n", .{ count, dict_struct });
            
            try writer.print("  call void @mantiq_print_dict_start()\n", .{});
            
            const loop_id = self.temp_counter;
            self.temp_counter += 1;
            const loop_cond = try std.fmt.allocPrint(self.allocator, "dict.print.cond.{d}", .{loop_id});
            const loop_body = try std.fmt.allocPrint(self.allocator, "dict.print.body.{d}", .{loop_id});
            const loop_end = try std.fmt.allocPrint(self.allocator, "dict.print.end.{d}", .{loop_id});
            const loop_inc = try std.fmt.allocPrint(self.allocator, "dict.print.inc.{d}", .{loop_id});
            const loop_occ = try std.fmt.allocPrint(self.allocator, "dict.print.occ.{d}", .{loop_id});

            const i_temp = self.nextTemp();
            try writer.print("  %t.{d} = alloca i32\n", .{i_temp});
            try writer.print("  store i32 0, ptr %t.{d}\n", .{i_temp});
            
            const printed_temp = self.nextTemp();
            try writer.print("  %t.{d} = alloca i32\n", .{printed_temp});
            try writer.print("  store i32 0, ptr %t.{d}\n", .{printed_temp});
            
            try writer.print("  br label %{s}\n", .{loop_cond});
            
            try writer.print("{s}:\n", .{loop_cond});
            const curr_i = self.nextTemp();
            try writer.print("  %t.{d} = load i32, ptr %t.{d}\n", .{ curr_i, i_temp });
            const cmp = self.nextTemp();
            try writer.print("  %t.{d} = icmp slt i32 %t.{d}, %t.{d}\n", .{ cmp, curr_i, capacity });
            try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cmp, loop_body, loop_end });
            
            try writer.print("{s}:\n", .{loop_body});
            const occ_gep = self.nextTemp();
            try writer.print("  %t.{d} = getelementptr inbounds i8, ptr %t.{d}, i32 %t.{d}\n", .{ occ_gep, occ_ptr, curr_i });
            const occ_val = self.nextTemp();
            try writer.print("  %t.{d} = load i8, ptr %t.{d}\n", .{ occ_val, occ_gep });
            const is_occ = self.nextTemp();
            try writer.print("  %t.{d} = icmp eq i8 %t.{d}, 1\n", .{ is_occ, occ_val });
            try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ is_occ, loop_occ, loop_inc });
            
            try writer.print("{s}:\n", .{loop_occ});
            const k_gep = self.nextTemp();
            try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr %t.{d}, i32 %t.{d}\n", .{ k_gep, k_llvm, keys_ptr, curr_i });
            const k_val = self.nextTemp();
            try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ k_val, k_llvm, k_gep });
            const k_val_str = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{k_val});
            try self.printValue(writer, k_val_str, k_type);
            
            try writer.print("  call void @mantiq_print_colon()\n", .{});
            
            const v_gep = self.nextTemp();
            try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr %t.{d}, i32 %t.{d}\n", .{ v_gep, v_llvm, values_ptr, curr_i });
            const v_val = self.nextTemp();
            try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ v_val, v_llvm, v_gep });
            const v_val_str = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{v_val});
            try self.printValue(writer, v_val_str, v_type);
            
            const curr_p = self.nextTemp();
            try writer.print("  %t.{d} = load i32, ptr %t.{d}\n", .{ curr_p, printed_temp });
            const next_p = self.nextTemp();
            try writer.print("  %t.{d} = add i32 %t.{d}, 1\n", .{ next_p, curr_p });
            try writer.print("  store i32 %t.{d}, ptr %t.{d}\n", .{ next_p, printed_temp });
            
            const cmp_comma = self.nextTemp();
            try writer.print("  %t.{d} = icmp slt i32 %t.{d}, %t.{d}\n", .{ cmp_comma, next_p, count });
            const comma_block = try std.fmt.allocPrint(self.allocator, "dict.print.comma.{d}", .{loop_id});
            try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cmp_comma, comma_block, loop_inc });
            
            try writer.print("{s}:\n", .{comma_block});
            try writer.print("  call void @mantiq_print_comma()\n", .{});
            try writer.print("  br label %{s}\n", .{loop_inc});
            
            try writer.print("{s}:\n", .{loop_inc});
            const next_i = self.nextTemp();
            try writer.print("  %t.{d} = add i32 %t.{d}, 1\n", .{ next_i, curr_i });
            try writer.print("  store i32 %t.{d}, ptr %t.{d}\n", .{ next_i, i_temp });
            try writer.print("  br label %{s}\n", .{loop_cond});
            
            try writer.print("{s}:\n", .{loop_end});
            try writer.print("  call void @mantiq_print_dict_end()\n", .{});
        } else if (ty.kind == .List) {
            var inner_type = types.Type{ .kind = .Any };
            if (ty.payload) |p| {
                inner_type = p.*;
            }
            const inner_llvm = typeToLLVM(self.allocator, inner_type);

            const ptr_temp = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ ptr_temp, llvm_t, val });
            const len_temp = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ len_temp, llvm_t, val });
            
            try writer.print("  call void @mantiq_print_list_start()\n", .{});
            
            const loop_id = self.temp_counter;
            self.temp_counter += 1;
            const loop_cond = try std.fmt.allocPrint(self.allocator, "list.print.cond.{d}", .{loop_id});
            const loop_body = try std.fmt.allocPrint(self.allocator, "list.print.body.{d}", .{loop_id});
            const loop_end = try std.fmt.allocPrint(self.allocator, "list.print.end.{d}", .{loop_id});

            const i_temp = self.nextTemp();
            try writer.print("  %t.{d} = alloca i64\n", .{i_temp});
            try writer.print("  store i64 0, ptr %t.{d}\n", .{i_temp});
            try writer.print("  br label %{s}\n", .{loop_cond});
            
            try writer.print("{s}:\n", .{loop_cond});
            const curr_i = self.nextTemp();
            try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ curr_i, i_temp });
            const cmp = self.nextTemp();
            try writer.print("  %t.{d} = icmp slt i64 %t.{d}, %t.{d}\n", .{ cmp, curr_i, len_temp });
            try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cmp, loop_body, loop_end });
            
            try writer.print("{s}:\n", .{loop_body});
            const elem_ptr = self.nextTemp();
            try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr %t.{d}, i64 %t.{d}\n", .{ elem_ptr, inner_llvm, ptr_temp, curr_i });
            
            const item_val = self.nextTemp();
            try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ item_val, inner_llvm, elem_ptr });
            const item_val_str = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{item_val});
            try self.printValue(writer, item_val_str, inner_type);
            
            const next_i = self.nextTemp();
            try writer.print("  %t.{d} = add i64 %t.{d}, 1\n", .{ next_i, curr_i });
            try writer.print("  store i64 %t.{d}, ptr %t.{d}\n", .{ next_i, i_temp });
            
            const cmp_comma = self.nextTemp();
            try writer.print("  %t.{d} = icmp slt i64 %t.{d}, %t.{d}\n", .{ cmp_comma, next_i, len_temp });
            const comma_block = try std.fmt.allocPrint(self.allocator, "list.print.comma.{d}", .{loop_id});
            const no_comma_block = try std.fmt.allocPrint(self.allocator, "list.print.nocomma.{d}", .{loop_id});
            try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cmp_comma, comma_block, no_comma_block });
            
            try writer.print("{s}:\n", .{comma_block});
            try writer.print("  call void @mantiq_print_comma()\n", .{});
            try writer.print("  br label %{s}\n", .{no_comma_block});
            
            try writer.print("{s}:\n", .{no_comma_block});
            try writer.print("  br label %{s}\n", .{loop_cond});
            
            try writer.print("{s}:\n", .{loop_end});
            try writer.print("  call void @mantiq_print_list_end()\n", .{});
        } else if (ty.kind == .Option) {
            const disc_temp = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ disc_temp, llvm_t, val });
            const cond = self.nextTemp();
            try writer.print("  %t.{d} = icmp eq i8 %t.{d}, 0\n", .{ cond, disc_temp });
            
            const label_id = self.temp_counter;
            self.temp_counter += 1;
            const label_empty = try std.fmt.allocPrint(self.allocator, "opt.print.empty.{d}", .{label_id});
            const label_some = try std.fmt.allocPrint(self.allocator, "opt.print.some.{d}", .{label_id});
            const label_end = try std.fmt.allocPrint(self.allocator, "opt.print.end.{d}", .{label_id});
            
            try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cond, label_empty, label_some });
            
            // Empty branch
            try writer.print("{s}:\n", .{label_empty});
            try self.printConstString(writer, "Empty");
            try writer.print("  br label %{s}\n", .{label_end});
            
            // Some branch
            try writer.print("{s}:\n", .{label_some});
            try self.printConstString(writer, "Some(");
            
            const payload_ptr = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ payload_ptr, llvm_t, val });
            
            var payload_type = types.Type{ .kind = .Any };
            if (ty.payload) |p| {
                payload_type = p.*;
            }
            const payload_llvm = typeToLLVM(self.allocator, payload_type);
            const payload_val = self.nextTemp();
            try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ payload_val, payload_llvm, payload_ptr });
            const payload_val_str = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{payload_val});
            
            try self.printValue(writer, payload_val_str, payload_type);
            try self.printConstString(writer, ")");
            try writer.print("  br label %{s}\n", .{label_end});
            
            // End
            try writer.print("{s}:\n", .{label_end});
        } else if (ty.kind == .Result) {
            const disc_temp = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ disc_temp, llvm_t, val });
            const cond = self.nextTemp();
            try writer.print("  %t.{d} = icmp eq i8 %t.{d}, 0\n", .{ cond, disc_temp });
            
            const label_id = self.temp_counter;
            self.temp_counter += 1;
            const label_ok = try std.fmt.allocPrint(self.allocator, "res.print.ok.{d}", .{label_id});
            const label_err = try std.fmt.allocPrint(self.allocator, "res.print.err.{d}", .{label_id});
            const label_end = try std.fmt.allocPrint(self.allocator, "res.print.end.{d}", .{label_id});
            
            try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cond, label_ok, label_err });
            
            // Ok branch
            try writer.print("{s}:\n", .{label_ok});
            try self.printConstString(writer, "Ok(");
            
            const payload_ptr = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ payload_ptr, llvm_t, val });
            
            var ok_type = types.Type{ .kind = .Any };
            if (ty.payload) |p| {
                ok_type = p.*;
            }
            const ok_llvm = typeToLLVM(self.allocator, ok_type);
            const ok_val = self.nextTemp();
            try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ ok_val, ok_llvm, payload_ptr });
            const ok_val_str = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ok_val});
            
            try self.printValue(writer, ok_val_str, ok_type);
            try self.printConstString(writer, ")");
            try writer.print("  br label %{s}\n", .{label_end});
            
            // Err branch
            try writer.print("{s}:\n", .{label_err});
            try self.printConstString(writer, "Err(");
            
            const err_ptr = self.nextTemp();
            try writer.print("  %t.{d} = extractvalue {s} {s}, 2\n", .{ err_ptr, llvm_t, val });
            
            const err_type = types.Type{ .kind = .I32 };
            const err_llvm = typeToLLVM(self.allocator, err_type);
            const err_val = self.nextTemp();
            try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ err_val, err_llvm, err_ptr });
            const err_val_str = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{err_val});
            
            try self.printValue(writer, err_val_str, err_type);
            try self.printConstString(writer, ")");
            try writer.print("  br label %{s}\n", .{label_end});
            
            // End
            try writer.print("{s}:\n", .{label_end});
        } else if (ty.kind == .Function or ty.kind == .Closure) {
            // no-op for print
        } else if (ty.kind == .Any) {
            // no-op for print
        } else if (ty.kind == .Struct or ty.kind == .Union) {
            // no-op for print
        } else {
            // no-op for print
        }
    }

    fn genExpr(self: *LLVMCodegen, node: *ast.Node) CodegenError![]const u8 {
        @setEvalBranchQuota(50000);
        const writer = self.out.writer();
        try writer.print("  ; Span: [row: {d}, col: {d}] - Expr: {s}\n", .{ node.span.start_row + 1, node.span.start_col + 1, @tagName(node.node_type) });
        switch (node.data) {
            .BlockStmt => |*b| {
                try self.pushScope();
                defer self.popScope();
                var last_val: []const u8 = "null";
                for (b.statements, 0..) |stmt, i| {
                    if (i == b.statements.len - 1) {
                        switch (stmt.node_type) {
                            .VarDecl, .FunDecl, .ClassDecl, .StructDecl, .InterfaceDecl, .ReturnStmt, .WhileStmt, .ForStmt, .ThrowStmt, .ImportDecl, .LinkDecl => {
                                try self.genNode(stmt);
                            },
                            else => {
                                last_val = try self.genExpr(stmt);
                            },
                        }
                    } else {
                        try self.genNode(stmt);
                    }
                }
                if (b.auto_drops) |drops| {
                    try self.genAutoDrops(drops);
                }
                return last_val;
            },
            .WhileStmt => |*w| {
                const cmp_temp = self.nextTemp();
                const cond_label = try std.fmt.allocPrint(self.allocator, "while.cond.{d}", .{cmp_temp});
                const body_label = try std.fmt.allocPrint(self.allocator, "while.body.{d}", .{cmp_temp});
                const end_label = try std.fmt.allocPrint(self.allocator, "while.end.{d}", .{cmp_temp});

                // Jump to condition
                try writer.print("  br label %{s}\n", .{cond_label});
                try writer.print("{s}:\n", .{cond_label});

                // Evaluate condition
                const cond_val = try self.genExpr(w.condition);
                const cmp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{self.nextTemp()});
                try writer.print("  {s} = icmp ne i8 {s}, 0\n", .{ cmp_name, cond_val });
                try self.flushStatementTemps();
                try writer.print("  br i1 {s}, label %{s}, label %{s}\n", .{ cmp_name, body_label, end_label });

                // Evaluate body
                try writer.print("{s}:\n", .{body_label});

                const prev_cond = self.active_loop_cond;
                const prev_exit = self.active_loop_exit;
                self.active_loop_cond = cond_label;
                self.active_loop_exit = end_label;

                _ = try self.genExpr(w.body);

                self.active_loop_cond = prev_cond;
                self.active_loop_exit = prev_exit;

                // Loop back to condition
                try writer.print("  br label %{s}\n", .{cond_label});

                // End block
                try writer.print("{s}:\n", .{end_label});
                return "null";
            },
            .BreakStmt => {
                if (self.active_loop_exit.len == 0) {
                    return error.UnsupportedNode;
                }
                try writer.print("  br label %{s}\n", .{self.active_loop_exit});

                // Emitting a dead block to prevent malformed IR if statements follow
                const dead_temp = self.nextTemp();
                try writer.print("dead.block.{d}:\n", .{dead_temp});
                return "null";
            },
            .ContinueStmt => {
                if (self.active_loop_cond.len == 0) {
                    return error.UnsupportedNode;
                }
                try writer.print("  br label %{s}\n", .{self.active_loop_cond});

                // Emitting a dead block
                const dead_temp = self.nextTemp();
                try writer.print("dead.block.{d}:\n", .{dead_temp});
                return "null";
            },
            .PassStmt => {
                return "null";
            },
            .WithStmt => |*w| {
                const expr_val = try self.genExpr(w.expr);
                const expr_t = typeToLLVM(self.allocator, w.expr.inferred_type orelse .{ .kind = .Any });
                const name = w.var_name.?;
                if (!self.local_allocas.contains(name)) {
                    try writer.print("  %{s} = alloca {s}\n", .{ name, expr_t });
                    try self.local_allocas.put(name, true);
                }
                try writer.print("  store {s} {s}, ptr %{s}\n", .{ expr_t, expr_val, name });
                
                const body_val = try self.genExpr(w.body);
                
                if (w.auto_drops) |drops| {
                    try self.genAutoDrops(drops);
                }
                
                return body_val;
            },
            .IfStmt => |*i| {
                const cond_val = try self.genExpr(i.condition);

                const cmp_temp = self.nextTemp();
                const cmp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{cmp_temp});

                try writer.print("  {s} = icmp ne i8 {s}, 0\n", .{ cmp_name, cond_val });
                try self.flushStatementTemps();

                const then_label = try std.fmt.allocPrint(self.allocator, "if.then.{d}", .{cmp_temp});
                const else_label = try std.fmt.allocPrint(self.allocator, "if.else.{d}", .{cmp_temp});
                const merge_label = try std.fmt.allocPrint(self.allocator, "if.end.{d}", .{cmp_temp});

                const ret_type = typeToLLVM(self.allocator, node.inferred_type orelse .{ .kind = .Unknown });
                const is_void = std.mem.eql(u8, ret_type, "void") or std.mem.eql(u8, ret_type, "null") or node.inferred_type.?.kind == .Unknown;

                var res_alloc: []const u8 = "null";
                if (!is_void) {
                    const alloc_temp = self.nextTemp();
                    res_alloc = try std.fmt.allocPrint(self.allocator, "%res_alloc.{d}", .{alloc_temp});
                    try writer.print("  {s} = alloca {s}\n", .{ res_alloc, ret_type });
                }

                try writer.print("  br i1 {s}, label %{s}, label %{s}\n", .{ cmp_name, then_label, else_label });

                // Then block
                try writer.print("{s}:\n", .{then_label});
                const then_val = try self.genExpr(i.then_branch);
                if (!is_void and !std.mem.eql(u8, then_val, "null")) {
                    try writer.print("  store {s} {s}, ptr {s}\n", .{ ret_type, then_val, res_alloc });
                }
                try writer.print("  br label %{s}\n", .{merge_label});

                // Else block
                try writer.print("{s}:\n", .{else_label});
                if (i.else_branch) |eb| {
                    const else_val = try self.genExpr(eb);
                    if (!is_void and !std.mem.eql(u8, else_val, "null")) {
                        try writer.print("  store {s} {s}, ptr {s}\n", .{ ret_type, else_val, res_alloc });
                    }
                }
                try writer.print("  br label %{s}\n", .{merge_label});

                // Merge block
                try writer.print("{s}:\n", .{merge_label});

                if (is_void) {
                    return "null";
                } else {
                    const res_temp = self.nextTemp();
                    const res_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{res_temp});
                    try writer.print("  {s} = load {s}, ptr {s}\n", .{ res_name, ret_type, res_alloc });
                    return res_name;
                }
            },
            .NumberLiteral => |*n| {
                var buf = std.ArrayList(u8).init(self.allocator);
                if (node.inferred_type.?.kind == .F64) {
                    const bits = @as(u64, @bitCast(@as(f64, n.value)));
                    try std.fmt.format(buf.writer(), "0x{X:0>16}", .{bits});
                } else if (node.inferred_type.?.kind == .F32 or node.inferred_type.?.kind == .BFloat16) {
                    const val_f32 = @as(f32, @floatCast(n.value));
                    const bits = @as(u64, @bitCast(@as(f64, val_f32)));
                    try std.fmt.format(buf.writer(), "0x{X:0>16}", .{bits});
                } else {
                    try std.fmt.format(buf.writer(), "{d}", .{@as(i64, @intFromFloat(n.value))});
                }
                return try buf.toOwnedSlice();
            },
            .StringLiteral => |*s| {
                if (self.is_global) {
                    return "undef"; // Global strings would need global constants
                }

                // Strip surrounding quotes from the raw source text
                var raw = s.value;
                if (raw.len >= 2) {
                    const first = raw[0];
                    const last = raw[raw.len - 1];
                    if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
                        raw = raw[1 .. raw.len - 1];
                    }
                    // Handle triple-quoted strings (""" or ''')
                    if (raw.len >= 4 and first == '"' and raw[0] == '"' and raw[1] == '"') {
                        if (raw[raw.len - 1] == '"' and raw[raw.len - 2] == '"') {
                            raw = raw[2 .. raw.len - 2];
                        }
                    }
                }
                const unescaped = try unescapeString(self.allocator, raw);
                const len = unescaped.len;

                // Emit a global constant for the string data
                const str_id = self.string_counter;
                self.string_counter += 1;
                const global_name = try std.fmt.allocPrint(self.allocator, "@.str.{d}", .{str_id});

                // Escape string content for LLVM IR
                var escaped = std.ArrayList(u8).init(self.allocator);
                for (unescaped) |byte| {
                    if (byte == '\\') {
                        try escaped.appendSlice("\\5C");
                    } else if (byte == '"') {
                        try escaped.appendSlice("\\22");
                    } else if (byte == '\n') {
                        try escaped.appendSlice("\\0A");
                    } else if (byte == '\r') {
                        try escaped.appendSlice("\\0D");
                    } else if (byte == '\t') {
                        try escaped.appendSlice("\\09");
                    } else if (byte < 0x20 or byte > 0x7E) {
                        const hex = "0123456789ABCDEF";
                        try escaped.append('\\');
                        try escaped.append(hex[byte >> 4]);
                        try escaped.append(hex[byte & 0x0F]);
                    } else {
                        try escaped.append(byte);
                    }
                }
                const escaped_str = try escaped.toOwnedSlice();

                // Write the global string constant to the type section (it goes before functions)
                try self.type_out.writer().print("{s} = private unnamed_addr constant [{d} x i8] c\"{s}\\00\"\n", .{ global_name, len + 1, escaped_str });

                // Construct fat pointer { ptr, i64 }
                const fat_temp1 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {{ ptr, i64 }} undef, ptr {s}, 0\n", .{ fat_temp1, global_name });
                const fat_temp2 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {{ ptr, i64 }} %t.{d}, i64 {d}, 1\n", .{ fat_temp2, fat_temp1, len });

                const fat_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp2});
                return fat_name;
            },
            .InterpolatedString => |*is| {
                if (is.parts.len == 0) {
                    const fat_temp1 = self.nextTemp();
                    try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} undef, ptr null, 0\n", .{fat_temp1});
                    const fat_temp2 = self.nextTemp();
                    try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 0, 1\n", .{ fat_temp2, fat_temp1 });
                    const fat_temp3 = self.nextTemp();
                    try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 0, 2\n", .{ fat_temp3, fat_temp2 });
                    return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp3});
                }
                
                var accum_ptr: []const u8 = "null";
                var accum_len: []const u8 = "0";

                for (is.parts) |part| {
                    const part_val = try self.genExpr(part);
                    const part_type = part.inferred_type orelse types.Type{ .kind = .Any };
                    
                    var new_ptr: []const u8 = undefined;
                    var new_len: []const u8 = undefined;

                    const p_llvm = typeToLLVM(self.allocator, part_type);
                    if (part_type.kind == .String or part_type.kind == .AsciiStr or part_type.kind == .Utf8Str or part_type.kind == .WebStr or part_type.kind == .RangeStr) {
                        const ptr_temp = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ ptr_temp, p_llvm, part_val });
                        new_ptr = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ptr_temp});

                        const len_temp = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ len_temp, p_llvm, part_val });
                        new_len = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{len_temp});
                    } else if (part_type.kind == .I32) {
                        const len_alloca = self.nextTemp();
                        try writer.print("  %t.{d} = alloca i64\n", .{len_alloca});
                        const str_temp = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_i32_to_str(i32 {s}, ptr %t.{d})\n", .{ str_temp, part_val, len_alloca });
                        new_ptr = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{str_temp});
                        
                        const len_load = self.nextTemp();
                        try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ len_load, len_alloca });
                        new_len = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{len_load});
                    } else if (part_type.kind == .F32) {
                        const len_alloca = self.nextTemp();
                        try writer.print("  %t.{d} = alloca i64\n", .{len_alloca});
                        const str_temp = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_float_to_str(float {s}, ptr %t.{d})\n", .{ str_temp, part_val, len_alloca });
                        new_ptr = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{str_temp});
                        
                        const len_load = self.nextTemp();
                        try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ len_load, len_alloca });
                        new_len = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{len_load});
                    } else if (part_type.kind == .Boolean) {
                        const i32_temp = self.nextTemp();
                        try writer.print("  %t.{d} = zext i8 {s} to i32\n", .{ i32_temp, part_val });
                        const i32_val = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{i32_temp});

                        const len_alloca = self.nextTemp();
                        try writer.print("  %t.{d} = alloca i64\n", .{len_alloca});
                        const str_temp = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_bool_to_str(i32 {s}, ptr %t.{d})\n", .{ str_temp, i32_val, len_alloca });
                        new_ptr = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{str_temp});
                        
                        const len_load = self.nextTemp();
                        try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ len_load, len_alloca });
                        new_len = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{len_load});
                    } else if (part_type.kind == .I64 or part_type.kind == .U64 or part_type.kind == .ISize or part_type.kind == .USize) {
                        const len_alloca = self.nextTemp();
                        try writer.print("  %t.{d} = alloca i64\n", .{len_alloca});
                        const str_temp = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_i64_to_str(i64 {s}, ptr %t.{d})\n", .{ str_temp, part_val, len_alloca });
                        new_ptr = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{str_temp});
                        
                        const len_load = self.nextTemp();
                        try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ len_load, len_alloca });
                        new_len = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{len_load});
                    } else {
                        new_ptr = part_val;
                        if (!std.mem.eql(u8, p_llvm, "ptr")) {
                            const ptr_temp = self.nextTemp();
                            try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ ptr_temp, p_llvm, part_val });
                            new_ptr = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ptr_temp});
                        }
                        const len_temp = self.nextTemp();
                        try writer.print("  %t.{d} = call i64 @strlen(ptr {s})\n", .{ len_temp, new_ptr });
                        new_len = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{len_temp});
                    }
                    
                    const concat_temp = self.nextTemp();
                    try writer.print("  %t.{d} = call ptr @mantiq_concat_str(ptr {s}, i64 {s}, ptr {s}, i64 {s})\n", .{ concat_temp, accum_ptr, accum_len, new_ptr, new_len });
                    
                    const add_temp = self.nextTemp();
                    try writer.print("  %t.{d} = add i64 {s}, {s}\n", .{ add_temp, accum_len, new_len });
                    
                    accum_ptr = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{concat_temp});
                    accum_len = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{add_temp});
                }
                
                const fat_temp1 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} undef, ptr {s}, 0\n", .{ fat_temp1, accum_ptr });
                const fat_temp2 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 {s}, 1\n", .{ fat_temp2, fat_temp1, accum_len });
                const fat_temp3 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 {s}, 2\n", .{ fat_temp3, fat_temp2, accum_len });
                return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp3});
            },
            .BooleanLiteral => |*b| {
                if (b.value) return "1";
                return "0";
            },
            .KeywordArg => {
                unreachable; // KeywordArgs are flattened during typechecking
            },
            .Identifier => |*id| {
                if (std.mem.eql(u8, id.name, "Empty")) {
                    const fat_temp = self.nextTemp();
                    const fat_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp});
                    try writer.print("  {s} = insertvalue {{ i8, ptr }} undef, i8 0, 0\n", .{fat_name});
                    const fat_temp2 = self.nextTemp();
                    const fat_name2 = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp2});
                    try writer.print("  {s} = insertvalue {{ i8, ptr }} {s}, ptr null, 1\n", .{ fat_name2, fat_name });
                    return fat_name2;
                } else if (std.mem.eql(u8, id.name, "None")) {
                    return "null";
                } else if (std.mem.eql(u8, id.name, "stdin")) {
                    return "0";
                } else if (std.mem.eql(u8, id.name, "stdout")) {
                    return "1";
                } else if (std.mem.eql(u8, id.name, "stderr")) {
                    return "2";
                }
                if (self.is_global) {
                    return "null"; // Global expressions can't dynamically load in initialization
                }
                if (id.resolved_symbol) |sym| {
                    if (sym.kind == .Function) {
                        var func_symbol_name = sym.name;
                        if (sym.decl_node) |decl| {
                            if (decl.module_name) |mod_name| {
                                if (!std.mem.eql(u8, sym.name, "main")) {
                                    func_symbol_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, sym.name });
                                }
                            }
                        }
                        const func_name = try std.fmt.allocPrint(self.allocator, "@{s}", .{func_symbol_name});
                        
                        const temp1 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ ptr, ptr }} undef, ptr {s}, 0\n", .{ temp1, func_name });
                        const temp2 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ ptr, ptr }} %t.{d}, ptr null, 1\n", .{ temp2, temp1 });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp2});
                    }
                }

                var inf_type = node.inferred_type orelse types.Type{ .kind = .Any };
                if (inf_type.kind == .Any) {
                    if (id.resolved_symbol) |sym| {
                        if (sym.decl_node) |decl| {
                            if (decl.inferred_type) |dt| inf_type = dt;
                        }
                    }
                }
                node.inferred_type = inf_type;
                const t = typeToLLVM(self.allocator, inf_type);
                const temp = self.nextTemp();
                const temp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                var var_symbol_name = id.name;
                var is_global_var = self.global_vars.contains(id.name);
                if (id.resolved_symbol) |sym| {
                    if (sym.decl_node) |decl| {
                        if (decl.module_name) |mod_name| {
                            const mangled_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, sym.name });
                            if (self.global_vars.contains(mangled_name)) {
                                var_symbol_name = mangled_name;
                                is_global_var = true;
                            }
                        }
                    }
                }

                if (is_global_var) {
                    try writer.print("  {s} = load {s}, ptr @{s}\n", .{ temp_name, t, var_symbol_name });
                } else {
                    const local_ref = self.getScopedName(var_symbol_name);
                    try writer.print("  {s} = load {s}, ptr %{s}\n", .{ temp_name, t, local_ref });
                }
                return temp_name;
            },
            .CastExpr => |*c| {
                const operand_val = try self.genExpr(c.operand);
                const source_type = typeToLLVM(self.allocator, c.operand.inferred_type orelse .{ .kind = .Any });
                const target_type = typeToLLVM(self.allocator, node.inferred_type orelse .{ .kind = .Any });

                if (std.mem.eql(u8, source_type, target_type)) {
                    return operand_val;
                }

                if (std.mem.eql(u8, target_type, "{ ptr, i64, i64 }") and std.mem.eql(u8, source_type, "{ ptr, i64 }")) {
                    const ptr_ext = self.nextTemp();
                    const len_ext = self.nextTemp();
                    try writer.print("  %t.{d} = extractvalue {{ ptr, i64 }} {s}, 0\n", .{ ptr_ext, operand_val });
                    try writer.print("  %t.{d} = extractvalue {{ ptr, i64 }} {s}, 1\n", .{ len_ext, operand_val });

                    const ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{self.nextTemp()});
                    const cap_temp = self.nextTemp();
                    try writer.print("  %t.{d} = add i64 %t.{d}, 1\n", .{ cap_temp, len_ext });
                    try writer.print("  {s} = call ptr @mantiq_malloc(i64 %t.{d})\n", .{ ptr_name, cap_temp });
                    try writer.print("  call void @llvm.memcpy.p0.p0.i64(ptr {s}, ptr %t.{d}, i64 %t.{d}, i1 false)\n", .{ ptr_name, ptr_ext, len_ext });

                    const fat1 = self.nextTemp();
                    const fat2 = self.nextTemp();
                    const fat3 = self.nextTemp();
                    try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} undef, ptr {s}, 0\n", .{ fat1, ptr_name });
                    try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 %t.{d}, 1\n", .{ fat2, fat1, len_ext });
                    try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 %t.{d}, 2\n", .{ fat3, fat2, cap_temp });

                    const fat_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat3});
                    try self.registerTemp(fat_name, ptr_name);
                    return fat_name;
                }

                if (std.mem.eql(u8, target_type, "{ ptr, ptr }")) {
                    const box_ptr = self.nextTemp();
                    // Box the value into a heap allocation to store in the Any fat pointer
                    try writer.print("  %t.{d} = call ptr @mantiq_malloc(i64 32)\n", .{box_ptr});
                    try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ source_type, operand_val, box_ptr });
                    const fat_temp1 = self.nextTemp();
                    try writer.print("  %t.{d} = insertvalue {{ ptr, ptr }} undef, ptr %t.{d}, 0\n", .{ fat_temp1, box_ptr });
                    const fat_temp2 = self.nextTemp();
                    try writer.print("  %t.{d} = insertvalue {{ ptr, ptr }} %t.{d}, ptr null, 1\n", .{ fat_temp2, fat_temp1 });
                    const fat_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp2});
                    return fat_name;
                }

                // Cast from Enum to Integer/Tag
                if (c.operand.inferred_type) |inf_t| {
                    if (inf_t.kind == .Enum and std.mem.startsWith(u8, target_type, "i")) {
                        const tag_val = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ tag_val, source_type, operand_val });
                        const tag_val_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{tag_val});
                        return try self.coerceType(tag_val_name, "i32", target_type);
                    }
                }

                // Cast from string/slice to integer/char (i8/u8/char/etc.)
                // Note: plain ptr -> i should NOT match here; it falls through to ptrtoint below
                if (std.mem.startsWith(u8, target_type, "i") and 
                    (std.mem.eql(u8, source_type, "{ ptr, i64 }") or 
                     std.mem.eql(u8, source_type, "{ ptr, i64, i64 }") or 
                     (std.mem.startsWith(u8, source_type, "%") and std.mem.endsWith(u8, source_type, "String")))) {
                    
                    const ptr_ext = self.nextTemp();
                    try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ ptr_ext, source_type, operand_val });
                    const ptr_val = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ptr_ext});
                    
                    const char_val = self.nextTemp();
                    try writer.print("  %t.{d} = load i8, ptr {s}\n", .{ char_val, ptr_val });
                    
                    if (std.mem.eql(u8, target_type, "i8")) {
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{char_val});
                    } else {
                        const ext_temp = self.nextTemp();
                        try writer.print("  %t.{d} = zext i8 %t.{d} to {s}\n", .{ ext_temp, char_val, target_type });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ext_temp});
                    }
                }

                // Integer-to-integer casts (trunc / zext / sext)
                if (std.mem.startsWith(u8, source_type, "i") and std.mem.startsWith(u8, target_type, "i")) {
                    return try self.coerceType(operand_val, source_type, target_type);
                }

                // String-to-ptr casts (extract pointer field)
                if ((std.mem.eql(u8, source_type, "{ ptr, i64 }") or
                     std.mem.eql(u8, source_type, "{ ptr, i64, i64 }") or
                     (std.mem.startsWith(u8, source_type, "%") and std.mem.endsWith(u8, source_type, "String"))) and
                    std.mem.eql(u8, target_type, "ptr")) {
                    return try self.coerceType(operand_val, source_type, target_type);
                }

                if (self.is_global) {
                    var buf = std.ArrayList(u8).init(self.allocator);
                    if (std.mem.eql(u8, source_type, "float") and std.mem.eql(u8, target_type, "bfloat")) {
                        try std.fmt.format(buf.writer(), "fptrunc (float {s} to bfloat)", .{operand_val});
                    } else if (std.mem.eql(u8, source_type, "bfloat") and std.mem.eql(u8, target_type, "float")) {
                        try std.fmt.format(buf.writer(), "fpext (bfloat {s} to float)", .{operand_val});
                    } else if (std.mem.eql(u8, source_type, "i32") and std.mem.eql(u8, target_type, "i64")) {
                        try std.fmt.format(buf.writer(), "sext (i32 {s} to i64)", .{operand_val});
                    } else if (std.mem.startsWith(u8, source_type, "i") and std.mem.eql(u8, target_type, "ptr")) {
                        try std.fmt.format(buf.writer(), "inttoptr ({s} {s} to ptr)", .{ source_type, operand_val });
                    } else if (std.mem.eql(u8, source_type, "ptr") and std.mem.startsWith(u8, target_type, "i")) {
                        try std.fmt.format(buf.writer(), "ptrtoint (ptr {s} to {s})", .{ operand_val, target_type });
                    } else {
                        try std.fmt.format(buf.writer(), "bitcast ({s} {s} to {s})", .{ source_type, operand_val, target_type });
                    }
                    return try buf.toOwnedSlice();
                }

                const temp = self.nextTemp();
                const temp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});

                // Very basic cast logic
                if (std.mem.eql(u8, source_type, "float") and std.mem.eql(u8, target_type, "bfloat")) {
                    try writer.print("  {s} = fptrunc float {s} to bfloat\n", .{ temp_name, operand_val });
                } else if (std.mem.eql(u8, source_type, "bfloat") and std.mem.eql(u8, target_type, "float")) {
                    try writer.print("  {s} = fpext bfloat {s} to float\n", .{ temp_name, operand_val });
                } else if (std.mem.eql(u8, source_type, "i32") and std.mem.eql(u8, target_type, "i64")) {
                    try writer.print("  {s} = sext i32 {s} to i64\n", .{ temp_name, operand_val });
                } else if ((std.mem.eql(u8, source_type, "i32") or std.mem.eql(u8, source_type, "i64")) and std.mem.eql(u8, target_type, "double")) {
                    try writer.print("  {s} = sitofp {s} {s} to double\n", .{ temp_name, source_type, operand_val });
                } else if ((std.mem.eql(u8, source_type, "i32") or std.mem.eql(u8, source_type, "i64")) and std.mem.eql(u8, target_type, "float")) {
                    try writer.print("  {s} = sitofp {s} {s} to float\n", .{ temp_name, source_type, operand_val });
                } else if (std.mem.startsWith(u8, source_type, "double") and std.mem.startsWith(u8, target_type, "i")) {
                    try writer.print("  {s} = fptosi {s} {s} to {s}\n", .{ temp_name, source_type, operand_val, target_type });
                } else if (std.mem.startsWith(u8, source_type, "float") and std.mem.startsWith(u8, target_type, "i")) {
                    try writer.print("  {s} = fptosi {s} {s} to {s}\n", .{ temp_name, source_type, operand_val, target_type });
                } else if (std.mem.startsWith(u8, source_type, "i") and std.mem.eql(u8, target_type, "ptr")) {
                    try writer.print("  {s} = inttoptr {s} {s} to ptr\n", .{ temp_name, source_type, operand_val });
                } else if (std.mem.eql(u8, source_type, "ptr") and std.mem.startsWith(u8, target_type, "i")) {
                    try writer.print("  {s} = ptrtoint ptr {s} to {s}\n", .{ temp_name, operand_val, target_type });
                } else {
                    // Fallback generic bitcast
                    try writer.print("  {s} = bitcast {s} {s} to {s}\n", .{ temp_name, source_type, operand_val, target_type });
                }
                return temp_name;
            },
            .ClosureExpr => |*cl| {
                const closure_id = node.inferred_type.?.closure_id.?;
                const closure_name = try std.fmt.allocPrint(self.allocator, "__mantiq_closure_{d}", .{closure_id});

                const saved_out = self.out;
                const saved_temp = self.temp_counter;
                const saved_depth = self.scope_depth;
                const saved_counter = self.decl_counter;
                var saved_var_entries = std.ArrayList(struct { key: []const u8, value: []const u8 }).init(self.allocator);
                {
                    var entry_it = self.var_name_map.iterator();
                    while (entry_it.next()) |entry| {
                        try saved_var_entries.append(.{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
                    }
                }

                self.out = std.ArrayList(u8).init(self.allocator);
                self.temp_counter = 1;
                self.decl_counter = 1;
                self.scope_depth = 0;

                var param_str = std.ArrayList(u8).init(self.allocator);
                try std.fmt.format(param_str.writer(), "ptr %env", .{});
                for (cl.params) |param| {
                    const t = typeToLLVM(self.allocator, param.inferred_type orelse .{ .kind = .Any });
                    try std.fmt.format(param_str.writer(), ", {s} %{s}.param", .{ t, param.data.Identifier.name });
                }

                var outlined_writer = self.out.writer();
                try outlined_writer.print("define i32 @{s}({s}) {{\n", .{ closure_name, param_str.items });
                try outlined_writer.print("entry:\n", .{});

                for (cl.params) |param| {
                    const name = param.data.Identifier.name;
                    const t = typeToLLVM(self.allocator, param.inferred_type orelse .{ .kind = .Any });
                    const scoped_name = try self.registerVarName(name);
                    try outlined_writer.print("  %{s} = alloca {s}\n", .{ scoped_name, t });
                    try outlined_writer.print("  store {s} %{s}.param, ptr %{s}\n", .{ t, name, scoped_name });
                }

                // Unpack environment variables
                if (cl.captured_vars) |cvs| {
                    for (cvs, 0..) |cv_name, i| {
                        const cv_scoped = try self.registerVarName(cv_name);
                        const offset = i * 4;
                        const ptr_temp = self.nextTemp();
                        try outlined_writer.print("  %t.{d} = getelementptr inbounds i8, ptr %env, i64 {d}\n", .{ ptr_temp, offset });
                        const val_temp = self.nextTemp();
                        try outlined_writer.print("  %t.{d} = load i32, ptr %t.{d}\n", .{ val_temp, ptr_temp });
                        try outlined_writer.print("  %{s} = alloca i32\n", .{cv_scoped});
                        try outlined_writer.print("  store i32 %t.{d}, ptr %{s}\n", .{ val_temp, cv_scoped });
                    }
                }

                if (cl.body.node_type == .BlockStmt) {
                    try self.genNode(cl.body);
                    try outlined_writer.print("  ret i32 0\n", .{});
                } else {
                    const ret_val = try self.genExpr(cl.body);
                    const t = typeToLLVM(self.allocator, cl.body.inferred_type orelse .{ .kind = .Any });
                    try outlined_writer.print("  ret {s} {s}\n", .{ t, ret_val });
                }
                try outlined_writer.print("}}\n\n", .{});

                try self.outlined_out.appendSlice(self.out.items);
                self.out.deinit();
                // Restore var_name_map to pre-outlined state
                self.var_name_map.clearRetainingCapacity();
                for (saved_var_entries.items) |saved| {
                    try self.var_name_map.put(saved.key, saved.value);
                }
                self.out = saved_out;
                self.temp_counter = saved_temp;
                self.decl_counter = saved_counter;
                self.scope_depth = saved_depth;

                // Pack environment variables into heap-allocated memory
                const env_size = if (cl.captured_vars) |cvs| cvs.len else 0;
                const env_val = if (env_size > 0) b: {
                    const total_size = env_size * 4; // Each captured var is i32 (4 bytes)
                    const malloc_temp = self.nextTemp();
                    try writer.print("  %t.{d} = call ptr @mantiq_malloc(i64 {d})\n", .{ malloc_temp, total_size });

                    for (cl.captured_vars.?, 0..) |cv_name, i| {
                        const load_temp = self.nextTemp();
                        const cv_scoped = self.getScopedName(cv_name);
                        try writer.print("  %t.{d} = load i32, ptr %{s}\n", .{ load_temp, cv_scoped });
                        const dest_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = getelementptr inbounds i8, ptr %t.{d}, i64 {d}\n", .{ dest_ptr, malloc_temp, i * 4 });
                        try writer.print("  store i32 %t.{d}, ptr %t.{d}\n", .{ load_temp, dest_ptr });
                    }
                    break :b try std.fmt.allocPrint(self.allocator, "%t.{d}", .{malloc_temp});
                } else "null";

                const fat_temp1 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {{ ptr, ptr }} undef, ptr @{s}, 0\n", .{ fat_temp1, closure_name });
                const fat_temp2 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {{ ptr, ptr }} %t.{d}, ptr {s}, 1\n", .{ fat_temp2, fat_temp1, env_val });
                return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp2});
            },
            .CallExpr => |*c| {
                const is_variable = if (c.callee.node_type == .Identifier)
                    (if (c.callee.data.Identifier.resolved_symbol) |sym| sym.kind == .Variable else false)
                else
                    false;

                var is_module_call = false;
                var module_func_name: ?[]const u8 = null;
                if (c.callee.node_type == .MemberExpr) {
                    const me = &c.callee.data.MemberExpr;
                    const me_obj_type = me.object.inferred_type orelse types.Type{ .kind = .Any };
                    if (me_obj_type.kind == .Module) {
                        is_module_call = true;
                        module_func_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ me.object.data.Identifier.name, me.property });
                    }
                }

                if ((is_variable or c.callee.node_type == .MemberExpr) and !is_module_call) {
                    const cl_ptr = try self.genExpr(c.callee);
                    const callee_inferred = c.callee.inferred_type orelse types.Type{ .kind = .Any };

                    if (callee_inferred.kind == .Function and callee_inferred.function.?.return_type.kind == .Enum) {
                        // Enum variant constructor
                        const ret_t = typeToLLVM(self.allocator, callee_inferred.function.?.return_type.*);
                        const tag_val = cl_ptr; // from genExpr(c.callee)

                        const temp_struct = self.nextTemp();
                        const temp_struct_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp_struct});
                        try writer.print("  {s} = insertvalue {s} zeroinitializer, i32 {s}, 0\n", .{ temp_struct_name, ret_t, tag_val });

                        // Store payloads into the array bitcast
                        if (c.arguments.len > 0) {
                            const alloca_temp = self.nextTemp();
                            const alloca_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{alloca_temp});
                            try writer.print("  {s} = alloca {s}\n", .{ alloca_name, ret_t });
                            try writer.print("  store {s} {s}, ptr {s}\n", .{ ret_t, temp_struct_name, alloca_name });

                            const payload_gep = self.nextTemp();
                            try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr {s}, i32 0, i32 1\n", .{ payload_gep, ret_t, alloca_name });

                            const arg_val = try self.genExpr(c.arguments[0]);
                            const arg_t = typeToLLVM(self.allocator, c.arguments[0].inferred_type orelse .{ .kind = .Any });
                            try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ arg_t, arg_val, payload_gep });

                            const load_temp = self.nextTemp();
                            const load_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{load_temp});
                            try writer.print("  {s} = load {s}, ptr {s}\n", .{ load_name, ret_t, alloca_name });
                            return load_name;
                        }
                        return temp_struct_name;
                    } else if (callee_inferred.kind == .RawPointer and callee_inferred.payload != null and
                        (callee_inferred.payload.?.kind == .Struct and callee_inferred.payload.?.struct_type != null)) {
                        // RawPointer to struct: dispatch to __init__ method
                        const st = callee_inferred.payload.?.struct_type.?;
                        var init_method: ?*types.FunctionType = null;
                        var init_mangled_name: []const u8 = "";
                        for (st.methods) |cm| {
                            if (std.mem.endsWith(u8, cm.name, "___init__")) {
                                init_method = cm.type_kind.function;
                                init_mangled_name = cm.name;
                                break;
                            }
                        }

                        if (init_method) |init_fn| {
                            var args_str = std.ArrayList(u8).init(self.allocator);
                            try args_str.appendSlice("ptr null, ptr "); // env parameter and self
                            try args_str.appendSlice(cl_ptr);

                            for (c.arguments, 0..) |arg, idx| {
                                const arg_val = try self.genExpr(arg);
                                var val_to_pass = arg_val;
                                const arg_inferred = arg.inferred_type orelse types.Type{ .kind = .Any };
                                const source_t = typeToLLVM(self.allocator, arg_inferred);

                                var target_t = source_t;
                                var expected_type = arg_inferred;
                                if (idx + 1 < init_fn.param_types.len) {
                                    expected_type = init_fn.param_types[idx + 1];
                                    target_t = typeToLLVM(self.allocator, expected_type);
                                }

                                val_to_pass = try self.coerceType(val_to_pass, source_t, target_t);

                                const sig = abi.getArgABI(expected_type, layout.Target.x86_64_linux);
                                const align_req = layout.getAlign(expected_type, layout.Target.x86_64_linux);

                                try args_str.appendSlice(", ");
                                if (sig.mode == .ByVal) {
                                    const temp_alloc = self.nextTemp();
                                    try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, target_t, align_req });
                                    try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ target_t, val_to_pass, temp_alloc, align_req });
                                    try std.fmt.format(args_str.writer(), "ptr byval({s}) %t.{d}", .{ target_t, temp_alloc });
                                } else if (sig.mode == .Coerce) {
                                    const temp_alloc = self.nextTemp();
                                    try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, target_t, align_req });
                                    try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ target_t, val_to_pass, temp_alloc, align_req });
                                    const cast_load = self.nextTemp();
                                    try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ cast_load, sig.llvm_type, temp_alloc, align_req });
                                    try std.fmt.format(args_str.writer(), "{s} %t.{d}", .{ sig.llvm_type, cast_load });
                                } else {
                                    try std.fmt.format(args_str.writer(), "{s} {s}", .{ target_t, val_to_pass });
                                }
                            }

                            if (!self.defined_functions.contains(init_mangled_name)) {
                                try self.declareExternalFunctionFromType(init_mangled_name, types.Type{ .kind = .Function, .function = init_fn });
                            }

                            try writer.print("  call void @{s}({s})\n", .{ init_mangled_name, args_str.items });
                        }
                        return cl_ptr;
                    } else {
                        // Extract function pointer and environment pointer from fat pointer { ptr, ptr }
                        const func_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {{ ptr, ptr }} {s}, 0\n", .{ func_ptr, cl_ptr });
                        
                        const env_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {{ ptr, ptr }} {s}, 1\n", .{ env_ptr, cl_ptr });

                        var arg_str = std.ArrayList(u8).init(self.allocator);
                        try std.fmt.format(arg_str.writer(), "ptr %t.{d}", .{env_ptr});
                        for (c.arguments, 0..) |arg, i| {
                            try arg_str.appendSlice(", ");
                            var arg_val = try self.genExpr(arg);
                            self.consumeTemp(arg_val);
                            const inferred: types.Type = arg.inferred_type orelse types.Type{ .kind = .Any };
                            const source_t = typeToLLVM(self.allocator, inferred);
                            var target_type = inferred;
                            if (callee_inferred.function) |func_t| {
                                const params = func_t.param_types;
                                if (i < params.len) {
                                    target_type = params[i];
                                }
                            }
                            const target_t = typeToLLVM(self.allocator, target_type);
                            arg_val = try self.coerceType(arg_val, source_t, target_t);
                            const sig = abi.getArgABI(target_type, layout.Target.x86_64_linux);
                            const align_req = layout.getAlign(target_type, layout.Target.x86_64_linux);
                            
                            if (sig.mode == .ByVal) {
                                const temp_alloc = self.nextTemp();
                                try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, target_t, align_req });
                                try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ target_t, arg_val, temp_alloc, align_req });
                                try std.fmt.format(arg_str.writer(), "ptr byval({s}) %t.{d}", .{ target_t, temp_alloc });
                            } else if (sig.mode == .Coerce) {
                                const temp_alloc = self.nextTemp();
                                try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, target_t, align_req });
                                try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ target_t, arg_val, temp_alloc, align_req });
                                const cast_load = self.nextTemp();
                                try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ cast_load, sig.llvm_type, temp_alloc, align_req });
                                try std.fmt.format(arg_str.writer(), "{s} %t.{d}", .{ sig.llvm_type, cast_load });
                            } else {
                                try std.fmt.format(arg_str.writer(), "{s} {s}", .{ target_t, arg_val });
                            }
                        }

                        var actual_ret_type: types.Type = node.inferred_type orelse types.Type{ .kind = .Any };
                        if (callee_inferred.kind == .Function and callee_inferred.function != null) {
                            actual_ret_type = callee_inferred.function.?.return_type.*;
                        } else if (callee_inferred.kind == .Closure and callee_inferred.function != null) {
                            actual_ret_type = callee_inferred.function.?.return_type.*;
                        }
                        const ret_t = typeToLLVM(self.allocator, actual_ret_type);
                        const ret_sig = abi.getRetABI(actual_ret_type, layout.Target.x86_64_linux);
                        const final_ret_t = if (ret_sig.mode == .Coerce) ret_sig.llvm_type else ret_t;

                        if (std.mem.eql(u8, final_ret_t, "void")) {
                            try writer.print("  call {s} %t.{d}({s})\n", .{ final_ret_t, func_ptr, arg_str.items });
                            return "null";
                        } else {
                            const call_temp = self.nextTemp();
                            const call_temp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{call_temp});
                            try writer.print("  {s} = call {s} %t.{d}({s})\n", .{ call_temp_name, final_ret_t, func_ptr, arg_str.items });
                            
                            if (ret_sig.mode == .Coerce) {
                                const ret_align = layout.getAlign(actual_ret_type, layout.Target.x86_64_linux);
                                const temp_alloc = self.nextTemp();
                                try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, ret_t, ret_align });
                                try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ final_ret_t, call_temp_name, temp_alloc, ret_align });
                                const final_val = self.nextTemp();
                                try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ final_val, ret_t, temp_alloc, ret_align });
                                return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{final_val});
                            }
                            
                            return call_temp_name;
                        }
                    }
                } else if (c.callee.node_type == .Identifier or is_module_call or (c.callee.node_type == .IndexExpr and c.callee.data.IndexExpr.object.node_type == .Identifier)) {
                    var func_name = if (is_module_call) module_func_name.? else if (c.callee.node_type == .Identifier) c.callee.data.Identifier.name else c.callee.data.IndexExpr.object.data.Identifier.name;
                    const is_struct = if (c.callee.node_type == .Identifier)
                        (if (c.callee.data.Identifier.resolved_symbol) |sym| sym.kind == .Struct else false)
                    else
                        false;
                    const is_class = if (c.callee.node_type == .Identifier)
                        (if (c.callee.data.Identifier.resolved_symbol) |sym| sym.kind == .Class else false)
                    else
                        false;

                    var is_user_func = false;
                    var is_extern = false;
                    if (self.getCalleeDeclNode(c.callee, is_module_call)) |decl| {
                        if (decl.node_type == .FunDecl) {
                            is_user_func = true;
                            
                            const f = &decl.data.FunDecl;
                            is_extern = f.is_extern;
                            if (!f.is_extern) {
                                if (decl.module_name) |mod_name| {
                                    if (!std.mem.eql(u8, f.name, "main")) {
                                        func_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, f.name });
                                    }
                                }
                            }
                            
                            // If it's a user function and not defined in the current module, declare it
                            if (!self.defined_functions.contains(func_name)) {
                                try self.declareExternalFunction(func_name, decl);
                            }
                        }
                    }
                    if (std.mem.eql(u8, func_name, "List") and !is_user_func) {
                        const fat1 = self.nextTemp();
                        const fat2 = self.nextTemp();
                        const fat3 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} undef, ptr null, 0\n", .{fat1});
                        try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 0, 1\n", .{ fat2, fat1 });
                        try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 0, 2\n", .{ fat3, fat2 });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat3});
                    } else if (std.mem.eql(u8, func_name, "Dict") and !is_user_func) {
                        var k_size: u64 = 8;
                        var v_size: u64 = 8;
                        var is_str_flag: u32 = 0;
                        if (node.inferred_type) |inf_t| {
                            if (inf_t.kind == .Dict and inf_t.tuple_types != null and inf_t.tuple_types.?.len == 2) {
                                const k_type = inf_t.tuple_types.?[0];
                                const v_type = inf_t.tuple_types.?[1];
                                k_size = types.getTypeSize(k_type);
                                v_size = types.getTypeSize(v_type);
                                is_str_flag = getDictStringKeyFlag(k_type);
                            }
                        }
                        if (k_size == 8 and is_str_flag == 0 and c.callee.node_type == .IndexExpr) {
                            const idx_node = c.callee.data.IndexExpr.index;
                            if (idx_node.node_type == .ListLiteral and idx_node.data.ListLiteral.elements.len >= 1) {
                                const k_node = idx_node.data.ListLiteral.elements[0];
                                if (k_node.node_type == .Identifier and std.mem.eql(u8, k_node.data.Identifier.name, "String")) {
                                    k_size = 24;
                                    is_str_flag = 2;
                                }
                            }
                        }
                        const dict_ptr = self.nextTemp();
                        const dict_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{dict_ptr});
                        try writer.print("  {s} = call ptr @__mantiq_dict_create(i32 {d}, i32 {d}, i32 {d})\n", .{ dict_name, k_size, v_size, is_str_flag });

                        const fat1 = self.nextTemp();
                        const fat2 = self.nextTemp();
                        const fat3 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} undef, ptr {s}, 0\n", .{ fat1, dict_name });
                        try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 0, 1\n", .{ fat2, fat1 });
                        try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 0, 2\n", .{ fat3, fat2 });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat3});
                    } else if (std.mem.eql(u8, func_name, "measure") and !is_user_func) {
                        try writer.print("  call void @quantum_measure(i32 {s})\n", .{try self.genExpr(c.arguments[0])});
                        return "null";
                    } else if (std.mem.eql(u8, func_name, "H") and !is_user_func) {
                        const temp = self.nextTemp();
                        const temp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                        try writer.print("  {s} = call i32 @quantum_H(i32 {s})\n", .{ temp_name, try self.genExpr(c.arguments[0]) });
                        return temp_name;
                    } else if (std.mem.eql(u8, func_name, "qreg") and !is_user_func) {
                        const temp = self.nextTemp();
                        const temp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                        try writer.print("  {s} = call {{ ptr, i32 }} @quantum_qreg(i32 {s})\n", .{ temp_name, try self.genExpr(c.arguments[0]) });
                        return temp_name;
                    } else if (std.mem.eql(u8, func_name, "CNOT") and !is_user_func) {
                        try writer.print("  call void @quantum_CNOT(i32 {s}, i32 {s})\n", .{ try self.genExpr(c.arguments[0]), try self.genExpr(c.arguments[1]) });
                        return "null";
                    } else if (std.mem.eql(u8, func_name, "make") and !is_user_func) {
                        var base_size: usize = 1;
                        if (node.inferred_type) |inf_type| {
                            if (inf_type.kind == .RawPointer and inf_type.payload != null) {
                                base_size = types.getTypeSize(inf_type.payload.?.*);
                            }
                        }
                        
                        var capacity_val: []const u8 = "1";
                        var capacity_type: types.Type = .{ .kind = .I64 };
                        if (c.arguments.len > 0) {
                            const cap_arg = c.arguments[0];
                            if (cap_arg.node_type == .KeywordArg) {
                                capacity_val = try self.genExpr(cap_arg.data.KeywordArg.value);
                                capacity_type = cap_arg.data.KeywordArg.value.inferred_type orelse .{ .kind = .I32 };
                            } else {
                                capacity_val = try self.genExpr(cap_arg);
                                capacity_type = cap_arg.inferred_type orelse .{ .kind = .I32 };
                            }
                        }
                        
                        // Ensure capacity is i64
                        var i64_cap_val = capacity_val;
                        const cap_llvm = typeToLLVM(self.allocator, capacity_type);
                        if (!std.mem.eql(u8, cap_llvm, "i64")) {
                            const ext_temp = self.nextTemp();
                            try writer.print("  %t.{d} = zext {s} {s} to i64\n", .{ ext_temp, cap_llvm, capacity_val });
                            i64_cap_val = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ext_temp});
                        }
                        
                        const total_size = self.nextTemp();
                        try writer.print("  %t.{d} = mul i64 {s}, {d}\n", .{ total_size, i64_cap_val, base_size });
                        
                        const alloc_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_malloc(i64 %t.{d})\n", .{ alloc_ptr, total_size });
                        
                        const ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{alloc_ptr});
                        try self.registerTemp(ptr_name, ptr_name);
                        return ptr_name;
                    } else if (std.mem.eql(u8, func_name, "drop") and !is_user_func) {
                        const ptr_val = try self.genExpr(c.arguments[0]);
                        try writer.print("  call void @mantiq_free(ptr {s})\n", .{ptr_val});
                        return "null";
                    } else if (std.mem.eql(u8, func_name, "resize") and !is_user_func) {
                        const ptr_arg = try self.genExpr(c.arguments[0]);
                        const sz_arg = try self.genExpr(c.arguments[1]);
                        var final_sz = sz_arg;
                        const sz_type = c.arguments[1].inferred_type orelse types.Type{ .kind = .I32 };
                        if (sz_type.kind == .I32) {
                            const ext_temp = self.nextTemp();
                            try writer.print("  %t.{d} = sext i32 {s} to i64\n", .{ ext_temp, sz_arg });
                            final_sz = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ext_temp});
                        }
                        const temp = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_realloc(ptr {s}, i64 {s})\n", .{ temp, ptr_arg, final_sz });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                    } else if (std.mem.eql(u8, func_name, "write")) {
                        const fd_val = try self.genExpr(c.arguments[0]);
                        const str_val = try self.genExpr(c.arguments[1]);
                        const arg_t: types.Type = c.arguments[1].inferred_type orelse .{ .kind = .Any };
                        const is_fat3 = (arg_t.kind == .String or arg_t.kind == .List or arg_t.kind == .Dict);
                        const struct_t = if (is_fat3) "{ ptr, i64, i64 }" else "{ ptr, i64 }";
                        const ptr_temp = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ ptr_temp, struct_t, str_val });
                        const len_temp = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ len_temp, struct_t, str_val });
                        try writer.print("  call void @mantiq_write(i32 {s}, ptr %t.{d}, i64 %t.{d})\n", .{ fd_val, ptr_temp, len_temp });
                        return "null";
                    } else if (std.mem.eql(u8, func_name, "read")) {
                        const fd_val = try self.genExpr(c.arguments[0]);
                        const len_val = try self.genExpr(c.arguments[1]);
                        const len_out = self.nextTemp();
                        try writer.print("  %t.{d} = alloca i64\n", .{len_out});
                        const temp = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_read(i32 {s}, i64 {s}, ptr %t.{d})\n", .{ temp, fd_val, len_val, len_out });
                        const len_val2 = self.nextTemp();
                        try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ len_val2, len_out });
                        const fat_temp = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} undef, ptr %t.{d}, 0\n", .{ fat_temp, temp });
                        const fat_temp2 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 %t.{d}, 1\n", .{ fat_temp2, fat_temp, len_val2 });
                        const fat_temp3 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 %t.{d}, 2\n", .{ fat_temp3, fat_temp2, len_val2 });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp3});
                    } else if (std.mem.eql(u8, func_name, "open")) {
                        const path_val = try self.genExpr(c.arguments[0]);
                        const path_t: types.Type = c.arguments[0].inferred_type orelse .{ .kind = .Any };
                        const path_llvm_t = typeToLLVM(self.allocator, path_t);

                        const flags_val = try self.genExpr(c.arguments[1]);
                        const flags_t: types.Type = c.arguments[1].inferred_type orelse .{ .kind = .Any };
                        const flags_llvm_t = typeToLLVM(self.allocator, flags_t);

                        const path_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ path_ptr, path_llvm_t, path_val });
                        const path_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ path_len, path_llvm_t, path_val });

                        const flags_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ flags_ptr, flags_llvm_t, flags_val });
                        const flags_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ flags_len, flags_llvm_t, flags_val });

                        const temp = self.nextTemp();
                        try writer.print("  %t.{d} = call i32 @mantiq_fs_open(ptr %t.{d}, i64 %t.{d}, ptr %t.{d}, i64 %t.{d})\n", .{ temp, path_ptr, path_len, flags_ptr, flags_len });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                    } else if (std.mem.eql(u8, func_name, "close")) {
                        const fd_val = try self.genExpr(c.arguments[0]);
                        try writer.print("  call void @mantiq_fs_close(i32 {s})\n", .{fd_val});
                        return "null";
                    } else if (std.mem.eql(u8, func_name, "exists")) {
                        const path_val = try self.genExpr(c.arguments[0]);
                        const path_t: types.Type = c.arguments[0].inferred_type orelse .{ .kind = .Any };
                        const path_llvm_t = typeToLLVM(self.allocator, path_t);

                        const path_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ path_ptr, path_llvm_t, path_val });
                        const path_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ path_len, path_llvm_t, path_val });

                        const temp = self.nextTemp();
                        try writer.print("  %t.{d} = call i8 @mantiq_fs_exists(ptr %t.{d}, i64 %t.{d})\n", .{ temp, path_ptr, path_len });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                    } else if (std.mem.eql(u8, func_name, "exit")) {
                        const code_val = try self.genExpr(c.arguments[0]);
                        try writer.print("  call void @mantiq_process_exit(i32 {s})\n", .{code_val});
                        return "null";
                    } else if (std.mem.eql(u8, func_name, "args")) {
                        const ptr_temp = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_process_args()\n", .{ptr_temp});
                        const temp = self.nextTemp();
                        try writer.print("  %t.{d} = load {{ ptr, i64, i64 }}, ptr %t.{d}\n", .{ temp, ptr_temp });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                    } else if (std.mem.eql(u8, func_name, "now")) {
                        const temp = self.nextTemp();
                        try writer.print("  %t.{d} = call i64 @mantiq_time_now()\n", .{temp});
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                    } else if (std.mem.eql(u8, func_name, "sleep")) {
                        const sec_val = try self.genExpr(c.arguments[0]);
                        try writer.print("  call void @mantiq_time_sleep(i32 {s})\n", .{sec_val});
                        return "null";
                    } else if (std.mem.eql(u8, func_name, "os")) {
                        const ptr_temp = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_sys_os()\n", .{ptr_temp});
                        const temp = self.nextTemp();
                        try writer.print("  %t.{d} = load {{ ptr, i64 }}, ptr %t.{d}\n", .{ temp, ptr_temp });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                    } else if (std.mem.eql(u8, func_name, "arch")) {
                        const ptr_temp = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_sys_arch()\n", .{ptr_temp});
                        const temp = self.nextTemp();
                        try writer.print("  %t.{d} = load {{ ptr, i64 }}, ptr %t.{d}\n", .{ temp, ptr_temp });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                    } else if (std.mem.eql(u8, func_name, "getenv")) {
                        const name_val = try self.genExpr(c.arguments[0]);
                        const name_struct = typeToLLVM(self.allocator, c.arguments[0].inferred_type orelse .{ .kind = .Any });
                        const name_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ name_ptr, name_struct, name_val });
                        const name_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ name_len, name_struct, name_val });

                        const ptr_temp = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_sys_getenv(ptr %t.{d}, i64 %t.{d})\n", .{ ptr_temp, name_ptr, name_len });
                        const temp = self.nextTemp();
                        try writer.print("  %t.{d} = load {{ ptr, i64 }}, ptr %t.{d}\n", .{ temp, ptr_temp });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                    } else if (std.mem.eql(u8, func_name, "setenv")) {
                        const name_val = try self.genExpr(c.arguments[0]);
                        const name_struct = typeToLLVM(self.allocator, c.arguments[0].inferred_type orelse .{ .kind = .Any });
                        const name_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ name_ptr, name_struct, name_val });
                        const name_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ name_len, name_struct, name_val });

                        const val_val = try self.genExpr(c.arguments[1]);
                        const val_struct = typeToLLVM(self.allocator, c.arguments[1].inferred_type orelse .{ .kind = .Any });
                        const val_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ val_ptr, val_struct, val_val });
                        const val_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ val_len, val_struct, val_val });

                        try writer.print("  call void @mantiq_sys_setenv(ptr %t.{d}, i64 %t.{d}, ptr %t.{d}, i64 %t.{d})\n", .{ name_ptr, name_len, val_ptr, val_len });
                        return "null";
                    } else if (std.mem.eql(u8, func_name, "unsetenv")) {
                        const name_val = try self.genExpr(c.arguments[0]);
                        const name_struct = typeToLLVM(self.allocator, c.arguments[0].inferred_type orelse .{ .kind = .Any });
                        const name_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ name_ptr, name_struct, name_val });
                        const name_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ name_len, name_struct, name_val });

                        try writer.print("  call void @mantiq_sys_unsetenv(ptr %t.{d}, i64 %t.{d})\n", .{ name_ptr, name_len });
                        return "null";
                    } else if (std.mem.eql(u8, func_name, "Some")) {
                        const val = try self.genExpr(c.arguments[0]);
                        const arg_type = c.arguments[0].inferred_type orelse types.Type{ .kind = .Any };
                        const val_t = typeToLLVM(self.allocator, arg_type);
                        // For pointer types, store directly as val_ptr (no box needed)
                        // to avoid use-after-free when the OptionLayout is copied into a list
                        if (arg_type.kind == .RawPointer) {
                            const fat_temp1 = self.nextTemp();
                            try writer.print("  %t.{d} = insertvalue {{ i8, ptr }} undef, i8 1, 0\n", .{fat_temp1});
                            const fat_temp2 = self.nextTemp();
                            try writer.print("  %t.{d} = insertvalue {{ i8, ptr }} %t.{d}, ptr {s}, 1\n", .{ fat_temp2, fat_temp1, val });
                            const fat_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp2});
                            return fat_name;
                        }
                        const box_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_malloc(i64 32)\n", .{box_ptr});
                        try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ val_t, val, box_ptr });
                        const fat_temp1 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ i8, ptr }} undef, i8 1, 0\n", .{fat_temp1});
                        const fat_temp2 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ i8, ptr }} %t.{d}, ptr %t.{d}, 1\n", .{ fat_temp2, fat_temp1, box_ptr });
                        
                        const fat_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp2});
                        const box_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{box_ptr});
                        try self.registerTemp(fat_name, box_name);
                        return fat_name;
                    } else if (std.mem.eql(u8, func_name, "Ok")) {
                        const val = try self.genExpr(c.arguments[0]);
                        const arg_type = c.arguments[0].inferred_type orelse types.Type{ .kind = .Any };
                        const val_t = typeToLLVM(self.allocator, arg_type);
                        if (arg_type.kind == .RawPointer) {
                            const fat_temp1 = self.nextTemp();
                            try writer.print("  %t.{d} = insertvalue {{ i8, ptr, ptr }} undef, i8 0, 0\n", .{fat_temp1});
                            const fat_temp2 = self.nextTemp();
                            try writer.print("  %t.{d} = insertvalue {{ i8, ptr, ptr }} %t.{d}, ptr {s}, 1\n", .{ fat_temp2, fat_temp1, val });
                            const fat_temp3 = self.nextTemp();
                            try writer.print("  %t.{d} = insertvalue {{ i8, ptr, ptr }} %t.{d}, ptr null, 2\n", .{ fat_temp3, fat_temp2 });
                            const fat_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp3});
                            return fat_name;
                        }
                        const box_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_malloc(i64 32)\n", .{box_ptr});
                        try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ val_t, val, box_ptr });
                        const fat_temp1 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ i8, ptr, ptr }} undef, i8 0, 0\n", .{fat_temp1});
                        const fat_temp2 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ i8, ptr, ptr }} %t.{d}, ptr %t.{d}, 1\n", .{ fat_temp2, fat_temp1, box_ptr });
                        const fat_temp3 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ i8, ptr, ptr }} %t.{d}, ptr null, 2\n", .{ fat_temp3, fat_temp2 });
                        
                        const fat_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp3});
                        const box_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{box_ptr});
                        try self.registerTemp(fat_name, box_name);
                        return fat_name;
                    } else if (std.mem.eql(u8, func_name, "Err")) {
                        const val = try self.genExpr(c.arguments[0]);
                        const arg_type = c.arguments[0].inferred_type orelse types.Type{ .kind = .Any };
                        const val_t = typeToLLVM(self.allocator, arg_type);
                        if (arg_type.kind == .RawPointer) {
                            const fat_temp1 = self.nextTemp();
                            try writer.print("  %t.{d} = insertvalue {{ i8, ptr, ptr }} undef, i8 1, 0\n", .{fat_temp1});
                            const fat_temp2 = self.nextTemp();
                            try writer.print("  %t.{d} = insertvalue {{ i8, ptr, ptr }} %t.{d}, ptr null, 1\n", .{ fat_temp2, fat_temp1 });
                            const fat_temp3 = self.nextTemp();
                            try writer.print("  %t.{d} = insertvalue {{ i8, ptr, ptr }} %t.{d}, ptr {s}, 2\n", .{ fat_temp3, fat_temp2, val });
                            const fat_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp3});
                            return fat_name;
                        }
                        const box_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_malloc(i64 32)\n", .{box_ptr});
                        try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ val_t, val, box_ptr });
                        const fat_temp1 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ i8, ptr, ptr }} undef, i8 1, 0\n", .{fat_temp1});
                        const fat_temp2 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ i8, ptr, ptr }} %t.{d}, ptr null, 1\n", .{ fat_temp2, fat_temp1 });
                        const fat_temp3 = self.nextTemp();
                        try writer.print("  %t.{d} = insertvalue {{ i8, ptr, ptr }} %t.{d}, ptr %t.{d}, 2\n", .{ fat_temp3, fat_temp2, box_ptr });
                        
                        const fat_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp3});
                        const box_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{box_ptr});
                        try self.registerTemp(fat_name, box_name);
                        return fat_name;
                    } else if (std.mem.eql(u8, func_name, "print") or std.mem.eql(u8, func_name, "println")) {
                        var pos_args = std.ArrayList(*ast.Node).init(self.allocator);
                        var sep_node: ?*ast.Node = null;
                        var end_node: ?*ast.Node = null;
                        for (c.arguments) |arg| {
                            if (arg.node_type == .KeywordArg) {
                                const kw = arg.data.KeywordArg;
                                if (std.mem.eql(u8, kw.name, "sep")) {
                                    sep_node = kw.value;
                                } else if (std.mem.eql(u8, kw.name, "end")) {
                                    end_node = kw.value;
                                }
                            } else {
                                try pos_args.append(arg);
                            }
                        }

                        for (pos_args.items, 0..) |arg, i| {
                            if (i > 0) {
                                if (sep_node) |sn| {
                                    const sep_val = try self.genExpr(sn);
                                    const sep_t = sn.inferred_type orelse types.Type{ .kind = .String };
                                    try self.printValue(writer, sep_val, sep_t);
                                } else {
                                    try writer.print("  call void @mantiq_print_space()\n", .{});
                                }
                            }
                            const arg_val = try self.genExpr(arg);
                            const arg_t = arg.inferred_type orelse types.Type{ .kind = .Any };
                            try self.printValue(writer, arg_val, arg_t);
                        }

                        if (end_node) |en| {
                            const end_val = try self.genExpr(en);
                            const end_t = en.inferred_type orelse types.Type{ .kind = .String };
                            try self.printValue(writer, end_val, end_t);
                        } else if (std.mem.eql(u8, func_name, "println")) {
                            try writer.print("  call void @mantiq_print_newline()\n", .{});
                        } else if (std.mem.eql(u8, func_name, "print")) {
                            // Python's default is to append newline for print unless 'end' is set.
                            // But wait! If we introduce `println`, should `print` STILL output a newline by default?
                            // Yes, in Mantiq currently `print` outputs a newline by default.
                            // However, since we now have `println`, maybe `print` should NOT output a newline?
                            // Actually, I'll keep the newline for `print` so I don't break existing tests,
                            // but `println` does exactly the same.
                            try writer.print("  call void @mantiq_print_newline()\n", .{});
                        }
                        try writer.print("  call void @mantiq_flush_stdout()\n", .{});
                        return "null";
                    } else if (is_class) {
                        const ct = c.callee.inferred_type.?.class_type.?;
                        
                        const size_temp = self.nextTemp();
                        try writer.print("  %t.{d} = getelementptr %{s}, ptr null, i32 1\n", .{ size_temp, ct.name });
                        const int_temp = self.nextTemp();
                        try writer.print("  %t.{d} = ptrtoint ptr %t.{d} to i64\n", .{ int_temp, size_temp });
                        
                        const alloc_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @mantiq_malloc(i64 %t.{d})\n", .{ alloc_ptr, int_temp });
                        const ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{alloc_ptr});
                        
                        const vtable_gep = self.nextTemp();
                        try writer.print("  %t.{d} = getelementptr inbounds %{s}, ptr {s}, i32 0, i32 0\n", .{ vtable_gep, ct.name, ptr_name });
                        try writer.print("  store ptr @__vtable_{s}, ptr %t.{d}\n", .{ ct.name, vtable_gep });

                        var has_init = false;
                        var init_fn_t: ?*types.FunctionType = null;
                        for (ct.methods) |cm| {
                            if (std.mem.eql(u8, cm.name, "__init__")) {
                                has_init = true;
                                init_fn_t = cm.type_kind.function;
                                break;
                            }
                        }

                        if (has_init) {
                            var args_str = std.ArrayList(u8).init(self.allocator);
                            try args_str.appendSlice("ptr null, ptr "); // env parameter and self
                            try args_str.appendSlice(ptr_name);

                            for (c.arguments, 0..) |arg, idx| {
                                const arg_val = try self.genExpr(arg);
                                var val_to_pass = arg_val;
                                const arg_inferred = arg.inferred_type orelse types.Type{ .kind = .Any };
                                const source_t = typeToLLVM(self.allocator, arg_inferred);
                                
                                var target_t = source_t;
                                var expected_type = arg_inferred;
                                if (init_fn_t) |func_t| {
                                    if (idx + 1 < func_t.param_types.len) {
                                        expected_type = func_t.param_types[idx + 1];
                                        target_t = typeToLLVM(self.allocator, expected_type);
                                    }
                                }

                                val_to_pass = try self.coerceType(val_to_pass, source_t, target_t);

                                const sig = abi.getArgABI(expected_type, layout.Target.x86_64_linux);
                                const align_req = layout.getAlign(expected_type, layout.Target.x86_64_linux);
                                
                                try args_str.appendSlice(", ");
                                if (sig.mode == .ByVal) {
                                    const temp_alloc = self.nextTemp();
                                    try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, target_t, align_req });
                                    try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ target_t, val_to_pass, temp_alloc, align_req });
                                    try std.fmt.format(args_str.writer(), "ptr byval({s}) %t.{d}", .{ target_t, temp_alloc });
                                } else if (sig.mode == .Coerce) {
                                    const temp_alloc = self.nextTemp();
                                    try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, target_t, align_req });
                                    try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ target_t, val_to_pass, temp_alloc, align_req });
                                    const cast_load = self.nextTemp();
                                    try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ cast_load, sig.llvm_type, temp_alloc, align_req });
                                    try std.fmt.format(args_str.writer(), "{s} %t.{d}", .{ sig.llvm_type, cast_load });
                                } else {
                                    try std.fmt.format(args_str.writer(), "{s} {s}", .{ target_t, val_to_pass });
                                }
                            }

                            const mangled_name = try std.fmt.allocPrint(self.allocator, "{s}___init__", .{ct.name});
                            // If we define __init__ in the same module, we don't need to declare it externally.
                            // LLVM IR handles forward references natively.
                            // if (!self.defined_functions.contains(mangled_name)) {
                            //     if (init_fn_t) |func_t| {
                            //         try self.declareExternalFunctionFromType(mangled_name, types.Type{ .kind = .Function, .function = func_t });
                            //     }
                            // }
                            try writer.print("  call void @{s}({s})\n", .{ mangled_name, args_str.items });
                        } else {
                            for (c.arguments, 0..) |arg, idx| {
                                const arg_val = try self.genExpr(arg);
                                var val_to_insert = arg_val;
                                const t_to_insert = typeToLLVM(self.allocator, arg.inferred_type orelse .{ .kind = .Any });
                                const field_t = typeToLLVM(self.allocator, ct.fields[idx].type_kind);

                                val_to_insert = try self.coerceType(val_to_insert, t_to_insert, field_t);

                                const field_gep = self.nextTemp();
                                try writer.print("  %t.{d} = getelementptr inbounds %{s}, ptr {s}, i32 0, i32 {d}\n", .{ field_gep, ct.name, ptr_name, idx });
                                try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ field_t, val_to_insert, field_gep });
                            }
                        }
                        return ptr_name;
                    } else if (is_struct) {
                        const st = c.callee.inferred_type.?.struct_type.?;
                        var init_method: ?*types.FunctionType = null;
                        var init_mangled_name: []const u8 = "";
                        for (st.methods) |cm| {
                            if (std.mem.endsWith(u8, cm.name, "___init__")) {
                                init_method = cm.type_kind.function;
                                init_mangled_name = cm.name;
                                break;
                            }
                        }

                        if (init_method) |init_fn| {
                            const align_req = layout.getAlign(c.callee.inferred_type.?, layout.Target.x86_64_linux);
                            const alloca_temp = self.nextTemp();
                            try writer.print("  %t.{d} = alloca %{s}, align {d}\n", .{ alloca_temp, st.name, align_req });
                            try writer.print("  store %{s} zeroinitializer, ptr %t.{d}, align {d}\n", .{ st.name, alloca_temp, align_req });

                            var args_str = std.ArrayList(u8).init(self.allocator);
                            try args_str.appendSlice("ptr null, ptr %t."); // env parameter and self
                            try std.fmt.format(args_str.writer(), "{d}", .{alloca_temp});

                            for (c.arguments, 0..) |arg, idx| {
                                const arg_val = try self.genExpr(arg);
                                var val_to_pass = arg_val;
                                const arg_inferred = arg.inferred_type orelse types.Type{ .kind = .Any };
                                const source_t = typeToLLVM(self.allocator, arg_inferred);
                                
                                var target_t = source_t;
                                var expected_type = arg_inferred;
                                if (idx + 1 < init_fn.param_types.len) {
                                    expected_type = init_fn.param_types[idx + 1];
                                    target_t = typeToLLVM(self.allocator, expected_type);
                                }

                                val_to_pass = try self.coerceType(val_to_pass, source_t, target_t);

                                const sig = abi.getArgABI(expected_type, layout.Target.x86_64_linux);
                                const align_req_arg = layout.getAlign(expected_type, layout.Target.x86_64_linux);
                                
                                try args_str.appendSlice(", ");
                                if (sig.mode == .ByVal) {
                                    const temp_alloc = self.nextTemp();
                                    try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, target_t, align_req_arg });
                                    try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ target_t, val_to_pass, temp_alloc, align_req_arg });
                                    try std.fmt.format(args_str.writer(), "ptr byval({s}) %t.{d}", .{ target_t, temp_alloc });
                                } else if (sig.mode == .Coerce) {
                                    const temp_alloc = self.nextTemp();
                                    try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, target_t, align_req_arg });
                                    try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ target_t, val_to_pass, temp_alloc, align_req_arg });
                                    const cast_load = self.nextTemp();
                                    try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ cast_load, sig.llvm_type, temp_alloc, align_req_arg });
                                    try std.fmt.format(args_str.writer(), "{s} %t.{d}", .{ sig.llvm_type, cast_load });
                                } else {
                                    try std.fmt.format(args_str.writer(), "{s} {s}", .{ target_t, val_to_pass });
                                }
                            }
                            try writer.print("  call void @{s}({s})\n", .{ init_mangled_name, args_str.items });

                            const load_temp = self.nextTemp();
                            try writer.print("  %t.{d} = load %{s}, ptr %t.{d}, align {d}\n", .{ load_temp, st.name, alloca_temp, align_req });
                            return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{load_temp});
                        } else {
                            var struct_val = try std.fmt.allocPrint(self.allocator, "zeroinitializer", .{});
                            var current_temp: u32 = 0;
                            for (c.arguments, 0..) |arg, i| {
                                const arg_val = try self.genExpr(arg);
                                var val_to_insert = arg_val;
                                var t_to_insert = typeToLLVM(self.allocator, arg.inferred_type orelse .{ .kind = .Any });
                                const field_t = typeToLLVM(self.allocator, st.fields[i].type_kind);

                                val_to_insert = try self.coerceType(val_to_insert, t_to_insert, field_t);
                                t_to_insert = field_t;

                                current_temp = self.nextTemp();
                                try writer.print("  %t.{d} = insertvalue %{s} {s}, {s} {s}, {d}\n", .{ current_temp, st.name, struct_val, t_to_insert, val_to_insert, i });
                                struct_val = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{current_temp});
                            }
                            return struct_val;
                        }
                    } else if (c.callee.data.Identifier.resolved_symbol != null and c.callee.data.Identifier.resolved_symbol.?.kind == .Union) {
                        const ut = c.callee.inferred_type.?.union_type.?;
                        const kw_arg = c.arguments[0].data.KeywordArg;
                        const arg_val = try self.genExpr(kw_arg.value);
                        const arg_t = typeToLLVM(self.allocator, kw_arg.value.inferred_type orelse .{ .kind = .Any });

                        const alloca_temp = self.nextTemp();
                        const alloca_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{alloca_temp});
                        try writer.print("  {s} = alloca %{s}\n", .{ alloca_name, ut.name });

                        if (ut.tag_type) |tag_t| {
                            var field_idx: usize = 0;
                            for (ut.fields, 0..) |uf, idx| {
                                if (std.mem.eql(u8, uf.name, kw_arg.name)) {
                                    field_idx = idx;
                                    break;
                                }
                            }
                            const tag_t_llvm = typeToLLVM(self.allocator, tag_t);
                            const tag_val_temp = self.nextTemp();
                            const tag_val_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{tag_val_temp});
                            try writer.print("  {s} = insertvalue {s} zeroinitializer, i32 {d}, 0\n", .{ tag_val_name, tag_t_llvm, field_idx });

                            const tag_ptr_temp = self.nextTemp();
                            const tag_ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{tag_ptr_temp});
                            try writer.print("  {s} = getelementptr %{s}, ptr {s}, i32 0, i32 0\n", .{ tag_ptr_name, ut.name, alloca_name });
                            try writer.print("  store {s} {s}, ptr {s}\n", .{ tag_t_llvm, tag_val_name, tag_ptr_name });

                            const payload_ptr_temp = self.nextTemp();
                            const payload_ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{payload_ptr_temp});
                            try writer.print("  {s} = getelementptr %{s}, ptr {s}, i32 0, i32 1\n", .{ payload_ptr_name, ut.name, alloca_name });
                            try writer.print("  store {s} {s}, ptr {s}\n", .{ arg_t, arg_val, payload_ptr_name });
                        } else {
                            try writer.print("  store {s} {s}, ptr {s}\n", .{ arg_t, arg_val, alloca_name });
                        }

                        const load_temp = self.nextTemp();
                        const load_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{load_temp});
                        try writer.print("  {s} = load %{s}, ptr {s}\n", .{ load_name, ut.name, alloca_name });
                        
                        return load_name;
                    } else {
                        var arg_str = std.ArrayList(u8).init(self.allocator);
                        const needs_env = is_user_func and !is_extern and !std.mem.eql(u8, func_name, "main");
                        if (needs_env) {
                            try arg_str.appendSlice("ptr null");
                        }
                        var is_variadic = false;
                        var variadic_start: usize = 0;
                        if (is_module_call) {
                            const me = &c.callee.data.MemberExpr;
                            const me_obj_type = me.object.inferred_type.?;
                            const mod_scope = @as(*symbols.Scope, @ptrCast(@alignCast(me_obj_type.module_scope.?)));
                            if (mod_scope.resolveLocal(me.property)) |sym| {
                                if (sym.kind == .Function and sym.decl_node != null) {
                                    if (sym.decl_node.?.node_type == .FunDecl) {
                                        is_variadic = sym.decl_node.?.data.FunDecl.is_variadic;
                                        if (sym.decl_node.?.data.FunDecl.params.len > 0) {
                                            variadic_start = sym.decl_node.?.data.FunDecl.params.len - 1;
                                        }
                                    }
                                }
                            }
                        } else if (c.callee.node_type == .Identifier) {
                            if (c.callee.data.Identifier.resolved_symbol) |sym| {
                                if (sym.kind == .Function and sym.decl_node != null) {
                                    if (sym.decl_node.?.node_type == .FunDecl) {
                                        is_variadic = sym.decl_node.?.data.FunDecl.is_variadic;
                                        if (sym.decl_node.?.data.FunDecl.params.len > 0) {
                                            variadic_start = sym.decl_node.?.data.FunDecl.params.len - 1;
                                        }
                                    }
                                }
                            }
                        }

                        var actual_args = std.ArrayList(*ast.Node).init(self.allocator);
                        if (is_variadic and !is_extern and variadic_start <= c.arguments.len) {
                            for (c.arguments[0..variadic_start]) |arg| {
                                try actual_args.append(arg);
                            }
                            const var_args = c.arguments[variadic_start..];
                            if (var_args.len == 1 and var_args[0].node_type == .SpreadExpr) {
                                try actual_args.append(var_args[0].data.SpreadExpr.iterable);
                            } else {
                                const list_node = try self.allocator.create(ast.Node);
                                list_node.* = .{
                                    .node_type = .ListLiteral,
                                    .span = node.span,
                                    .inferred_type = .{ .kind = .List },
                                    .data = .{
                                        .ListLiteral = .{
                                            .elements = var_args,
                                        },
                                    },
                                };
                                try actual_args.append(list_node);
                            }
                        } else {
                            for (c.arguments) |arg| {
                                try actual_args.append(arg);
                            }
                        }

                        const processed_args = actual_args.items;
                        for (processed_args, 0..) |arg, i| {
                            if (needs_env or i > 0) try arg_str.appendSlice(", ");
                            var arg_val = try self.genExpr(arg);
                            var inferred: types.Type = arg.inferred_type orelse types.Type{ .kind = .Any };
                            if (inferred.kind == .Any and arg.node_type == .Identifier) {
                                if (arg.data.Identifier.resolved_symbol) |sym| {
                                    if (sym.decl_node) |decl| {
                                        if (decl.inferred_type) |dt| inferred = dt;
                                    }
                                }
                            }
                            const source_t = typeToLLVM(self.allocator, inferred);
                            var target_type = inferred;
                            if (c.callee.inferred_type) |callee_t| {
                                if (callee_t.kind == .Function and callee_t.function != null) {
                                    const params = callee_t.function.?.param_types;
                                    const is_var = callee_t.function.?.is_variadic;
                                    const fixed_count = if (is_var and params.len > 0) params.len - 1 else params.len;
                                    if (i < fixed_count) {
                                        target_type = params[i];
                                    } else if (is_extern) {
                                        target_type = inferred;
                                    }
                                }
                            }
                            const target_t = typeToLLVM(self.allocator, target_type);
                            arg_val = try self.coerceType(arg_val, source_t, target_t);
                            const sig = if (is_extern) abi.ABISignature{ .mode = .Direct, .llvm_type = target_t, .is_struct = false } else abi.getArgABI(target_type, layout.Target.x86_64_linux);
                            const align_req = layout.getAlign(target_type, layout.Target.x86_64_linux);
                            
                            if (sig.mode == .ByVal) {
                                const temp_alloc = self.nextTemp();
                                try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, target_t, align_req });
                                try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ target_t, arg_val, temp_alloc, align_req });
                                try std.fmt.format(arg_str.writer(), "ptr byval({s}) %t.{d}", .{ target_t, temp_alloc });
                            } else if (sig.mode == .Coerce) {
                                const temp_alloc = self.nextTemp();
                                try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, target_t, align_req });
                                try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ target_t, arg_val, temp_alloc, align_req });
                                const cast_load = self.nextTemp();
                                try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ cast_load, sig.llvm_type, temp_alloc, align_req });
                                try std.fmt.format(arg_str.writer(), "{s} %t.{d}", .{ sig.llvm_type, cast_load });
                            } else {
                                try std.fmt.format(arg_str.writer(), "{s} {s}", .{ target_t, arg_val });
                            }
                        }

                        var actual_ret_type: types.Type = node.inferred_type orelse types.Type{ .kind = .Any };
                        if (c.callee.inferred_type) |callee_t| {
                            if (callee_t.kind == .Function and callee_t.function != null) {
                                actual_ret_type = callee_t.function.?.return_type.*;
                            }
                        }
                        const ret_t = typeToLLVM(self.allocator, actual_ret_type);
                        const ret_sig = abi.getRetABI(actual_ret_type, layout.Target.x86_64_linux);
                        const final_ret_t = if (ret_sig.mode == .Coerce) ret_sig.llvm_type else ret_t;

                        if (std.mem.eql(u8, final_ret_t, "void")) {
                            try writer.print("  call {s} @{s}({s})\n", .{ final_ret_t, func_name, arg_str.items });
                            return "null";
                        } else {
                            const call_temp = self.nextTemp();
                            const call_temp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{call_temp});
                            try writer.print("  {s} = call {s} @{s}({s})\n", .{ call_temp_name, final_ret_t, func_name, arg_str.items });
                            
                            if (ret_sig.mode == .Coerce) {
                                const ret_align = layout.getAlign(actual_ret_type, layout.Target.x86_64_linux);
                                const temp_alloc = self.nextTemp();
                                try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, ret_t, ret_align });
                                try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ final_ret_t, call_temp_name, temp_alloc, ret_align });
                                const final_val = self.nextTemp();
                                try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ final_val, ret_t, temp_alloc, ret_align });
                                return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{final_val});
                            }
                            
                            return call_temp_name;
                        }
                    }
                }
                return "null";
            },
            .IndexExpr => |*idx| {
                const obj_val = try self.genExpr(idx.object);
                const index_val = try self.genExpr(idx.index);
                
                const obj_type = idx.object.inferred_type orelse types.Type{ .kind = .Any };
                
                if (obj_type.kind == .List) {
                    var inner_type = types.Type{ .kind = .Any };
                    if (obj_type.payload) |p| inner_type = p.*;
                    const inner_llvm = typeToLLVM(self.allocator, inner_type);
                    
                    const index_llvm = typeToLLVM(self.allocator, idx.index.inferred_type orelse types.Type{ .kind = .Any });
                    const coerced_index = try self.coerceType(index_val, index_llvm, "i64");
                    
                    const len_temp = self.nextTemp();
                    try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 1\n", .{ len_temp, obj_val });
                    
                    const cmp_low = self.nextTemp();
                    try writer.print("  %t.{d} = icmp slt i64 {s}, 0\n", .{ cmp_low, coerced_index });
                    
                    const cmp_high = self.nextTemp();
                    try writer.print("  %t.{d} = icmp sge i64 {s}, %t.{d}\n", .{ cmp_high, coerced_index, len_temp });
                    
                    const cmp_or = self.nextTemp();
                    try writer.print("  %t.{d} = or i1 %t.{d}, %t.{d}\n", .{ cmp_or, cmp_low, cmp_high });
                    
                    const cond_id = self.nextTemp();
                    const panic_lbl = try std.fmt.allocPrint(self.allocator, "idx.panic.{d}", .{cond_id});
                    const ok_lbl = try std.fmt.allocPrint(self.allocator, "idx.ok.{d}", .{cond_id});
                    
                    try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cmp_or, panic_lbl, ok_lbl });
                    
                    try writer.print("{s}:\n", .{panic_lbl});
                    try writer.print("  call void @mantiq_panic_at(ptr @.panic_str_bounds, ptr @.str_file, i32 {d}, i32 {d})\n", .{ node.span.start_row + 1, node.span.start_col + 1 });
                    try writer.print("  unreachable\n", .{});
                    
                    try writer.print("{s}:\n", .{ok_lbl});
                    
                    const ptr_temp = self.nextTemp();
                    try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 0\n", .{ ptr_temp, obj_val });
                    
                    const elem_ptr = self.nextTemp();
                    try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr %t.{d}, i64 {s}\n", .{ elem_ptr, inner_llvm, ptr_temp, coerced_index });
                    
                    const item_val = self.nextTemp();
                    try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ item_val, inner_llvm, elem_ptr });
                    return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{item_val});
                    
                } else if (obj_type.kind == .RawPointer) {
                    var inner_type = types.Type{ .kind = .U8 };
                    if (obj_type.payload) |p| inner_type = p.*;
                    const inner_llvm = typeToLLVM(self.allocator, inner_type);
                    
                    const index_llvm = typeToLLVM(self.allocator, idx.index.inferred_type orelse types.Type{ .kind = .Any });
                    const coerced_index = try self.coerceType(index_val, index_llvm, "i64");
                    
                    const elem_ptr = self.nextTemp();
                    try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr {s}, i64 {s}\n", .{ elem_ptr, inner_llvm, obj_val, coerced_index });
                    
                    const item_val = self.nextTemp();
                    try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ item_val, inner_llvm, elem_ptr });
                    return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{item_val});
                } else if (obj_type.kind == .Dict) {
                    var k_type = types.Type{ .kind = .Any };
                    var v_type = types.Type{ .kind = .Any };
                    var k_kind: types.TypeKind = .I32;
                    if (obj_type.tuple_types) |tt| {
                        if (tt.len == 2) {
                            k_type = tt[0];
                            v_type = tt[1];
                            k_kind = tt[0].kind;
                        }
                    }
                    const k_llvm = typeToLLVM(self.allocator, k_type);
                    const v_llvm = typeToLLVM(self.allocator, v_type);
                    
                    const ptr_temp = self.nextTemp();
                    try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 0\n", .{ ptr_temp, obj_val });
                    
                    const k_size_ptr = self.nextTemp();
                    const k_size_int = self.nextTemp();
                    try writer.print("  %t.{d} = getelementptr {s}, ptr null, i32 1\n", .{ k_size_ptr, k_llvm });
                    try writer.print("  %t.{d} = ptrtoint ptr %t.{d} to i32\n", .{ k_size_int, k_size_ptr });
                    
                    const hash_temp = self.nextTemp();
                    const k_alloc = self.nextTemp();
                    try writer.print("  %t.{d} = alloca {s}\n", .{ k_alloc, k_llvm });
                    try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ k_llvm, index_val, k_alloc });
                    
                    if (isStringLikeType(k_type)) {
                        const str_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ str_ptr, k_llvm, index_val });
                        const str_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ str_len, k_llvm, index_val });
                        try writer.print("  %t.{d} = call i32 @__mantiq_hash_string(ptr %t.{d}, i64 %t.{d})\n", .{ hash_temp, str_ptr, str_len });
                    } else {
                        const byte_len = self.nextTemp();
                        try writer.print("  %t.{d} = zext i32 %t.{d} to i64\n", .{ byte_len, k_size_int });
                        try writer.print("  %t.{d} = call i32 @__mantiq_hash_bytes(ptr %t.{d}, i64 %t.{d})\n", .{ hash_temp, k_alloc, byte_len });
                    }
                    
                    const res_ptr = self.nextTemp();
                    try writer.print("  %t.{d} = call ptr @__mantiq_dict_get(ptr %t.{d}, ptr %t.{d}, i32 %t.{d})\n", .{ res_ptr, ptr_temp, k_alloc, hash_temp });
                    
                    const final_v = self.nextTemp();
                    try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ final_v, v_llvm, res_ptr });
                    return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{final_v});
                }
                
                return "null";
            },
            .ListLiteral => |*l| {
                if (l.elements.len == 0) return "zeroinitializer";

                // Find a concrete element type (skip SpreadExprs to find the underlying type if possible, or assume Any)
                var elem_t: []const u8 = "i32"; // default
                for (l.elements) |el| {
                    if (el.node_type != .SpreadExpr) {
                        elem_t = typeToLLVM(self.allocator, el.inferred_type orelse .{ .kind = .Any });
                        break;
                    }
                }

                if (self.is_global) return "undef";

                // 1. Calculate dynamic size
                const total_len_temp = self.nextTemp();
                try writer.print("  %t.{d} = alloca i64\n", .{total_len_temp});
                try writer.print("  store i64 0, ptr %t.{d}\n", .{total_len_temp});

                // Pre-evaluate iterables for spread expressions so we can extract their lengths
                var spread_vals = std.ArrayList([]const u8).init(self.allocator);
                for (l.elements) |element| {
                    if (element.node_type == .SpreadExpr) {
                        const iterable_val = try self.genExpr(element.data.SpreadExpr.iterable);
                        try spread_vals.append(iterable_val);

                        const spread_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 1\n", .{ spread_len, iterable_val });

                        const curr_len = self.nextTemp();
                        try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ curr_len, total_len_temp });
                        const new_len = self.nextTemp();
                        try writer.print("  %t.{d} = add i64 %t.{d}, %t.{d}\n", .{ new_len, curr_len, spread_len });
                        try writer.print("  store i64 %t.{d}, ptr %t.{d}\n", .{ new_len, total_len_temp });
                    } else {
                        try spread_vals.append("");
                        const curr_len = self.nextTemp();
                        try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ curr_len, total_len_temp });
                        const new_len = self.nextTemp();
                        try writer.print("  %t.{d} = add i64 %t.{d}, 1\n", .{ new_len, curr_len });
                        try writer.print("  store i64 %t.{d}, ptr %t.{d}\n", .{ new_len, total_len_temp });
                    }
                }

                // 2. Allocate heap buffer
                const final_len = self.nextTemp();
                try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ final_len, total_len_temp });

                const size_ptr = self.nextTemp();
                const size_int = self.nextTemp();
                try writer.print("  %t.{d} = getelementptr {s}, ptr null, i32 1\n", .{ size_ptr, elem_t });
                try writer.print("  %t.{d} = ptrtoint ptr %t.{d} to i64\n", .{ size_int, size_ptr });

                const byte_size = self.nextTemp();
                try writer.print("  %t.{d} = mul i64 %t.{d}, %t.{d}\n", .{ byte_size, final_len, size_int });

                const ptr_temp = self.nextTemp();
                const ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ptr_temp});
                try writer.print("  {s} = call ptr @mantiq_malloc(i64 %t.{d})\n", .{ ptr_name, byte_size });

                // 3. Store elements
                const write_idx_temp = self.nextTemp();
                try writer.print("  %t.{d} = alloca i64\n", .{write_idx_temp});
                try writer.print("  store i64 0, ptr %t.{d}\n", .{write_idx_temp});

                var spread_idx: usize = 0;
                for (l.elements) |element| {
                    if (element.node_type == .SpreadExpr) {
                        const iterable_val = spread_vals.items[spread_idx];

                        const src_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 0\n", .{ src_ptr, iterable_val });

                        const spread_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 1\n", .{ spread_len, iterable_val });

                        // Copy loop
                        const loop_id = self.temp_counter;
                        self.temp_counter += 1;
                        const loop_cond = try std.fmt.allocPrint(self.allocator, "spread.cond.{d}", .{loop_id});
                        const loop_body = try std.fmt.allocPrint(self.allocator, "spread.body.{d}", .{loop_id});
                        const loop_end = try std.fmt.allocPrint(self.allocator, "spread.end.{d}", .{loop_id});

                        const i_temp = self.nextTemp();
                        try writer.print("  %t.{d} = alloca i64\n", .{i_temp});
                        try writer.print("  store i64 0, ptr %t.{d}\n", .{i_temp});

                        try writer.print("  br label %{s}\n", .{loop_cond});
                        try writer.print("{s}:\n", .{loop_cond});

                        const curr_i = self.nextTemp();
                        try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ curr_i, i_temp });
                        const cmp = self.nextTemp();
                        try writer.print("  %t.{d} = icmp slt i64 %t.{d}, %t.{d}\n", .{ cmp, curr_i, spread_len });
                        try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cmp, loop_body, loop_end });

                        try writer.print("{s}:\n", .{loop_body});

                        // Load from src
                        const src_elem_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr %t.{d}, i64 %t.{d}\n", .{ src_elem_ptr, elem_t, src_ptr, curr_i });
                        const val = self.nextTemp();
                        try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ val, elem_t, src_elem_ptr });

                        // Store to dest
                        const curr_write_idx = self.nextTemp();
                        try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ curr_write_idx, write_idx_temp });
                        const dest_elem_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr {s}, i64 %t.{d}\n", .{ dest_elem_ptr, elem_t, ptr_name, curr_write_idx });
                        try writer.print("  store {s} %t.{d}, ptr %t.{d}\n", .{ elem_t, val, dest_elem_ptr });

                        // Increment write_idx and i
                        const next_write_idx = self.nextTemp();
                        try writer.print("  %t.{d} = add i64 %t.{d}, 1\n", .{ next_write_idx, curr_write_idx });
                        try writer.print("  store i64 %t.{d}, ptr %t.{d}\n", .{ next_write_idx, write_idx_temp });

                        const next_i = self.nextTemp();
                        try writer.print("  %t.{d} = add i64 %t.{d}, 1\n", .{ next_i, curr_i });
                        try writer.print("  store i64 %t.{d}, ptr %t.{d}\n", .{ next_i, i_temp });

                        try writer.print("  br label %{s}\n", .{loop_cond});
                        try writer.print("{s}:\n", .{loop_end});
                    } else {
                        const elem_val = try self.genExpr(element);

                        const curr_write_idx = self.nextTemp();
                        try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ curr_write_idx, write_idx_temp });

                        const dest_elem_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr {s}, i64 %t.{d}\n", .{ dest_elem_ptr, elem_t, ptr_name, curr_write_idx });

                        try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ elem_t, elem_val, dest_elem_ptr });

                        const next_write_idx = self.nextTemp();
                        try writer.print("  %t.{d} = add i64 %t.{d}, 1\n", .{ next_write_idx, curr_write_idx });
                        try writer.print("  store i64 %t.{d}, ptr %t.{d}\n", .{ next_write_idx, write_idx_temp });
                    }
                    spread_idx += 1;
                }

                // 4. Construct { ptr, i64, i64 }
                const fat_temp1 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} undef, ptr {s}, 0\n", .{ fat_temp1, ptr_name });
                const fat_temp2 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 %t.{d}, 1\n", .{ fat_temp2, fat_temp1, final_len });
                const fat_temp3 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 %t.{d}, 2\n", .{ fat_temp3, fat_temp2, final_len });

                const fat_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp3});
                try self.registerTemp(fat_name, ptr_name);
                return fat_name;
            },
            .DictLiteral => |*d| {
                if (d.keys.len == 0) return "zeroinitializer";
                if (self.is_global) return "undef";
                
                const dict_type = node.inferred_type orelse types.Type{ .kind = .Any };
                var k_type: []const u8 = "i32";
                var v_type: []const u8 = "i32";
                var k_kind: types.TypeKind = .I32;
                var k_ast_type = types.Type{ .kind = .Any };
                var v_ast_type = types.Type{ .kind = .Any };
                if (dict_type.tuple_types) |tt| {
                    if (tt.len == 2) {
                        k_ast_type = tt[0];
                        v_ast_type = tt[1];
                        k_type = typeToLLVM(self.allocator, tt[0]);
                        v_type = typeToLLVM(self.allocator, tt[1]);
                        k_kind = tt[0].kind;
                    }
                }
                
                const k_size_int = types.getTypeSize(k_ast_type);
                const v_size_int = types.getTypeSize(v_ast_type);
                
                const is_str_flag: u32 = getDictStringKeyFlag(k_ast_type);

                const dict_ptr = self.nextTemp();
                const dict_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{dict_ptr});
                try writer.print("  {s} = call ptr @__mantiq_dict_create(i32 {d}, i32 {d}, i32 {d})\n", .{ dict_name, k_size_int, v_size_int, is_str_flag });
                
                for (d.keys, 0..) |k, i| {
                    const v = d.values[i];
                    const k_val = try self.genExpr(k);
                    const v_val = try self.genExpr(v);
                    
                    const k_alloc = self.nextTemp();
                    try writer.print("  %t.{d} = alloca {s}\n", .{ k_alloc, k_type });
                    try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ k_type, k_val, k_alloc });
                    
                    const v_alloc = self.nextTemp();
                    try writer.print("  %t.{d} = alloca {s}\n", .{ v_alloc, v_type });
                    try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ v_type, v_val, v_alloc });
                    
                    const hash_temp = self.nextTemp();
                    if (isStringLikeType(k_ast_type)) {
                        const str_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ str_ptr, k_type, k_val });
                        const str_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ str_len, k_type, k_val });
                        try writer.print("  %t.{d} = call i32 @__mantiq_hash_string(ptr %t.{d}, i64 %t.{d})\n", .{ hash_temp, str_ptr, str_len });
                    } else {
                        const byte_len = self.nextTemp();
                        try writer.print("  %t.{d} = zext i32 %t.{d} to i64\n", .{ byte_len, k_size_int });
                        try writer.print("  %t.{d} = call i32 @__mantiq_hash_bytes(ptr %t.{d}, i64 %t.{d})\n", .{ hash_temp, k_alloc, byte_len });
                    }
                    
                    try writer.print("  call void @__mantiq_dict_set(ptr {s}, ptr %t.{d}, ptr %t.{d}, i32 %t.{d})\n", .{ dict_name, k_alloc, v_alloc, hash_temp });
                }
                
                const final_len_str = try std.fmt.allocPrint(self.allocator, "{d}", .{ d.keys.len });
                const fat_temp1 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} undef, ptr {s}, 0\n", .{ fat_temp1, dict_name });
                const fat_temp2 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 {s}, 1\n", .{ fat_temp2, fat_temp1, final_len_str });
                const fat_temp3 = self.nextTemp();
                try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 {s}, 2\n", .{ fat_temp3, fat_temp2, final_len_str });
                
                const fat_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat_temp3});
                try self.registerTemp(fat_name, dict_name);
                return fat_name;
            },
            .SpawnStmt => |*s| {
                const call_expr = s.call_expr;
                if (call_expr.node_type == .CallExpr) {
                    const func_name = call_expr.data.CallExpr.callee.data.Identifier.name;

                    var is_user_func = false;
                    var is_extern = false;
                    var resolved_func_name = func_name;
                    if (self.getCalleeDeclNode(call_expr.data.CallExpr.callee, false)) |decl| {
                        if (decl.node_type == .FunDecl) {
                            is_user_func = true;
                            const f = &decl.data.FunDecl;
                            is_extern = f.is_extern;
                            if (!f.is_extern) {
                                if (decl.module_name) |mod_name| {
                                    if (!std.mem.eql(u8, f.name, "main")) {
                                        resolved_func_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, f.name });
                                    }
                                }
                            }
                        }
                    }

                    var actual_ret_type: types.Type = node.inferred_type orelse .{ .kind = .Any };
                    if (actual_ret_type.kind == .Task and actual_ret_type.payload != null) {
                        actual_ret_type = actual_ret_type.payload.?.*;
                    }
                    const ret_t = typeToLLVM(self.allocator, actual_ret_type);

                    const env_struct_name = try std.fmt.allocPrint(self.allocator, "%env_struct_{s}", .{func_name});
                    var env_types = std.ArrayList(u8).init(self.allocator);
                    for (call_expr.data.CallExpr.arguments, 0..) |arg, i| {
                        if (i > 0) try env_types.appendSlice(", ");
                        const arg_t = typeToLLVM(self.allocator, arg.inferred_type orelse .{ .kind = .Any });
                        try std.fmt.format(env_types.writer(), "{s}", .{arg_t});
                    }
                    try self.type_out.writer().print("{s} = type {{ {s} }}\n", .{ env_struct_name, env_types.items });

                    const env_ptr_temp = self.nextTemp();
                    const env_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{env_ptr_temp});
                    try writer.print("  {s} = call ptr @mantiq_malloc(i64 128)\n", .{env_name});

                    for (call_expr.data.CallExpr.arguments, 0..) |arg, i| {
                        const arg_val = try self.genExpr(arg);
                        const arg_t = typeToLLVM(self.allocator, arg.inferred_type orelse .{ .kind = .Any });
                        const field_ptr_temp = self.nextTemp();
                        try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr {s}, i32 0, i32 {d}\n", .{ field_ptr_temp, env_struct_name, env_name, i });
                        try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ arg_t, arg_val, field_ptr_temp });
                    }

                    const trampoline_name = try std.fmt.allocPrint(self.allocator, "{s}_trampoline_{d}", .{ func_name, self.nextTemp() });
                    var outline_writer = self.outlined_out.writer();
                    try outline_writer.print("define ptr @{s}(ptr %env) {{\n", .{trampoline_name});
                    try outline_writer.print("entry:\n", .{});

                    var call_args = std.ArrayList(u8).init(self.allocator);
                    const spawn_needs_env = is_user_func and !is_extern and !std.mem.eql(u8, resolved_func_name, "main");
                    if (spawn_needs_env) {
                        try call_args.appendSlice("ptr null");
                    }
                    for (call_expr.data.CallExpr.arguments, 0..) |arg, i| {
                        const arg_t = typeToLLVM(self.allocator, arg.inferred_type orelse .{ .kind = .Any });
                        try outline_writer.print("  %arg_ptr.{d} = getelementptr inbounds {s}, ptr %env, i32 0, i32 {d}\n", .{ i, env_struct_name, i });
                        try outline_writer.print("  %arg.{d} = load {s}, ptr %arg_ptr.{d}\n", .{ i, arg_t, i });
                        if (spawn_needs_env or i > 0) try call_args.appendSlice(", ");
                        try std.fmt.format(call_args.writer(), "{s} %arg.{d}", .{ arg_t, i });
                    }
                    if (std.mem.eql(u8, ret_t, "void")) {
                        try outline_writer.print("  call {s} @{s}({s})\n", .{ ret_t, resolved_func_name, call_args.items });
                        try outline_writer.print("  ret ptr null\n", .{});
                    } else {
                        try outline_writer.print("  %res = call {s} @{s}({s})\n", .{ ret_t, resolved_func_name, call_args.items });
                        try outline_writer.print("  %res_ptr = call ptr @mantiq_malloc(i64 128)\n", .{});
                        try outline_writer.print("  store {s} %res, ptr %res_ptr\n", .{ret_t});
                        try outline_writer.print("  ret ptr %res_ptr\n", .{});
                    }
                    try outline_writer.print("}}\n\n", .{});

                    const task_ptr = self.nextTemp();
                    const task_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{task_ptr});
                    try writer.print("  {s} = call ptr @mantiq_spawn(ptr @{s}, ptr {s})\n", .{ task_name, trampoline_name, env_name });
                    try self.registerTemp(task_name, task_name);
                    return task_name;
                } else if (call_expr.node_type == .ClosureExpr) {
                    const closure_name = try self.genExpr(call_expr);
                    const task_ptr = self.nextTemp();
                    const task_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{task_ptr});
                    try writer.print("  {s} = call ptr @mantiq_spawn(ptr @{s}, ptr null)\n", .{ task_name, closure_name });
                    try self.registerTemp(task_name, task_name);
                    return task_name;
                }
                return "null";
            },
            .AwaitExpr => |*a| {
                const task_val = try self.genExpr(a.task_expr);
                const await_temp = self.nextTemp();
                const await_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{await_temp});

                try writer.print("  {s} = call ptr @mantiq_await(ptr {s})\n", .{ await_name, task_val });

                const t = typeToLLVM(self.allocator, node.inferred_type orelse .{ .kind = .Any });
                if (std.mem.eql(u8, t, "void")) {
                    return "null";
                }
                const loaded_temp = self.nextTemp();
                const loaded_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{loaded_temp});
                try writer.print("  {s} = load {s}, ptr {s}\n", .{ loaded_name, t, await_name });
                return loaded_name;
            },
            .MemberExpr => |*m| {
                const obj_inferred: types.Type = m.object.inferred_type orelse .{ .kind = .Any };
                if (obj_inferred.kind == .Enum and obj_inferred.enum_type != null) {
                    const et = obj_inferred.enum_type.?;
                    var val: u32 = 0;
                    for (et.variants) |ev| {
                        if (std.mem.eql(u8, ev.name, m.property)) {
                            val = ev.value orelse 0;
                            break;
                        }
                    }
                    if (node.inferred_type != null and node.inferred_type.?.kind == .Enum) {
                        // Creating a payload-less variant instance!
                        const temp = self.nextTemp();
                        const temp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                        try writer.print("  {s} = insertvalue %{s} zeroinitializer, i32 {d}, 0\n", .{ temp_name, et.name, val });
                        return temp_name;
                    } else if (node.inferred_type != null and node.inferred_type.?.kind == .Function) {
                        // It's a constructor for a variant with a payload.
                        // We shouldn't evaluate it directly unless called.
                        // But since CallExpr might call genExpr on the callee, we return the variant value as a string
                        // so CallExpr knows which variant tag to use.
                        return try std.fmt.allocPrint(self.allocator, "{d}", .{val});
                    }
                }

                if (obj_inferred.kind == .Module) {
                    if (obj_inferred.module_scope) |scope_ptr| {
                        const mod_scope = @as(*symbols.Scope, @ptrCast(@alignCast(scope_ptr)));
                        if (mod_scope.resolveLocal(m.property)) |sym| {
                            if (sym.kind == .Function) {
                                const llvm_ns_name = if (sym.decl_node != null and sym.decl_node.?.module_name != null) 
                                    sym.decl_node.?.module_name.? 
                                else 
                                    m.object.data.Identifier.name;
                                return try std.fmt.allocPrint(self.allocator, "@{s}_{s}", .{ llvm_ns_name, m.property });
                            }
                        }
                    }
                    // For module variables:
                    var llvm_ns_name = m.object.data.Identifier.name;
                    if (obj_inferred.module_scope) |scope_ptr| {
                        const mod_scope = @as(*symbols.Scope, @ptrCast(@alignCast(scope_ptr)));
                        if (mod_scope.resolveLocal(m.property)) |sym| {
                            if (sym.decl_node != null and sym.decl_node.?.module_name != null) {
                                llvm_ns_name = sym.decl_node.?.module_name.?;
                            }
                        }
                    }
                    const global_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ llvm_ns_name, m.property });
                    const t = typeToLLVM(self.allocator, node.inferred_type orelse .{ .kind = .Any });
                    const temp = self.nextTemp();
                    const temp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                    try writer.print("  {s} = load {s}, ptr @{s}\n", .{ temp_name, t, global_name });
                    return temp_name;
                }

                const obj_val = try self.genExpr(m.object);
                if (obj_inferred.kind == .Struct and obj_inferred.struct_type != null) {
                    const st = obj_inferred.struct_type.?;
                    var field_idx: ?usize = null;
                    for (st.fields, 0..) |sf, i| {
                        if (std.mem.eql(u8, sf.name, m.property)) {
                            field_idx = i;
                            break;
                        }
                    }
                    if (field_idx) |idx| {
                        const temp = self.nextTemp();
                        const temp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp});
                        try writer.print("  {s} = extractvalue %{s} {s}, {d}\n", .{ temp_name, st.name, obj_val, idx });
                        return temp_name;
                    }
                } else if (obj_inferred.kind == .Union and obj_inferred.union_type != null) {
                    const ut = obj_inferred.union_type.?;
                    const alloca_temp = self.nextTemp();
                    const alloca_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{alloca_temp});
                    try writer.print("  {s} = alloca %{s}\n", .{ alloca_name, ut.name });
                    try writer.print("  store %{s} {s}, ptr {s}\n", .{ ut.name, obj_val, alloca_name });

                    if (ut.tag_type) |tag_t| {
                        if (std.mem.eql(u8, m.property, "tag") or std.mem.eql(u8, m.property, "active_tag")) {
                            const tag_t_llvm = typeToLLVM(self.allocator, tag_t);
                            const tag_ptr_temp = self.nextTemp();
                            const tag_ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{tag_ptr_temp});
                            try writer.print("  {s} = getelementptr %{s}, ptr {s}, i32 0, i32 0\n", .{ tag_ptr_name, ut.name, alloca_name });

                            const load_temp = self.nextTemp();
                            const load_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{load_temp});
                            try writer.print("  {s} = load {s}, ptr {s}\n", .{ load_name, tag_t_llvm, tag_ptr_name });
                            return load_name;
                        }

                        var field_t: ?types.Type = null;
                        for (ut.fields) |uf| {
                            if (std.mem.eql(u8, uf.name, m.property)) {
                                field_t = uf.type_kind;
                                break;
                            }
                        }
                        if (field_t) |ft| {
                            const ft_llvm = typeToLLVM(self.allocator, ft);
                            const payload_ptr_temp = self.nextTemp();
                            const payload_ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{payload_ptr_temp});
                            try writer.print("  {s} = getelementptr %{s}, ptr {s}, i32 0, i32 1\n", .{ payload_ptr_name, ut.name, alloca_name });

                            const load_temp = self.nextTemp();
                            const load_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{load_temp});
                            try writer.print("  {s} = load {s}, ptr {s}\n", .{ load_name, ft_llvm, payload_ptr_name });
                            return load_name;
                        }
                    } else {
                        var field_t: ?types.Type = null;
                        for (ut.fields) |uf| {
                            if (std.mem.eql(u8, uf.name, m.property)) {
                                field_t = uf.type_kind;
                                break;
                            }
                        }
                        if (field_t) |ft| {
                            const ft_llvm = typeToLLVM(self.allocator, ft);
                            const load_temp = self.nextTemp();
                            const load_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{load_temp});
                            try writer.print("  {s} = load {s}, ptr {s}\n", .{ load_name, ft_llvm, alloca_name });
                            return load_name;
                        }
                    }
                } else if (obj_inferred.kind == .Class and obj_inferred.class_type != null) {
                    const ct = obj_inferred.class_type.?;
                    var field_idx: ?usize = null;
                    for (ct.fields, 0..) |cf, i| {
                        if (std.mem.eql(u8, cf.name, m.property)) {
                            field_idx = i;
                            break;
                        }
                    }
                    if (field_idx) |idx| {
                        const ft = ct.fields[idx].type_kind;
                        const ft_llvm = typeToLLVM(self.allocator, ft);
                        const ptr_temp = self.nextTemp();
                        const ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ptr_temp});
                        try writer.print("  {s} = getelementptr inbounds %{s}, ptr {s}, i32 0, i32 {d}\n", .{ ptr_name, ct.name, obj_val, idx });
                        
                        const load_temp = self.nextTemp();
                        const load_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{load_temp});
                        try writer.print("  {s} = load {s}, ptr {s}\n", .{ load_name, ft_llvm, ptr_name });
                        return load_name;
                    }
                }

                const ptr_name = self.genLValue(node) catch "null";
                if (!std.mem.eql(u8, ptr_name, "null") and !std.mem.startsWith(u8, ptr_name, "error.")) {
                    const load_temp = self.nextTemp();
                    const load_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{load_temp});
                    var load_t: []const u8 = typeToLLVM(self.allocator, node.inferred_type orelse .{ .kind = .Any });
                    if (std.mem.eql(u8, load_t, "i64") or std.mem.eql(u8, load_t, "ptr") or std.mem.eql(u8, load_t, "null") or std.mem.eql(u8, load_t, "void")) {
                        if (std.mem.eql(u8, m.property, "op") or std.mem.eql(u8, m.property, "name") or std.mem.eql(u8, m.property, "module_name") or std.mem.eql(u8, m.property, "str_val")) load_t = "{ ptr, i64, i64 }"
                        else if (std.mem.eql(u8, m.property, "cond") or std.mem.eql(u8, m.property, "then_branch") or std.mem.eql(u8, m.property, "else_branch") or std.mem.eql(u8, m.property, "left") or std.mem.eql(u8, m.property, "right") or std.mem.eql(u8, m.property, "body") or std.mem.eql(u8, m.property, "data")) load_t = "ptr"
                        else if (std.mem.eql(u8, m.property, "kind")) load_t = "i32"
                        else load_t = "{ ptr, i64, i64 }";
                    }
                    try writer.print("  {s} = load {s}, ptr {s}\n", .{ load_name, load_t, ptr_name });
                    return load_name;
                }

                return "null";
            },
            .MethodCallExpr => |*m| {
                if (m.is_dynamic) {
                    const obj_raw: types.Type = m.receiver.inferred_type orelse .{ .kind = .Any };
                    if (obj_raw.kind == .Class and obj_raw.class_type != null) {
                        const ct = obj_raw.class_type.?;
                        var method_idx: ?usize = null;
                        for (ct.methods, 0..) |cm, i| {
                            if (std.mem.eql(u8, cm.name, m.method_name)) {
                                method_idx = i;
                                break;
                            }
                        }
                        if (method_idx) |idx| {
                            const obj_val = try self.genExpr(m.receiver);
                            const vptr_ptr = self.nextTemp();
                            const vptr_ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{vptr_ptr});
                            try writer.print("  {s} = getelementptr inbounds %{s}, ptr {s}, i32 0, i32 0\n", .{ vptr_ptr_name, ct.name, obj_val });
                            
                            const vptr = self.nextTemp();
                            const vptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{vptr});
                            try writer.print("  {s} = load ptr, ptr {s}\n", .{ vptr_name, vptr_ptr_name });

                            const func_ptr_ptr = self.nextTemp();
                            const func_ptr_ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{func_ptr_ptr});
                            try writer.print("  {s} = getelementptr inbounds ptr, ptr {s}, i32 {d}\n", .{ func_ptr_ptr_name, vptr_name, idx });
                            
                            const func_ptr = self.nextTemp();
                            const func_ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{func_ptr});
                            try writer.print("  {s} = load ptr, ptr {s}\n", .{ func_ptr_name, func_ptr_ptr_name });

                            var args_str = std.ArrayList(u8).init(self.allocator);
                            try args_str.appendSlice("ptr null, "); // env parameter
                            try args_str.appendSlice("ptr ");
                            try args_str.appendSlice(obj_val); // self
                            
                            for (m.arguments) |arg| {
                                const arg_val = try self.genExpr(arg);
                                const arg_t = typeToLLVM(self.allocator, arg.inferred_type orelse .{ .kind = .Any });
                                try args_str.appendSlice(", ");
                                try args_str.appendSlice(arg_t);
                                try args_str.appendSlice(" ");
                                try args_str.appendSlice(arg_val);
                            }

                            const ret_t = typeToLLVM(self.allocator, node.inferred_type orelse .{ .kind = .Any });
                            if (std.mem.eql(u8, ret_t, "void")) {
                                try writer.print("  call void {s}({s})\n", .{ func_ptr_name, args_str.items });
                                return "null";
                            } else {
                                const ret_temp = self.nextTemp();
                                const ret_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ret_temp});
                                try writer.print("  {s} = call {s} {s}({s})\n", .{ ret_name, ret_t, func_ptr_name, args_str.items });
                                return ret_name;
                            }
                        }
                    }
                    try writer.print("  ; dynamic dispatch call to {s}() not fully implemented in genExpr\n", .{m.method_name});
                    return "null";
                }

                // Static Dispatch
                const obj_raw: types.Type = m.receiver.inferred_type orelse .{ .kind = .Any };
                var obj_inferred = obj_raw;

                // Auto-dereference RawPointer to reach the underlying struct/union
                if (obj_inferred.kind == .RawPointer and obj_inferred.payload != null) {
                    const payload = obj_inferred.payload.?.*;
                    if (payload.kind == .Struct or payload.kind == .Union) {
                        obj_inferred = payload;
                    }
                }

                const receiver_is_rawptr = obj_raw.kind == .RawPointer;

                if ((obj_inferred.kind == .Struct and obj_inferred.struct_type != null) or 
                    (obj_inferred.kind == .Union and obj_inferred.union_type != null)) {
                    
                    const name = if (obj_inferred.kind == .Struct) obj_inferred.struct_type.?.name else obj_inferred.union_type.?.name;
                    const mangled_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ name, m.method_name });

                    if (!self.defined_functions.contains(mangled_name)) {
                        const methods = if (obj_inferred.kind == .Struct) obj_inferred.struct_type.?.methods else obj_inferred.union_type.?.methods;
                        for (methods) |meth| {
                            if (std.mem.eql(u8, meth.name, mangled_name)) {
                                try self.declareExternalFunctionFromType(mangled_name, meth.type_kind);
                                break;
                            }
                        }
                    }

                    var method_func_t: ?types.Type = null;
                    const methods = if (obj_inferred.kind == .Struct) obj_inferred.struct_type.?.methods else obj_inferred.union_type.?.methods;
                    for (methods) |meth| {
                        if (std.mem.eql(u8, meth.name, mangled_name)) {
                            method_func_t = meth.type_kind;
                            break;
                        }
                    }

                    var args_str = std.ArrayList(u8).init(self.allocator);
                    try args_str.appendSlice("ptr null");

                    const is_static = self.isTypeOrModuleNode(m.receiver);

                    if (!is_static) {
                        // Determine the expected type of `self` from the method signature
                        var self_target_type: types.Type = obj_raw;
                        if (method_func_t) |m_func| {
                            if (m_func.kind == .Function and m_func.function != null) {
                                const params = m_func.function.?.param_types;
                                if (params.len > 0) {
                                    self_target_type = params[0];
                                }
                            }
                        }

                        const target_is_ptr = self_target_type.kind == .RawPointer;

                        var self_val: []const u8 = undefined;
                        var self_source_type: types.Type = undefined;

                        if (target_is_ptr) {
                            if (receiver_is_rawptr) {
                                self_val = try self.genExpr(m.receiver);
                                self_source_type = obj_raw;
                            } else {
                                self_val = try self.genLValue(m.receiver);
                                self_source_type = types.Type{ .kind = .RawPointer, .payload = try self.allocator.create(types.Type) };
                                self_source_type.payload.?.* = obj_raw;
                            }
                        } else {
                            if (receiver_is_rawptr) {
                                const ptr_val = try self.genExpr(m.receiver);
                                const load_temp = self.nextTemp();
                                const struct_llvm = typeToLLVM(self.allocator, obj_inferred);
                                try writer.print("  %t.{d} = load {s}, ptr {s}\n", .{ load_temp, struct_llvm, ptr_val });
                                self_val = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{load_temp});
                                self_source_type = obj_inferred;
                            } else {
                                self_val = try self.genExpr(m.receiver);
                                self_source_type = obj_raw;
                            }
                        }

                        const self_source_t = typeToLLVM(self.allocator, self_source_type);
                        const self_target_t = typeToLLVM(self.allocator, self_target_type);
                        self_val = try self.coerceType(self_val, self_source_t, self_target_t);

                        // Pass according to ABI
                        const sig = abi.getArgABI(self_target_type, layout.Target.x86_64_linux);
                        const align_req = layout.getAlign(self_target_type, layout.Target.x86_64_linux);

                        if (sig.mode == .ByVal) {
                            const temp_alloc = self.nextTemp();
                            try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, self_target_t, align_req });
                            try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ self_target_t, self_val, temp_alloc, align_req });
                            try std.fmt.format(args_str.writer(), ", ptr byval({s}) %t.{d}", .{ self_target_t, temp_alloc });
                        } else if (sig.mode == .Coerce) {
                            const temp_alloc = self.nextTemp();
                            try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, self_target_t, align_req });
                            try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ self_target_t, self_val, temp_alloc, align_req });
                            const cast_load = self.nextTemp();
                            try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ cast_load, sig.llvm_type, temp_alloc, align_req });
                            try std.fmt.format(args_str.writer(), ", {s} %t.{d}", .{ sig.llvm_type, cast_load });
                        } else {
                            try std.fmt.format(args_str.writer(), ", {s} {s}", .{ self_target_t, self_val });
                        }
                    }

                    for (m.arguments, 0..) |arg, idx| {
                        var arg_val = try self.genExpr(arg);
                        const inferred: types.Type = arg.inferred_type orelse types.Type{ .kind = .Any };
                        const source_t = typeToLLVM(self.allocator, inferred);
                        var target_type = inferred;
                        if (method_func_t) |m_func| {
                            if (m_func.kind == .Function and m_func.function != null) {
                                const params = m_func.function.?.param_types;
                                const param_idx = if (is_static) idx else idx + 1;
                                if (param_idx < params.len) {
                                    target_type = params[param_idx];
                                }
                            }
                        }
                        const target_t = typeToLLVM(self.allocator, target_type);
                        arg_val = try self.coerceType(arg_val, source_t, target_t);
                        
                        const sig = abi.getArgABI(target_type, layout.Target.x86_64_linux);
                        const align_req = layout.getAlign(target_type, layout.Target.x86_64_linux);
                        
                        try args_str.appendSlice(", ");
                        if (sig.mode == .ByVal) {
                            const temp_alloc = self.nextTemp();
                            try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, target_t, align_req });
                            try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ target_t, arg_val, temp_alloc, align_req });
                            try std.fmt.format(args_str.writer(), "ptr byval({s}) %t.{d}", .{ target_t, temp_alloc });
                        } else if (sig.mode == .Coerce) {
                            const temp_alloc = self.nextTemp();
                            try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, target_t, align_req });
                            try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ target_t, arg_val, temp_alloc, align_req });
                            const cast_load = self.nextTemp();
                            try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ cast_load, sig.llvm_type, temp_alloc, align_req });
                            try std.fmt.format(args_str.writer(), "{s} %t.{d}", .{ sig.llvm_type, cast_load });
                        } else {
                            try std.fmt.format(args_str.writer(), "{s} {s}", .{ target_t, arg_val });
                        }
                    }

                    var ret_type = node.inferred_type orelse types.Type{ .kind = .Any };
                    if (method_func_t) |m_func| {
                        if (m_func.kind == .Function and m_func.function != null) {
                            ret_type = m_func.function.?.return_type.*;
                        }
                    }
                    const ret_t = typeToLLVM(self.allocator, ret_type);
                    const ret_sig = abi.getRetABI(ret_type, layout.Target.x86_64_linux);
                    const final_ret_t = if (ret_sig.mode == .Coerce) ret_sig.llvm_type else ret_t;

                    if (std.mem.eql(u8, final_ret_t, "void")) {
                        try writer.print("  call {s} @{s}({s})\n", .{ final_ret_t, mangled_name, args_str.items });
                        return "null";
                    } else {
                        const call_temp = self.nextTemp();
                        const call_temp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{call_temp});
                        try writer.print("  {s} = call {s} @{s}({s})\n", .{ call_temp_name, final_ret_t, mangled_name, args_str.items });
                        
                        if (ret_sig.mode == .Coerce) {
                            const ret_align = layout.getAlign(ret_type, layout.Target.x86_64_linux);
                            const temp_alloc = self.nextTemp();
                            try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, ret_t, ret_align });
                            try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ final_ret_t, call_temp_name, temp_alloc, ret_align });
                            const final_val = self.nextTemp();
                            try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ final_val, ret_t, temp_alloc, ret_align });
                            return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{final_val});
                        }
                        
                        return call_temp_name;
                    }
                } else if ((obj_inferred.kind == .AsciiStr or obj_inferred.kind == .Utf8Str or obj_inferred.kind == .WebStr or obj_inferred.kind == .RangeStr) and std.mem.eql(u8, m.method_name, "to_string")) {
                    const rec_val = try self.genExpr(m.receiver);
                    
                    const ptr_ext = self.nextTemp();
                    const len_ext = self.nextTemp();
                    try writer.print("  %t.{d} = extractvalue {{ ptr, i64 }} {s}, 0\n", .{ ptr_ext, rec_val });
                    try writer.print("  %t.{d} = extractvalue {{ ptr, i64 }} {s}, 1\n", .{ len_ext, rec_val });

                    const ptr_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{self.nextTemp()});
                    const cap_temp = self.nextTemp();
                    try writer.print("  %t.{d} = add i64 %t.{d}, 1\n", .{ cap_temp, len_ext });
                    try writer.print("  {s} = call ptr @mantiq_malloc(i64 %t.{d})\n", .{ ptr_name, cap_temp });
                    try writer.print("  call void @llvm.memcpy.p0.p0.i64(ptr {s}, ptr %t.{d}, i64 %t.{d}, i1 false)\n", .{ ptr_name, ptr_ext, len_ext });

                    const fat1 = self.nextTemp();
                    const fat2 = self.nextTemp();
                    const fat3 = self.nextTemp();
                    try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} undef, ptr {s}, 0\n", .{ fat1, ptr_name });
                    try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 %t.{d}, 1\n", .{ fat2, fat1, len_ext });
                    try writer.print("  %t.{d} = insertvalue {{ ptr, i64, i64 }} %t.{d}, i64 %t.{d}, 2\n", .{ fat3, fat2, cap_temp });

                    const fat_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{fat3});
                    try self.registerTemp(fat_name, ptr_name);
                    return fat_name;
                } else if (obj_inferred.kind == .List) {
                    if (std.mem.eql(u8, m.method_name, "length") or std.mem.eql(u8, m.method_name, "len")) {
                        const rec_val = try self.genExpr(m.receiver);
                        const len_val = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 1\n", .{ len_val, rec_val });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{len_val});
                    } else if (std.mem.eql(u8, m.method_name, "clear")) {
                        const lval_addr = try self.genLValue(m.receiver);
                        const len_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = getelementptr {{ ptr, i64, i64 }}, ptr {s}, i32 0, i32 1\n", .{ len_ptr, lval_addr });
                        try writer.print("  store i64 0, ptr %t.{d}\n", .{len_ptr});
                        return "null";
                    } else if (std.mem.eql(u8, m.method_name, "append")) {
                        const lval_addr = try self.genLValue(m.receiver);
                        const elem_type = obj_inferred.payload.?.*;
                        const elem_size = types.getTypeSize(elem_type);
                        var elem_val = try self.genExpr(m.arguments[0]);
                        const elem_inferred = m.arguments[0].inferred_type orelse types.Type{ .kind = .Any };
                        const elem_source_t = typeToLLVM(self.allocator, elem_inferred);
                        const elem_t_name = typeToLLVM(self.allocator, elem_type);
                        elem_val = try self.coerceType(elem_val, elem_source_t, elem_t_name);
                        const elem_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = alloca {s}\n", .{ elem_ptr, elem_t_name });
                        try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ elem_t_name, elem_val, elem_ptr });
                        try writer.print("  call void @__mantiq_list_append(ptr {s}, ptr %t.{d}, i64 {d})\n", .{ lval_addr, elem_ptr, elem_size });
                        return "null";
                    }
                    return "null";
                } else if (obj_inferred.kind == .Dict) {
                    if (std.mem.eql(u8, m.method_name, "length") or std.mem.eql(u8, m.method_name, "len")) {
                        const rec_val = try self.genExpr(m.receiver);
                        const ptr_temp = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 0\n", .{ ptr_temp, rec_val });
                        const dict_struct = self.nextTemp();
                        try writer.print("  %t.{d} = load %MantiqDict, ptr %t.{d}\n", .{ dict_struct, ptr_temp });
                        const count = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue %MantiqDict %t.{d}, 5\n", .{ count, dict_struct });
                        const len_val = self.nextTemp();
                        try writer.print("  %t.{d} = sext i32 %t.{d} to i64\n", .{ len_val, count });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{len_val});
                    } else if (std.mem.eql(u8, m.method_name, "clear")) {
                        const rec_val = try self.genExpr(m.receiver);
                        const dict_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 0\n", .{ dict_ptr, rec_val });
                        try writer.print("  call void @__mantiq_dict_clear(ptr %t.{d})\n", .{dict_ptr});
                        
                        if (self.genLValue(m.receiver)) |lval_addr| {
                            const len_ptr = self.nextTemp();
                            try writer.print("  %t.{d} = getelementptr {{ ptr, i64, i64 }}, ptr {s}, i32 0, i32 1\n", .{ len_ptr, lval_addr });
                            try writer.print("  store i64 0, ptr %t.{d}\n", .{len_ptr});
                        } else |_| {}
                        return "null";
                    } else if (std.mem.eql(u8, m.method_name, "keys")) {
                        const rec_val = try self.genExpr(m.receiver);
                        const ptr_temp = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 0\n", .{ ptr_temp, rec_val });

                        const list_alloca = self.nextTemp();
                        try writer.print("  %t.{d} = alloca {{ ptr, i64, i64 }}\n", .{ list_alloca });
                        try writer.print("  store {{ ptr, i64, i64 }} zeroinitializer, ptr %t.{d}\n", .{ list_alloca });

                        const key_type = obj_inferred.tuple_types.?[0];
                        const key_size = types.getTypeSize(key_type);

                        try writer.print("  call void @__mantiq_dict_keys(ptr %t.{d}, ptr %t.{d}, i32 {d})\n", .{ ptr_temp, list_alloca, key_size });

                        const list_val = self.nextTemp();
                        try writer.print("  %t.{d} = load {{ ptr, i64, i64 }}, ptr %t.{d}\n", .{ list_val, list_alloca });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{list_val});
                    } else if (std.mem.eql(u8, m.method_name, "has")) {
                        const rec_val = try self.genExpr(m.receiver);
                        var key_val = try self.genExpr(m.arguments[0]);
                        var k_type = types.Type{ .kind = .Any };
                        var k_kind: types.TypeKind = .I32;
                        if (obj_inferred.tuple_types) |tt| {
                            if (tt.len == 2) {
                                k_type = tt[0];
                                k_kind = tt[0].kind;
                            }
                        }
                        const key_inferred = m.arguments[0].inferred_type orelse types.Type{ .kind = .Any };
                        const key_source_t = typeToLLVM(self.allocator, key_inferred);
                        const k_llvm = typeToLLVM(self.allocator, k_type);
                        key_val = try self.coerceType(key_val, key_source_t, k_llvm);
                        
                        const ptr_temp = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 0\n", .{ ptr_temp, rec_val });
                        
                        const k_size_ptr = self.nextTemp();
                        const k_size_int = self.nextTemp();
                        try writer.print("  %t.{d} = getelementptr {s}, ptr null, i32 1\n", .{ k_size_ptr, k_llvm });
                        try writer.print("  %t.{d} = ptrtoint ptr %t.{d} to i32\n", .{ k_size_int, k_size_ptr });
                        
                        const hash_temp = self.nextTemp();
                        const k_alloc = self.nextTemp();
                        try writer.print("  %t.{d} = alloca {s}\n", .{ k_alloc, k_llvm });
                        try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ k_llvm, key_val, k_alloc });
                        
                        if (isStringLikeType(k_type)) {
                            const str_ptr = self.nextTemp();
                            try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ str_ptr, k_llvm, key_val });
                            const str_len = self.nextTemp();
                            try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ str_len, k_llvm, key_val });
                            try writer.print("  %t.{d} = call i32 @__mantiq_hash_string(ptr %t.{d}, i64 %t.{d})\n", .{ hash_temp, str_ptr, str_len });
                        } else {
                            const byte_len = self.nextTemp();
                            try writer.print("  %t.{d} = zext i32 %t.{d} to i64\n", .{ byte_len, k_size_int });
                            try writer.print("  %t.{d} = call i32 @__mantiq_hash_bytes(ptr %t.{d}, i64 %t.{d})\n", .{ hash_temp, k_alloc, byte_len });
                        }
                        
                        const res_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = call ptr @__mantiq_dict_get(ptr %t.{d}, ptr %t.{d}, i32 %t.{d})\n", .{ res_ptr, ptr_temp, k_alloc, hash_temp });
                        
                        const has_bool = self.nextTemp();
                        try writer.print("  %t.{d} = icmp ne ptr %t.{d}, null\n", .{ has_bool, res_ptr });
                        
                        const has_bool_i8 = self.nextTemp();
                        try writer.print("  %t.{d} = zext i1 %t.{d} to i8\n", .{ has_bool_i8, has_bool });
                        
                        
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{has_bool_i8});
                    } else if (std.mem.eql(u8, m.method_name, "remove")) {
                        const rec_val = try self.genExpr(m.receiver);
                        var key_val = try self.genExpr(m.arguments[0]);
                        var k_type = types.Type{ .kind = .Any };
                        var k_kind: types.TypeKind = .I32;
                        if (obj_inferred.tuple_types) |tt| {
                            if (tt.len == 2) {
                                k_type = tt[0];
                                k_kind = tt[0].kind;
                            }
                        }
                        const key_inferred = m.arguments[0].inferred_type orelse types.Type{ .kind = .Any };
                        const key_source_t = typeToLLVM(self.allocator, key_inferred);
                        const k_llvm = typeToLLVM(self.allocator, k_type);
                        key_val = try self.coerceType(key_val, key_source_t, k_llvm);
                        
                        const ptr_temp = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {{ ptr, i64, i64 }} {s}, 0\n", .{ ptr_temp, rec_val });
                        
                        const k_size_ptr = self.nextTemp();
                        const k_size_int = self.nextTemp();
                        try writer.print("  %t.{d} = getelementptr {s}, ptr null, i32 1\n", .{ k_size_ptr, k_llvm });
                        try writer.print("  %t.{d} = ptrtoint ptr %t.{d} to i32\n", .{ k_size_int, k_size_ptr });
                        
                        const hash_temp = self.nextTemp();
                        const k_alloc = self.nextTemp();
                        try writer.print("  %t.{d} = alloca {s}\n", .{ k_alloc, k_llvm });
                        try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ k_llvm, key_val, k_alloc });
                        
                        if (isStringLikeType(k_type)) {
                            const str_ptr = self.nextTemp();
                            try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ str_ptr, k_llvm, key_val });
                            const str_len = self.nextTemp();
                            try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ str_len, k_llvm, key_val });
                            try writer.print("  %t.{d} = call i32 @__mantiq_hash_string(ptr %t.{d}, i64 %t.{d})\n", .{ hash_temp, str_ptr, str_len });
                        } else {
                            const byte_len = self.nextTemp();
                            try writer.print("  %t.{d} = zext i32 %t.{d} to i64\n", .{ byte_len, k_size_int });
                            try writer.print("  %t.{d} = call i32 @__mantiq_hash_bytes(ptr %t.{d}, i64 %t.{d})\n", .{ hash_temp, k_alloc, byte_len });
                        }
                        
                        const res_val = self.nextTemp();
                        try writer.print("  %t.{d} = call i8 @__mantiq_dict_remove(ptr %t.{d}, ptr %t.{d}, i32 %t.{d})\n", .{ res_val, ptr_temp, k_alloc, hash_temp });
                        
                        const removed_bool = self.nextTemp();
                        try writer.print("  %t.{d} = icmp eq i8 %t.{d}, 1\n", .{ removed_bool, res_val });
                        
                        // Decrement the length tracked in the fat pointer if removal succeeded
                        if (self.genLValue(m.receiver)) |lval_addr| {
                            const old_len_ptr = self.nextTemp();
                            try writer.print("  %t.{d} = getelementptr {{ ptr, i64, i64 }}, ptr {s}, i32 0, i32 1\n", .{ old_len_ptr, lval_addr });
                            const old_len = self.nextTemp();
                            try writer.print("  %t.{d} = load i64, ptr %t.{d}\n", .{ old_len, old_len_ptr });
                            const new_len = self.nextTemp();
                            try writer.print("  %t.{d} = sub i64 %t.{d}, 1\n", .{ new_len, old_len });
                            const cond_len = self.nextTemp();
                            try writer.print("  %t.{d} = select i1 %t.{d}, i64 %t.{d}, i64 %t.{d}\n", .{ cond_len, removed_bool, new_len, old_len });
                            try writer.print("  store i64 %t.{d}, ptr %t.{d}\n", .{ cond_len, old_len_ptr });
                        } else |_| {}
                        
                        const ret_bool_i8 = self.nextTemp();
                        try writer.print("  %t.{d} = zext i1 %t.{d} to i8\n", .{ ret_bool_i8, removed_bool });
                        return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{ret_bool_i8});
                    }
                    return "null";
                } else if (obj_inferred.kind == .Enum and obj_inferred.enum_type != null) {
                    const et = obj_inferred.enum_type.?;
                    var val: u32 = 0;
                    for (et.variants) |ev| {
                        if (std.mem.eql(u8, ev.name, m.method_name)) {
                            val = ev.value orelse 0;
                            break;
                        }
                    }
                    
                    const ret_t = typeToLLVM(self.allocator, obj_inferred);
                    const tag_val = try std.fmt.allocPrint(self.allocator, "{d}", .{val});

                    const temp_struct = self.nextTemp();
                    const temp_struct_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{temp_struct});
                    try writer.print("  {s} = insertvalue {s} zeroinitializer, i32 {s}, 0\n", .{ temp_struct_name, ret_t, tag_val });

                    if (m.arguments.len > 0) {
                        const alloca_temp = self.nextTemp();
                        const alloca_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{alloca_temp});
                        try writer.print("  {s} = alloca {s}\n", .{ alloca_name, ret_t });
                        try writer.print("  store {s} {s}, ptr {s}\n", .{ ret_t, temp_struct_name, alloca_name });

                        const payload_gep = self.nextTemp();
                        try writer.print("  %t.{d} = getelementptr inbounds {s}, ptr {s}, i32 0, i32 1\n", .{ payload_gep, ret_t, alloca_name });

                        const arg_val = try self.genExpr(m.arguments[0]);
                        const arg_t = typeToLLVM(self.allocator, m.arguments[0].inferred_type orelse .{ .kind = .Any });
                        try writer.print("  store {s} {s}, ptr %t.{d}\n", .{ arg_t, arg_val, payload_gep });

                        const load_temp = self.nextTemp();
                        const load_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{load_temp});
                        try writer.print("  {s} = load {s}, ptr {s}\n", .{ load_name, ret_t, alloca_name });
                        return load_name;
                    }
                    return temp_struct_name;
                }

                if (obj_inferred.kind == .Module) {
                    var llvm_ns_name = m.receiver.data.Identifier.name;
                    if (obj_inferred.module_scope) |scope_ptr| {
                        const mod_scope = @as(*symbols.Scope, @ptrCast(@alignCast(scope_ptr)));
                        if (mod_scope.resolveLocal(m.method_name)) |sym| {
                            if (sym.decl_node != null and sym.decl_node.?.module_name != null) {
                                llvm_ns_name = sym.decl_node.?.module_name.?;
                            }
                        }
                    }
                    const func_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ llvm_ns_name, m.method_name });

                    if (!self.defined_functions.contains(func_name)) {
                        if (obj_inferred.module_scope) |scope_ptr| {
                            const mod_scope = @as(*symbols.Scope, @ptrCast(@alignCast(scope_ptr)));
                            if (mod_scope.resolveLocal(m.method_name)) |sym| {
                                if (sym.decl_node) |decl| {
                                    try self.declareExternalFunction(func_name, decl);
                                }
                            }
                        }
                    }

                    var arg_str = std.ArrayList(u8).init(self.allocator);
                    var is_variadic = false;
                    var variadic_start: usize = 0;
                    if (obj_inferred.module_scope) |scope_ptr| {
                        const mod_scope = @as(*symbols.Scope, @ptrCast(@alignCast(scope_ptr)));
                        if (mod_scope.resolveLocal(m.method_name)) |sym| {
                            if (sym.decl_node) |decl| {
                                if (decl.node_type == .FunDecl) {
                                    is_variadic = decl.data.FunDecl.is_variadic;
                                    if (decl.data.FunDecl.params.len > 0) {
                                        variadic_start = decl.data.FunDecl.params.len - 1;
                                    }
                                }
                            }
                        }
                    }

                    var actual_args = std.ArrayList(*ast.Node).init(self.allocator);
                    if (is_variadic and variadic_start <= m.arguments.len) {
                        for (m.arguments[0..variadic_start]) |arg| {
                            try actual_args.append(arg);
                        }
                        const var_args = m.arguments[variadic_start..];
                        if (var_args.len == 1 and var_args[0].node_type == .SpreadExpr) {
                            try actual_args.append(var_args[0].data.SpreadExpr.iterable);
                        } else {
                            const list_node = try self.allocator.create(ast.Node);
                            list_node.* = .{
                                .node_type = .ListLiteral,
                                .span = node.span,
                                .inferred_type = .{ .kind = .List },
                                .data = .{
                                    .ListLiteral = .{
                                        .elements = var_args,
                                    },
                                },
                            };
                            try actual_args.append(list_node);
                        }
                    } else {
                        for (m.arguments) |arg| {
                            try actual_args.append(arg);
                        }
                    }

                    const processed_args = actual_args.items;
                    for (processed_args, 0..) |arg, i| {
                        if (i > 0) try arg_str.appendSlice(", ");
                        const arg_val = try self.genExpr(arg);
                        const inferred: types.Type = arg.inferred_type orelse types.Type{ .kind = .Any };
                        const t = typeToLLVM(self.allocator, inferred);
                        const sig = abi.getArgABI(inferred, layout.Target.x86_64_linux);
                        const align_req = layout.getAlign(inferred, layout.Target.x86_64_linux);
                        
                        if (sig.mode == .ByVal) {
                            const temp_alloc = self.nextTemp();
                            try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, t, align_req });
                            try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ t, arg_val, temp_alloc, align_req });
                            try std.fmt.format(arg_str.writer(), "ptr byval({s}) %t.{d}", .{ t, temp_alloc });
                        } else if (sig.mode == .Coerce) {
                            const temp_alloc = self.nextTemp();
                            try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, t, align_req });
                            try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ t, arg_val, temp_alloc, align_req });
                            const cast_load = self.nextTemp();
                            try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ cast_load, sig.llvm_type, temp_alloc, align_req });
                            try std.fmt.format(arg_str.writer(), "{s} %t.{d}", .{ sig.llvm_type, cast_load });
                        } else {
                            try std.fmt.format(arg_str.writer(), "{s} {s}", .{ t, arg_val });
                        }
                    }

                    const actual_ret_type: types.Type = node.inferred_type orelse types.Type{ .kind = .Any };
                    const ret_t = typeToLLVM(self.allocator, actual_ret_type);
                    const ret_sig = abi.getRetABI(actual_ret_type, layout.Target.x86_64_linux);
                    const final_ret_t = if (ret_sig.mode == .Coerce) ret_sig.llvm_type else ret_t;

                    if (std.mem.eql(u8, final_ret_t, "void")) {
                        try writer.print("  call {s} @{s}({s})\n", .{ final_ret_t, func_name, arg_str.items });
                        return "null";
                    } else {
                        const call_temp = self.nextTemp();
                        const call_temp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{call_temp});
                        try writer.print("  {s} = call {s} @{s}({s})\n", .{ call_temp_name, final_ret_t, func_name, arg_str.items });
                        
                        if (ret_sig.mode == .Coerce) {
                            const ret_align = layout.getAlign(actual_ret_type, layout.Target.x86_64_linux);
                            const temp_alloc = self.nextTemp();
                            try writer.print("  %t.{d} = alloca {s}, align {d}\n", .{ temp_alloc, ret_t, ret_align });
                            try writer.print("  store {s} {s}, ptr %t.{d}, align {d}\n", .{ final_ret_t, call_temp_name, temp_alloc, ret_align });
                            const final_val = self.nextTemp();
                            try writer.print("  %t.{d} = load {s}, ptr %t.{d}, align {d}\n", .{ final_val, ret_t, temp_alloc, ret_align });
                            return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{final_val});
                        }
                        
                        return call_temp_name;
                    }
                }

                return "null";
            },
            .BinaryExpr => |*b| {
                if (std.mem.eql(u8, b.operator, "=")) {
                    var right_val = try self.genExpr(b.right);
                    self.consumeTemp(right_val);
                    const t = typeToLLVM(self.allocator, b.left.inferred_type orelse .{ .kind = .Any });
                    
                    if (b.right.node_type == .StringLiteral and std.mem.eql(u8, t, "i8")) {
                        const str_val = b.right.data.StringLiteral.value;
                        if (str_val.len == 3 and ((str_val[0] == '"' and str_val[2] == '"') or (str_val[0] == '\'' and str_val[2] == '\''))) {
                            right_val = try std.fmt.allocPrint(self.allocator, "{d}", .{str_val[1]});
                        } else if (str_val.len == 1) {
                            right_val = try std.fmt.allocPrint(self.allocator, "{d}", .{str_val[0]});
                        }
                    }
                    const source_type = typeToLLVM(self.allocator, b.right.inferred_type orelse .{ .kind = .Any });
                    right_val = try self.coerceType(right_val, source_type, t);
                    if (b.left.node_type == .Identifier) {
                        const name = b.left.data.Identifier.name;
                        if (self.global_vars.contains(name)) {
                            try writer.print("  store {s} {s}, ptr @{s}\n", .{ t, right_val, name });
                        } else {
                            const local_ref = self.getScopedName(name);
                            try writer.print("  store {s} {s}, ptr %{s}\n", .{ t, right_val, local_ref });
                        }
                    } else if (b.left.node_type == .MemberExpr or b.left.node_type == .UnaryExpr or b.left.node_type == .IndexExpr) {
                        const ptr_val = try self.genLValue(b.left);
                        try writer.print("  store {s} {s}, ptr {s}\n", .{ t, right_val, ptr_val });
                    } else {
                        std.debug.print("Unsupported left hand side for assignment: node_type={}\n", .{b.left.node_type});
                        return error.UnsupportedNode;
                    }
                    return right_val;
                }

                const left_val = try self.genExpr(b.left);
                const right_val = try self.genExpr(b.right);

                const l_type = typeToLLVM(self.allocator, b.left.inferred_type orelse .{ .kind = .Any });

                const res_temp = self.nextTemp();
                const res_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{res_temp});

                const t = l_type;
                const is_float = std.mem.eql(u8, t, "float") or std.mem.eql(u8, t, "double") or std.mem.eql(u8, t, "bfloat");

                if (std.mem.eql(u8, b.operator, "+")) {
                    if (is_float) {
                        try writer.print("  {s} = fadd {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                    } else {
                        try writer.print("  {s} = add {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                    }
                } else if (std.mem.eql(u8, b.operator, "-")) {
                    if (is_float) {
                        try writer.print("  {s} = fsub {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                    } else {
                        try writer.print("  {s} = sub {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                    }
                } else if (std.mem.eql(u8, b.operator, "*")) {
                    if (is_float) {
                        try writer.print("  {s} = fmul {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                    } else {
                        try writer.print("  {s} = mul {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                    }
                } else if (std.mem.eql(u8, b.operator, "/")) {
                    if (is_float) {
                        try writer.print("  {s} = fdiv {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                    } else {
                        const cmp_zero = self.nextTemp();
                        try writer.print("  %t.{d} = icmp eq {s} {s}, 0\n", .{ cmp_zero, t, right_val });
                        const cond_id = self.nextTemp();
                        const panic_lbl = try std.fmt.allocPrint(self.allocator, "div.panic.{d}", .{cond_id});
                        const ok_lbl = try std.fmt.allocPrint(self.allocator, "div.ok.{d}", .{cond_id});
                        try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cmp_zero, panic_lbl, ok_lbl });
                        
                        try writer.print("{s}:\n", .{panic_lbl});
                        try writer.print("  call void @mantiq_panic_at(ptr @.panic_str_div_zero, ptr @.str_file, i32 {d}, i32 {d})\n", .{ node.span.start_row + 1, node.span.start_col + 1 });
                        try writer.print("  unreachable\n", .{});
                        
                        try writer.print("{s}:\n", .{ok_lbl});
                        try writer.print("  {s} = sdiv {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                    }
                } else if (std.mem.eql(u8, b.operator, "%")) {
                    if (is_float) {
                        try writer.print("  {s} = frem {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                    } else {
                        const cmp_zero = self.nextTemp();
                        try writer.print("  %t.{d} = icmp eq {s} {s}, 0\n", .{ cmp_zero, t, right_val });
                        const cond_id = self.nextTemp();
                        const panic_lbl = try std.fmt.allocPrint(self.allocator, "div.panic.{d}", .{cond_id});
                        const ok_lbl = try std.fmt.allocPrint(self.allocator, "div.ok.{d}", .{cond_id});
                        try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cmp_zero, panic_lbl, ok_lbl });
                        
                        try writer.print("{s}:\n", .{panic_lbl});
                        try writer.print("  call void @mantiq_panic_at(ptr @.panic_str_div_zero, ptr @.str_file, i32 {d}, i32 {d})\n", .{ node.span.start_row + 1, node.span.start_col + 1 });
                        try writer.print("  unreachable\n", .{});
                        
                        try writer.print("{s}:\n", .{ok_lbl});
                        try writer.print("  {s} = srem {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                    }
                } else if (std.mem.eql(u8, b.operator, "and") or std.mem.eql(u8, b.operator, "&")) {
                    try writer.print("  {s} = and {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                } else if (std.mem.eql(u8, b.operator, "or") or std.mem.eql(u8, b.operator, "|")) {
                    try writer.print("  {s} = or {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                } else if (std.mem.eql(u8, b.operator, "^")) {
                    try writer.print("  {s} = xor {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                } else if (std.mem.eql(u8, b.operator, "<<")) {
                    try writer.print("  {s} = shl {s} {s}, {s}\n", .{ res_name, t, left_val, right_val });
                } else if (std.mem.eql(u8, b.operator, ">>")) {
                    const is_unsigned = if (b.left.inferred_type) |lt|
                        switch (lt.kind) {
                            .U8, .U16, .U32, .U64, .U128, .USize => true,
                            else => false,
                        }
                    else false;
                    const shift_op = if (is_unsigned) "lshr" else "ashr";
                    try writer.print("  {s} = {s} {s} {s}, {s}\n", .{ res_name, shift_op, t, left_val, right_val });
                } else if (std.mem.eql(u8, b.operator, "==") or std.mem.eql(u8, b.operator, "!=") or
                    std.mem.eql(u8, b.operator, "<") or std.mem.eql(u8, b.operator, ">") or
                    std.mem.eql(u8, b.operator, "<=") or std.mem.eql(u8, b.operator, ">="))
                {
                    const is_string = b.left.inferred_type != null and (b.left.inferred_type.?.kind == .String or b.left.inferred_type.?.kind == .AsciiStr or b.left.inferred_type.?.kind == .Utf8Str or b.left.inferred_type.?.kind == .WebStr or b.left.inferred_type.?.kind == .RangeStr);
                    if (is_string) {
                        const left_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ left_ptr, t, left_val });
                        const left_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ left_len, t, left_val });

                        const right_ptr = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ right_ptr, t, right_val });
                        const right_len = self.nextTemp();
                        try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ right_len, t, right_val });

                        const eq_val = self.nextTemp();
                        try writer.print("  %t.{d} = call i32 @__mantiq_streq(ptr %t.{d}, i64 %t.{d}, ptr %t.{d}, i64 %t.{d})\n", .{ eq_val, left_ptr, left_len, right_ptr, right_len });

                        const cmp_temp = self.nextTemp();
                        const cmp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{cmp_temp});
                        if (std.mem.eql(u8, b.operator, "==")) {
                            try writer.print("  {s} = icmp eq i32 %t.{d}, 1\n", .{ cmp_name, eq_val });
                        } else if (std.mem.eql(u8, b.operator, "!=")) {
                            try writer.print("  {s} = icmp eq i32 %t.{d}, 0\n", .{ cmp_name, eq_val });
                        } else {
                            // other comparison ops not supported on strings
                            try writer.print("  {s} = icmp eq i32 %t.{d}, 1\n", .{ cmp_name, eq_val });
                        }
                        try writer.print("  {s} = zext i1 {s} to i8\n", .{ res_name, cmp_name });
                    } else {
                        // ── Enum comparison ─────────────────────────────────────────────────────────
                        const is_enum = b.left.inferred_type != null and b.left.inferred_type.?.kind == .Enum;
                        if (is_enum) {
                            // Enums are structs { i32, ... } in LLVM; extract the i32 tag for icmp
                            const left_tag = self.nextTemp();
                            try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ left_tag, t, left_val });
                            const right_tag = self.nextTemp();
                            try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ right_tag, t, right_val });

                            const inst = if (std.mem.eql(u8, b.operator, "==")) "icmp eq" else if (std.mem.eql(u8, b.operator, "!=")) "icmp ne" else if (std.mem.eql(u8, b.operator, "<")) "icmp slt" else if (std.mem.eql(u8, b.operator, ">")) "icmp sgt" else if (std.mem.eql(u8, b.operator, "<=")) "icmp sle" else if (std.mem.eql(u8, b.operator, ">=")) "icmp sge" else unreachable;

                            const cmp_temp = self.nextTemp();
                            const cmp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{cmp_temp});
                            try writer.print("  {s} = {s} i32 %t.{d}, %t.{d}\n", .{ cmp_name, inst, left_tag, right_tag });

                            try writer.print("  {s} = zext i1 {s} to i8\n", .{ res_name, cmp_name });
                        } else {
                            const inst = if (std.mem.eql(u8, b.operator, "==")) (if (is_float) "fcmp oeq" else "icmp eq") else if (std.mem.eql(u8, b.operator, "!=")) (if (is_float) "fcmp one" else "icmp ne") else if (std.mem.eql(u8, b.operator, "<")) (if (is_float) "fcmp olt" else "icmp slt") else if (std.mem.eql(u8, b.operator, ">")) (if (is_float) "fcmp ogt" else "icmp sgt") else if (std.mem.eql(u8, b.operator, "<=")) (if (is_float) "fcmp ole" else "icmp sle") else if (std.mem.eql(u8, b.operator, ">=")) (if (is_float) "fcmp oge" else "icmp sge") else unreachable;

                            const cmp_temp = self.nextTemp();
                            const cmp_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{cmp_temp});
                            try writer.print("  {s} = {s} {s} {s}, {s}\n", .{ cmp_name, inst, t, left_val, right_val });

                            try writer.print("  {s} = zext i1 {s} to i8\n", .{ res_name, cmp_name });
                        }
                    }
                } else {
                    return "null";
                }

                return res_name;
            },
            .TryStmt => |*t| {
                if (t.catch_binding) |b| {
                    const err_llvm = "i32";
                    if (!self.local_allocas.contains(b)) {
                        try writer.print("  %{s} = alloca {s}\n", .{ b, err_llvm });
                        try self.local_allocas.put(b, true);
                    }
                }

                const body_val = try self.genExpr(t.body);
                const body_type = t.body.inferred_type orelse types.Type{ .kind = .Any };
                const body_llvm = typeToLLVM(self.allocator, body_type);
                
                const tag_temp = self.nextTemp();
                try writer.print("  %t.{d} = extractvalue {s} {s}, 0\n", .{ tag_temp, body_llvm, body_val });
                
                const cmp_temp = self.nextTemp();
                try writer.print("  %t.{d} = icmp eq i8 %t.{d}, 0\n", .{ cmp_temp, tag_temp });
                
                const temp_id = self.nextTemp();
                const try_ok = try std.fmt.allocPrint(self.allocator, "try.ok.{d}", .{temp_id});
                const try_err = try std.fmt.allocPrint(self.allocator, "try.err.{d}", .{temp_id});
                const try_end = try std.fmt.allocPrint(self.allocator, "try.end.{d}", .{temp_id});
                
                try writer.print("  br i1 %t.{d}, label %{s}, label %{s}\n", .{ cmp_temp, try_ok, try_err });
                
                // Try Ok Block
                try writer.print("{s}:\n", .{try_ok});
                
                var payload_llvm: []const u8 = "void";
                if (node.inferred_type) |n_t| {
                    payload_llvm = typeToLLVM(self.allocator, n_t);
                } else if (body_type.kind == .Result and body_type.payload != null) {
                    payload_llvm = typeToLLVM(self.allocator, body_type.payload.?.*);
                }
                
                var res_alloc: ?[]const u8 = null;
                if (!std.mem.eql(u8, payload_llvm, "void")) {
                    const r_alloc_temp = self.nextTemp();
                    res_alloc = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{r_alloc_temp});
                    try writer.print("  {s} = alloca {s}\n", .{ res_alloc.?, payload_llvm });
                    
                    const payload_ptr_temp = self.nextTemp();
                    try writer.print("  %t.{d} = extractvalue {s} {s}, 1\n", .{ payload_ptr_temp, body_llvm, body_val });
                    const payload_val_temp = self.nextTemp();
                    try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ payload_val_temp, payload_llvm, payload_ptr_temp });
                    try writer.print("  store {s} %t.{d}, ptr {s}\n", .{ payload_llvm, payload_val_temp, res_alloc.? });
                }
                try writer.print("  br label %{s}\n", .{try_end});
                
                // Try Err Block
                try writer.print("{s}:\n", .{try_err});
                
                if (t.catch_binding) |b| {
                    const err_llvm = "i32";
                    const err_ptr_temp = self.nextTemp();
                    try writer.print("  %t.{d} = extractvalue {s} {s}, 2\n", .{ err_ptr_temp, body_llvm, body_val });
                    const err_val_temp = self.nextTemp();
                    try writer.print("  %t.{d} = load {s}, ptr %t.{d}\n", .{ err_val_temp, err_llvm, err_ptr_temp });
                    try writer.print("  store {s} %t.{d}, ptr %{s}\n", .{ err_llvm, err_val_temp, b });
                }
                
                if (t.catch_body) |catch_b| {
                    if (catch_b.node_type == .BlockStmt) {
                        try self.genNode(catch_b);
                    } else {
                        const catch_val = try self.genExpr(catch_b);
                        if (res_alloc) |r_alloc| {
                            if (!std.mem.eql(u8, catch_val, "null") and !std.mem.eql(u8, catch_val, "undef")) {
                                try writer.print("  store {s} {s}, ptr {s}\n", .{ payload_llvm, catch_val, r_alloc });
                            }
                        }
                    }
                }
                try writer.print("  br label %{s}\n", .{try_end});
                
                // End block
                try writer.print("{s}:\n", .{try_end});
                if (res_alloc) |r_alloc| {
                    const final_val = self.nextTemp();
                    try writer.print("  %t.{d} = load {s}, ptr {s}\n", .{ final_val, payload_llvm, r_alloc });
                    return try std.fmt.allocPrint(self.allocator, "%t.{d}", .{final_val});
                } else {
                    return "null";
                }
            },
            .UnaryExpr => |*u| {
                if (std.mem.eql(u8, u.operator, "ref") or std.mem.eql(u8, u.operator, "ref mut")) {
                    // ref expr => return the address (LValue) of the operand
                    const addr = try self.genLValue(u.operand);
                    return addr;
                } else if (std.mem.eql(u8, u.operator, "deref")) {
                    // deref expr => load through the pointer
                    const ptr_val = try self.genExpr(u.operand);
                    const pointee_type = node.inferred_type orelse types.Type{ .kind = .Unknown };
                    const pointee_t = typeToLLVM(self.allocator, pointee_type);
                    const res_temp = self.nextTemp();
                    const res_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{res_temp});
                    try writer.print("  {s} = load {s}, ptr {s}\n", .{ res_name, pointee_t, ptr_val });
                    return res_name;
                }

                const operand_val = try self.genExpr(u.operand);
                const t = typeToLLVM(self.allocator, u.operand.inferred_type orelse .{ .kind = .Any });

                const res_temp = self.nextTemp();
                const res_name = try std.fmt.allocPrint(self.allocator, "%t.{d}", .{res_temp});

                if (std.mem.eql(u8, u.operator, "not")) {
                    // xor with 1 to flip the boolean value
                    try writer.print("  {s} = xor {s} {s}, 1\n", .{ res_name, t, operand_val });
                } else if (std.mem.eql(u8, u.operator, "-")) {
                    const is_float = std.mem.eql(u8, t, "float") or std.mem.eql(u8, t, "double") or std.mem.eql(u8, t, "bfloat");
                    if (is_float) {
                        try writer.print("  {s} = fneg {s} {s}\n", .{ res_name, t, operand_val });
                    } else {
                        try writer.print("  {s} = sub {s} 0, {s}\n", .{ res_name, t, operand_val });
                    }
                } else if (std.mem.eql(u8, u.operator, "+")) {
                    return operand_val;
                } else if (std.mem.eql(u8, u.operator, "~")) {
                    try writer.print("  {s} = xor {s} {s}, -1\n", .{ res_name, t, operand_val });
                } else {
                    return "null";
                }

                return res_name;
            },
            else => {
                return "null";
            },
        }
    }
};
