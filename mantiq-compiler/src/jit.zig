//! JIT (Just-In-Time) compiler — compile-link-load execution.
//!
//! Writes LLVM IR to a `.ll` file, invokes `zig cc -shared` to produce a `.so`,
//! then `dlopen`s the shared library and returns a `JITCompiler` ready to call
//! the compiled functions. Used by the REPL and interactive execution.
//! Not a traditional ORC JIT — it is compile-link-load per evaluation.
//!
//! Key responsibilities:
//! - `compile` — write IR, invoke zig cc, dlopen
//! - `findFunction` — lookup a function by name in the loaded library
//! - `deinit` — close all loaded libraries and clean up temp files

const std = @import("std");
const ast = @import("ast.zig");

const runtime_c = @embedFile("runtime.c");

pub const JITCompiler = struct {
    allocator: std.mem.Allocator,
    loaded_libs: std.ArrayList(std.DynLib),
    previous_so_files: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) JITCompiler {
        return .{
            .allocator = allocator,
            .loaded_libs = std.ArrayList(std.DynLib).init(allocator),
            .previous_so_files = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *JITCompiler) void {
        for (self.loaded_libs.items) |*lib| {
            lib.close();
        }
        self.loaded_libs.deinit();
        for (self.previous_so_files.items) |so_file| {
            std.fs.cwd().deleteFile(so_file) catch |err| {
                if (ast.show_debug) {
                    std.debug.print("JIT Warning: Failed to clean up shared library '{s}': {}\n", .{ so_file, err });
                }
            };
            self.allocator.free(so_file);
        }
        self.previous_so_files.deinit();
    }

    pub fn evaluate(self: *JITCompiler, ir: []const u8, name_prefix: []const u8) !void {
        const ll_filename = try std.fmt.allocPrint(self.allocator, "{s}_jit.ll", .{name_prefix});
        defer self.allocator.free(ll_filename);

        const so_filename = try std.fmt.allocPrint(self.allocator, "lib{s}_jit.so", .{name_prefix});
        defer self.allocator.free(so_filename);

        var file = try std.fs.cwd().createFile(ll_filename, .{});
        try file.writeAll(ir);
        file.close();
        if (ast.show_ir) {
            std.debug.print("DEBUG IR for {s}:\n{s}\n", .{name_prefix, ir});
        }

        const runtime_filename = try std.fmt.allocPrint(self.allocator, "{s}_jit_runtime.c", .{name_prefix});
        defer self.allocator.free(runtime_filename);

        var rt_file = try std.fs.cwd().createFile(runtime_filename, .{});
        try rt_file.writeAll(runtime_c);
        rt_file.close();
        defer std.fs.cwd().deleteFile(runtime_filename) catch {};

        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append("zig");
        try args.append("cc");
        try args.append("-shared");
        try args.append("-fPIC");
        try args.append(ll_filename);
        try args.append(runtime_filename);
        
        // Link against all previous snippet shared libraries
        for (self.previous_so_files.items) |prev_so| {
            try args.append(prev_so);
        }
        
        try args.append("-O3");
        try args.append("-o");
        try args.append(so_filename);
        try args.append("-lmimalloc");
        try args.append("-lpthread");

        var child = std.process.Child.init(args.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        var stdout = std.ArrayList(u8).init(self.allocator);
        defer stdout.deinit();
        var stderr = std.ArrayList(u8).init(self.allocator);
        defer stderr.deinit();

        try child.spawn();
        try child.collectOutput(&stdout, &stderr, 50 * 1024 * 1024);
        const term = try child.wait();
        
        if (term != .Exited or term.Exited != 0) {
            std.debug.print("JIT Compilation failed for {s}:\n{s}\n", .{name_prefix, stderr.items});
            return error.JITCompilationFailed;
        }
        
        const so_path = try std.fmt.allocPrint(self.allocator, "./{s}", .{so_filename});

        {
            var lib = std.DynLib.open(so_path) catch |err| {
                std.debug.print("JIT Failed to load shared library {s}: {}\n", .{so_path, err});
                return error.JITLoadFailed;
            };

            const main_func = lib.lookup(*const fn() callconv(.C) i32, "main") orelse {
                std.debug.print("JIT Error: entry point 'main' not found in {s}\n", .{so_path});
                lib.close();
                return error.JITEntryPointMissing;
            };

            if (ast.show_debug) {
                std.debug.print("--- JIT Evaluation Output ({s}) ---\n", .{name_prefix});
            }
            const result = main_func();
            if (ast.show_debug) {
                std.debug.print("--- JIT Execution completed (exit code: {d}) ---\n", .{result});
            }
            
            // Keep the library open and store it for future snippets
            try self.loaded_libs.append(lib);
            try self.previous_so_files.append(so_path);
        }
        
        // Only delete the .ll file. The .so file must remain on disk for future linkages
        std.fs.cwd().deleteFile(ll_filename) catch |err| {
            if (ast.show_debug) {
                std.debug.print("JIT Warning: Failed to clean up IR file '{s}': {}\n", .{ ll_filename, err });
            }
        };
    }
};
