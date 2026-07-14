//! Build system configuration for the Mantiq/Nizam compiler.
//!
//! Defines the build target (`mantiq-compiler`) and its dependencies:
//! tree-sitter (generated parser C source), mimalloc (allocator), pthread
//! (threading/concurrency). Supports cross-compilation to WASM and standard
//! Zig build modes (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall).
//!
//! Key build outputs:
//! - `mantiq-compiler` — the compiler binary (static-linked tree-sitter)
//! - `zig build test` — runs the Zig-side unit tests in `tests.zig`
//! - Link-time deps: mimalloc (allocator), pthread (spawn/await), rt (quantum)

const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "mantiq-compiler",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "mantiq",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const nizam_exe = b.addExecutable(.{
        .name = "nizam",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ExeConfig = struct {
        fn configure(b_ctx: *std.Build, compile_step: *std.Build.Step.Compile, ts_dir_path: []const u8) void {
            compile_step.addCSourceFile(.{
                .file = b_ctx.path("../tree-sitter-mantiq/src/parser.c"),
                .flags = &[_][]const u8{"-std=c11"},
            });
            compile_step.addCSourceFile(.{
                .file = b_ctx.path("../tree-sitter-mantiq/src/scanner.c"),
                .flags = &[_][]const u8{"-std=c11"},
            });
            const ts_lib_c = std.fmt.allocPrint(b_ctx.allocator, "{s}/src/lib.c", .{ts_dir_path}) catch @panic("OOM");
            compile_step.addCSourceFile(.{
                .file = .{ .cwd_relative = ts_lib_c },
                .flags = &[_][]const u8{ "-std=c11", "-D_DEFAULT_SOURCE", "-D_POSIX_C_SOURCE=200809L" },
            });
            const ts_include = std.fmt.allocPrint(b_ctx.allocator, "{s}/include", .{ts_dir_path}) catch @panic("OOM");
            const ts_src = std.fmt.allocPrint(b_ctx.allocator, "{s}/src", .{ts_dir_path}) catch @panic("OOM");
            compile_step.addIncludePath(.{ .cwd_relative = ts_include });
            compile_step.addIncludePath(.{ .cwd_relative = ts_src });
            compile_step.addIncludePath(b_ctx.path("../tree-sitter-mantiq/src"));
            compile_step.linkLibC();
        }
    };

    const ts_dir_opt = b.option([]const u8, "tree-sitter-dir", "Path to tree-sitter C library source (contains include/ and src/)");
    const ts_dir = ts_dir_opt orelse blk: {
        var env_map = std.process.getEnvMap(b.allocator) catch @panic("Env OOM");
        const home_dir = env_map.get("HOME") orelse env_map.get("USERPROFILE") orelse "";
        break :blk std.fmt.allocPrint(b.allocator, "{s}/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/tree-sitter-0.26.7", .{home_dir}) catch @panic("OOM");
    };

    ExeConfig.configure(b, exe, ts_dir);
    ExeConfig.configure(b, nizam_exe, ts_dir);

    b.installArtifact(exe);
    b.installArtifact(nizam_exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_unit_tests.step);
}
