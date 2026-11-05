/// Brazier's custom linting tool — enforces engineering principles via AST analysis.
/// Uses Glance to parse source files and check for violations.
///
/// Rules, over `src/` and `examples/` unless a rule says otherwise:
/// 1. No `todo` or `panic` (`no-todo`, `no-panic`)
/// 2. Public functions in `brazier/transport*` and `brazier/runtime*`
///    modules contain a `log.*` call, unless their name marks them as pure
///    (`public-fn-must-log`)
/// 3. No degraded-path phrases (`no-degraded-path-phrases`)
/// 4. No `let _ =` discards in `src/` (`no-discarded-result`, see
///    `check_no_discarded_results`)
/// 5. Examples do not use the removed route API (`deprecated-route-api`)
/// 6. `docs/` does not describe the removed routing model
///    (`stale-docs-model`)
/// 7. No pre-rename project name in `src/`, `test/` and `examples/`
///    (`stale-name`, see `lint_stale_names`)
/// 8. Every `let assert` in `src/` has a non-empty `as "..."` message
///    (`let-assert-message`, see `check_let_assert_messages`)
/// 9. Every file must be readable and parse; failures are violations
/// 10. No Unicode case folding (`string.lowercase`, `string.uppercase`,
///     `string.capitalise`) in `src/` outside `case_folding_allowed`
///     (`unicode-case-folding`, see `check_case_folding`)
///
/// The AST rules (1, 2, 4, 8 and 10) visit every statement and expression of a
/// function body at any depth (see `body_nodes`): code inside `use`
/// callbacks, `assert`s, case guards, record updates, captures, bit arrays
/// and `as` messages is checked like any other.
///
/// Reference: CLAUDE.md engineering principles, TigerBeetle approach.
import brazier/build/files
import brazier/build/source_location
import brazier/internal/ascii
import brazier/log
import glance
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import simplifile

/// A lint violation found in a source file.
pub type Violation {
  Violation(
    /// The file path where the violation was found.
    file: String,
    /// The line/byte offset of the violation.
    location: String,
    /// The rule that was violated.
    rule: String,
    /// Human-readable description.
    message: String,
  )
}

/// Lint a directory of Gleam source files.
/// Returns a list of violations found.
pub fn lint_directory(dir: String) -> List(Violation) {
  log.info("brazier.lint", "Linting directory: " <> dir)
  case files.list_directory(dir) {
    Ok(entries) -> {
      let violations =
        list.flat_map(entries, fn(entry) {
          let path = dir <> "/" <> entry
          case should_skip_entry(dir, entry), simplifile.is_directory(path) {
            True, _ -> []
            False, Ok(True) -> lint_directory(path)
            False, Ok(False) -> {
              case string.ends_with(entry, ".gleam") {
                True -> lint_file(path)
                False -> []
              }
            }
            False, Error(err) -> [
              io_violation(path, "Cannot stat " <> path, err),
            ]
          }
        })
      violations
    }
    Error(reason) -> [listing_violation(dir, reason)]
  }
}

fn io_violation(
  path: String,
  context: String,
  err: simplifile.FileError,
) -> Violation {
  let message = context <> ": " <> simplifile.describe_error(err)
  log.error("brazier.lint", message)
  Violation(file: path, location: "file", rule: "unreadable-path", message:)
}

/// A directory `files.list_directory` could not list. Its error already
/// names the directory and the reason.
fn listing_violation(dir: String, reason: String) -> Violation {
  log.error("brazier.lint", reason)
  Violation(
    file: dir,
    location: "file",
    rule: "unreadable-path",
    message: reason,
  )
}

/// Lint Markdown documentation for stale public model language.
/// Every file named `PROGRESS.md`, at any depth, is excluded: these are
/// progress logs that record old names on purpose. The exclusion is by file
/// name, not by directory: `docs/archive/PROGRESS.md` is skipped because it
/// is named `PROGRESS.md`, and any other file under `docs/archive/` is
/// linted like the rest of `docs/`.
pub fn lint_docs_directory(dir: String) -> List(Violation) {
  log.info("brazier.lint", "Linting docs directory: " <> dir)
  case files.list_directory(dir) {
    Ok(entries) ->
      list.flat_map(entries, fn(entry) {
        let path = dir <> "/" <> entry
        case should_skip_entry(dir, entry), simplifile.is_directory(path) {
          True, _ -> []
          False, Ok(True) -> lint_docs_directory(path)
          False, Ok(False) -> {
            case string.ends_with(entry, ".md") && entry != "PROGRESS.md" {
              True -> lint_doc_file(path)
              False -> []
            }
          }
          False, Error(err) -> [
            io_violation(path, "Cannot stat docs path " <> path, err),
          ]
        }
      })
    Error(reason) -> [listing_violation(dir, reason)]
  }
}

fn lint_doc_file(path: String) -> List(Violation) {
  case simplifile.read(path) {
    Ok(source) -> lint_doc_source(path, source)
    Error(err) -> [io_violation(path, "Cannot read docs file " <> path, err)]
  }
}

pub fn lint_doc_source(file_path: String, source: String) -> List(Violation) {
  let forbidden = [
    "FILE_BASED_ROUTING",
    "file-" <> "based routing",
    "file based routing",
    "route files",
    "RouterBuilder",
    "start_" <> "router",
    "brazier." <> "router",
    "runtime" <> "-only",
    "HTML morph",
  ]
  list.filter_map(forbidden, fn(phrase) {
    case string.contains(source, phrase) {
      True ->
        Ok(Violation(
          file: file_path,
          location: "text",
          rule: "stale-docs-model",
          message: "Found stale Brazier routing/rendering phrase `"
            <> phrase
            <> "`. Docs must describe generated contracts and explicit route_pages.",
        ))
      False -> Error(Nil)
    }
  })
}

/// The project's name before the rename to Brazier, built from parts so
/// that this file does not contain it.
const old_name = "bea" <> "con"

/// The old name as it starts an environment variable (`<OLD>_ENV`).
const old_env_prefix = "BEA" <> "CON_"

/// The dev secret the old name published, which `brazier/config` refuses.
const old_dev_secret = old_name <> "-dev-secret-change-in-production"

/// The file that refuses the old names at start.
const config_module_path = "src/brazier/config.gleam"

/// Files whose old name is checked: source, FFI, scripts and package files.
const text_source_extensions = [
  ".gleam", ".erl", ".hrl", ".mjs", ".js", ".toml", ".md", ".sh", ".py", ".html",
  ".css", ".json",
]

/// Lint every text file under `dir`, at any depth, for the project's
/// pre-rename name (see `lint_stale_names`). `main` runs it over `src`,
/// `test` and `examples`.
pub fn lint_names_directory(dir: String) -> List(Violation) {
  log.info("brazier.lint", "Linting names in directory: " <> dir)
  case files.list_directory(dir) {
    Ok(entries) ->
      list.flat_map(entries, fn(entry) {
        let path = dir <> "/" <> entry
        case should_skip_entry(dir, entry), simplifile.is_directory(path) {
          True, _ -> []
          False, Ok(True) -> lint_names_directory(path)
          False, Ok(False) ->
            case list.any(text_source_extensions, string.ends_with(entry, _)) {
              True -> lint_names_file(path)
              False -> []
            }
          False, Error(err) -> [
            io_violation(path, "Cannot stat " <> path, err),
          ]
        }
      })
    Error(reason) -> [listing_violation(dir, reason)]
  }
}

fn lint_names_file(path: String) -> List(Violation) {
  case simplifile.read(path) {
    Ok(source) -> lint_stale_names(path, source)
    Error(err) -> [io_violation(path, "Cannot read file " <> path, err)]
  }
}

/// Flag every line of `source` that uses the project's pre-rename name, in
/// any case. The uses allowed are the ones that keep the rename safe, each
/// only where it belongs:
/// - `src/brazier/config.gleam` refuses old-named environment variables
///   (`<OLD>_ENV`, ...) by their prefix (the string `"<OLD>_"`) and the old
///   published dev secret, and its comment names the rename
///   (`` `<old>` to `brazier` ``);
/// - tests under `test/` set those variables and that secret to check the
///   refusals.
///
/// Nothing else may keep the old name: not an alias, a comment or a log
/// line. `gleam.toml`'s repository is outside the linted directories.
pub fn lint_stale_names(file_path: String, source: String) -> List(Violation) {
  let allowed = allowed_old_name_uses(file_path)
  source
  |> string.split("\n")
  |> list.index_map(fn(line, index) { #(index + 1, line) })
  |> list.filter_map(fn(numbered) {
    let #(number, line) = numbered
    // The old name is ASCII, so ASCII lowercasing finds it in any case.
    let uses = occurrences(ascii.lowercase(line), old_name)
    let allowed_uses =
      list.fold(allowed, 0, fn(sum, count_uses) { sum + count_uses(line) })
    case uses > allowed_uses {
      True ->
        Ok(Violation(
          file: file_path,
          location: "line " <> int.to_string(number),
          rule: "stale-name",
          message: "Found the pre-rename name `"
            <> old_name
            <> "`. Use `brazier`; only "
            <> config_module_path
            <> " and test/ may name the old environment variables and dev secret it refuses.",
        ))
      False -> Error(Nil)
    }
  })
}

/// How many allowed uses of the old name a line of `file_path` has, as one
/// counter per allowed form. Each form contains the old name exactly once.
fn allowed_old_name_uses(file_path: String) -> List(fn(String) -> Int) {
  let refusals = [old_env_name_uses, occurrences(_, old_dev_secret)]
  case file_path == config_module_path, string.starts_with(file_path, "test/") {
    True, _ -> [
      occurrences(_, "`" <> old_name <> "` to `brazier`"),
      // The prefix itself, as the string the refusal matches on.
      occurrences(_, "\"" <> old_env_prefix <> "\""),
      ..refusals
    ]
    False, True -> refusals
    False, False -> []
  }
}

/// Uses of the old name as an environment variable: the prefix followed by
/// an upper-case letter.
fn old_env_name_uses(line: String) -> Int {
  case string.split(line, old_env_prefix) {
    [] | [_] -> 0
    [_, ..after] ->
      list.count(after, fn(rest) {
        case string.first(rest) {
          Ok(first) -> string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", first)
          Error(Nil) -> False
        }
      })
  }
}

fn occurrences(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

/// Generated or vendored directories the lint does not read. A `build`
/// directory is skipped only when it is Gleam's build output, the one next
/// to a `gleam.toml`: `src/brazier/build` holds Brazier's own build tool
/// and is linted like any other source directory.
fn should_skip_entry(dir: String, entry: String) -> Bool {
  case entry {
    "build" -> is_project_root(dir)
    ".venv" | "node_modules" | "priv" -> True
    _ -> False
  }
}

fn is_project_root(dir: String) -> Bool {
  case simplifile.is_file(dir <> "/gleam.toml") {
    Ok(found) -> found
    Error(err) -> {
      // The directory was just listed, so a stat failure here is an I/O
      // error worth reporting; the walk then descends into `build` and
      // reports what it cannot read there.
      log.error(
        "brazier.lint",
        "Cannot stat "
          <> dir
          <> "/gleam.toml: "
          <> simplifile.describe_error(err),
      )
      False
    }
  }
}

/// Lint a single Gleam source file.
pub fn lint_file(path: String) -> List(Violation) {
  case simplifile.read(path) {
    Ok(source) -> lint_source(path, source)
    Error(err) -> [io_violation(path, "Cannot read file " <> path, err)]
  }
}

/// Lint source code from a string.
/// A file that does not parse is itself a violation: the linter cannot vouch
/// for code it cannot read.
pub fn lint_source(file_path: String, source: String) -> List(Violation) {
  case glance.module(source) {
    Ok(module) -> {
      let todo_violations = check_no_todo_panic(file_path, source, module)
      let logging_violations =
        check_public_functions_log(file_path, source, module)
      let discard_violations =
        check_no_discarded_results(file_path, source, module)
      let degraded_path_violations =
        check_no_degraded_path_phrases(file_path, source)
      let deprecated_route_violations =
        check_deprecated_route_api(file_path, source)
      let assert_message_violations =
        check_let_assert_messages(file_path, source, module)
      let case_folding_violations =
        check_case_folding(file_path, source, module, case_folding_allowed)
      list.flatten([
        todo_violations,
        logging_violations,
        degraded_path_violations,
        deprecated_route_violations,
        discard_violations,
        assert_message_violations,
        case_folding_violations,
      ])
    }
    Error(err) -> [parse_error_violation(file_path, source, err)]
  }
}

/// Run only the `unicode-case-folding` rule over `source`, with `allowed`
/// in place of `case_folding_allowed`. `lint_source` runs it with
/// `case_folding_allowed`; this entry point lets a test exercise an
/// allow-list the source tree does not need.
pub fn lint_case_folding(
  file_path: String,
  source: String,
  allowed: List(CaseFoldingAllowance),
) -> List(Violation) {
  case glance.module(source) {
    Ok(module) -> check_case_folding(file_path, source, module, allowed)
    Error(err) -> [parse_error_violation(file_path, source, err)]
  }
}

fn parse_error_violation(
  file_path: String,
  source: String,
  err: glance.Error,
) -> Violation {
  let message = source_location.describe_parse_error(file_path, source, err)
  log.error("brazier.lint", "Cannot parse " <> message)
  Violation(
    file: file_path,
    location: "file",
    rule: "parse-error",
    message: "Cannot parse: " <> message,
  )
}

/// A `src/` module allowed to fold text in Unicode, and the reason its text
/// is Unicode by design rather than ASCII by grammar.
pub type CaseFoldingAllowance {
  CaseFoldingAllowance(path: String, reason: String)
}

/// The modules in `src/` allowed `string.lowercase`, `string.uppercase` and
/// `string.capitalise`, each with its reason.
///
/// Those functions fold in Unicode: the Kelvin sign U+212A lowercases to
/// `k`, U+0130 to `i` plus a combining dot, `ß` uppercases to `SS`. Almost
/// all text the framework folds is ASCII by grammar: HTTP field names and
/// tokens (RFC 9110 §5.1, §5.6.2), URL schemes (WHATWG URL), HTML and SVG
/// attribute names, media types, file extensions and Gleam names (glexer's
/// `[A-Z][A-Za-z0-9]*`). Unicode folding of such text lets a non-ASCII
/// lookalike pass a check that compares against an ASCII name, so it is
/// folded with `brazier/internal/ascii` instead.
///
/// The list is empty: no module in `src/` folds text that is Unicode by
/// design. A module that does (say, a search that matches user text
/// without case) is added here with the reason, which the rule requires to
/// be non-empty.
pub const case_folding_allowed: List(CaseFoldingAllowance) = []

/// The `gleam/string` functions that fold case in Unicode.
const unicode_case_functions = ["lowercase", "uppercase", "capitalise"]

/// Flag every use of a Unicode case function from `gleam/string` in a `src/`
/// module not in `allowed`: a qualified reference (`string.lowercase`,
/// called, piped or passed as a value, in a function body or a constant)
/// and an unqualified import (`import gleam/string.{lowercase}`). `examples/`
/// is application code, where Unicode folding of user text is the app's
/// choice, so the rule covers `src/` only.
///
/// The linter works on the untyped AST: a local variable named like the
/// `gleam/string` import with a field named like a case function would be
/// flagged too. No such code exists; renaming it would be the fix.
fn check_case_folding(
  file_path: String,
  source: String,
  module: glance.Module,
  allowed: List(CaseFoldingAllowance),
) -> List(Violation) {
  case
    string.starts_with(file_path, "src/"),
    list.find(allowed, fn(allowance) { allowance.path == file_path })
  {
    False, _ -> []
    True, Ok(allowance) ->
      case string.trim(allowance.reason) {
        "" -> [
          Violation(
            file: file_path,
            location: "file",
            rule: "unicode-case-folding",
            message: "The case-folding allowance for "
              <> file_path
              <> " gives no reason. State why its text is Unicode by design.",
          ),
        ]
        _ -> []
      }
    True, Error(Nil) -> {
      let string_imports =
        list.filter(module.imports, fn(def) {
          def.definition.module == "gleam/string"
        })
      let import_violations =
        list.flat_map(string_imports, fn(def) {
          unqualified_case_imports(file_path, source, def.definition)
        })
      let qualifiers = list.flat_map(string_imports, import_qualifier)
      let function_violations =
        list.flat_map(module.functions, fn(def) {
          let func = def.definition
          body_nodes(func.body)
          |> list.flat_map(fn(node) {
            case_folding_violation(
              file_path,
              source,
              qualifiers,
              "function `" <> func.name <> "`",
              node,
            )
          })
        })
      let constant_violations =
        list.flat_map(module.constants, fn(def) {
          let constant = def.definition
          nodes_under(ExpressionNode(constant.value))
          |> list.flat_map(fn(node) {
            case_folding_violation(
              file_path,
              source,
              qualifiers,
              "constant `" <> constant.name <> "`",
              node,
            )
          })
        })
      list.flatten([import_violations, function_violations, constant_violations])
    }
  }
}

/// The name `import gleam/string` binds for qualified access: `string`, or
/// its `as` alias. `as _` binds none.
fn import_qualifier(def: glance.Definition(glance.Import)) -> List(String) {
  case def.definition.alias {
    option.None -> ["string"]
    option.Some(glance.Named(alias)) -> [alias]
    option.Some(glance.Discarded(_)) -> []
  }
}

fn unqualified_case_imports(
  file_path: String,
  source: String,
  import_: glance.Import,
) -> List(Violation) {
  import_.unqualified_values
  |> list.filter(fn(value) { list.contains(unicode_case_functions, value.name) })
  |> list.map(fn(value) {
    Violation(
      file: file_path,
      location: source_location.format_span(source, import_.location),
      rule: "unicode-case-folding",
      message: case_folding_message("the import of `" <> value.name <> "`"),
    )
  })
}

fn case_folding_violation(
  file_path: String,
  source: String,
  qualifiers: List(String),
  owner: String,
  node: Node,
) -> List(Violation) {
  case node {
    ExpressionNode(glance.FieldAccess(
      container: glance.Variable(name: qualifier, ..),
      label:,
      location:,
    )) ->
      case
        list.contains(qualifiers, qualifier),
        list.contains(unicode_case_functions, label)
      {
        True, True -> [
          Violation(
            file: file_path,
            location: source_location.format_span(source, location),
            rule: "unicode-case-folding",
            message: case_folding_message(
              "`" <> qualifier <> "." <> label <> "` in " <> owner,
            ),
          ),
        ]
        _, _ -> []
      }
    ExpressionNode(..) | StatementNode(..) -> []
  }
}

fn case_folding_message(what: String) -> String {
  what
  <> " folds case in Unicode (the Kelvin sign U+212A lowercases to `k`). "
  <> "Fold text that is ASCII by grammar with `brazier/internal/ascii`, or "
  <> "add the module to `case_folding_allowed` with the reason its text is "
  <> "Unicode."
}

/// The comment that opts a single `let _ =` out of the discard rule.
/// It must sit on the line directly above the assignment and carry a reason:
///
/// ```gleam
/// // lint:allow-discard the decrement returns the new count, which is unused
/// let _ = connection_tracker_decrement()
/// ```
pub const allow_discard_marker = "// lint:allow-discard"

/// Flag every `let _ =` (or `let _name =`) in `src/`.
///
/// The linter works on the untyped AST, so it cannot tell whether the
/// discarded value is a `Result`. It therefore flags every discard and asks
/// the author to either handle the value or state, with
/// `allow_discard_marker`, why dropping it is safe.
fn check_no_discarded_results(
  file_path: String,
  source: String,
  module: glance.Module,
) -> List(Violation) {
  case string.starts_with(file_path, "src/") {
    False -> []
    True ->
      list.flat_map(module.functions, fn(def) {
        let func = def.definition
        body_nodes(func.body)
        |> list.flat_map(discard_location)
        |> list.filter_map(fn(span) {
          discard_violation(file_path, source, func.name, span)
        })
      })
  }
}

/// The span of a `let _ =` (or `let _name =`), if the node is one. A
/// `let assert _ =` is an assertion, not a discard, and is not flagged.
fn discard_location(node: Node) -> List(glance.Span) {
  case node {
    StatementNode(glance.Assignment(
      kind: glance.Let,
      pattern: glance.PatternDiscard(..),
      location:,
      ..,
    )) -> [location]
    StatementNode(glance.Assignment(..))
    | StatementNode(glance.Use(..))
    | StatementNode(glance.Assert(..))
    | StatementNode(glance.Expression(..))
    | ExpressionNode(..) -> []
  }
}

fn discard_violation(
  file_path: String,
  source: String,
  func_name: String,
  span: glance.Span,
) -> Result(Violation, Nil) {
  let location = source_location.format_span(source, span)
  let opt_out = case source_location.previous_line(source, span.start) {
    Ok(line) -> parse_allow_discard(string.trim(line))
    Error(Nil) -> NoOptOut
  }
  case opt_out {
    OptOutWithReason -> Error(Nil)
    OptOutWithoutReason ->
      Ok(Violation(
        file: file_path,
        location:,
        rule: "no-discarded-result",
        message: "`"
          <> allow_discard_marker
          <> "` in `"
          <> func_name
          <> "` must give a reason after the marker.",
      ))
    NoOptOut ->
      Ok(Violation(
        file: file_path,
        location:,
        rule: "no-discarded-result",
        message: "`let _ =` in `"
          <> func_name
          <> "` discards a value that may be a Result. Handle it, or add `"
          <> allow_discard_marker
          <> " <reason>` on the line above.",
      ))
  }
}

type DiscardOptOut {
  NoOptOut
  OptOutWithoutReason
  OptOutWithReason
}

fn parse_allow_discard(line: String) -> DiscardOptOut {
  case string.starts_with(line, allow_discard_marker) {
    False -> NoOptOut
    True -> {
      let reason =
        line
        |> string.drop_start(string.length(allow_discard_marker))
        |> string.trim
      case reason {
        "" -> OptOutWithoutReason
        _ -> OptOutWithReason
      }
    }
  }
}

/// One node of a function body: a statement or an expression.
type Node {
  StatementNode(glance.Statement)
  ExpressionNode(glance.Expression)
}

/// Every statement and expression in `body`, at any depth, each before the
/// nodes inside it. The AST rules filter this list, so a node kind a rule
/// does not name is still searched for the nodes the rule does name.
fn body_nodes(body: List(glance.Statement)) -> List(Node) {
  list.flat_map(body, fn(statement) { nodes_under(StatementNode(statement)) })
}

fn nodes_under(node: Node) -> List(Node) {
  [node, ..list.flat_map(children(node), nodes_under)]
}

/// The nodes directly inside `node`. Exhaustive over glance's AST, with no
/// catch-all arm: a new node kind fails to compile here instead of being
/// skipped by every rule.
fn children(node: Node) -> List(Node) {
  case node {
    StatementNode(statement) ->
      list.map(statement_children(statement), ExpressionNode)
    ExpressionNode(expression) -> expression_children(expression)
  }
}

fn statement_children(statement: glance.Statement) -> List(glance.Expression) {
  case statement {
    glance.Use(function:, ..) -> [function]
    glance.Assignment(kind: glance.Let, value:, ..) -> [value]
    glance.Assignment(kind: glance.LetAssert(message:), value:, ..) -> [
      value,
      ..optional(message)
    ]
    glance.Assert(expression:, message:, ..) -> [
      expression,
      ..optional(message)
    ]
    glance.Expression(expression) -> [expression]
  }
}

fn expression_children(expression: glance.Expression) -> List(Node) {
  case expression {
    glance.Block(statements:, ..) -> list.map(statements, StatementNode)
    glance.Fn(body:, ..) -> list.map(body, StatementNode)
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> []
    glance.NegateInt(value:, ..) | glance.NegateBool(value:, ..) ->
      expressions([value])
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      expressions(optional(message))
    glance.Tuple(elements:, ..) -> expressions(elements)
    glance.List(elements:, rest:, ..) ->
      expressions(list.append(elements, optional(rest)))
    glance.RecordUpdate(record:, fields:, ..) ->
      expressions([
        record,
        ..list.flat_map(fields, fn(field) { optional(field.item) })
      ])
    glance.FieldAccess(container:, ..) -> expressions([container])
    glance.Call(function:, arguments:, ..) ->
      expressions([function, ..list.flat_map(arguments, field_items)])
    glance.TupleIndex(tuple:, ..) -> expressions([tuple])
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      expressions(
        list.flatten([
          [function],
          list.flat_map(arguments_before, field_items),
          list.flat_map(arguments_after, field_items),
        ]),
      )
    glance.BitString(segments:, ..) ->
      expressions(
        list.flat_map(segments, fn(segment) {
          let #(value, options) = segment
          [value, ..list.flat_map(options, size_expressions)]
        }),
      )
    glance.Case(subjects:, clauses:, ..) ->
      expressions(list.append(
        subjects,
        list.flat_map(clauses, fn(clause) {
          list.append(optional(clause.guard), [clause.body])
        }),
      ))
    glance.BinaryOperator(left:, right:, ..) -> expressions([left, right])
    glance.Echo(expression:, message:, ..) ->
      expressions(list.append(optional(expression), optional(message)))
  }
}

fn expressions(items: List(glance.Expression)) -> List(Node) {
  list.map(items, ExpressionNode)
}

/// An optional child (a message, a guard, a list tail) as zero or one items.
fn optional(child: option.Option(a)) -> List(a) {
  case child {
    option.Some(item) -> [item]
    option.None -> []
  }
}

fn field_items(
  field: glance.Field(glance.Expression),
) -> List(glance.Expression) {
  case field {
    glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) -> [item]
    // `label:` with no value names a variable; there is nothing inside.
    glance.ShorthandField(..) -> []
  }
}

fn size_expressions(
  option: glance.BitStringSegmentOption(glance.Expression),
) -> List(glance.Expression) {
  case option {
    glance.SizeValueOption(size) -> [size]
    glance.BytesOption
    | glance.IntOption
    | glance.FloatOption
    | glance.BitsOption
    | glance.Utf8Option
    | glance.Utf16Option
    | glance.Utf32Option
    | glance.Utf8CodepointOption
    | glance.Utf16CodepointOption
    | glance.Utf32CodepointOption
    | glance.SignedOption
    | glance.UnsignedOption
    | glance.BigOption
    | glance.LittleOption
    | glance.NativeOption
    | glance.SizeOption(..)
    | glance.UnitOption(..) -> []
  }
}

fn check_deprecated_route_api(
  file_path: String,
  source: String,
) -> List(Violation) {
  let is_example = string.starts_with(file_path, "examples/")
  case is_example {
    False -> []
    True -> {
      let deprecated = [
        "brazier." <> "routes(",
        "brazier." <> "on_route_change(",
        "start_" <> "router",
        "routes" <> "_" <> "dir",
      ]
      list.filter_map(deprecated, fn(phrase) {
        case string.contains(source, phrase) {
          True ->
            Ok(Violation(
              file: file_path,
              location: "text",
              rule: "deprecated-route-api",
              message: "Found deprecated route API `"
                <> phrase
                <> "`. Use explicit route_pages with imported page modules.",
            ))
          False -> Error(Nil)
        }
      })
    }
  }
}

/// Check that public functions in key modules contain logging calls.
/// Only applies to files whose path contains `brazier/transport` or
/// `brazier/runtime`: `brazier/transport.gleam`, `brazier/transport/*` and
/// `brazier/runtime.gleam`.
fn check_public_functions_log(
  file_path: String,
  source: String,
  module: glance.Module,
) -> List(Violation) {
  // Only apply this rule to key framework modules
  let is_key_module =
    string.contains(file_path, "brazier/transport")
    || string.contains(file_path, "brazier/runtime")
  case is_key_module {
    False -> []
    True -> {
      list.filter_map(module.functions, fn(def) {
        let func = def.definition
        case func.publicity {
          glance.Public -> {
            // Exempt pure utility functions (encode/decode/to_*/create_*)
            let is_exempt = is_pure_function_name(func.name)
            case is_exempt {
              True -> Error(Nil)
              False -> {
                let has_log = body_contains_log_call(func.body)
                case has_log {
                  True -> Error(Nil)
                  False ->
                    Ok(Violation(
                      file: file_path,
                      location: source_location.format_span(
                        source,
                        func.location,
                      ),
                      rule: "public-fn-must-log",
                      message: "Public function `"
                        <> func.name
                        <> "` in key module should contain a logging call.",
                    ))
                }
              }
            }
          }
          glance.Private -> Error(Nil)
        }
      })
    }
  }
}

/// Check for source phrases that historically hid unsupported rendering paths.
fn check_no_degraded_path_phrases(
  file_path: String,
  source: String,
) -> List(Violation) {
  let forbidden = [
    "fall" <> "back",
    "fall " <> "back",
    "runtime" <> "-only",
    "SSR morphing " <> "only",
    "HTML morphing " <> "only",
    "brazier." <> "router",
    "start_" <> "router",
    "router_" <> "routes" <> "_" <> "dir",
    "routes" <> "_" <> "dir",
    "file-" <> "based routing",
  ]
  list.filter_map(forbidden, fn(phrase) {
    case string.contains(source, phrase) {
      True ->
        Ok(Violation(
          file: file_path,
          location: "text",
          rule: "no-degraded-path-phrases",
          message: "Found forbidden degraded-path phrase `"
            <> phrase
            <> "`. Brazier must fail loudly instead of degrading to another rendering path.",
        ))
      False -> Error(Nil)
    }
  })
}

/// Check if a function name suggests it's a pure utility (no side effects → no logging needed).
fn is_pure_function_name(name: String) -> Bool {
  string.starts_with(name, "encode_")
  || string.starts_with(name, "decode_")
  || string.starts_with(name, "to_")
  || string.starts_with(name, "from_")
  || string.starts_with(name, "create_")
  || string.starts_with(name, "is_")
  || string.starts_with(name, "has_")
  || string.starts_with(name, "get_")
  || string.starts_with(name, "patches_to_")
  || string.starts_with(name, "default_")
  || string.starts_with(name, "describe_")
  || name == "diff"
  || name == "main"
  || name == "listen"
  || name == "accept"
  || name == "send_bytes"
  || name == "close"
  || name == "controlling_process"
  || name == "set_active_once"
  || name == "send_text_frame"
  || name == "send_close_frame"
  || name == "read_body"
  || name == "classify_tcp_message"
  || name == "connection_tracker_init"
}

/// Whether a function body calls `log.<anything>` anywhere.
fn body_contains_log_call(body: List(glance.Statement)) -> Bool {
  list.any(body_nodes(body), is_log_call)
}

fn is_log_call(node: Node) -> Bool {
  case node {
    ExpressionNode(glance.Call(
      function: glance.FieldAccess(
        container: glance.Variable(name: "log", ..),
        ..,
      ),
      ..,
    )) -> True
    ExpressionNode(..) | StatementNode(..) -> False
  }
}

/// Flag every `let assert` in `src/` that has no `as "..."` message, or whose
/// message is an empty string literal (TIGERSTYLE §3, TS-12). The message is
/// what the crash report shows, so it must name the invariant that failed.
/// A message built from an expression is accepted: the linter cannot know
/// its value, and the compiler already checks it is a `String`.
fn check_let_assert_messages(
  file_path: String,
  source: String,
  module: glance.Module,
) -> List(Violation) {
  case string.starts_with(file_path, "src/") {
    False -> []
    True ->
      list.flat_map(module.functions, fn(def) {
        let func = def.definition
        body_nodes(func.body)
        |> list.flat_map(fn(node) {
          let_assert_violation(file_path, source, func.name, node)
        })
      })
  }
}

fn let_assert_violation(
  file_path: String,
  source: String,
  func_name: String,
  node: Node,
) -> List(Violation) {
  let problem = case node {
    StatementNode(glance.Assignment(
      kind: glance.LetAssert(message: option.None),
      location:,
      ..,
    )) -> Ok(#(location, "has no `as \"...\"` message"))
    StatementNode(glance.Assignment(
      kind: glance.LetAssert(message: option.Some(glance.String(value:, ..))),
      location:,
      ..,
    )) ->
      case string.trim(value) {
        "" -> Ok(#(location, "has an empty `as` message"))
        _ -> Error(Nil)
      }
    StatementNode(glance.Assignment(..))
    | StatementNode(glance.Use(..))
    | StatementNode(glance.Assert(..))
    | StatementNode(glance.Expression(..))
    | ExpressionNode(..) -> Error(Nil)
  }
  case problem {
    Error(Nil) -> []
    Ok(#(location, what)) -> [
      Violation(
        file: file_path,
        location: source_location.format_span(source, location),
        rule: "let-assert-message",
        message: "`let assert` in `"
          <> func_name
          <> "` "
          <> what
          <> ". Add `as \"...\"` stating the invariant and why it holds.",
      ),
    ]
  }
}

/// Check for `todo` and `panic` expressions in function bodies.
/// These are development placeholders and must not appear in shipped code.
fn check_no_todo_panic(
  file_path: String,
  source: String,
  module: glance.Module,
) -> List(Violation) {
  list.flat_map(module.functions, fn(def) {
    let func = def.definition
    body_nodes(func.body)
    |> list.flat_map(fn(node) {
      todo_panic_violation(file_path, source, func.name, node)
    })
  })
}

fn todo_panic_violation(
  file_path: String,
  source: String,
  func_name: String,
  node: Node,
) -> List(Violation) {
  case node {
    ExpressionNode(glance.Todo(location:, ..)) -> [
      Violation(
        file: file_path,
        location: source_location.format_span(source, location),
        rule: "no-todo",
        message: "Found `todo` in function `"
          <> func_name
          <> "`. Remove before shipping.",
      ),
    ]
    ExpressionNode(glance.Panic(location:, ..)) -> [
      Violation(
        file: file_path,
        location: source_location.format_span(source, location),
        rule: "no-panic",
        message: "Found `panic` in function `"
          <> func_name
          <> "`. Use proper error handling instead.",
      ),
    ]
    ExpressionNode(..) | StatementNode(..) -> []
  }
}

/// Format a lint violation as a human-readable string.
/// Format: `file:location [rule] message`
pub fn violation_to_string(v: Violation) -> String {
  v.file <> ":" <> v.location <> " [" <> v.rule <> "] " <> v.message
}

/// Main entry point for CLI: `gleam run -m brazier/lint`
pub fn main() {
  log.configure()
  log.info("brazier.lint", "Starting lint check")
  let violations =
    list.flatten([
      lint_directory("src"),
      lint_directory("examples"),
      lint_docs_directory("docs"),
      lint_names_directory("src"),
      lint_names_directory("test"),
      lint_names_directory("examples"),
    ])
  log.info(
    "brazier.lint",
    "Found " <> int.to_string(list.length(violations)) <> " violation(s)",
  )
  case violations {
    [] -> {
      log.info("brazier.lint", "No violations found!")
      Nil
    }
    _ -> {
      list.each(violations, fn(v) {
        log.error("brazier.lint", violation_to_string(v))
      })
      log.error(
        "brazier.lint",
        int.to_string(list.length(violations)) <> " violation(s) found",
      )
      // Use init:stop for a graceful shutdown that flushes logs
      erlang_init_stop(1)
    }
  }
}

@external(erlang, "brazier_lint_ffi", "stop_with_code")
fn erlang_init_stop(code: Int) -> Nil
