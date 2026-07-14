//! Tree-sitter parser wrapper — thin C FFI for CST construction.
//!
//! Initialises a tree-sitter parser with the Mantiq/Nizam language definition
//! (generated from `tree-sitter-mantiq/grammar.js`). Provides `parseString` to
//! produce a CST tree and exposes the tree-sitter C API for downstream use by
//! `lower.zig`. The generated parser is in `tree-sitter-mantiq/src/parser.c`.
//!
//! Key responsibilities:
//! - `Parser.init` — create a tree-sitter parser and set the language
//! - `parseString` — parse source text into a tree-sitter `TSTree`
//! - `c` — re-export of the `tree_sitter/api.h` C imports for CST traversal

const std = @import("std");

pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_mantiq() *const c.TSLanguage;

pub const Parser = struct {
    ts_parser: *c.TSParser,

    pub fn init() !Parser {
        const ts_parser = c.ts_parser_new() orelse return error.OutOfMemory;
        const language = tree_sitter_mantiq();
        if (!c.ts_parser_set_language(ts_parser, language)) {
            return error.LanguageVersionMismatch;
        }

        return Parser{
            .ts_parser = ts_parser,
        };
    }

    pub fn deinit(self: *Parser) void {
        c.ts_parser_delete(self.ts_parser);
    }

    pub fn parseString(self: *Parser, source: []const u8) !*c.TSTree {
        const tree = c.ts_parser_parse_string(
            self.ts_parser,
            null,
            source.ptr,
            @as(u32, @intCast(source.len)),
        ) orelse return error.ParseFailed;
        return tree;
    }
};
