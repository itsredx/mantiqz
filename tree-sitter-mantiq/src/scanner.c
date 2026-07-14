#include <tree_sitter/parser.h>
#include <wctype.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>

enum TokenType {
    INDENT,
    DEDENT,
    NEWLINE,
};

typedef struct {
    uint16_t indent_stack[128];
    uint16_t stack_size;
    uint16_t current_line_indent;
} Scanner;

void *tree_sitter_mantiq_external_scanner_create() {
    Scanner *scanner = calloc(1, sizeof(Scanner));
    scanner->indent_stack[0] = 0;
    scanner->stack_size = 1;
    scanner->current_line_indent = 0;
    return scanner;
}

void tree_sitter_mantiq_external_scanner_destroy(void *payload) {
    free(payload);
}

unsigned tree_sitter_mantiq_external_scanner_serialize(void *payload, char *buffer) {
    Scanner *scanner = (Scanner *)payload;
    unsigned size = 0;
    buffer[size++] = (char)scanner->stack_size;
    buffer[size++] = (char)(scanner->current_line_indent & 0xFF);
    buffer[size++] = (char)((scanner->current_line_indent >> 8) & 0xFF);
    for (uint16_t i = 0; i < scanner->stack_size && size + 2 <= TREE_SITTER_SERIALIZATION_BUFFER_SIZE; i++) {
        buffer[size++] = (char)(scanner->indent_stack[i] & 0xFF);
        buffer[size++] = (char)((scanner->indent_stack[i] >> 8) & 0xFF);
    }
    return size;
}

void tree_sitter_mantiq_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
    Scanner *scanner = (Scanner *)payload;
    if (length < 3) {
        scanner->stack_size = 1;
        scanner->indent_stack[0] = 0;
        scanner->current_line_indent = 0;
        return;
    }
    scanner->stack_size = (unsigned char)buffer[0];
    uint16_t low = (unsigned char)buffer[1];
    uint16_t high = (unsigned char)buffer[2];
    scanner->current_line_indent = low | (high << 8);
    unsigned index = 3;
    for (uint16_t i = 0; i < scanner->stack_size && index + 1 < length; i++) {
        uint16_t low_val = (unsigned char)buffer[index++];
        uint16_t high_val = (unsigned char)buffer[index++];
        scanner->indent_stack[i] = low_val | (high_val << 8);
    }
    if (scanner->stack_size == 0) {
        scanner->indent_stack[0] = 0;
        scanner->stack_size = 1;
    }
}

static void skip(TSLexer *lexer) { lexer->advance(lexer, true); }
static void advance(TSLexer *lexer) { lexer->advance(lexer, false); }

bool tree_sitter_mantiq_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
    Scanner *scanner = (Scanner *)payload;

    if (lexer->eof(lexer)) {
        if (valid_symbols[DEDENT] && scanner->stack_size > 1) {
            scanner->stack_size--;
            lexer->result_symbol = DEDENT;
            return true;
        }
        return false;
    }

    uint16_t indent = 0;
    bool found_newline = false;
    uint32_t start_column = lexer->get_column(lexer);

    while (lexer->lookahead == ' ' || lexer->lookahead == '\t' || lexer->lookahead == '\f' || lexer->lookahead == '\v' ||
           lexer->lookahead == '\n' || lexer->lookahead == '\r') {
        if (lexer->lookahead == '\n' || lexer->lookahead == '\r') {
            indent = 0;
            found_newline = true;
            advance(lexer);
            lexer->mark_end(lexer); 
        } else if (lexer->lookahead == ' ') {
            indent++;
            advance(lexer);
        } else if (lexer->lookahead == '\t') {
            indent += 4;
            advance(lexer);
        }
    }

    if (found_newline || start_column == 0) {
        scanner->current_line_indent = indent;
    }

    uint16_t current_indent = scanner->indent_stack[scanner->stack_size - 1];

    if (valid_symbols[DEDENT] && scanner->current_line_indent < current_indent) {
        scanner->stack_size--;
        lexer->result_symbol = DEDENT;
        return true;
    }

    if (found_newline) {
        if (scanner->current_line_indent > current_indent && valid_symbols[INDENT]) {
            if (scanner->stack_size < 128) {
                scanner->indent_stack[scanner->stack_size++] = scanner->current_line_indent;
                lexer->mark_end(lexer);
                lexer->result_symbol = INDENT;
                return true;
            }
        }

        if (valid_symbols[NEWLINE]) {
            lexer->result_symbol = NEWLINE;
            return true;
        }
    } else {
        bool at_start_of_line = (start_column == 0 || start_column == indent);
        if (at_start_of_line) {
             if (scanner->current_line_indent > current_indent && valid_symbols[INDENT]) {
                if (scanner->stack_size < 128) {
                    scanner->indent_stack[scanner->stack_size++] = scanner->current_line_indent;
                    lexer->mark_end(lexer);
                    lexer->result_symbol = INDENT;
                    return true;
                }
            }
        }
    }

    return false;
}
