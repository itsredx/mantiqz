[
  "if" "else" "elif"
  "for" "while" "in" "break" "continue"
  "match" "case"
  "try" "except" "finally" "with"
  "let" "mut" "ref" "as"
  "return" "spawn"
  "fn" "class" "interface" "struct" "enum" "union" "type" "macro"
  "import" "from"
] @keyword

(identifier) @variable
(string) @string
(interpolated_str) @string
(number) @number
(boolean_literal) @boolean
(null_literal) @constant.builtin
(color_literal) @constant
(quantum_literal) @constant

(comment) @comment

(kw_to) @keyword
