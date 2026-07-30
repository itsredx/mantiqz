//! AOT (Ahead-Of-Time) compiler — native binary generation.
//!
//! Writes LLVM IR to a `.ll` file, then invokes `zig cc` (or a cross-compiler
//! for WASM/ARM targets) to produce a static binary or object file. Collects
//! `link[c]` / `link[pkg]` declarations from the AST and passes them as linker
//! flags (`-l`). Supports cross-compilation to WebAssembly.
//!
//! Key responsibilities:
//! - `compile` — write IR, invoke the system C compiler, link output
//! - Cross-compilation — target triple and `-target` flag forwarding
//! - Link target collection — `link_targets` from LinkDecl AST nodes

const std = @import("std");
const ast = @import("ast.zig");

const runtime_c = @embedFile("runtime.c");

pub const AOTCompiler = struct {
    allocator: std.mem.Allocator,
    library_dirs: [][]const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) AOTCompiler {
        return .{
            .allocator = allocator,
        };
    }

    pub fn compile(self: *AOTCompiler, ir: []const u8, name_prefix: []const u8, target: ?[]const u8, as_object: bool, link_targets: ?[][]const u8) !void {
        // Create {name_prefix}.ll
        const ll_filename = try std.fmt.allocPrint(self.allocator, "{s}.ll", .{name_prefix});
        defer self.allocator.free(ll_filename);

        var file = try std.fs.cwd().createFile(ll_filename, .{});
        try file.writeAll(ir);
        file.close();

        const runtime_filename = try std.fmt.allocPrint(self.allocator, "{s}_runtime.c", .{name_prefix});
        defer self.allocator.free(runtime_filename);

        if (!as_object) {
            var rt_file = try std.fs.cwd().createFile(runtime_filename, .{});
            try rt_file.writeAll(runtime_c);
            rt_file.close();
        }
        defer if (!as_object) {
            std.fs.cwd().deleteFile(runtime_filename) catch {};
        };

        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append("zig");
        try args.append("cc");
        try args.append(ll_filename);
        if (!as_object) {
            try args.append(runtime_filename);
        }
        try args.append("-O2");
        try args.append("-fno-sanitize=address");

        var allocated_flags = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (allocated_flags.items) |flag| {
                self.allocator.free(flag);
            }
            allocated_flags.deinit();
        }

        for (self.library_dirs) |dir| {
            const lflag = try std.fmt.allocPrint(self.allocator, "-L{s}", .{dir});
            try allocated_flags.append(lflag);
            try args.append(lflag);
        }

        if (as_object) {
            try args.append("-c");
            const obj_filename = try std.fmt.allocPrint(self.allocator, "{s}.o", .{name_prefix});
            defer self.allocator.free(obj_filename);
            try args.append("-o");
            try args.append(obj_filename);
        } else {
            try args.append("-o");
            try args.append(name_prefix);
        }
        
        if (link_targets) |targets| {
            for (targets) |t| {
                const flag = try std.fmt.allocPrint(self.allocator, "-l{s}", .{t});
                try allocated_flags.append(flag);
                try args.append(flag);
            }
        }

        if (target) |t| {
            try args.append("-target");
            try args.append(t);
            if (std.mem.indexOf(u8, t, "wasm32") != null) {
                try args.append("-Wl,--no-entry");
                try args.append("-nostdlib");
            }
        } else if (!as_object) {
            // For native executable generation with unresolved quantum runtime symbols
            try args.append("-Wl,-z,undefs");
        }

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
            // We ignore linker errors for simple snippets without main
            if (std.mem.indexOf(u8, stderr.items, "undefined reference to `main'") != null or 
                std.mem.indexOf(u8, stderr.items, "undefined symbol: main") != null) {
                // Compile as object instead
                return try self.compile(ir, name_prefix, target, true, link_targets);
            }
            std.debug.print("AOT Compilation failed for {s}:\n{s}\n", .{name_prefix, stderr.items});
            return error.AOTCompilationFailed;
        }
        
        if (ast.show_debug) {
            std.debug.print("AOT compiled successfully to {s}{s}\n", .{name_prefix, if (as_object) ".o" else ""});
        }
    }
};
