//! Compiler entry point and pipeline orchestration.
//!
//! Parses CLI arguments, reads source files, runs the full compiler pipeline,
//! and dispatches to the JIT or AOT backend. Also contains the REPL loop and
//! the `mergeImportedDeclarations` pass that flattens imported module ASTs
//! into the parent program before codegen.
//!
//! Pipeline order: Parse → Lower → Sema → CFG → Typecheck → Borrowck → DCE
//!   → MergeImports → Codegen → JIT/AOT
//!
//! Key responsibilities:
//! - `testPipeline` — run the full pipeline with structured test definitions
//! - REPL — interactive read-eval-print loop with persistent state
//! - `mergeImportedDeclarations` — recursive AST flattening for modules
//! - CLI argument parsing — `--show-ir`, `--debug`, file arguments

const std = @import("std");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const lower = @import("lower.zig");
const sema = @import("sema.zig");
const typecheck = @import("typecheck.zig");
const borrowck = @import("borrowck.zig");
const cfg = @import("cfg.zig");
const dce = @import("dce.zig");
const codegen = @import("codegen.zig");
const aot = @import("aot.zig");
const jit = @import("jit.zig");
const c = parser.c;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse flags
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--show-ir")) {
            ast.show_ir = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            ast.show_debug = true;
        }
    }

    // Detect default language mode based on executable name (args[0])
    var default_mode: ast.LanguageMode = .Mantiq;
    if (args.len > 0) {
        const exe_name = std.fs.path.basename(args[0]);
        if (std.mem.indexOf(u8, exe_name, "nizam") != null) {
            default_mode = .Nizam;
        }
    }

    if (args.len == 1) {
        try startRepl(allocator, stdout, default_mode);
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "repl")) {
        var mode = default_mode;
        if (args.len > 2) {
            if (std.mem.eql(u8, args[2], "nizam")) {
                mode = .Nizam;
            } else if (std.mem.eql(u8, args[2], "mantiq")) {
                mode = .Mantiq;
            }
        }
        try startRepl(allocator, stdout, mode);
        return;
    } else if (std.mem.eql(u8, command, "test")) {
        try runTests(allocator, stdout);
        return;
    } else if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        try printHelp(stdout);
        return;
    } else if (std.mem.eql(u8, command, "build")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing input file for 'build' command.\n\n", .{});
            try printHelp(stdout);
            std.process.exit(1);
        }
        const input_file = args[2];
        if (std.mem.startsWith(u8, input_file, "-")) {
            std.debug.print("Error: Input file cannot start with '-'. Got: {s}\n", .{input_file});
            std.process.exit(1);
        }

        var output_file: ?[]const u8 = null;
        var target: ?[]const u8 = null;
        var lib_dirs = std.ArrayList([]const u8).init(allocator);
        defer lib_dirs.deinit();

        var arg_idx: usize = 3;
        while (arg_idx < args.len) : (arg_idx += 1) {
            const arg = args[arg_idx];
            if (std.mem.eql(u8, arg, "-o")) {
                if (arg_idx + 1 >= args.len) {
                    std.debug.print("Error: Missing argument for '-o' option.\n", .{});
                    std.process.exit(1);
                }
                arg_idx += 1;
                output_file = args[arg_idx];
            } else if (std.mem.eql(u8, arg, "-target")) {
                if (arg_idx + 1 >= args.len) {
                    std.debug.print("Error: Missing argument for '-target' option.\n", .{});
                    std.process.exit(1);
                }
                arg_idx += 1;
                target = args[arg_idx];
            } else if (std.mem.eql(u8, arg, "--lib-dir")) {
                if (arg_idx + 1 >= args.len) {
                    std.debug.print("Error: Missing argument for '--lib-dir' option.\n", .{});
                    std.process.exit(1);
                }
                arg_idx += 1;
                try lib_dirs.append(args[arg_idx]);
            } else if (std.mem.eql(u8, arg, "--show-ir") or std.mem.eql(u8, arg, "--debug")) {
                // Handled
            } else {
                std.debug.print("Error: Unknown option '{s}'\n", .{arg});
                std.process.exit(1);
            }
        }

        const final_output = output_file orelse blk: {
            if (std.mem.lastIndexOfScalar(u8, input_file, '.')) |dot_idx| {
                const sep_idx = std.mem.lastIndexOfAny(u8, input_file, "/\\") orelse 0;
                if (dot_idx > sep_idx) {
                    break :blk try allocator.dupe(u8, input_file[0..dot_idx]);
                } else {
                    break :blk input_file;
                }
            } else {
                break :blk input_file;
            }
        };

        try doBuild(allocator, input_file, final_output, target, default_mode, lib_dirs.items);
        return;
    } else if (std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing input file for 'run' command.\n\n", .{});
            try printHelp(stdout);
            std.process.exit(1);
        }
        const input_file = args[2];
        if (std.mem.startsWith(u8, input_file, "-")) {
            std.debug.print("Error: Input file cannot start with '-'. Got: {s}\n", .{input_file});
            std.process.exit(1);
        }
        try doRun(allocator, input_file, default_mode);
        return;
    } else {
        if (!std.mem.startsWith(u8, command, "-")) {
            try doRun(allocator, command, default_mode);
            return;
        } else {
            std.debug.print("Error: Unknown command/option '{s}'\n\n", .{command});
            try printHelp(stdout);
            std.process.exit(1);
        }
    }
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Mantiq / Nizam Compiler Command Line Interface
        \\
        \\Usage:
        \\  mantiq build <input_file> [-o <output_file>] [-target <target>] [--lib-dir <dir>] [--show-ir] [--debug]
        \\  mantiq run <input_file> [--show-ir] [--debug] [args...]
        \\  mantiq repl [nizam] [--show-ir] [--debug]
        \\  mantiq test
        \\
        \\Options:
        \\  -o <output_file>   Specify the output binary filename (for 'build' command)
        \\  -target <target>   Specify the target architecture for cross-compilation
        \\  --lib-dir <dir>    Add directory to library search path (for 'build' command)
        \\  --show-ir          Print generated LLVM IR to stdout during compilation
        \\  --debug            Enable compiler debug logging
        \\  -h, --help         Show this help message
        \\
    );
}

fn runPipeline(
    allocator: std.mem.Allocator,
    p: *parser.Parser,
    source_code: []const u8,
    mode: ast.LanguageMode,
    arena: *std.heap.ArenaAllocator,
    link_targets: *std.ArrayList([]const u8),
) ![]const u8 {
    _ = allocator;
    const tree = c.ts_parser_parse_string(
        p.ts_parser,
        null,
        source_code.ptr,
        @as(u32, @intCast(source_code.len)),
    ) orelse return error.ParseFailed;
    defer c.ts_tree_delete(tree);

    const root_node = c.ts_tree_root_node(tree);

    var macros = std.StringHashMap(lower.MacroDef).init(arena.allocator());
    var lowerer = lower.Lowerer.init(arena.allocator(), mode, source_code, &macros);
    const ast_root = try lowerer.lowerProgram(root_node);

    var analyzer = try sema.SemanticAnalyzer.init(arena.allocator(), mode);
    try analyzer.analyze(ast_root);

    var cfg_analyzer = cfg.CFGAnalyzer.init(arena.allocator());
    try cfg_analyzer.analyzeProgram(ast_root);

    var checker = typecheck.TypeChecker.init(arena.allocator(), mode);
    try checker.checkProgram(ast_root);

    var bck = borrowck.BorrowChecker.init(arena.allocator());
    try bck.checkProgram(ast_root);

    var optimizer = dce.DeadCodeEliminator.init(arena.allocator());
    try optimizer.optimizeProgram(ast_root);

    var merged_modules = std.StringHashMap(void).init(arena.allocator());
    try mergeImportedDeclarations(arena.allocator(), ast_root, &merged_modules);

    for (ast_root.data.Program.declarations) |decl| {
        if (decl.node_type == .LinkDecl) {
            try link_targets.append(try arena.allocator().dupe(u8, decl.data.LinkDecl.target));
        }
    }

    var global_vars = std.StringHashMap([]const u8).init(arena.allocator());
    var cg = codegen.LLVMCodegen.init(arena.allocator(), &global_vars);
    const ll_ir = try cg.generate(ast_root);

    return ll_ir;
}

fn doBuild(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, target: ?[]const u8, default_mode: ast.LanguageMode, lib_dirs: [][]const u8) !void {
    var file = std.fs.cwd().openFile(input_path, .{}) catch |err| {
        std.debug.print("Error: Failed to open input file '{s}': {}\n", .{input_path, err});
        std.process.exit(1);
    };
    defer file.close();
    const source = file.readToEndAlloc(allocator, 1024 * 1024 * 10) catch |err| {
        std.debug.print("Error: Failed to read input file '{s}': {}\n", .{input_path, err});
        std.process.exit(1);
    };
    defer allocator.free(source);

    const mode: ast.LanguageMode = if (std.mem.endsWith(u8, input_path, ".nz")) .Nizam else if (std.mem.endsWith(u8, input_path, ".mq")) .Mantiq else default_mode;
    var p = try parser.Parser.init();
    defer p.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var link_targets = std.ArrayList([]const u8).init(arena.allocator());
    defer link_targets.deinit();

    const ll_ir = runPipeline(allocator, &p, source, mode, &arena, &link_targets) catch |err| {
        std.debug.print("Compilation failed: {}\n", .{err});
        std.process.exit(1);
    };

    var aot_compiler = aot.AOTCompiler.init(allocator);
    aot_compiler.library_dirs = lib_dirs;
    aot_compiler.compile(ll_ir, output_path, target, false, if (link_targets.items.len > 0) link_targets.items else null) catch |err| {
        std.debug.print("AOT Compilation failed: {}\n", .{err});
        std.process.exit(1);
    };
}

fn doRun(allocator: std.mem.Allocator, input_path: []const u8, default_mode: ast.LanguageMode) !void {
    var file = std.fs.cwd().openFile(input_path, .{}) catch |err| {
        std.debug.print("Error: Failed to open input file '{s}': {}\n", .{input_path, err});
        std.process.exit(1);
    };
    defer file.close();
    const source = file.readToEndAlloc(allocator, 1024 * 1024 * 10) catch |err| {
        std.debug.print("Error: Failed to read input file '{s}': {}\n", .{input_path, err});
        std.process.exit(1);
    };
    defer allocator.free(source);

    const mode: ast.LanguageMode = if (std.mem.endsWith(u8, input_path, ".nz")) .Nizam else if (std.mem.endsWith(u8, input_path, ".mq")) .Mantiq else default_mode;
    var p = try parser.Parser.init();
    defer p.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var link_targets = std.ArrayList([]const u8).init(arena.allocator());
    defer link_targets.deinit();

    const ll_ir = runPipeline(allocator, &p, source, mode, &arena, &link_targets) catch |err| {
        std.debug.print("Compilation failed: {}\n", .{err});
        std.process.exit(1);
    };

    var prefix_buf = std.ArrayList(u8).init(allocator);
    defer prefix_buf.deinit();
    
    const base_name = std.fs.path.basename(input_path);
    for (base_name) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try prefix_buf.append(char);
        } else if (char == ' ') {
            try prefix_buf.append('_');
        }
    }
    const prefix = prefix_buf.items;

    var jit_compiler = jit.JITCompiler.init(allocator);
    defer jit_compiler.deinit();
    jit_compiler.evaluate(ll_ir, prefix) catch |err| {
        std.debug.print("JIT Evaluation failed: {}\n", .{err});
        std.process.exit(1);
    };
}

fn runTests(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Initializing Mantiq Compiler Frontend...\n", .{});

    var p = try parser.Parser.init();
    defer p.deinit();

    try stdout.print("Successfully initialized tree-sitter CST parser for Mantiq.\n\n", .{});

    // Test 1: Successful bf16 and type inference
    const valid_code = 
        \\let weights as bf16 = 0.5 to bf16
        \\let age = 30
        \\fn calculate() -> f32:
        \\    let loss as f32 = weights to f32
        \\    return loss
    ;
    try testPipeline(allocator, stdout, &p, valid_code, .Mantiq, "Valid Implicit Widening & Inference");

    // Test 2: Type Mismatch Error
    const mismatch_code = 
        \\let name as i32 = "Mantiq"
    ;
    try testPipeline(allocator, stdout, &p, mismatch_code, .Mantiq, "Type Mismatch Error");

    // Test 3: Use After Move Error
    const move_code = 
        \\from std.string import String
        \\let s1 as String = String("Mantiq")
        \\let s2 as String = s1
        \\let crash as String = s1
    ;
    try testPipeline(allocator, stdout, &p, move_code, .Nizam, "Use After Move Error");

    // Test 4: Use After Drop (Free) Error
    const drop_code = 
        \\let ptr as Any = make()
        \\drop(ptr)
        \\let crash as Any = ptr
    ;
    try testPipeline(allocator, stdout, &p, drop_code, .Nizam, "Use After Drop Error");

    // Test 5: Explicit Lifetimes
    const life_code = 
        \\from std.string import String
        \\let source as String = String("Mantiq")
        \\let reference as life[a] mut String = source
        \\let trigger as Any = reference
    ;
    try testPipeline(allocator, stdout, &p, life_code, .Nizam, "Explicit Lifetimes Tracking");

    // Test 6: OOP & Dynamic Dispatch
    const oop_code = 
        \\class MyClass:
        \\    fn calculate():
        \\        let x as i32 = 10
        \\
        \\let obj as Any = make()
        \\obj.calculate()
        \\
    ;
    try testPipeline(allocator, stdout, &p, oop_code, .Mantiq, "OOP & Dynamic Dispatch");

    // Test 7: Quantum Dead Code Elimination (Zero-cost unused)
    const dce_unused_code = 
        \\import std.quantum
        \\fn main():
        \\    if False:
        \\        let qb as qbit = H(0)
        \\        measure(qb)
        \\
    ;
    try testPipeline(allocator, stdout, &p, dce_unused_code, .Nizam, "Quantum DCE (Unused / Pruned)");

    // Test 8: Quantum Dead Code Elimination (Used / Retained)
    const dce_used_code = 
        \\import std.quantum
        \\fn main():
        \\    if True:
        \\        let qb as qbit = H(0)
        \\        measure(qb)
        \\
    ;
    try testPipeline(allocator, stdout, &p, dce_used_code, .Nizam, "Quantum DCE (Used / Retained)");
    // Test 9: CFG Missing Return Statement
    const cfg_missing_ret = 
        \\fn calc() -> i32:
        \\    if True:
        \\        return 1
    ;
    try testPipeline(allocator, stdout, &p, cfg_missing_ret, .Nizam, "CFG Missing Return Path");

    // Test 10: CFG Unreachable Code
    const cfg_unreachable = 
        \\fn calc() -> i32:
        \\    return 1
        \\    let x as i32 = 2
    ;
    try testPipeline(allocator, stdout, &p, cfg_unreachable, .Nizam, "CFG Unreachable Code");

    // Test 11: Concurrency Lowering (Parsed)
    const concurrency_code = 
        \\fn main():
        \\    for@par i in range(10):
        \\        measure(H(0))
        \\    for@vec j in range(10):
        \\        measure(H(0))
        \\
    ;
    try testPipeline(allocator, stdout, &p, concurrency_code, .Mantiq, "Concurrency_Lowering");

    // Test 12: Closure / Lambda
    const closure_code = 
        \\fn main():
        \\    let my_closure = (x as i32) => x
        \\    my_closure(5 to i32)
        \\
    ;
    try testPipeline(allocator, stdout, &p, closure_code, .Mantiq, "Closure_Evaluation");

    // Test 13: Closure Capture (Higher-Order Function)
    const closure_capture_code =
        \\fn make_multiplier(x as i32) -> fn(i32) -> i32:
        \\    let multiply = (y as i32) => x * y
        \\    return multiply
        \\
        \\fn main() -> i32:
        \\    let times3 = make_multiplier(3 to i32)
        \\    let result as i32 = times3(5 to i32)
        \\    return result
        \\
    ;
    try testPipeline(allocator, stdout, &p, closure_capture_code, .Mantiq, "Closure_Capture");

    // Test 14: Built-in Print Function
    const print_code = 
        \\fn main():
        \\    let a as i32 = 10
        \\    let b as f32 = 20.5
        \\    let my_closure = (x as i32) => x
        \\    print(a, b, my_closure, 42 to i32)
        \\
    ;
    try testPipeline(allocator, stdout, &p, print_code, .Mantiq, "Builtin_Print");

    // Test 15: Nizam Implicit Allocation Error (String)
    const nizam_implicit_str = 
        \\fn main():
        \\    let s as String = "test"
        \\
    ;
    try testPipeline(allocator, stdout, &p, nizam_implicit_str, .Nizam, "Nizam_Implicit_String_Error");

    // Test 16: Nizam Explicit Allocation (List)
    const nizam_explicit_list = 
        \\import std.collections
        \\fn main():
        \\    let l as List[i32, 5]
        \\
    ;
    try testPipeline(allocator, stdout, &p, nizam_explicit_list, .Nizam, "Nizam_Explicit_List_Success");

    // Test 17: Mantiq Implicit Allocation (List)
    const mantiq_implicit_list = 
        \\fn main():
        \\    let l as List[i32, 5]
        \\
    ;
    try testPipeline(allocator, stdout, &p, mantiq_implicit_list, .Mantiq, "Mantiq_Implicit_List_Success");

    // Test 18: List Literal Initialization
    const list_literal_code = 
        \\fn main():
        \\    let l as List[i32, 5] = [1, 2, 3, 4, 5]
        \\
    ;
    try testPipeline(allocator, stdout, &p, list_literal_code, .Mantiq, "List_Literal_Initialization");

    // Test 19: Dynamic Type (Any) and Strings
    const dynamic_toolkit_code = 
        \\fn main():
        \\    let my_str as str = "hello mantiq"
        \\    let my_dynamic as Any = my_str
        \\    let my_num as Any = 42
        \\    let my_list as Any = [1, 2, 3]
        \\
    ;
    try testPipeline(allocator, stdout, &p, dynamic_toolkit_code, .Mantiq, "Dynamic_Toolkit_Types");

    // Test 20: Mantiq String Encodings
    const string_encodings_code = 
        \\fn main():
        \\    let w as webstr = "browser string"
        \\    let u16 as utf16str = "jvm string"
        \\    let r as rangestr = "fast unicode"
        \\    let u32 as utf32str = "full unicode"
        \\
    ;
    try testPipeline(allocator, stdout, &p, string_encodings_code, .Mantiq, "Mantiq_String_Encodings");

    // Test 21: Functional_Option_Result
    const functional_code = 
        \\fn main():
        \\    let op1 as Option[i32] = Some(42)
        \\    let op2 as Option[i32] = Empty
        \\    let res1 as Result[i32, i32] = Ok(100)
        \\    let res2 as Result[i32, i32] = Err(500)
        \\
    ;
    try testPipeline(allocator, stdout, &p, functional_code, .Mantiq, "Functional_Option_Result");

    // Test 22: Quantum_Simulation
    const quantum_sim_code = 
        \\import std.quantum
        \\fn main():
        \\    let qb1 as qbit = H(0)
        \\    let qb2 as qbit = H(1)
        \\    CNOT(qb1, qb2)
        \\    measure(qb1)
        \\    measure(qb2)
        \\    let entangled as qreg = qreg(2)
        \\
    ;
    try testPipeline(allocator, stdout, &p, quantum_sim_code, .Mantiq, "Quantum_Simulation");

    // Test 23: Memory Allocator (Mimalloc)
    const allocator_code = 
        \\fn main():
        \\    let dyn_obj as ptr[u8] = make(16)
        \\    let str_buffer as str = "mimalloc test string"
        \\    let list_buffer as List[i32] = [10, 20, 30, 40, 50]
        \\
    ;
    try testPipeline(allocator, stdout, &p, allocator_code, .Mantiq, "Memory_Allocator_Mimalloc");

    // Test 24: Multiple Variable Binding
    const multi_var_code = 
        \\fn main():
        \\    let a, b as i32 = 1, 2
        \\    let c as u8, d as i32, e as f32 = 2, 54, 32.32
        \\
    ;
    try testPipeline(allocator, stdout, &p, multi_var_code, .Mantiq, "Multiple_Variable_Binding");

    // Test 25: Async Actor Spawn
    const async_code = 
        \\async fn calc(x as i32) -> i32:
        \\    return x
        \\
        \\fn main():
        \\    let task = spawn calc(21)
        \\    let result as i32 = await task
        \\
    ;
    try testPipeline(allocator, stdout, &p, async_code, .Mantiq, "Async_Actor_Spawn");

    // Test 25b: Unions
    const union_code = 
        \\union Value:
        \\    var i as i32
        \\    var f as f32
        \\
        \\fn main():
        \\    let v as Value = Value(f=3.14)
        \\    unsafe:
        \\        let i_val as i32 = v.i
        \\        print(i_val)
        \\
    ;
    try testPipeline(allocator, stdout, &p, union_code, .Mantiq, "Unions");

    // Test 25c: Tagged Unions
    const tagged_union_code =
        \\enum NodeType:
        \\    Var
        \\    Func
        \\    Block
        \\
        \\union(NodeType) NodeData:
        \\    var var_decl as i32
        \\    var fun_decl as i32
        \\    var block_stmt as i32
        \\
        \\fn main():
        \\    let u as NodeData = NodeData(fun_decl=42)
        \\    let f_val as i32 = u.fun_decl
        \\    print(f_val)
        \\    let tag_val as NodeType = u.tag
        \\    print(tag_val)
        \\
    ;
    try testPipeline(allocator, stdout, &p, tagged_union_code, .Mantiq, "Tagged_Unions");

    // Test 26: Parameterized Blocks (Tuple binding)
    const param_block_code =
        \\fn main():
        \\    let mut x as i32 = 10
        \\    let mut y as i32 = 20
        \\
        \\    block (x as i32, y as i32) as (res_x as i64, res_y as i64):
        \\        return x * 2, y * 2
        \\
    ;
    try testPipeline(allocator, stdout, &p, param_block_code, .Nizam, "Parameterized_Blocks");

    const test_control_flow =
        \\fn main():
        \\    let mut x as i32 = 10
        \\
        \\    if x == 10:
        \\        x = x + 1
        \\    elif x == 20:
        \\        x = x + 2
        \\    else:
        \\        x = x + 3
        \\
        \\    let y as i32 = if x == 11: 100 else: 200
        \\    let z as i32 = if x == 5: 50 elif x == 11: 100 else: 200
    ;
    try testPipeline(allocator, stdout, &p, test_control_flow, .Mantiq, "Control_Flow_If");

    const test_while_loop =
        \\fn main():
        \\    let mut x as i32 = 0
        \\    let mut loops as i32 = 0
        \\    while x < 10:
        \\        x = x + 1
        \\        if x == 5:
        \\            continue
        \\        if x == 8:
        \\            break
        \\        loops = loops + 1
        \\        pass
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_while_loop, .Mantiq, "While_Loop_Control");

    const test_for_loop =
        \\fn main():
        \\    let mut loops as i32 = 0
        \\    for i as i32 in range(0, 10):
        \\        if i == 5:
        \\            continue
        \\        if i == 8:
        \\            break
        \\        loops = loops + 1
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_for_loop, .Mantiq, "For_Loop_Control");

    const test_spread =
        \\fn main():
        \\    let a as List[i32] = [1, 2, 3]
        \\    let b as List[i32] = [...a, 4, 5]
        \\    let c as List[i32] = [0, ...b, 6]
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_spread, .Mantiq, "Spread_Operator");

    const test_match =
        \\fn main():
        \\    let score as i32 = 95
        \\    match score:
        \\        case 100:
        \\            pass
        \\        case 90..99:
        \\            score = score + 1
        \\        case x if x < 50:
        \\            pass
        \\        case _:
        \\            pass
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_match, .Mantiq, "Match_Statement");

    const test_func_params =
        \\class Player:
        \\    fn move(self, x as i32, y as i32):
        \\        pass
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_func_params, .Mantiq, "Function_Params");

    const test_semantic_err =
        \\fn calc(x as i32) -> i32:
        \\    return x
        \\
        \\fn main():
        \\    let a as i32 = calc()
        \\    let b as i32 = calc(5)
        \\
    ;
    // We expect this to fail typechecking — log the expected error rather than silently discarding
    testPipeline(allocator, stdout, &p, test_semantic_err, .Mantiq, "Semantic_Error_Args") catch |err| {
        try stdout.print("(Expected failure for Semantic_Error_Args: {})\n\n", .{err});
    };

    const test_tuples =
        \\fn get_coords() -> (i32, i32):
        \\    return 10, 20
        \\
        \\fn main():
        \\    let x , y = get_coords()
        \\    print(x)
        \\    print(y)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_tuples, .Mantiq, "Multiple_Returns_Tuples");

    const test_variadic =
        \\fn sum_all(base as i32, ...args as i32) -> i32:
        \\    let mut total as i32 = base
        \\    for num as i32 in args:
        \\        total = total + num
        \\    return total
        \\
        \\fn main():
        \\    print(sum_all(10, 1, 2, 3))
        \\    let extra as List[i32] = [4, 5]
        \\    print(sum_all(20, ...extra))
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_variadic, .Mantiq, "Variadic_Spread_Args");

    const test_generics =
        \\fn calc[T](a as T, b as T) -> T:
        \\    return a + b
        \\
        \\fn main():
        \\    print(calc(10, 20))
        \\    print(calc(1.5, 2.5))
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_generics, .Mantiq, "Generic_Functions");

    const test_func_sigs =
        \\fn add(a as i32, b as i32) -> i32:
        \\    return a + b
        \\
        \\fn apply_func(op as fn(i32, i32) -> i32, x as i32, y as i32) -> i32:
        \\    return op(x, y)
        \\
        \\fn main():
        \\    let my_op = add
        \\    let res as i32 = apply_func(my_op, 100, 200)
        \\    print(res)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_func_sigs, .Mantiq, "Function_Signatures");

    const test_closure_mono =
        \\fn run_callback[T](op as T) -> i32:
        \\    return op(10)
        \\
        \\fn main():
        \\    let x as i32 = 50
        \\    let my_closure = fn(y as i32) => x + y
        \\    print(run_callback(my_closure))
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_closure_mono, .Mantiq, "Closures_Monomorphized");
    
    const test_keyword_args =
        \\fn move(x as i32 = 0, y as i32 = 0) -> i32:
        \\    return x + y
        \\
        \\fn main():
        \\    print(move())
        \\    print(move(10))
        \\    print(move(y=10, x=5))
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_keyword_args, .Mantiq, "Keyword_Arguments");
    
    const struct_code = 
        \\struct Vector2:
        \\    public x as i32
        \\    public y as i32
        \\
        \\fn main():
        \\    let v as Vector2 = Vector2(x=10, y=20)
        \\    print(v.x)
        \\    print(v.y)
        \\    print(v.x + v.y)
        \\
    ;
    try testPipeline(allocator, stdout, &p, struct_code, .Mantiq, "Struct_Basics");

    const struct_methods_code = 
        \\struct Vector2:
        \\    public var x as i32
        \\    public var y as i32
        \\
        \\    fn get_x(self as Vector2) -> i32:
        \\        return self.x
        \\
        \\fn main():
        \\    let v as Vector2 = Vector2(x=100, y=200)
        \\    print(v.get_x())
        \\
    ;
    try testPipeline(allocator, stdout, &p, struct_methods_code, .Mantiq, "Struct_Methods");

    const struct_mut_code = 
        \\struct MutablePoint:
        \\    public var x as i32
        \\    let y as i32
        \\
        \\fn main():
        \\    let p as MutablePoint = MutablePoint(x=10, y=20)
        \\    p.x = 500
        \\    print(p.x)
        \\
    ;
    try testPipeline(allocator, stdout, &p, struct_mut_code, .Mantiq, "Struct_Mutation");

    const generic_struct_code = 
        \\struct GenericPoint[T]:
        \\    public var x as T
        \\    public var y as T
        \\
        \\    fn get_x(self as GenericPoint[T]) -> T:
        \\        return self.x
        \\
        \\fn main():
        \\    let p1 as GenericPoint[i32] = GenericPoint[i32](x=10, y=20)
        \\    let p2 as GenericPoint[f32] = GenericPoint[f32](x=1.5, y=2.5)
        \\    print(p1.get_x())
        \\    print(p2.get_x())
        \\
    ;
    try testPipeline(allocator, stdout, &p, generic_struct_code, .Mantiq, "Generic_Struct");

    const struct_defaults_code = 
        \\struct LLVMCodegen:
        \\    public var allocator as i32
        \\    public var is_global as bool = True
        \\    public var out as f32 = 3.14
        \\
        \\fn main():
        \\    let cg1 as LLVMCodegen = LLVMCodegen(allocator=100)
        \\    let cg2 as LLVMCodegen = LLVMCodegen(allocator=200, is_global=False)
        \\    print(cg1.allocator)
        \\    print(cg1.is_global)
        \\    print(cg1.out)
        \\    print(cg2.allocator)
        \\    print(cg2.is_global)
        \\    print(cg2.out)
        \\
    ;
    try testPipeline(allocator, stdout, &p, struct_defaults_code, .Mantiq, "Struct_Default_Values");

    const struct_magic_code =
        \\struct MagicPoint:
        \\    public var x as i32
        \\    public var y as i32
        \\
        \\    public fn __init__(self as ptr[MagicPoint], x as i32, y as i32):
        \\        (deref self).x = x
        \\        (deref self).y = y
        \\
        \\    public fn __add__(self as MagicPoint, other as MagicPoint) -> MagicPoint:
        \\        return MagicPoint(self.x + other.x, self.y + other.y)
        \\
        \\    public fn __neg__(self as MagicPoint) -> MagicPoint:
        \\        return MagicPoint(-self.x, -self.y)
        \\
        \\    public fn __getitem__(self as MagicPoint, idx as i32) -> i32:
        \\        if idx == 0:
        \\            return self.x
        \\        return self.y
        \\
        \\fn main():
        \\    let p1 as MagicPoint = MagicPoint(10, 20)
        \\    let p2 as MagicPoint = MagicPoint(5, 15)
        \\    let p3 as MagicPoint = p1 + p2
        \\    let p4 as MagicPoint = -p1
        \\    print(p3.x)
        \\    print(p3.y)
        \\    print(p4.x)
        \\    print(p4.y)
        \\    print(p1[0])
        \\    print(p1[1])
        \\
    ;
    try testPipeline(allocator, stdout, &p, struct_magic_code, .Mantiq, "Struct_Magic_Methods");

    const enums_code = 
        \\enum Color:
        \\    Red
        \\    Green
        \\    Blue
        \\
        \\enum Option:
        \\    Some(i32)
        \\    Empty
        \\
        \\fn main():
        \\    let c1 as Color = Color.Green
        \\    let opt1 as Option = Option.Some(42)
        \\    let opt2 as Option = Option.Empty
        \\    print(c1)
        \\    print(opt1)
        \\    print(opt2)
        \\
    ;
    try testPipeline(allocator, stdout, &p, enums_code, .Mantiq, "Enums");

    const function_signatures_code = 
        \\fn add(a as i32, b as i32) -> i32:
        \\    return a + b
        \\
        \\fn apply_func(op as fn(i32, i32) -> i32, x as i32, y as i32) -> i32:
        \\    return op(x, y)
        \\
        \\fn main():
        \\    let my_op = add
        \\    let res as i32 = apply_func(my_op, 100, 200)
        \\    print(res)
        \\
    ;
    try testPipeline(allocator, stdout, &p, function_signatures_code, .Mantiq, "Function_Signatures");

    const python_print_code =
        \\fn main():
        \\    print(1, 2, 3)
        \\    print(4, 5, sep="-")
        \\    print(6, 7, end="---")
        \\    print(8, 9, sep="*", end="\n")
        \\
    ;
    try testPipeline(allocator, stdout, &p, python_print_code, .Mantiq, "Python_Print");

    const error_handling_code =
        \\fn parse_age(age as i32) -> Result[i32, i32]:
        \\    if age == 20:
        \\        return Ok(20)
        \\    else:
        \\        raise 404
        \\
        \\fn main():
        \\    let res as i32 = try parse_age(20) catch err:
        \\        print(err)
        \\        return
        \\    print(res)
        \\    let res2 as i32 = try parse_age(10) catch err:
        \\        print(err)
        \\        return
        \\    print(res2)
        \\
    ;
    try testPipeline(allocator, stdout, &p, error_handling_code, .Mantiq, "Zero_Cost_Error_Handling");

    const test_modifiers =
        \\inline fn _inl() -> i32:
        \\    return 42
        \\
        \\static var _st = 1
        \\
        \\fn main():
        \\    _st = _inl()
        \\    print(_st)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_modifiers, .Mantiq, "System_Modifiers");

    // Test 28: Uninitialized Variable Error (Expect Typecheck Failure)
    const test_uninit_var =
        \\fn main():
        \\    let x as i32
        \\    print(x)
        \\
    ;
    _ = testPipeline(allocator, stdout, &p, test_uninit_var, .Mantiq, "Uninitialized_Variable_Error") catch {};

    // Test 29: Generic Name Resolution
    const test_generic_resolve =
        \\fn make_point[T](val as T) -> T:
        \\    let x as T = val
        \\    return x
        \\
        \\fn main():
        \\    let p as i32 = make_point(42)
        \\    print(p)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_generic_resolve, .Mantiq, "Generic_Name_Resolution");

    // Test 30: Module Import Namespace (Mantiq)
    const test_module_namespace =
        \\import math
        \\
        \\fn main():
        \\    let sum = math.add(10, 20)
        \\    print(sum)
        \\    let p = math.pi
        \\    print(p)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_module_namespace, .Mantiq, "Module_Import_Namespace");

    // Test 31: Module Import From Alias (Nizam)
    const test_module_from_import =
        \\from math import add, Vector
        \\from utils import multiply
        \\
        \\fn main():
        \\    let v as Vector = Vector(x = 5, y = 7)
        \\    let prod as i32 = multiply(v.x, v.y)
        \\    let result as i32 = add(prod, 100)
        \\    print(result)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_module_from_import, .Nizam, "Module_From_Import_Alias");
    // Test 32: Extended Import Syntax
    const test_extended_imports =
        \\import[c] "time.h"
        \\import[c] "math.h"
        \\import[vendor] my_package
        \\import[vendor] org.pkg
        \\import[path] "path/to/my/module"
        \\link "pthread"
        \\link "m"
        \\
        \\extern fn time(t as i64) -> i64:
        \\    pass
        \\
        \\extern fn sqrt(x as f64) -> f64:
        \\    pass
        \\
        \\fn main():
        \\    let a as i32 = my_package.do_vendor()
        \\    let nested as i32 = pkg.greet()
        \\    let b as i32 = module.do_path()
        \\    let current_time as i64 = time(0)
        \\    let root as f64 = sqrt(144.0 to f64)
        \\    print(a)
        \\    print(nested)
        \\    print(b)
        \\    print(current_time)
        \\    print(root)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_extended_imports, .Nizam, "Extended_Imports");

    const test_mem =
        \\import std.mem
        \\
        \\fn main():
        \\    let ptr as ptr[u8] = make(16)
        \\    print("Allocated!")
        \\    let new_ptr as ptr[u8] = resize(ptr, 32)
        \\    print("Reallocated!")
        \\    drop(new_ptr)
        \\    print("Freed!")
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_mem, .Nizam, "StdMem_AllocFree");

    const test_io =
        \\import std.io
        \\
        \\fn main():
        \\    let fd_in = stdin
        \\    let fd_out = stdout
        \\    let fd_err = stderr
        \\    write(fd_out, "Writing to stdout!\n")
        \\    write(fd_err, "Writing to stderr!\n")
        \\    write(fd_out, "Please type something: ")
        \\    //let input = read(fd_in, 100)
        \\    //write(fd_out, "Received: ")
        \\    //write(fd_out, input)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_io, .Nizam, "StdIO_Streams");

    const test_fs =
        \\import std.fs
        \\import std.io
        \\
        \\fn main():
        \\    let path as str = "temp_test.txt"
        \\    let not_exists as bool = exists(path)
        \\    print("Initial exists check: ", not_exists, "\n")
        \\
        \\    let fd_write = open(path, "w")
        \\    write(fd_write, "Hello Nizam Filesystem!\n")
        \\    close(fd_write)
        \\
        \\    let does_exist as bool = exists(path)
        \\    print("Exists check after write: ", does_exist, "\n")
        \\
        \\    let fd_read = open(path, "r")
        \\    let data as str = read(fd_read, 100)
        \\    close(fd_read)
        \\
        \\    print("File Contents: ")
        \\    write(stdout, data)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_fs, .Nizam, "StdFS_Operations");

    const test_with =
        \\import std.fs
        \\import std.io
        \\
        \\fn main():
        \\    let path as str = "temp_with.txt"
        \\    with open(path, "w") as f:
        \\        write(f, "Hello Nizam with Context Manager!\n")
        \\
        \\    let does_exist as bool = exists(path)
        \\    print("Exists check after with write: ", does_exist, "\n")
        \\
        \\    with open(path, "r") as f_read:
        \\        let data as str = read(f_read, 100)
        \\        print("With File Contents: ")
        \\        write(stdout, data)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_with, .Nizam, "WithStmt_Operations");

    const test_time =
        \\import std.time
        \\import std.io
        \\
        \\fn main():
        \\    let t0 = now()
        \\    sleep(1)
        \\    let t1 = now()
        \\    if t1 >= t0:
        \\        print("Time elapsed successfully\n")
        \\    else:
        \\        print("Error: Backwards time travel\n")
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_time, .Nizam, "StdTime_Operations");

    const test_sys =
        \\import std.sys
        \\import std.io
        \\
        \\fn main():
        \\    let my_os as str = os()
        \\    let my_arch as str = arch()
        \\    print("OS: ")
        \\    println(my_os)
        \\    print("Arch: ")
        \\    println(my_arch)
        \\
        \\    setenv("MANTIQ_TEST_VAR", "12345")
        \\    let val as str = getenv("MANTIQ_TEST_VAR")
        \\    print("MANTIQ_TEST_VAR: ")
        \\    println(val)
        \\
        \\    unsetenv("MANTIQ_TEST_VAR")
        \\    let unset_val as str = getenv("MANTIQ_TEST_VAR")
        \\    if unset_val == "":
        \\        print("Environment variable unset successfully\n")
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_sys, .Nizam, "StdSys_Operations");

    const test_std_imports_scoping =
        \\from std.sys import os, arch
        \\
        \\fn main():
        \\    let my_os as str = os()
        \\    let my_arch as str = arch()
        \\
    ;
    _ = testPipeline(allocator, stdout, &p, test_std_imports_scoping, .Nizam, "StdImportsScoping_Error") catch {};


    const test_collections =
        \\from std.collections import List, Dict
        \\import std.io
        \\
        \\fn main():
        \\    let lst as List[i32] = List[i32]()
        \\    print("List len: ")
        \\    println(lst.length())
        \\    lst.append(10)
        \\    lst.append(20)
        \\    print("List len after append: ")
        \\    println(lst.length())
        \\    print("Elements: ")
        \\    print(lst[0])
        \\    print(" ")
        \\    println(lst[1])
        \\    lst[1] = 99
        \\    print("Element 1 updated: ")
        \\    println(lst[1])
        \\    lst.clear()
        \\    print("List len after clear: ")
        \\    println(lst.length())
        \\
        \\    let d as Dict[AsciiStr, i32] = Dict[AsciiStr, i32]()
        \\    print("Dict len: ")
        \\    println(d.length())
        \\    d["alice"] = 100
        \\    d["bob"] = 200
        \\    print("Dict len after inserts: ")
        \\    println(d.length())
        \\    print("Dict has alice: ")
        \\    println(d.has("alice"))
        \\    print("Dict has charlie: ")
        \\    println(d.has("charlie"))
        \\    print("Dict values: ")
        \\    print(d["alice"])
        \\    print(" ")
        \\    println(d["bob"])
        \\    let removed_alice as bool = d.remove("alice")
        \\    print("Dict removed alice: ")
        \\    println(removed_alice)
        \\    print("Dict has alice: ")
        \\    println(d.has("alice"))
        \\    print("Dict len after remove: ")
        \\    println(d.length())
        \\    d.clear()
        \\    print("Dict len after clear: ")

        \\    println(d.length())
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_collections, .Nizam, "StdCollections_Operations");

    const test_nizam_list_fail =
        \\fn main():
        \\    let lst as List[i32] = List[i32]()
        \\
    ;
    _ = testPipeline(allocator, stdout, &p, test_nizam_list_fail, .Nizam, "NizamListFail_Error") catch {};

    const test_nizam_dict_fail =
        \\fn main():
        \\    let d as Dict[String, i32] = Dict[String, i32]()
        \\
    ;
    _ = testPipeline(allocator, stdout, &p, test_nizam_dict_fail, .Nizam, "NizamDictFail_Error") catch {};

    const test_nizam_set =
        \\from std.collections import Set, List
        \\from std.string import String
        \\import std.io
        \\
        \\fn main():
        \\    let s as Set[AsciiStr] = Set[AsciiStr]()
        \\    print("Set len: ")
        \\    println(s.length())
        \\    s["apple"] = True
        \\    s["banana"] = True
        \\    s["apple"] = True // Should not increase length
        \\    print("Set len after adds: ")
        \\    println(s.length())
        \\    print("Set has apple: ")
        \\    println(s["apple"])
        \\    print("Set has orange: ")
        \\    println(s["orange"])
        \\    s["apple"] = False
        \\    print("Set has apple after remove: ")
        \\    println(s["apple"])
        \\    print("Set len after remove: ")
        \\    println(s.length())
        \\    let list_items as List[AsciiStr] = s.to_list()
        \\    print("List len from set: ")
        \\    println(list_items.length())
        \\    print(list_items[0])
        \\    s.clear()
        \\    print("Set len after clear: ")
        \\    println(s.length())
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_nizam_set, .Nizam, "StdCollections_Set");

    const test_option_result =
        \\from std.option import Option, Some, Empty
        \\from std.result import Result, Ok, Err
        \\
        \\fn main():
        \\    let opt as Option[i32] = Some(42)
        \\    let empty_opt as Option[i32] = Empty
        \\    let res as Result[i32, i32] = Ok(100)
        \\    let err_res as Result[i32, i32] = Err(1)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_option_result, .Nizam, "StdOptionResult_Operations");

    const test_nizam_option_fail =
        \\fn main():
        \\    let opt as Option[i32] = Some(42)
        \\
    ;
    _ = testPipeline(allocator, stdout, &p, test_nizam_option_fail, .Nizam, "NizamOptionFail_Error") catch {};

    const test_nizam_result_fail =
        \\fn main():
        \\    let res as Result[i32, i32] = Ok(100)
        \\
    ;
    _ = testPipeline(allocator, stdout, &p, test_nizam_result_fail, .Nizam, "NizamResultFail_Error") catch {};

    const test_nizam_string =
        \\from std.string import String, StringBuilder
        \\
        \\fn main():
        \\    let mut s1 as String = String("Hello ")
        \\    let s2 as String = String("World")
        \\    print(s1.len)
        \\    print(s2.len)
        \\    print(s1[0])
        \\    print(s2[0])
        \\    s1.append(ref s2)
        \\    print(s1.len)
        \\
        \\    let mut sb as StringBuilder = StringBuilder()
        \\    sb.append_builder("StringBuilder ")
        \\    sb.append_builder("works!")
        \\    let s3 as String = sb.builder_to_string()
        \\    print(s3.len)
        \\
        \\    s1.__del__()
        \\    s2.__del__()
        \\    s3.__del__()
        \\    sb.__del__()
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_nizam_string, .Nizam, "StdString_Operations");

    const test_nizam_string_fail =
        \\fn main():
        \\    let mut s as String = String("Hello World")
        \\
    ;
    _ = testPipeline(allocator, stdout, &p, test_nizam_string_fail, .Nizam, "NizamStringFail_Error") catch {};

    const test_nizam_bitwise =
        \\fn main():
        \\    let a as i32 = 5
        \\    let b as i32 = 3
        \\    let and_val as i32 = a & b
        \\    let or_val as i32 = a | b
        \\    let xor_val as i32 = a ^ b
        \\    let shl_val as i32 = a << 1
        \\    let shr_val as i32 = a >> 1
        \\    let not_val as i32 = ~a
        \\    print(and_val)
        \\    print(or_val)
        \\    print(xor_val)
        \\    print(shl_val)
        \\    print(shr_val)
        \\    print(not_val)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_nizam_bitwise, .Nizam, "NizamBitwise_Operations");

    const test_nizam_text =
        \\from std.text import Codepoint
        \\from std.text import is_digit, is_alpha, is_alphanumeric, is_whitespace, is_hex_digit, is_octal_digit
        \\from std.text import utf8_char_length, utf8_decode, utf8_encode, utf8_validate, utf8_count_codepoints
        \\from std.text import ascii_encode, ascii_decode, ascii_validate, ascii_count_codepoints, ascii_char_length
        \\from std.text import utf16_encode, utf16_decode, utf16_validate, utf16_count_codepoints, utf16_char_length
        \\from std.text import utf32_encode, utf32_decode, utf32_validate, utf32_count_codepoints, utf32_char_length
        \\from std.mem import make, drop
        \\
        \\fn main():
        \\    let d as bool = is_digit('7' to char)
        \\    let a as bool = is_alpha('x' to char)
        \\    let al as bool = is_alphanumeric('_' to char)
        \\    let w as bool = is_whitespace(' ' to char)
        \\    let h as bool = is_hex_digit('A' to char)
        \\    let o as bool = is_octal_digit('5' to char)
        \\    print(d)
        \\    print(a)
        \\    print(al)
        \\    print(w)
        \\    print(h)
        \\    print(o)
        \\
        \\    let mut buf as ptr[u8] = make(4) to ptr[u8]
        \\    let len as usize = utf8_encode(128512 to u32, buf)
        \\    print(len)
        \\    let is_valid as bool = utf8_validate(buf, len)
        \\    print(is_valid)
        \\    let count as usize = utf8_count_codepoints(buf, len)
        \\    print(count)
        \\    let cp as Codepoint = utf8_decode(buf, 0)
        \\    print(cp.value)
        \\    print(cp.length)
        \\
        \\    let len_ascii as usize = ascii_encode(65 to u32, buf)
        \\    let is_valid_ascii as bool = ascii_validate(buf, len_ascii)
        \\    let count_ascii as usize = ascii_count_codepoints(buf, len_ascii)
        \\    let cp_ascii as Codepoint = ascii_decode(buf, 0)
        \\    print(cp_ascii.value)
        \\    drop(buf to ptr)
        \\
        \\    let mut buf16 as ptr[u16] = make(4) to ptr[u16]
        \\    let len16 as usize = utf16_encode(128512 to u32, buf16)
        \\    print(len16)
        \\    let is_valid16 as bool = utf16_validate(buf16, len16)
        \\    print(is_valid16)
        \\    let count16 as usize = utf16_count_codepoints(buf16, len16)
        \\    print(count16)
        \\    let cp16 as Codepoint = utf16_decode(buf16, 0)
        \\    print(cp16.value)
        \\    print(cp16.length)
        \\    drop(buf16 to ptr)
        \\
        \\    let mut buf32 as ptr[u32] = make(4) to ptr[u32]
        \\    let len32 as usize = utf32_encode(128512 to u32, buf32)
        \\    print(len32)
        \\    let is_valid32 as bool = utf32_validate(buf32, len32)
        \\    print(is_valid32)
        \\    let count32 as usize = utf32_count_codepoints(buf32, len32)
        \\    print(count32)
        \\    let cp32 as Codepoint = utf32_decode(buf32, 0)
        \\    print(cp32.value)
        \\    print(cp32.length)
        \\    drop(buf32 to ptr)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_nizam_text, .Nizam, "StdText_Operations");

    const test_nizam_math =
        \\from std.math import PI, E, min, max, abs, sqrt
        \\
        \\fn main():
        \\    print("PI: ")
        \\    print(PI)
        \\    print("\nE: ")
        \\    print(E)
        \\    print("\nMin: ")
        \\    print(min(10, 20))
        \\    print("\nMax: ")
        \\    print(max(10, 20))
        \\    print("\nAbs: ")
        \\    print(abs(-42))
        \\    print("\nSqrt: ")
        \\    print(sqrt(144.0 to f64))
        \\    print("\n")
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_nizam_math, .Nizam, "StdMath_Operations");

    const test_nizam_path =
        \\from std.path import join, join_ref, dirname, dirname_ref, basename, basename_ref, isabs, isabs_ref, exists, exists_ref, is_windows
        \\from std.string import String
        \\
        \\fn main():
        \\    let p1 as String = String("/usr/bin/test")
        \\    let p2 as String = String("usr/bin/test")
        \\    let isabs_p1 as bool = isabs(p1)
        \\    let isabs_p2 as bool = isabs_ref(ref p2)
        \\
        \\    let p3 as String = String("/usr")
        \\    let p4 as String = String("bin")
        \\    let joined1 as String = join(p3, p4)
        \\
        \\    let p5 as String = String("/usr/")
        \\    let p6 as String = String("bin")
        \\    let joined2 as String = join_ref(ref p5, ref p6)
        \\
        \\    let p7 as String = String("usr")
        \\    let p8 as String = String("/bin")
        \\    let joined3 as String = join_ref(ref p7, ref p8)
        \\
        \\    let dir1 as String = dirname(p5)
        \\    let dir2 as String = dirname_ref(ref p6)
        \\
        \\    let p9 as String = String("usr/bin/test")
        \\    let dir3 as String = dirname(p9)
        \\
        \\    let base1 as String = basename(p7)
        \\    let base2 as String = basename_ref(ref p8)
        \\
        \\    let ex1 as String = String("/etc/passwd")
        \\    let ex2 as String = String("/nonexistent_file_abc")
        \\    let has_ex1 as bool = exists_ref(ref ex1)
        \\    let has_ex2 as bool = exists(ex2)
        \\
        \\    print(isabs_p1, isabs_p2, joined1.data to cstr, joined2.data to cstr, joined3.data to cstr, dir1.data to cstr, dir2.data to cstr, dir3.data to cstr, base1.data to cstr, base2.data to cstr, has_ex1, has_ex2)
        \\
        \\    if is_windows():
        \\        let w1 as String = String("C:\\Windows\\System32")
        \\        let w2 as String = String("test.txt")
        \\        let w_joined as String = join(w1, w2)
        \\        let w_dir as String = dirname_ref(ref w_joined)
        \\        let w_base as String = basename_ref(ref w_joined)
        \\        let w_isabs as bool = isabs_ref(ref w_joined)
        \\        print("WindowsPath: ", w_isabs, w_joined.data to cstr, w_dir.data to cstr, w_base.data to cstr)
        \\        w_joined.__del__()
        \\        w_dir.__del__()
        \\        w_base.__del__()
        \\
        \\    joined1.__del__()
        \\    joined2.__del__()
        \\    joined3.__del__()
        \\    dir1.__del__()
        \\    dir2.__del__()
        \\    dir3.__del__()
        \\    base1.__del__()
        \\    base2.__del__()
        \\    ex1.__del__()
        \\    p2.__del__()
        \\    p6.__del__()
        \\    p8.__del__()
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_nizam_path, .Nizam, "StdPath_Operations");

    const test_classes =
        \\class Shape:
        \\    area as i32
        \\
        \\    public fn get_area(self as Shape) -> i32:
        \\        return self.area
        \\
        \\class Circle(Shape):
        \\    radius as i32
        \\
        \\    public fn get_area(self as Circle) -> i32:
        \\        return self.radius * self.radius * 3
        \\
        \\fn main():
        \\    let s as Shape = Shape(area=100)
        \\    let c as Circle = Circle(area=0, radius=10)
        \\    print(c.get_area())
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_classes, .Mantiq, "Mantiq_Classes");

    const test_interfaces =
        \\interface Drawable:
        \\    fn draw(self as Drawable) -> i32
        \\
        \\class Window(Drawable):
        \\    public fn draw(self as Window) -> i32:
        \\        return 42
        \\
        \\fn main():
        \\    let w as Window = Window()
        \\    print(w.draw())
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_interfaces, .Mantiq, "Mantiq_Interfaces");

    const test_macro_hygiene_locals =
        \\macro swap(a, b):
        \\    let temp = a
        \\    a = b
        \\    b = temp
        \\
        \\fn main():
        \\    let temp = 100
        \\    let y = 200
        \\    swap!(temp, y)
        \\    print(temp)
        \\    print(y)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_macro_hygiene_locals, .Mantiq, "Macro_Hygiene_Locals");

    const test_macro_hygiene_shadowing =
        \\macro define_x():
        \\    let x = 42
        \\    print(x)
        \\    
        \\fn main():
        \\    let x = 10
        \\    define_x!()
        \\    print(x)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_macro_hygiene_shadowing, .Mantiq, "Macro_Hygiene_Shadowing");

    const test_process =
        \\import std.process
        \\import std.io
        \\
        \\fn main():
        \\    let my_args = args()
        \\    print("Process Args count: ")
        \\    let arg0 = my_args[0]
        \\    print("Args 0 retrieved successfully\n")
        \\    exit(0)
        \\
    ;
    try testPipeline(allocator, stdout, &p, test_process, .Nizam, "StdProcess_Operations");
}

fn testPipeline(
    allocator: std.mem.Allocator,
    stdout: anytype,
    p: *parser.Parser,
    source_code: []const u8,
    mode: ast.LanguageMode,
    test_name: []const u8,
) !void {
    try stdout.print("=== Test: {s} ===\n", .{test_name});
    try stdout.print("Source:\n{s}\n\n", .{source_code});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var link_targets = std.ArrayList([]const u8).init(arena.allocator());
    defer link_targets.deinit();

    const ll_ir = runPipeline(allocator, p, source_code, mode, &arena, &link_targets) catch |err| {
        try stdout.print("Compilation pipeline failed with error: {}\n\n", .{err});
        return;
    };

    if (ast.show_ir) {
        try stdout.print("=== Generated LLVM IR ===\n{s}\n", .{ll_ir});
    }
    try stdout.print("Compilation pipeline successful! LLVM IR generated.\n", .{});

    var prefix_buf = std.ArrayList(u8).init(allocator);
    defer prefix_buf.deinit();
    for (test_name) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try prefix_buf.append(char);
        } else if (char == ' ') {
            try prefix_buf.append('_');
        }
    }
    const prefix = prefix_buf.items;

    try stdout.print("Starting JIT Evaluation for '{s}'...\n", .{prefix});
    var jit_compiler = jit.JITCompiler.init(allocator);
    defer jit_compiler.deinit();
    jit_compiler.evaluate(ll_ir, prefix) catch |err| {
        try stdout.print("JIT Evaluation failed: {}\n", .{err});
    };
    try stdout.print("\n", .{});

    try stdout.print("Starting AOT Compilation for '{s}'...\n", .{prefix});
    var aot_compiler = aot.AOTCompiler.init(allocator);
    aot_compiler.compile(ll_ir, prefix, null, false, if (link_targets.items.len > 0) link_targets.items else null) catch |err| {
        try stdout.print("AOT Compilation failed: {}\n\n", .{err});
        return;
    };
    try stdout.print("\n", .{});
}


fn startRepl(allocator: std.mem.Allocator, stdout: anytype, mode: ast.LanguageMode) !void {
    const stdin = std.io.getStdIn().reader();
    var p = try parser.Parser.init();
    defer p.deinit();

    try stdout.print("Welcome to the {s} REPL.\n", .{if (mode == .Mantiq) "Mantiq" else "Nizam (Persistent)"});
    try stdout.print("Type your code and press Enter. (Persistent snippet evaluation mode)\n", .{});
    try stdout.print("Type 'exit' or press Ctrl+C to quit.\n\n", .{});

    var line_buf = std.ArrayList(u8).init(allocator);
    defer line_buf.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var analyzer = sema.SemanticAnalyzer.init(arena.allocator(), mode) catch |err| {
        try stdout.print("Failed to initialize SemanticAnalyzer: {}\n", .{err});
        return;
    };
    var tc = typecheck.TypeChecker.init(arena.allocator(), mode);
    var jit_compiler = jit.JITCompiler.init(allocator);
    defer jit_compiler.deinit();
    var global_vars = std.StringHashMap([]const u8).init(arena.allocator());
    var macros = std.StringHashMap(lower.MacroDef).init(arena.allocator());
    var snippet_count: u32 = 1;

    while (true) {
        if (mode == .Mantiq) {
            try stdout.print("mantiq> ", .{});
        } else {
            try stdout.print("nizam> ", .{});
        }

        line_buf.clearRetainingCapacity();
        stdin.streamUntilDelimiter(line_buf.writer(), '\n', null) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };

        const input = std.mem.trim(u8, line_buf.items, " \r\t");
        if (input.len == 0) continue;
        if (std.mem.eql(u8, input, "exit") or std.mem.eql(u8, input, "quit")) break;

        // Tree-sitter needs the newline to parse statements properly
        line_buf.append('\n') catch |err| {
            try stdout.print("Memory Error: Failed to append newline: {}\n", .{err});
            continue;
        };
        
        // Execute the snippet
        replEvaluate(
            allocator, 
            stdout, 
            &p, 
            line_buf.items, 
            mode, 
            arena.allocator(),
            &analyzer,
            &tc,
            &jit_compiler,
            &global_vars,
            &macros,
            snippet_count
        ) catch |err| {
            try stdout.print("REPL Error: {}\n", .{err});
        };
        snippet_count += 1;
        try stdout.print("\n", .{});
    }
}

fn replEvaluate(
    allocator: std.mem.Allocator,
    stdout: anytype,
    p: *parser.Parser,
    source_code: []const u8,
    mode: ast.LanguageMode,
    arena_allocator: std.mem.Allocator,
    analyzer: *sema.SemanticAnalyzer,
    tc: *typecheck.TypeChecker,
    jit_compiler: *jit.JITCompiler,
    global_vars: *std.StringHashMap([]const u8),
    macros: *std.StringHashMap(lower.MacroDef),
    snippet_id: u32,
) !void {
    const tree = c.ts_parser_parse_string(
        p.ts_parser,
        null,
        source_code.ptr,
        @as(u32, @intCast(source_code.len)),
    ) orelse return error.ParseFailed;
    defer c.ts_tree_delete(tree);

    const root_node = c.ts_tree_root_node(tree);
    
    // Duplicate source code into the persistent arena so AST slices outlive the REPL buffer
    const persistent_source = try arena_allocator.dupe(u8, source_code);
    var lowerer = lower.Lowerer.init(arena_allocator, mode, persistent_source, macros);
    const ast_root = lowerer.lowerProgram(root_node) catch |err| {
        try stdout.print("Syntax Error: {}\n", .{err});
        return;
    };

    analyzer.analyze(ast_root) catch |err| {
        try stdout.print("Semantic Error: {}\n", .{err});
        return;
    };

    var cfg_analyzer = cfg.CFGAnalyzer.init(arena_allocator);
    cfg_analyzer.analyzeProgram(ast_root) catch |err| {
        try stdout.print("CFG Analysis Error: {}\n", .{err});
        return;
    };

    tc.checkProgram(ast_root) catch |err| {
        try stdout.print("Typecheck Error: {}\n", .{err});
        return;
    };

    var bc = borrowck.BorrowChecker.init(arena_allocator);
    bc.checkProgram(ast_root) catch |err| {
        try stdout.print("Borrow Checker Error: {}\n", .{err});
        return;
    };

    var optimizer = dce.DeadCodeEliminator.init(arena_allocator);
    optimizer.optimizeProgram(ast_root) catch |err| {
        try stdout.print("DCE Error: {}\n", .{err});
        return;
    };

    var merged_modules = std.StringHashMap(void).init(arena_allocator);
    mergeImportedDeclarations(arena_allocator, ast_root, &merged_modules) catch |err| {
        try stdout.print("AST Merging Error: {}\n", .{err});
        return;
    };

    var cg = codegen.LLVMCodegen.init(arena_allocator, global_vars);
    const ll_ir = cg.generate(ast_root) catch |err| {
        try stdout.print("Codegen Error: {}\n", .{err});
        return;
    };

    const snippet_name = try std.fmt.allocPrint(allocator, "repl_snippet_{d}", .{snippet_id});
    defer allocator.free(snippet_name);
    
    jit_compiler.evaluate(ll_ir, snippet_name) catch |err| {
        try stdout.print("JIT Evaluation Error: {}\n", .{err});
    };
}

fn mergeImportedDeclarations(allocator: std.mem.Allocator, program: *ast.Node, merged_modules: *std.StringHashMap(void)) !void {
    if (program.node_type != .Program) return;

    var new_decls = std.ArrayList(*ast.Node).init(allocator);
    for (program.data.Program.declarations) |decl| {
        if (decl.node_type == .ImportDecl) {
            const imp = decl.data.ImportDecl;
            if (imp.module_ast) |sub_ast| {
                if (!merged_modules.contains(imp.target)) {
                    try merged_modules.put(imp.target, {});
                    try mergeImportedDeclarations(allocator, sub_ast, merged_modules);
                    for (sub_ast.data.Program.declarations) |sub_decl| {
                        try new_decls.append(sub_decl);
                    }
                }
            }
        }
        try new_decls.append(decl);
    }
    program.data.Program.declarations = try new_decls.toOwnedSlice();
}
