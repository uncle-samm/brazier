/// A small structured builder for the Gleam source that `brazier/build`
/// generates.
///
/// Generated code is described as data (`Module`, `Definition`, `Expr`, ...)
/// and rendered by one function, instead of being assembled by string
/// concatenation at every call site. That gives three guarantees:
///
/// - every string literal is escaped by `Str`, so user values (field names,
///   variant names, error text) can never break out of a literal;
/// - every identifier, constructor and module path is validated before
///   anything is rendered, so a bad name is a build error naming the name;
/// - imports are derived from what the code references: unused imports are
///   dropped and a reference to a module that is not imported is an error.
///
/// Layout is not this module's job. The rendered text is valid Gleam with
/// simple line breaks; `gleam format` produces the final layout.
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// A generated source file.
pub type Module {
  Module(
    /// Header comment lines, given without the leading slashes and rendered
    /// as `///` lines at the top of the file.
    docs: List(String),
    imports: List(Import),
    definitions: List(Definition),
  )
}

/// `import path` or `import path as alias`. Generated code always refers to
/// imported names qualified, so there are no unqualified imports.
pub type Import {
  Import(path: String, alias: Option(String))
}

pub type Definition {
  Function(
    name: String,
    public: Bool,
    docs: List(String),
    params: List(Param),
    return: TypeExpr,
    body: List(Stmt),
  )
}

pub type Param {
  Param(name: String, type_: TypeExpr)
}

pub type TypeExpr {
  /// `module.Name(params)`; `module: None` is a prelude or local type.
  TNamed(module: Option(String), name: String, params: List(TypeExpr))
  TTuple(elements: List(TypeExpr))
  TFn(params: List(TypeExpr), return: TypeExpr)
  /// `_`: a type the compiler infers. Used where the generated code wraps a
  /// user function whose parameter types it does not need to name.
  THole
}

pub type Expr {
  /// A local variable.
  Var(name: String)
  /// A function or constant: `module.name`, or `name` in this module.
  Ref(module: Option(String), name: String)
  /// A constructor: `module.Name`, or `Name` from the prelude.
  Ctor(module: Option(String), name: String)
  /// A string literal. The value is escaped when rendered.
  Str(value: String)
  IntLit(value: Int)
  Call(function: Expr, args: List(Arg))
  ListExpr(elements: List(Expr))
  TupleExpr(elements: List(Expr))
  /// An anonymous function with untyped parameters.
  FnExpr(params: List(String), body: List(Stmt))
  Case(subjects: List(Expr), clauses: List(Clause))
  Block(body: List(Stmt))
  /// `left |> right`
  Pipe(left: Expr, right: Expr)
  BinOp(operator: Operator, left: Expr, right: Expr)
  FieldAccess(container: Expr, label: String)
  TupleIndex(tuple: Expr, index: Int)
}

pub type Operator {
  Concat
  Equal
  NotEqual
}

pub type Arg {
  Arg(value: Expr)
  Labelled(label: String, value: Expr)
}

pub type Clause {
  Clause(patterns: List(Pattern), body: Expr)
}

pub type Pattern {
  PVar(name: String)
  /// `_` or `_name`. The name, when not empty, must be a valid identifier.
  PDiscard(name: String)
  PString(value: String)
  PInt(value: Int)
  /// `module.Name(args)`, `module.Name(..)` when `spread` is true and args
  /// is empty, or `module.Name(a, ..)`.
  PCtor(module: Option(String), name: String, args: List(Pattern), spread: Bool)
  PTuple(elements: List(Pattern))
}

pub type Stmt {
  Let(pattern: Pattern, value: Expr)
  /// `use a, b <- function`
  Use(names: List(String), function: Expr)
  ExprStmt(value: Expr)
}

const keywords = [
  "as", "assert", "auto", "case", "const", "delegate", "derive", "echo", "else",
  "fn", "if", "implement", "import", "let", "macro", "opaque", "panic", "pub",
  "test", "todo", "type", "use",
]

/// Validate a module and render it to Gleam source.
pub fn render(module: Module) -> Result(String, String) {
  use imports <- result.try(resolve_imports(module))
  use Nil <- result.try(validate_definitions(module.definitions))
  let docs = list.map(module.docs, fn(line) { "/// " <> line })
  let import_lines = list.map(imports, render_import)
  let defs = list.map(module.definitions, render_definition)
  let header = case docs {
    [] -> []
    _ -> [string.join(docs, "\n")]
  }
  let imports_block = case import_lines {
    [] -> []
    _ -> [string.join(import_lines, "\n")]
  }
  Ok(string.join(list.flatten([header, imports_block, defs]), "\n\n") <> "\n")
}

// ===== Validation =====

/// True for a valid lowercase Gleam name (`[a-z][a-z0-9_]*`) that is not a
/// keyword.
pub fn is_identifier(name: String) -> Bool {
  case string.to_graphemes(name) {
    [first, ..rest] ->
      is_lower(first)
      && list.all(rest, fn(c) { is_lower(c) || is_digit(c) || c == "_" })
      && !list.contains(keywords, name)
    [] -> False
  }
}

/// True for a valid constructor or type name (`[A-Z][A-Za-z0-9]*`).
pub fn is_upper_name(name: String) -> Bool {
  case string.to_graphemes(name) {
    [first, ..rest] ->
      is_upper(first)
      && list.all(rest, fn(c) { is_upper(c) || is_lower(c) || is_digit(c) })
    [] -> False
  }
}

/// True for a valid module path such as `app/domain/item`.
pub fn is_module_path(path: String) -> Bool {
  path != "" && list.all(string.split(path, "/"), is_identifier)
}

fn is_lower(c: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyz", c) && string.length(c) == 1
}

fn is_upper(c: String) -> Bool {
  string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c) && string.length(c) == 1
}

fn is_digit(c: String) -> Bool {
  string.contains("0123456789", c) && string.length(c) == 1
}

fn check(ok: Bool, message: String) -> Result(Nil, String) {
  case ok {
    True -> Ok(Nil)
    False -> Error("Generated code is invalid: " <> message)
  }
}

fn check_identifier(name: String, what: String) -> Result(Nil, String) {
  check(is_identifier(name), what <> " `" <> name <> "` is not a valid name")
}

fn check_upper(name: String, what: String) -> Result(Nil, String) {
  check(
    is_upper_name(name),
    what <> " `" <> name <> "` is not a valid constructor or type name",
  )
}

fn check_discard(name: String) -> Result(Nil, String) {
  case name {
    "" -> Ok(Nil)
    _ -> check_identifier(name, "discarded name")
  }
}

fn import_name(import_: Import) -> Result(String, String) {
  case import_.alias {
    Some(alias) -> Ok(alias)
    None ->
      case string.split(import_.path, "/") |> list.last {
        Ok(name) -> Ok(name)
        Error(Nil) -> Error("Generated code is invalid: empty import path")
      }
  }
}

/// Keep only the imports the code references, in the order given, and fail
/// when a referenced module is not imported or two imports share a name.
fn resolve_imports(module: Module) -> Result(List(Import), String) {
  use named <- result.try(
    list.try_map(module.imports, fn(import_) {
      use Nil <- result.try(check(
        is_module_path(import_.path),
        "import path `" <> import_.path <> "` is not a valid module path",
      ))
      use name <- result.try(import_name(import_))
      use Nil <- result.map(check_identifier(name, "import alias"))
      #(name, import_)
    }),
  )
  use Nil <- result.try(
    list.try_fold(named, set.new(), fn(seen, entry) {
      let #(name, import_) = entry
      case set.contains(seen, name) {
        True ->
          Error(
            "Generated code is invalid: two imports are both named `"
            <> name
            <> "` (second is `"
            <> import_.path
            <> "`)",
          )
        False -> Ok(set.insert(seen, name))
      }
    })
    |> result.replace(Nil),
  )
  let used = list.fold(module.definitions, set.new(), definition_modules)
  let names = set.from_list(list.map(named, fn(entry) { entry.0 }))
  case set.to_list(set.difference(used, names)) |> list.sort(string.compare) {
    [] ->
      Ok(
        list.filter_map(named, fn(entry) {
          case set.contains(used, entry.0) {
            True -> Ok(entry.1)
            False -> Error(Nil)
          }
        }),
      )
    missing ->
      Error(
        "Generated code is invalid: it references modules that are not imported: "
        <> string.join(missing, ", "),
      )
  }
}

fn validate_definitions(definitions: List(Definition)) -> Result(Nil, String) {
  use _ <- result.try(
    list.try_fold(definitions, set.new(), fn(seen, def) {
      case set.contains(seen, def.name) {
        True ->
          Error(
            "Generated code is invalid: function `"
            <> def.name
            <> "` is defined twice",
          )
        False -> Ok(set.insert(seen, def.name))
      }
    }),
  )
  list.try_each(definitions, validate_definition)
}

fn validate_definition(def: Definition) -> Result(Nil, String) {
  let Function(name:, params:, return:, body:, ..) = def
  use Nil <- result.try(check_identifier(name, "function"))
  use Nil <- result.try(
    list.try_each(params, fn(param) {
      use Nil <- result.try(case param.name {
        "_" <> rest -> check_discard(rest)
        _ -> check_identifier(param.name, "parameter")
      })
      validate_type(param.type_)
    }),
  )
  use Nil <- result.try(validate_type(return))
  list.try_each(body, validate_stmt)
}

fn validate_type(type_: TypeExpr) -> Result(Nil, String) {
  case type_ {
    TNamed(name:, params:, ..) -> {
      use Nil <- result.try(check_upper(name, "type"))
      list.try_each(params, validate_type)
    }
    TTuple(elements) -> list.try_each(elements, validate_type)
    TFn(params, return) -> {
      use Nil <- result.try(list.try_each(params, validate_type))
      validate_type(return)
    }
    THole -> Ok(Nil)
  }
}

fn validate_stmt(stmt: Stmt) -> Result(Nil, String) {
  case stmt {
    Let(pattern, value) -> {
      use Nil <- result.try(validate_pattern(pattern))
      validate_expr(value)
    }
    Use(names, function) -> {
      use Nil <- result.try(
        list.try_each(names, fn(name) {
          case name {
            "_" <> rest -> check_discard(rest)
            _ -> check_identifier(name, "use binding")
          }
        }),
      )
      validate_expr(function)
    }
    ExprStmt(value) -> validate_expr(value)
  }
}

fn validate_pattern(pattern: Pattern) -> Result(Nil, String) {
  case pattern {
    PVar(name) -> check_identifier(name, "variable")
    PDiscard(name) -> check_discard(name)
    PString(_) | PInt(_) -> Ok(Nil)
    PCtor(name:, args:, ..) -> {
      use Nil <- result.try(check_upper(name, "constructor"))
      list.try_each(args, validate_pattern)
    }
    PTuple(elements) -> list.try_each(elements, validate_pattern)
  }
}

fn validate_expr(expr: Expr) -> Result(Nil, String) {
  case expr {
    Var(name) ->
      case name {
        "_" <> _ ->
          Error(
            "Generated code is invalid: discarded name `"
            <> name
            <> "` is used as a value",
          )
        _ -> check_identifier(name, "variable")
      }
    Ref(name:, ..) -> check_identifier(name, "function")
    Ctor(name:, ..) -> check_upper(name, "constructor")
    Str(_) | IntLit(_) -> Ok(Nil)
    Call(function, args) -> {
      use Nil <- result.try(validate_expr(function))
      list.try_each(args, fn(arg) {
        case arg {
          Arg(value) -> validate_expr(value)
          Labelled(label, value) -> {
            use Nil <- result.try(check_identifier(label, "label"))
            validate_expr(value)
          }
        }
      })
    }
    ListExpr(elements) | TupleExpr(elements) ->
      list.try_each(elements, validate_expr)
    FnExpr(params, body) -> {
      use Nil <- result.try(
        list.try_each(params, fn(name) {
          case name {
            "_" <> rest -> check_discard(rest)
            _ -> check_identifier(name, "parameter")
          }
        }),
      )
      list.try_each(body, validate_stmt)
    }
    Case(subjects, clauses) -> {
      use Nil <- result.try(check(subjects != [], "case without subjects"))
      use Nil <- result.try(check(clauses != [], "case without clauses"))
      use Nil <- result.try(list.try_each(subjects, validate_expr))
      list.try_each(clauses, fn(clause) {
        use Nil <- result.try(check(
          list.length(clause.patterns) == list.length(subjects),
          "case clause has a different number of patterns than subjects",
        ))
        use Nil <- result.try(list.try_each(clause.patterns, validate_pattern))
        validate_expr(clause.body)
      })
    }
    Block(body) -> {
      use Nil <- result.try(check(body != [], "empty block"))
      list.try_each(body, validate_stmt)
    }
    Pipe(left, right) | BinOp(left:, right:, ..) -> {
      use Nil <- result.try(validate_expr(left))
      validate_expr(right)
    }
    FieldAccess(container, label) -> {
      use Nil <- result.try(check_identifier(label, "field"))
      validate_expr(container)
    }
    TupleIndex(tuple, index) -> {
      use Nil <- result.try(check(index >= 0, "negative tuple index"))
      validate_expr(tuple)
    }
  }
}

// ===== Referenced modules =====

fn add_module(acc: Set(String), module: Option(String)) -> Set(String) {
  case module {
    Some(name) -> set.insert(acc, name)
    None -> acc
  }
}

fn definition_modules(acc: Set(String), def: Definition) -> Set(String) {
  let acc =
    list.fold(def.params, acc, fn(acc, param) { type_modules(acc, param.type_) })
  let acc = type_modules(acc, def.return)
  list.fold(def.body, acc, stmt_modules)
}

fn type_modules(acc: Set(String), type_: TypeExpr) -> Set(String) {
  case type_ {
    TNamed(module:, params:, ..) ->
      list.fold(params, add_module(acc, module), type_modules)
    TTuple(elements) -> list.fold(elements, acc, type_modules)
    TFn(params, return) ->
      type_modules(list.fold(params, acc, type_modules), return)
    THole -> acc
  }
}

fn stmt_modules(acc: Set(String), stmt: Stmt) -> Set(String) {
  case stmt {
    Let(pattern, value) -> expr_modules(pattern_modules(acc, pattern), value)
    Use(_, function) -> expr_modules(acc, function)
    ExprStmt(value) -> expr_modules(acc, value)
  }
}

fn pattern_modules(acc: Set(String), pattern: Pattern) -> Set(String) {
  case pattern {
    PCtor(module:, args:, ..) ->
      list.fold(args, add_module(acc, module), pattern_modules)
    PTuple(elements) -> list.fold(elements, acc, pattern_modules)
    PVar(_) | PDiscard(_) | PString(_) | PInt(_) -> acc
  }
}

fn expr_modules(acc: Set(String), expr: Expr) -> Set(String) {
  case expr {
    Ref(module:, ..) | Ctor(module:, ..) -> add_module(acc, module)
    Var(_) | Str(_) | IntLit(_) -> acc
    Call(function, args) ->
      list.fold(args, expr_modules(acc, function), fn(acc, arg) {
        case arg {
          Arg(value) | Labelled(value:, ..) -> expr_modules(acc, value)
        }
      })
    ListExpr(elements) | TupleExpr(elements) ->
      list.fold(elements, acc, expr_modules)
    FnExpr(_, body) | Block(body) -> list.fold(body, acc, stmt_modules)
    Case(subjects, clauses) ->
      list.fold(clauses, list.fold(subjects, acc, expr_modules), fn(acc, c) {
        expr_modules(list.fold(c.patterns, acc, pattern_modules), c.body)
      })
    Pipe(left, right) | BinOp(left:, right:, ..) ->
      expr_modules(expr_modules(acc, left), right)
    FieldAccess(container, _) -> expr_modules(acc, container)
    TupleIndex(tuple, _) -> expr_modules(acc, tuple)
  }
}

// ===== Rendering =====

fn render_import(import_: Import) -> String {
  case import_.alias {
    Some(alias) -> "import " <> import_.path <> " as " <> alias
    None -> "import " <> import_.path
  }
}

fn render_definition(def: Definition) -> String {
  let Function(name:, public:, docs:, params:, return:, body:) = def
  let doc_lines = list.map(docs, fn(line) { "/// " <> line <> "\n" })
  let visibility = case public {
    True -> "pub "
    False -> ""
  }
  let rendered_params =
    list.map(params, fn(param) {
      param.name <> ": " <> render_type(param.type_)
    })
  string.concat(doc_lines)
  <> visibility
  <> "fn "
  <> name
  <> "("
  <> string.join(rendered_params, ", ")
  <> ") -> "
  <> render_type(return)
  <> " {\n"
  <> render_body(body)
  <> "\n}"
}

fn qualified(module: Option(String), name: String) -> String {
  case module {
    Some(module) -> module <> "." <> name
    None -> name
  }
}

/// Render a type annotation.
pub fn render_type(type_: TypeExpr) -> String {
  case type_ {
    TNamed(module:, name:, params: []) -> qualified(module, name)
    TNamed(module:, name:, params:) ->
      qualified(module, name)
      <> "("
      <> string.join(list.map(params, render_type), ", ")
      <> ")"
    TTuple(elements) ->
      "#(" <> string.join(list.map(elements, render_type), ", ") <> ")"
    TFn(params, return) ->
      "fn("
      <> string.join(list.map(params, render_type), ", ")
      <> ") -> "
      <> render_type(return)
    THole -> "_"
  }
}

fn render_body(body: List(Stmt)) -> String {
  body |> list.map(render_stmt) |> string.join("\n")
}

fn render_stmt(stmt: Stmt) -> String {
  case stmt {
    Let(pattern, value) ->
      "let " <> render_pattern(pattern) <> " = " <> render_expr(value)
    Use(names, function) ->
      "use " <> string.join(names, ", ") <> " <- " <> render_expr(function)
    ExprStmt(value) -> render_expr(value)
  }
}

fn render_pattern(pattern: Pattern) -> String {
  case pattern {
    PVar(name) -> name
    PDiscard(name) -> "_" <> name
    PString(value) -> string_literal(value)
    PInt(value) -> int.to_string(value)
    PCtor(module:, name:, args: [], spread: False) -> qualified(module, name)
    PCtor(module:, name:, args: [], spread: True) ->
      qualified(module, name) <> "(..)"
    PCtor(module:, name:, args:, spread:) -> {
      let rendered = list.map(args, render_pattern)
      let rendered = case spread {
        True -> list.append(rendered, [".."])
        False -> rendered
      }
      qualified(module, name) <> "(" <> string.join(rendered, ", ") <> ")"
    }
    PTuple(elements) ->
      "#(" <> string.join(list.map(elements, render_pattern), ", ") <> ")"
  }
}

fn render_expr(expr: Expr) -> String {
  case expr {
    Var(name) -> name
    Ref(module:, name:) | Ctor(module:, name:) -> qualified(module, name)
    Str(value) -> string_literal(value)
    IntLit(value) -> int.to_string(value)
    Call(function, args) ->
      render_callee(function)
      <> "("
      <> string.join(list.map(args, render_arg), ", ")
      <> ")"
    ListExpr(elements) ->
      "[" <> string.join(list.map(elements, render_expr), ", ") <> "]"
    TupleExpr(elements) ->
      "#(" <> string.join(list.map(elements, render_expr), ", ") <> ")"
    FnExpr(params, body) ->
      "fn("
      <> string.join(params, ", ")
      <> ") {\n"
      <> render_body(body)
      <> "\n}"
    Case(subjects, clauses) ->
      "case "
      <> string.join(list.map(subjects, render_operand), ", ")
      <> " {\n"
      <> string.join(list.map(clauses, render_clause), "\n")
      <> "\n}"
    Block(body) -> "{\n" <> render_body(body) <> "\n}"
    Pipe(left, right) ->
      render_operand(left) <> "\n|> " <> render_operand(right)
    BinOp(operator, left, right) ->
      render_operand(left)
      <> " "
      <> render_operator(operator)
      <> " "
      <> render_operand(right)
    FieldAccess(container, label) -> render_callee(container) <> "." <> label
    TupleIndex(tuple, index) ->
      render_callee(tuple) <> "." <> int.to_string(index)
  }
}

fn render_operator(operator: Operator) -> String {
  case operator {
    Concat -> "<>"
    Equal -> "=="
    NotEqual -> "!="
  }
}

/// Operands of operators, case subjects and callees that are themselves
/// compound expressions are wrapped in `{ }`, so precedence never depends on
/// the reader knowing Gleam's operator table.
fn render_operand(expr: Expr) -> String {
  case expr {
    Pipe(..) | BinOp(..) | Case(..) | FnExpr(..) ->
      "{\n" <> render_expr(expr) <> "\n}"
    _ -> render_expr(expr)
  }
}

fn render_callee(expr: Expr) -> String {
  case expr {
    Var(_) | Ref(..) | Ctor(..) | FieldAccess(..) | Call(..) | TupleIndex(..) ->
      render_expr(expr)
    _ -> "{\n" <> render_expr(expr) <> "\n}"
  }
}

fn render_arg(arg: Arg) -> String {
  case arg {
    Arg(value) -> render_expr(value)
    Labelled(label, value) -> label <> ": " <> render_expr(value)
  }
}

fn render_clause(clause: Clause) -> String {
  string.join(list.map(clause.patterns, render_pattern), ", ")
  <> " -> "
  <> render_expr(clause.body)
}

/// Render a value as an escaped Gleam string literal.
pub fn string_literal(value: String) -> String {
  "\"" <> escape(value) <> "\""
}

fn escape(value: String) -> String {
  value
  |> string.to_utf_codepoints
  |> list.map(fn(codepoint) {
    case string.utf_codepoint_to_int(codepoint) {
      0x5C -> "\\\\"
      0x22 -> "\\\""
      0x0A -> "\\n"
      0x0D -> "\\r"
      0x09 -> "\\t"
      0x0C -> "\\f"
      code if code < 0x20 || code == 0x7F -> "\\u{" <> int.to_base16(code) <> "}"
      _ -> string.from_utf_codepoints([codepoint])
    }
  })
  |> string.concat
}
