module.exports = grammar({
  name: 'mantiq',
  word: $ => $.identifier,

  extras: $ => [
    $.comment,
    /[ \t\f\uFEFF\u2060\u200B]/,
  ],

  externals: $ => [
    $._indent,
    $._dedent,
    $._newline,
  ],

  conflicts: $ => [
    [$.match_case, $.primary],
    [$.anonymous_function],
    [$.fun_modifier, $.async_expression],
    [$.collection_item, $.primary],
    [$.arguments],
    [$.dict_arguments],
    [$.primary, $.parameters],
    [$.type_annotation, $.tuple_type],
    [$.primary, $.parameters, $._base_type],
    [$.primary, $._base_type],
    [$.parameters, $._base_type],
    [$.type_decl, $.primary],
    [$.enum_variant, $.primary],

    [$._base_type],
    [$.collection_item],
    [$.if_stmt, $.collection_item],
    [$.if_stmt, $.expr_stmt],
    [$.statement, $.primary],
    [$.dict_item],
    [$.ternary, $._ternary],
    [$.param_decl, $._base_type],
    [$.param_decl, $._type_desc],
    [$.primary, $.const_generic],
    [$.typed_var, $.var_decl],
  ],

  rules: {
    program: $ => repeat(choice($._declaration, $._newline)),

    _declaration: $ => choice(
      prec(5, $.import_decl),
      prec(5, $.link_decl),
      prec(5, $.class_decl),
      prec(5, $.interface_decl),
      prec(5, $.struct_decl),
      prec(5, $.enum_decl),
      prec(5, $.union_decl),
      prec(5, $.type_decl),
      prec(5, $.macro_decl),
      prec(5, $.fun_decl),
      prec(5, $.var_decl),
      prec(5, $.statement)
    ),

    // ------------------------------------------------------------------------
    // DECLARATIONS
    // ------------------------------------------------------------------------

    import_decl: $ => seq(
      choice(
        seq('import', optional(seq('[', field('tag', $.identifier), ']')), choice($.module_path, $.string), optional(seq('as', $.identifier))),
        seq('from', $.module_path, 'import', commaSep1($.identifier)),
        seq('import', $.identifier, 'from', $.module_path)
      ),
      $._newline
    ),

    link_decl: $ => seq(
      'link', optional(seq('[', field('tag', $.identifier), ']')), $.string,
      $._newline
    ),

    module_path: $ => seq($.identifier, repeat(seq('.', $.identifier))),

    class_decl: $ => seq(
        repeat($.decorator),
      optional($.access_modifier),
        'class',
        $.identifier,
        optional($.generic_params),
      optional(seq('(', commaSep1($._base_type), ')')),
        ':',
        $.block_body
    ),

    access_modifier: $ => choice('public', 'private'),

    interface_decl: $ => seq(
        'interface',
        $.identifier,
        optional($.generic_params),
        ':',
        $.block_body
    ),

    struct_decl: $ => seq(
        repeat($.decorator),
      optional($.access_modifier),
        'struct',
        $.identifier,
        optional($.generic_params),
        ':',
        $.block_body
    ),

    enum_decl: $ => prec(10, seq(
        repeat($.decorator),
      optional($.access_modifier),
        'enum',
        $.identifier,
        optional($.generic_params),
        ':',
        $.enum_body
    )),

    union_decl: $ => seq(
        repeat($.decorator),
      optional($.access_modifier),
        'union',
        optional(seq('(', field('tag_type', $._type_desc), ')')),
        field('name', $.identifier),
        optional(field('generic_params', $.generic_params)),
        ':',
        field('body', $.block_body)
    ),

    macro_decl: $ => seq(
      'macro', $.identifier, '(', optional($.typed_params), ')', ':',
      choice($.block_body, $.statement)
    ),

    type_decl: $ => seq(
        'type',
        $.identifier,
        optional($.generic_params),
        '=',
        $._type_desc,
        $._newline
    ),

    fun_decl: $ => seq(
        repeat($.decorator),
        repeat($.fun_modifier),
        'fn',
      $.named_function
    ),

    var_modifier: $ => choice('volatile', 'atomic', 'static'),

    fun_modifier: $ => choice('async', 'inline', 'const', $.kw_unsafe, 'abstract', 'static', 'extern', 'final'),

    typed_var: $ => seq($.identifier, $.type_annotation),

    var_decl: $ => seq(
      choice(
        seq(
          optional($.access_modifier),
          optional($.var_modifier),
          choice('let', 'var'),
          optional('mut'),
          commaSep1(choice($.identifier, $.typed_var)),
          optional($.type_annotation),
          optional(seq('=', commaSep1($.expression)))
        ),
        seq(
          optional($.access_modifier),
          'const',
          commaSep1(choice($.identifier, $.typed_var)),
          optional($.type_annotation),
          '=', commaSep1($.expression)
        )
      )
    ),






    decorator: $ => seq(
        '@',
        choice($.identifier, 'override', 'final', 'gpu', 'vec', 'par'),
        $._newline
    ),

    // ------------------------------------------------------------------------
    // STATEMENTS
    // ------------------------------------------------------------------------

    statement: $ => choice(
        $.expr_stmt,
        $.if_stmt,
        $.for_stmt,
        $.while_stmt,
        $.match_stmt,
        $.try_stmt,
        $.with_stmt,
        $.spawn_stmt,
        $.unsafe_block,
        $.block_stmt,
        $.jump_stmt,
        $.pass_stmt
    ),

    unsafe_block: $ => prec.right(10, seq(
      $.kw_unsafe, ':', $.block_body,
    )),

    pass_stmt: $ => seq('pass', $._newline),

    expr_stmt: $ => prec.dynamic(-1, seq($.expression, $._newline)),

    if_stmt: $ => prec.right(seq(
      'if', $.expression, ':',
      choice($.block_body, $.expression),
      repeat(seq(
        'elif', $.expression, ':',
        choice($.block_body, $.expression)
      )),
      optional(seq(
        'else', ':',
        choice($.block_body, $.expression)
      ))
    )),

    loop_modifier: $ => choice('@vec', '@par'),

    for_stmt: $ => seq(
      'for', repeat($.loop_modifier), $.identifier, optional(seq('as', $._type_desc)), $.kw_in, $.expression, ':',
      choice($.block_body, $.statement)
    ),

    while_stmt: $ => seq(
      repeat($.loop_modifier),
      'while', $.expression, ':',
      choice($.block_body, $.statement)
    ),

    match_stmt: $ => seq(
        $.kw_match, $.expression, ':',
        $._newline,
        $._indent,
        repeat1(choice($.match_case, $._newline)),
        $._dedent
    ),

    match_case: $ => seq(
      $.kw_case, choice($.expression, seq($.identifier, $.kw_is, $._type_desc)),
      optional(seq('if', $.expression)), ':', choice($.block_body, $.statement)
    ),

    try_stmt: $ => prec.right(seq(
      $.kw_try, ':', $.block_body,
      repeat(seq(
        $.kw_except, optional(choice($.identifier, seq($.identifier, 'as', $._type_desc))), ':', $.block_body
      )),
      optional(seq('else', ':', $.block_body)),
      optional(seq($.kw_finally, ':', $.block_body))
    )),

    with_stmt: $ => seq(
        $.kw_with, $.expression, optional(seq('as', $.identifier)), ':', $.block_body
    ),

    spawn_stmt: $ => prec.right(seq('spawn', $.expression, optional($._newline))),

    block_stmt: $ => seq(
        'block', 
        optional($.identifier), 
        optional(seq('(', optional($.typed_params), ')')), 
        optional($.return_annotation), 
        ':', 
        choice($.block_body, $.statement)
    ),

    jump_stmt: $ => prec.right(seq(
        choice(
            seq(choice('return', 'break', 'continue'), optional(commaSep1($.expression))),
            seq('raise', $.expression)
        ),
        optional($._newline)
    )),

    import_stmt: $ => seq(
        choice(
            seq('import', commaSep1($.identifier)),
            seq('from', $.identifier, 'import', commaSep1($.identifier))
        ),
        optional($._newline)
    ),

    block_body: $ => seq(
        $._newline,
        $._indent,
        repeat(choice($._declaration, $._newline)),
        $._dedent
    ),

    enum_body: $ => seq(
        $._newline,
        $._indent,
        repeat(choice(
            prec(20, $.enum_variant),
            prec(10, $._declaration),
            $._newline
        )),
        $._dedent
    ),

    enum_variant: $ => seq(
        $.identifier,
        optional(seq('(', optional($.typed_params), ')')),
        optional($.type_annotation),
        optional(seq('=', $.expression)),
        optional(','),
        $._newline
    ),

    // ------------------------------------------------------------------------
    // EXPRESSIONS
    // ------------------------------------------------------------------------

    expression: $ => $._assignment,

    _assignment: $ => prec.right(1, choice(
      $.assignment,
      $._lambda_expr,
      $._ternary
    )),

    assignment: $ => seq(field('left', choice($._lambda_expr, $._ternary)), field('operator', $.assign_op), field('right', $._assignment)),

    assign_op: $ => choice('=', '+=', '-=', '*=', '/=', '%=', '**=', '<<=', '>>=', '&=', '|=', '^='),

    _lambda_expr: $ => $.lambda_expr,

    lambda_expr: $ => seq('(', $.lambda_typed_params, ')', '=>', $.expression),

    ternary: $ => prec.right(seq($._null_coalesce, 'if', $.expression, 'else', $.expression)),

    _ternary: $ => choice(
      $._null_coalesce,
      $.ternary
    ),

    _null_coalesce: $ => choice(
      $._logic_or,
      alias($._bin_expr_2, $.binary_expression)
    ),

    _logic_or: $ => choice(
      $._logic_and,
      alias($._bin_expr_3, $.binary_expression)
    ),
    _logic_and: $ => choice(
      $._bitwise_or,
      alias($._bin_expr_4, $.binary_expression)
    ),

    _bitwise_or: $ => choice(
      $._bitwise_xor,
      alias($._bin_expr_5, $.binary_expression)
    ),
    _bitwise_xor: $ => choice(
      $._bitwise_and,
      alias($._bin_expr_6, $.binary_expression)
    ),
    _bitwise_and: $ => choice(
      $._equality,
      alias($._bin_expr_7, $.binary_expression)
    ),

    _equality: $ => choice(
      $._comparison,
      alias($._bin_expr_8, $.binary_expression)
    ),

    _comparison: $ => choice(
      $._range_expr,
      alias($._bin_expr_9, $.binary_expression)
    ),

    _range_expr: $ => choice(
      $._bitwise_sh,
      alias($._bin_expr_10, $.binary_expression)
    ),

    _bitwise_sh: $ => choice(
      $._term,
      alias($._bin_expr_11, $.binary_expression)
    ),

    _term: $ => choice(
      $._factor,
      alias($._bin_expr_12, $.binary_expression)
    ),

    _factor: $ => choice(
      $._unary,
      alias($._bin_expr_14, $.binary_expression)
    ),

    unary_expression: $ => prec.right(15, choice(
      seq(choice($.kw_not, '!', '-', '+', '~', 'deref', 'size', 'type', 'await'), $._unary),
      seq('spawn', $._postfix),
      seq('ref', optional('mut'), $._postfix),
      $.try_expr
    )),

    try_expr: $ => prec.right(15, seq(
      $.kw_try,
      $._postfix,
      optional(seq(
        'catch',
        optional(field('catch_binding', $.identifier)),
        ':',
        field('catch_body', choice($.block_body, $.statement))
      ))
    )),

    _unary: $ => choice(
      $.unary_expression,
      $.async_expression,
      $._power
    ),

    async_expression: $ => seq('async', $._unary),

    _power: $ => choice(
      $._postfix,
      alias($._bin_expr_16_r, $.binary_expression)
    ),

    _postfix: $ => choice(
      $._call,
      alias(prec.left(14, seq($._postfix, choice('++', '--'))), $.update_expression),
      $.cast_expression
    ),

    cast_expression: $ => prec.left(14, seq(
      field('operand', $._postfix),
      $.kw_to,
      field('target', $._type_desc)
    )),

    _call: $ => choice(
        $.primary,
        $.call_expression,
        $.index_expression,
        $.member_expression
    ),

    call_expression: $ => prec.left(17, seq(
      field('function', $._call),
      optional($.generic_params),
      '(',
      optional($.arguments),
      ')'
    )),

    index_expression: $ => prec.left(17, seq(
      $._call,
      '[',
      $.expression,
      ']'
    )),

    member_expression: $ => prec.left(17, seq(
      field('object', $._call),
      choice('.', '?.'),
      field('property', $.identifier)
    )),

    fun_expr: $ => prec.dynamic(20, seq(
      repeat($.fun_modifier),
      'fn',
      $.anonymous_function
    )),

    fun_decl: $ => prec.dynamic(20, seq(
      repeat($.decorator),
      repeat($.fun_modifier),
      'fn',
      $.named_function
    )),

    _nl: $ => repeat1($._newline),

    primary: $ => choice(
        $.macro_invocation,
        $.boolean_literal,
        $.null_literal,
        $.self_reference,
        $.color_literal,
        $.number,
        $.string,
        $.interpolated_str,
        $.identifier,
        $.quantum_literal,
        $.list_literal,
        seq('(', optional($._nl), $.expression, optional($._nl), ')'),
        $.dict_literal,
        seq('super', '(', optional($.arguments), ')'),
        $.fun_expr,
        $.if_stmt
    ),

    list_literal: $ => seq('[', optional($._nl), optional(seq($.arguments, optional($._nl))), ']'),
    dict_literal: $ => seq('{', optional($._nl), optional(seq($.dict_arguments, optional($._nl))), '}'),

    macro_invocation: $ => prec(10, seq($.identifier, '!', '(', optional($.arguments), ')')),

    quantum_literal: $ => seq('|', choice('0', '1'), '>'),

    // ------------------------------------------------------------------------
    // TYPES & UTILITIES
    // ------------------------------------------------------------------------

    named_function: $ => seq(
        $.identifier,
        optional($.generic_params),
        '(',
        optional($.typed_params),
        ')',
        optional($.return_annotation),
      optional(choice(
        seq('=>', $.expression),
        seq(':', $.block_body)
      ))
    ),

    anonymous_function: $ => seq(
      '(',
      optional($.typed_params),
      ')',
      optional($.return_annotation),
      optional(choice(
        seq('=>', $.expression),
        seq(':', $.block_body)
      ))
    ),

    typed_params: $ => seq($.param_decl, repeat(seq(',', $.param_decl))),

    // Lambda-specific typed params: requires type annotation to avoid conflict with primary expression
    lambda_typed_params: $ => seq(
        seq(field('name', $.identifier), field('type', $.type_annotation)),
        repeat(seq(',', seq(field('name', $.identifier), field('type', $.type_annotation))))
    ),

    param_decl: $ => choice(
      seq(
          optional(repeat(choice('ref', 'mut', seq('life', '[', field('lifetime_args', commaSep1($.expression)), ']')))),
          field('name', $.self_reference),
          field('type', optional($.type_annotation)),
          field('default_value', optional(seq('=', $.expression)))
      ),
      seq(
        optional('...'),
          optional(repeat(choice('ref', 'mut', seq('life', '[', field('lifetime_args', commaSep1($.expression)), ']')))),
          field('name', $.identifier),
          field('type', optional($.type_annotation)),
          field('default_value', optional(seq('=', $.expression)))
        )
    ),

    parameters: $ => seq($.identifier, repeat(seq(',', $.identifier))),

    arguments: $ => seq($.collection_item, repeat(seq(optional($._nl), ',', optional($._nl), $.collection_item)), optional(seq(optional($._nl), ','))),

    collection_item: $ => choice(
        seq($.identifier, optional($._nl), ':', optional($._nl), $.expression),
        $.expression,
        $.spread_expr,
        seq('if', $.expression, ':', $.collection_item, optional(seq('else', ':', $.collection_item))),
        seq('for', $.identifier, optional($.type_annotation), $.kw_in, $.expression, ':', $.collection_item)
    ),

    spread_expr: $ => seq('...', $.expression),

    dict_arguments: $ => seq($.dict_item, repeat(seq(optional($._nl), ',', optional($._nl), $.dict_item)), optional(seq(optional($._nl), ','))),

    dict_item: $ => choice(
        seq($.expression, ':', $.expression),
        $.spread_expr,
        seq('if', $.expression, ':', $.dict_item, optional(seq('else', ':', $.dict_item))),
        seq('for', $.identifier, optional($.type_annotation), $.kw_in, $.expression, ':', $.dict_item)
    ),

    type_annotation: $ => seq(choice(':', 'as'), $._type_desc),
    return_annotation: $ => seq(choice('->', 'as'), $._type_desc),

    _type_desc: $ => seq(
        repeat(choice('ref', 'mut', seq('life', '[', field('lifetime_args', commaSep1($.expression)), ']'))),
        $._base_type
    ),

    _base_type: $ => choice(
        seq($.identifier, optional($.generic_params), optional('?')),
      seq('(', optional($.tuple_type_list), ')'),
        seq('fn', '(', $.type_list, ')', choice('->', 'as'), $._type_desc)
    ),

    tuple_type_list: $ => seq($.tuple_type, repeat(seq(',', $.tuple_type))),
    tuple_type: $ => choice(
        seq($.identifier, 'as', $._type_desc),
        $._type_desc
    ),

    generic_params: $ => seq('[', $.type_list, ']'),
    type_list: $ => seq(
      choice($._type_desc, $.const_generic),
      repeat(seq(',', choice($._type_desc, $.const_generic)))
    ),
    const_generic: $ => choice($.number, $.string, $.boolean_literal),

    // ------------------------------------------------------------------------
    // TOKENS
    // ------------------------------------------------------------------------

    identifier: $ => /[a-zA-Z_][a-zA-Z0-9_]*/,

    number: $ => /\d+(\.\d+)?/,





    boolean_literal: $ => choice('True', 'False'),

    null_literal: $ => 'None',

    self_reference: $ => 'self',

    color_literal: $ => /#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})/,

    comment: $ => choice(
        seq('//', /.*/),
        seq('/*', /[^*]*\*+([^/*][^*]*\*+)*/, '/')
    ),

    
    kw_and: $ => 'and',
    kw_or: $ => 'or',
    kw_to: $ => 'to',
    kw_is: $ => 'is',
    kw_in: $ => 'in',
    kw_not: $ => 'not',

    kw_match: $ => 'match',
    kw_case: $ => 'case',

    kw_try: $ => 'try',
    kw_except: $ => 'except',
    kw_finally: $ => 'finally',
    kw_with: $ => 'with',
    kw_unsafe: $ => 'unsafe',

    string: $ => choice(
        seq('"""', repeat(choice(/[^"\\]/, /\\./, /"[^"]/, /""[^"]/)), '"""'),
        seq("'''", repeat(choice(/[^'\\]/, /\\./, /'[^']/, /''[^']/)), "'''"),
        seq(/([bBrRuU]*)"/, repeat(choice(/[^"\\]/, /\\./)), '"'),
        seq(/([bBrRuU]*)'/, repeat(choice(/[^'\\]/, /\\./)), "'")
    ),

    interpolated_str: $ => choice(
        seq(
            alias(/([bBrRuU]*[fF][bBrRuU]*)"/, $.string_start),
            repeat(choice(
                alias($._f_string_double_content, $.string_content),
                $.interpolation
            )),
            alias('"', $.string_end)
        ),
        seq(
            alias(/([bBrRuU]*[fF][bBrRuU]*)'/, $.string_start),
            repeat(choice(
                alias($._f_string_single_content, $.string_content),
                $.interpolation
            )),
            alias("'", $.string_end)
        ),
        seq(
            alias(/([bBrRuU]*[fF][bBrRuU]*)\"\"\"/, $.string_start),
            repeat(choice(
                alias($._f_string_multiline_double_content, $.string_content),
                $.interpolation
            )),
            alias('"""', $.string_end)
        ),
        seq(
            alias(/([bBrRuU]*[fF][bBrRuU]*)\'\'\'/, $.string_start),
            repeat(choice(
                alias($._f_string_multiline_single_content, $.string_content),
                $.interpolation
            )),
            alias("'''", $.string_end)
        ),
        seq(
            alias('`', $.string_start),
            repeat(choice(
                alias($._backtick_string_content, $.string_content),
                $.interpolation
            )),
            alias('`', $.string_end)
        )
    ),

    _f_string_double_content: $ => choice(
        /[^"{\\]+/,
        /\\./,
        '{{',
        '}}'
    ),

    _f_string_single_content: $ => choice(
        /[^'{\\]+/,
        /\\./,
        '{{',
        '}}'
    ),

    _f_string_multiline_double_content: $ => choice(
        /[^"{\\]+/,
        /"[^"{\\]+/,
        /""[^"{\\]+/,
        /\\./,
        '{{',
        '}}'
    ),

    _f_string_multiline_single_content: $ => choice(
        /[^'{\\]+/,
        /'[^'{\\]+/,
        /''[^'{\\]+/,
        /\\./,
        '{{',
        '}}'
    ),

    _backtick_string_content: $ => choice(
        /[^`{\\]+/,
        /\\./,
        '{{',
        '}}'
    ),

    interpolation: $ => seq(
        '{',
        $.expression,
        '}'
    ),
_bin_expr_2: $ => prec.left(2, seq(field('left', $._null_coalesce), field('operator', '??'), field('right', $._logic_or))),
    _bin_expr_3: $ => prec.left(3, seq(field('left', $._logic_or), field('operator', $.kw_or), field('right', $._logic_and))),
    _bin_expr_4: $ => prec.left(4, seq(field('left', $._logic_and), field('operator', $.kw_and), field('right', $._bitwise_or))),
    _bin_expr_5: $ => prec.left(5, seq(field('left', $._bitwise_or), field('operator', '|'), field('right', $._bitwise_xor))),
    _bin_expr_6: $ => prec.left(6, seq(field('left', $._bitwise_xor), field('operator', '^'), field('right', $._bitwise_and))),
    _bin_expr_7: $ => prec.left(7, seq(field('left', $._bitwise_and), field('operator', '&'), field('right', $._equality))),
    _bin_expr_8: $ => prec.left(8, seq(field('left', $._equality), field('operator', choice('!=', '==')), field('right', $._comparison))),
    _bin_expr_9: $ => prec.left(9, seq(field('left', $._comparison), field('operator', choice('>', '>=', '<', '<=', $.kw_is, seq($.kw_is, $.kw_not), $.kw_in, seq($.kw_not, $.kw_in))), field('right', $._range_expr))),
    _bin_expr_10: $ => prec.left(10, seq(field('left', $._range_expr), field('operator', '..'), field('right', $._bitwise_sh))),
    _bin_expr_11: $ => prec.left(11, seq(field('left', $._bitwise_sh), field('operator', choice('<<', '>>')), field('right', $._term))),
    _bin_expr_12: $ => prec.left(12, seq(field('left', $._term), field('operator', choice('-', '+')), field('right', $._factor))),
    _bin_expr_14: $ => prec.left(14, seq(field('left', $._factor), field('operator', choice('*', '/', '%')), field('right', $._unary))),
    _bin_expr_16_r: $ => prec.right(16, seq(field('left', $._postfix), field('operator', '**'), field('right', $._unary)))
  }
});

function commaSep1(rule) {
  return seq(rule, repeat(seq(',', rule)));
}
