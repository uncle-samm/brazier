/// Beacon's custom linting tool — enforces engineering principles via AST analysis.
/// Uses Glance to parse source files and check for violations.
///
/// Rules:
/// 1. No `todo` or `panic` in non-test source code
/// 2. No catch-all `_` patterns in case expressions that don't log
/// 3. Public functions in key modules should have logging
/// 4. No degraded-path phrases in shipped source
/// 5. No `let _ =` discards in `src/` (see `check_no_discarded_results`)
/// 6. Every file must be readable and parse; failures are violations
///
/// Reference: CLAUDE.md engineering principles, TigerBeetle approach.
import beacon/build/source_location
import beacon/log
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
  log.info("beacon.lint", "Linting directory: " <> dir)
  case simplifile.read_directory(dir) {
    Ok(entries) -> {
      let violations =
        list.flat_map(entries, fn(entry) {
          let path = dir <> "/" <> entry
          case should_skip_entry(entry), simplifile.is_directory(path) {
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
    Error(err) -> [io_violation(dir, "Cannot read directory " <> dir, err)]
  }
}

fn io_violation(
  path: String,
  context: String,
  err: simplifile.FileError,
) -> Violation {
  let message = context <> ": " <> simplifile.describe_error(err)
  log.error("beacon.lint", message)
  Violation(file: path, location: "file", rule: "unreadable-path", message:)
}

/// Lint Markdown documentation for stale public model language.
/// `docs/PROGRESS.md` is historical by design and is intentionally excluded.
pub fn lint_docs_directory(dir: String) -> List(Violation) {
  log.info("beacon.lint", "Linting docs directory: " <> dir)
  case simplifile.read_directory(dir) {
    Ok(entries) ->
      list.flat_map(entries, fn(entry) {
        let path = dir <> "/" <> entry
        case should_skip_entry(entry), simplifile.is_directory(path) {
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
    Error(err) -> [
      io_violation(dir, "Cannot read docs directory " <> dir, err),
    ]
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
    "beacon." <> "router",
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
          message: "Found stale Beacon routing/rendering phrase `"
            <> phrase
            <> "`. Docs must describe generated contracts and explicit route_pages.",
        ))
      False -> Error(Nil)
    }
  })
}

fn should_skip_entry(entry: String) -> Bool {
  entry == "build"
  || entry == ".venv"
  || entry == "node_modules"
  || entry == "priv"
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
      list.append(
        list.append(
          list.append(todo_violations, logging_violations),
          degraded_path_violations,
        ),
        list.append(deprecated_route_violations, discard_violations),
      )
    }
    Error(err) -> {
      let message = source_location.describe_parse_error(file_path, source, err)
      log.error("beacon.lint", "Cannot parse " <> message)
      [
        Violation(
          file: file_path,
          location: "file",
          rule: "parse-error",
          message: "Cannot parse: " <> message,
        ),
      ]
    }
  }
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
        list.flat_map(func.body, discards_in_statement)
        |> list.filter_map(fn(span) {
          discard_violation(file_path, source, func.name, span)
        })
      })
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

fn discards_in_statement(statement: glance.Statement) -> List(glance.Span) {
  case statement {
    glance.Assignment(
      kind: glance.Let,
      pattern: glance.PatternDiscard(..),
      value:,
      location:,
      ..,
    ) -> [location, ..discards_in_expression(value)]
    glance.Assignment(value:, ..) -> discards_in_expression(value)
    glance.Use(function:, ..) -> discards_in_expression(function)
    glance.Assert(expression:, ..) -> discards_in_expression(expression)
    glance.Expression(expression) -> discards_in_expression(expression)
  }
}

fn discards_in_expression(expression: glance.Expression) -> List(glance.Span) {
  case expression {
    glance.Block(statements:, ..) ->
      list.flat_map(statements, discards_in_statement)
    glance.Fn(body:, ..) -> list.flat_map(body, discards_in_statement)
    glance.Case(subjects:, clauses:, ..) ->
      list.append(
        list.flat_map(subjects, discards_in_expression),
        list.flat_map(clauses, fn(clause) {
          discards_in_expression(clause.body)
        }),
      )
    glance.Call(function:, arguments:, ..) ->
      list.append(
        discards_in_expression(function),
        list.flat_map(arguments, discards_in_field),
      )
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      list.flatten([
        discards_in_expression(function),
        list.flat_map(arguments_before, discards_in_field),
        list.flat_map(arguments_after, discards_in_field),
      ])
    glance.BinaryOperator(left:, right:, ..) ->
      list.append(discards_in_expression(left), discards_in_expression(right))
    glance.List(elements:, ..) | glance.Tuple(elements:, ..) ->
      list.flat_map(elements, discards_in_expression)
    glance.NegateInt(value:, ..) | glance.NegateBool(value:, ..) ->
      discards_in_expression(value)
    glance.FieldAccess(container:, ..) -> discards_in_expression(container)
    glance.TupleIndex(tuple:, ..) -> discards_in_expression(tuple)
    glance.RecordUpdate(record:, fields:, ..) ->
      list.append(
        discards_in_expression(record),
        list.flat_map(fields, fn(field) {
          case field.item {
            option.Some(item) -> discards_in_expression(item)
            option.None -> []
          }
        }),
      )
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..)
    | glance.Panic(..)
    | glance.Todo(..)
    | glance.BitString(..)
    | glance.Echo(..) -> []
  }
}

fn discards_in_field(
  field: glance.Field(glance.Expression),
) -> List(glance.Span) {
  case field {
    glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
      discards_in_expression(item)
    glance.ShorthandField(..) -> []
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
        "beacon." <> "routes(",
        "beacon." <> "on_route_change(",
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
/// Only applies to files in beacon/transport, beacon/runtime, beacon/diff.
fn check_public_functions_log(
  file_path: String,
  source: String,
  module: glance.Module,
) -> List(Violation) {
  // Only apply this rule to key framework modules
  let is_key_module =
    string.contains(file_path, "beacon/transport")
    || string.contains(file_path, "beacon/runtime")
    || string.contains(file_path, "beacon/diff")
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
    "beacon." <> "router",
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
            <> "`. Beacon must fail loudly instead of degrading to another rendering path.",
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

/// Check if a function body contains any call to log.info/debug/warning/error.
fn body_contains_log_call(body: List(glance.Statement)) -> Bool {
  list.any(body, fn(stmt) { statement_has_log(stmt) })
}

/// Check a statement for log calls.
fn statement_has_log(stmt: glance.Statement) -> Bool {
  case stmt {
    glance.Expression(expr) -> expression_has_log(expr)
    glance.Assignment(value: expr, ..) -> expression_has_log(expr)
    _ -> False
  }
}

/// Check an expression for log calls (looking for `log.info`, `log.debug`, etc).
fn expression_has_log(expr: glance.Expression) -> Bool {
  case expr {
    // Direct call to log.something
    glance.Call(
      function: glance.FieldAccess(
        container: glance.Variable(name: "log", ..),
        ..,
      ),
      ..,
    ) -> True

    // Recurse into sub-expressions
    glance.Call(function: func, arguments: args, ..) -> {
      expression_has_log(func)
      || list.any(args, fn(arg) {
        case arg {
          glance.LabelledField(item: value, ..) -> expression_has_log(value)
          glance.UnlabelledField(item: value) -> expression_has_log(value)
          glance.ShorthandField(..) -> False
        }
      })
    }

    glance.Block(statements: stmts, ..) -> list.any(stmts, statement_has_log)

    glance.Case(clauses: clauses, ..) ->
      list.any(clauses, fn(c) { expression_has_log(c.body) })

    glance.BinaryOperator(left: l, right: r, ..) ->
      expression_has_log(l) || expression_has_log(r)

    glance.Fn(body: body, ..) -> list.any(body, statement_has_log)

    _ -> False
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
    list.flat_map(func.body, fn(statement) {
      find_todo_panic_in_statement(file_path, source, func.name, statement)
    })
  })
}

/// Recursively search a statement for todo/panic expressions.
fn find_todo_panic_in_statement(
  file_path: String,
  source: String,
  func_name: String,
  statement: glance.Statement,
) -> List(Violation) {
  case statement {
    glance.Expression(expr) ->
      find_todo_panic_in_expression(file_path, source, func_name, expr)
    glance.Assignment(value: expr, ..) ->
      find_todo_panic_in_expression(file_path, source, func_name, expr)
    _ -> []
  }
}

/// Recursively search an expression for todo/panic.
fn find_todo_panic_in_expression(
  file_path: String,
  source: String,
  func_name: String,
  expr: glance.Expression,
) -> List(Violation) {
  case expr {
    glance.Todo(location: loc, ..) -> [
      Violation(
        file: file_path,
        location: source_location.format_span(source, loc),
        rule: "no-todo",
        message: "Found `todo` in function `"
          <> func_name
          <> "`. Remove before shipping.",
      ),
    ]
    glance.Panic(location: loc, ..) -> [
      Violation(
        file: file_path,
        location: source_location.format_span(source, loc),
        rule: "no-panic",
        message: "Found `panic` in function `"
          <> func_name
          <> "`. Use proper error handling instead.",
      ),
    ]

    // Recurse into sub-expressions
    glance.Call(function: func, arguments: args, ..) -> {
      let func_violations =
        find_todo_panic_in_expression(file_path, source, func_name, func)
      let arg_violations =
        list.flat_map(args, fn(arg) {
          case arg {
            glance.LabelledField(item: value, ..) ->
              find_todo_panic_in_expression(file_path, source, func_name, value)
            glance.UnlabelledField(item: value) ->
              find_todo_panic_in_expression(file_path, source, func_name, value)
            glance.ShorthandField(..) -> []
          }
        })
      list.append(func_violations, arg_violations)
    }

    glance.BinaryOperator(left: left, right: right, ..) ->
      list.append(
        find_todo_panic_in_expression(file_path, source, func_name, left),
        find_todo_panic_in_expression(file_path, source, func_name, right),
      )

    glance.Block(statements: stmts, ..) ->
      list.flat_map(stmts, fn(s) {
        find_todo_panic_in_statement(file_path, source, func_name, s)
      })

    glance.Case(subjects: subjects, clauses: clauses, ..) -> {
      let subj_v =
        list.flat_map(subjects, fn(s) {
          find_todo_panic_in_expression(file_path, source, func_name, s)
        })
      let clause_v =
        list.flat_map(clauses, fn(c) {
          find_todo_panic_in_expression(file_path, source, func_name, c.body)
        })
      list.append(subj_v, clause_v)
    }

    glance.Fn(body: body, ..) ->
      list.flat_map(body, fn(s) {
        find_todo_panic_in_statement(file_path, source, func_name, s)
      })

    glance.List(elements: elems, ..) ->
      list.flat_map(elems, fn(e) {
        find_todo_panic_in_expression(file_path, source, func_name, e)
      })

    glance.Tuple(elements: elems, ..) ->
      list.flat_map(elems, fn(e) {
        find_todo_panic_in_expression(file_path, source, func_name, e)
      })

    glance.NegateInt(value: inner, ..) | glance.NegateBool(value: inner, ..) ->
      find_todo_panic_in_expression(file_path, source, func_name, inner)

    glance.FieldAccess(container: inner, ..) ->
      find_todo_panic_in_expression(file_path, source, func_name, inner)

    _ -> []
  }
}

/// Format a lint violation as a human-readable string.
/// Format: `file:location [rule] message`
pub fn violation_to_string(v: Violation) -> String {
  v.file <> ":" <> v.location <> " [" <> v.rule <> "] " <> v.message
}

/// Main entry point for CLI: `gleam run -m beacon/lint`
pub fn main() {
  log.configure()
  log.info("beacon.lint", "Starting lint check")
  let violations =
    list.append(
      list.append(lint_directory("src"), lint_directory("examples")),
      lint_docs_directory("docs"),
    )
  log.info(
    "beacon.lint",
    "Found " <> int.to_string(list.length(violations)) <> " violation(s)",
  )
  case violations {
    [] -> {
      log.info("beacon.lint", "No violations found!")
      Nil
    }
    _ -> {
      list.each(violations, fn(v) {
        log.error("beacon.lint", violation_to_string(v))
      })
      log.error(
        "beacon.lint",
        int.to_string(list.length(violations)) <> " violation(s) found",
      )
      // Use init:stop for a graceful shutdown that flushes logs
      erlang_init_stop(1)
    }
  }
}

@external(erlang, "beacon_lint_ffi", "stop_with_code")
fn erlang_init_stop(code: Int) -> Nil
