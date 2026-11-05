import brazier/lint
import gleam/list
import gleam/string
import simplifile

pub fn clean_code_no_violations_test() {
  let source =
    "
pub fn greet(name: String) -> String {
  \"Hello, \" <> name
}
"
  let violations = lint.lint_source("test.gleam", source)
  let assert [] = violations
}

pub fn todo_detected_test() {
  let source =
    "
pub fn incomplete() {
  todo
}
"
  let violations = lint.lint_source("test.gleam", source)
  let assert [v] = violations
  let assert "no-todo" = v.rule
  let assert True = str_contains(v.message, "todo")
}

pub fn panic_detected_test() {
  let source =
    "
pub fn bad() {
  panic
}
"
  let violations = lint.lint_source("test.gleam", source)
  let assert [v] = violations
  let assert "no-panic" = v.rule
  let assert True = str_contains(v.message, "panic")
}

pub fn todo_in_nested_expression_test() {
  let source =
    "
pub fn nested() {
  case True {
    True -> todo
    False -> \"ok\"
  }
}
"
  let violations = lint.lint_source("test.gleam", source)
  let assert [v] = violations
  let assert "no-todo" = v.rule
}

pub fn multiple_violations_test() {
  let source =
    "
pub fn bad1() { todo }
pub fn bad2() { panic }
"
  let violations = lint.lint_source("test.gleam", source)
  let assert 2 = list.length(violations)
}

pub fn private_functions_also_checked_test() {
  let source =
    "
fn helper() { todo }
"
  let violations = lint.lint_source("test.gleam", source)
  let assert [_v] = violations
}

pub fn violation_includes_function_name_test() {
  let source =
    "
pub fn my_function() { todo }
"
  let violations = lint.lint_source("test.gleam", source)
  let assert [v] = violations
  let assert True = str_contains(v.message, "my_function")
}

pub fn violation_includes_file_path_test() {
  let source =
    "
pub fn bad() { todo }
"
  // Use a non-key-module path to avoid the logging rule
  let violations = lint.lint_source("src/brazier/other.gleam", source)
  let assert [v] = violations
  let assert "src/brazier/other.gleam" = v.file
}

pub fn violation_to_string_format_test() {
  let v =
    lint.Violation(
      file: "src/test.gleam",
      location: "byte 10-20",
      rule: "no-todo",
      message: "Found todo",
    )
  let result = lint.violation_to_string(v)
  let assert True = str_contains(result, "src/test.gleam")
  let assert True = str_contains(result, "no-todo")
  let assert True = str_contains(result, "Found todo")
}

pub fn public_fn_without_log_in_key_module_test() {
  let source =
    "
pub fn handle() { Nil }
"
  let violations = lint.lint_source("src/brazier/transport.gleam", source)
  let assert [v] = violations
  let assert "public-fn-must-log" = v.rule
}

pub fn public_fn_with_log_passes_test() {
  let source =
    "
import brazier/log
pub fn handle() { log.info(\"mod\", \"msg\") }
"
  let violations = lint.lint_source("src/brazier/runtime.gleam", source)
  let assert [] = violations
}

pub fn private_fn_not_checked_for_log_test() {
  let source =
    "
fn helper() { Nil }
"
  let violations = lint.lint_source("src/brazier/transport.gleam", source)
  let assert [] = violations
}

pub fn non_key_module_not_checked_for_log_test() {
  let source =
    "
pub fn handle() { Nil }
"
  let violations = lint.lint_source("src/brazier/form.gleam", source)
  let assert [] = violations
}

pub fn invalid_source_is_parse_error_violation_test() {
  let source = "pub fn ok() { 1 }\nthis is not valid gleam @@@"
  let violations = lint.lint_source("bad.gleam", source)
  let assert [v] = violations
  let assert "parse-error" = v.rule
  // The message names the file, the line:column and the offending token.
  let assert True = str_contains(v.message, "bad.gleam:2:1")
  let assert True = str_contains(v.message, "\"this\"")
}

pub fn unreadable_file_is_violation_test() {
  let violations = lint.lint_file("test/fixtures/does_not_exist.gleam")
  let assert [v] = violations
  let assert "unreadable-path" = v.rule
}

pub fn discarded_value_in_src_is_violation_test() {
  let source =
    "
pub fn save() {
  let _ = write()
  Nil
}
"
  let violations = lint.lint_source("src/brazier/other.gleam", source)
  let assert [v] = violations
  let assert "no-discarded-result" = v.rule
  let assert "3:3" = v.location
  let assert True = str_contains(v.message, "save")
}

pub fn named_discard_in_nested_block_is_violation_test() {
  let source =
    "
pub fn save() {
  case True {
    True -> {
      let _ignored = write()
      Nil
    }
    False -> Nil
  }
}
"
  let violations = lint.lint_source("src/brazier/other.gleam", source)
  let assert [v] = violations
  let assert "no-discarded-result" = v.rule
}

pub fn discard_with_reasoned_opt_out_passes_test() {
  let source =
    "
pub fn save() {
  // lint:allow-discard the returned count is informational only
  let _ = decrement()
  Nil
}
"
  let assert [] = lint.lint_source("src/brazier/other.gleam", source)
}

pub fn discard_opt_out_without_reason_is_violation_test() {
  let source =
    "
pub fn save() {
  // lint:allow-discard
  let _ = decrement()
  Nil
}
"
  let assert [v] = lint.lint_source("src/brazier/other.gleam", source)
  let assert "no-discarded-result" = v.rule
  let assert True = str_contains(v.message, "must give a reason")
}

pub fn discard_opt_out_must_be_directly_above_test() {
  let source =
    "
pub fn save() {
  // lint:allow-discard the returned count is informational only

  let _ = decrement()
  Nil
}
"
  let assert [_] = lint.lint_source("src/brazier/other.gleam", source)
}

pub fn discard_outside_src_is_not_checked_test() {
  let source =
    "
pub fn save() {
  let _ = write()
  Nil
}
"
  let assert [] = lint.lint_source("test/brazier/other_test.gleam", source)
}

pub fn let_assert_discard_is_not_flagged_test() {
  let source =
    "
pub fn save() {
  let assert Ok(_) = write() as \"write cannot fail here\"
  Nil
}
"
  let assert [] = lint.lint_source("src/brazier/other.gleam", source)
}

pub fn let_assert_without_message_in_src_is_violation_test() {
  let source =
    "
pub fn save() {
  let assert Ok(_) = write()
  Nil
}
"
  let assert [v] = lint.lint_source("src/brazier/other.gleam", source)
    as "the one let assert without `as` is the one violation"
  assert v.rule == "let-assert-message"
  assert v.location == "3:3"
  assert str_contains(v.message, "`save`")
  assert str_contains(v.message, "no `as")
}

pub fn let_assert_with_empty_message_is_violation_test() {
  let source =
    "
pub fn save() {
  let assert Ok(_) = write() as \"  \"
  Nil
}
"
  let assert [v] = lint.lint_source("src/brazier/other.gleam", source)
    as "a blank `as` message names no invariant"
  assert v.rule == "let-assert-message"
  assert str_contains(v.message, "empty `as` message")
}

pub fn let_assert_without_message_deep_in_a_use_callback_is_found_test() {
  let source =
    "
pub fn save() {
  use x <- result.try(read())
  case x {
    _ -> {
      let assert Ok(y) = write(x)
      y
    }
  }
}
"
  let violations = lint.lint_source("src/brazier/other.gleam", source)
  assert list.map(violations, fn(v) { v.rule }) == ["let-assert-message"]
}

pub fn let_assert_with_computed_message_passes_test() {
  let source =
    "
pub fn save(path: String) {
  let assert Ok(_) = write(path) as { \"cannot write \" <> path }
  Nil
}
"
  let assert [] = lint.lint_source("src/brazier/other.gleam", source)
}

pub fn let_assert_without_message_outside_src_is_not_checked_test() {
  let source =
    "
pub fn save_test() {
  let assert Ok(_) = write()
  Nil
}
"
  let assert [] = lint.lint_source("test/brazier/other_test.gleam", source)
}

pub fn removed_router_api_phrase_is_violation_test() {
  let source =
    "
pub fn note() -> String {
  \"brazier.router is not a supported API\"
}
"
  let violations = lint.lint_source("src/brazier/bad_route_doc.gleam", source)
  let assert [v] = violations
  let assert "no-degraded-path-phrases" = v.rule
}

pub fn low_level_route_api_in_example_is_violation_test() {
  let source =
    "
import brazier

pub fn start() {
  brazier.app(fn() { 1 }, fn(m, _msg) { m }, fn(m) { m })
  |> brazier.routes([\"/\"])
}
"
  let violations = lint.lint_source("examples/bad/src/bad.gleam", source)
  let assert [v] = violations
  let assert "deprecated-route-api" = v.rule
}

pub fn stale_docs_route_model_is_violation_test() {
  let source =
    "
# Routing

Use start_router with route files.
"
  let violations = lint.lint_doc_source("docs/OLD.md", source)
  let assert [_, _] = violations
  let assert True = list.any(violations, fn(v) { v.rule == "stale-docs-model" })
}

// --- The AST rules see every node ---

// Each body puts a `todo` where the old walker did not look: it skipped
// `use` and `assert` statements, `as` messages, captures, record updates,
// tuple indexes, bit arrays, case guards, list tails and `echo`.
pub fn todo_is_found_in_every_kind_of_node_test() {
  let bodies = [
    #("use", "use x <- result.try(todo)\n  x"),
    #("assert", "assert todo"),
    #("let assert message", "let assert Ok(x) = y as todo\n  x"),
    #("assert message", "assert y as todo"),
    #("capture", "f(todo, _)"),
    #("record update", "Model(..m, count: todo)"),
    #("tuple index", "#(todo, 1).0"),
    #("bit array value", "<<todo:int>>"),
    #("bit array size", "<<1:size(todo)>>"),
    #("case guard", "case 1 {\n    _ if todo -> 1\n  }"),
    #("list tail", "[1, ..todo]"),
    #("echo", "echo todo"),
    #("panic message", "panic as todo"),
    #("todo message", "todo as todo"),
  ]
  list.each(bodies, fn(body) {
    let #(name, code) = body
    let source = "pub fn f() {\n  " <> code <> "\n}\n"
    let todos =
      lint.lint_source("src/brazier/other.gleam", source)
      |> list.filter(fn(v) { v.rule == "no-todo" })
    assert list.length(todos) >= 1 as name
  })
}

pub fn panic_in_a_use_callback_is_found_test() {
  let source =
    "
pub fn f() {
  use x <- result.try(fn() { panic }())
  x
}
"
  let assert [v] = lint.lint_source("src/brazier/other.gleam", source)
    as "exactly the one panic is a violation"
  assert v.rule == "no-panic"
}

pub fn a_log_inside_a_use_statement_counts_test() {
  let source =
    "
import brazier/log
pub fn handle() {
  use <- defer(fn() { log.info(\"mod\", \"done\") })
  Nil
}
"
  assert lint.lint_source("src/brazier/transport.gleam", source) == []
}

pub fn a_log_inside_a_tuple_counts_test() {
  let source =
    "
import brazier/log
pub fn handle() {
  #(log.info(\"mod\", \"msg\"), 1)
}
"
  assert lint.lint_source("src/brazier/runtime.gleam", source) == []
}

pub fn a_log_capture_is_not_a_log_call_test() {
  // A capture makes a function; it does not log.
  let source =
    "
import brazier/log
pub fn handle() {
  log.info(\"mod\", _)
}
"
  let assert [v] = lint.lint_source("src/brazier/runtime.gleam", source)
    as "the capture alone does not satisfy the rule"
  assert v.rule == "public-fn-must-log"
}

pub fn discard_inside_an_echo_is_found_test() {
  let source =
    "
pub fn save() {
  echo {
    let _ = write()
    1
  }
}
"
  let assert [v] = lint.lint_source("src/brazier/other.gleam", source)
    as "the discard inside the echoed block is the one violation"
  assert v.rule == "no-discarded-result"
  assert v.location == "4:5"
}

pub fn discard_inside_a_list_tail_is_found_test() {
  let source =
    "
pub fn save() {
  [1, ..{
    let _ = write()
    []
  }]
}
"
  let violations = lint.lint_source("src/brazier/other.gleam", source)
  assert list.map(violations, fn(v) { v.rule }) == ["no-discarded-result"]
}

// --- Stale pre-rename names ---

// Built from parts so this file does not itself contain the old name.
const old = "bea" <> "con"

const old_upper = "BEA" <> "CON"

pub fn old_name_in_src_is_a_violation_test() {
  let source = "pub fn f() {\n  // see " <> old <> "/runtime\n  1\n}\n"
  let assert [v] = lint.lint_stale_names("src/brazier/other.gleam", source)
    as "the one line with the old name is flagged"
  assert v.rule == "stale-name"
  assert v.location == "line 2"
}

pub fn old_name_in_any_case_is_a_violation_test() {
  let lines = [
    old,
    old_upper,
    "B" <> string.drop_start(old, 1),
    "data-" <> old <> "-key",
    "__" <> "B" <> string.drop_start(old, 1) <> "_x",
  ]
  list.each(lines, fn(line) {
    let violations = lint.lint_stale_names("examples/app/src/app.gleam", line)
    assert list.length(violations) == 1 as line
  })
}

pub fn config_may_name_what_it_refuses_test() {
  let source =
    "const published_dev_secret = \""
    <> old
    <> "-dev-secret-change-in-production\"\n"
    <> "/// `"
    <> old
    <> "` to `brazier` (2026-11-04).\n"
    <> "const renamed_env_prefix = \""
    <> old_upper
    <> "_\"\n"
    <> "// "
    <> old_upper
    <> "_ENV is refused.\n"
  assert lint.lint_stale_names("src/brazier/config.gleam", source) == []
  // The same lines anywhere else in src are stale.
  assert list.length(lint.lint_stale_names("src/brazier/other.gleam", source))
    == 4
}

pub fn tests_may_name_the_refused_variables_and_secret_test() {
  let source =
    "putenv(\""
    <> old_upper
    <> "_ENV\", \"prod\")\n"
    <> "start(\""
    <> old
    <> "-dev-secret-change-in-production\")\n"
  assert lint.lint_stale_names("test/brazier/config_test.gleam", source) == []
  // The rename comment is allowed only in config.gleam.
  let comment = "// `" <> old <> "` to `brazier`\n"
  let assert [_] = lint.lint_stale_names("test/brazier/x_test.gleam", comment)
    as "the rename comment is stale outside config.gleam"
  // A prefix not followed by a variable name is not a variable.
  let prefix = "let p = \"" <> old_upper <> "_\"\n"
  let assert [_] = lint.lint_stale_names("test/brazier/x_test.gleam", prefix)
    as "a bare prefix is allowed only in config.gleam"
}

pub fn an_allowed_use_does_not_excuse_a_stale_one_on_its_line_test() {
  let line = "putenv(\"" <> old_upper <> "_ENV\", \"" <> old <> "\")"
  let assert [_] = lint.lint_stale_names("test/brazier/x_test.gleam", line)
    as "two uses of the old name, one allowed, is one violation"
}

pub fn names_directory_reads_text_files_at_any_depth_test() {
  let root = "build/lint_names_test_" <> unique_ref()
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/nested")
    as "the build directory is writable"
  let stale = "%% " <> old <> "_ffi\n"
  let assert Ok(Nil) = simplifile.write(root <> "/nested/x_ffi.erl", stale)
    as "the build directory is writable"
  let assert Ok(Nil) =
    simplifile.write(root <> "/clean.gleam", "pub fn f() { 1 }\n")
    as "the build directory is writable"
  // Not a text source: never read.
  let assert Ok(Nil) = simplifile.write(root <> "/node.pem", stale)
    as "the build directory is writable"
  let violations = lint.lint_names_directory(root)
  let assert Ok(Nil) = simplifile.delete(root)
    as "the test removes only the directory it created"
  let assert [v] = violations as "only the .erl file has the old name"
  assert v.file == root <> "/nested/x_ffi.erl"
  assert v.location == "line 1"
}

pub fn names_directory_that_does_not_exist_is_a_violation_test() {
  let assert [v] = lint.lint_names_directory("test/fixtures/no_such_dir")
    as "a missing directory is reported, not skipped"
  assert v.rule == "unreadable-path"
}

// --- unicode-case-folding ---

fn rules(violations: List(lint.Violation)) -> List(String) {
  list.map(violations, fn(v) { v.rule })
}

pub fn string_lowercase_call_in_src_is_violation_test() {
  let source =
    "import gleam/string
pub fn name(text: String) -> String {
  string.lowercase(text)
}
"
  let assert [v] = lint.lint_source("src/brazier/other.gleam", source)
    as "the one Unicode lowercase is the one violation"
  assert v.rule == "unicode-case-folding"
  assert v.location == "3:3"
  assert str_contains(v.message, "`string.lowercase` in function `name`")
  assert str_contains(v.message, "brazier/internal/ascii")
}

pub fn every_unicode_case_function_is_flagged_as_a_value_test() {
  // A pipe, a reference passed as a value, a capture's function and a case
  // guard: each is a use, called or not.
  let source =
    "import gleam/list
import gleam/string
pub fn names(texts: List(String), text: String) -> List(String) {
  let first = text |> string.uppercase
  let rest = list.map(texts, string.capitalise)
  case text {
    t if t == string.lowercase(t) -> [first, ..rest]
    _ -> list.map(rest, string.lowercase(_))
  }
}
"
  let violations = lint.lint_source("src/brazier/other.gleam", source)
  assert rules(violations)
    == [
      "unicode-case-folding", "unicode-case-folding", "unicode-case-folding",
      "unicode-case-folding",
    ]
  assert list.map(violations, fn(v) { v.location })
    == ["4:23", "5:30", "7:15", "8:25"]
}

pub fn aliased_string_import_is_followed_test() {
  let source =
    "import gleam/string as text
pub fn name(value: String) -> String {
  text.lowercase(value)
}
"
  let assert [v] = lint.lint_source("src/brazier/other.gleam", source)
    as "the alias names gleam/string"
  assert v.rule == "unicode-case-folding"
  assert str_contains(v.message, "`text.lowercase`")
}

pub fn unqualified_import_is_violation_test() {
  let source =
    "import gleam/string.{lowercase as lower, trim}
pub fn name(value: String) -> String {
  lower(trim(value))
}
"
  let assert [v] = lint.lint_source("src/brazier/other.gleam", source)
    as "the import of lowercase is the violation; trim is not"
  assert v.rule == "unicode-case-folding"
  assert v.location == "1:1"
  assert str_contains(v.message, "the import of `lowercase`")
}

pub fn case_folding_in_a_constant_is_violation_test() {
  let source =
    "import gleam/string
pub const fold = string.lowercase
"
  let assert [v] = lint.lint_source("src/brazier/other.gleam", source)
    as "a constant holding the function is a use"
  assert str_contains(v.message, "in constant `fold`")
}

pub fn other_modules_lowercase_is_not_flagged_test() {
  // `ascii.lowercase` and a local `string` that is not the gleam/string
  // import (here `as _` binds no qualifier) are not Unicode case folding.
  let source =
    "import brazier/internal/ascii
import gleam/string.{trim} as _
pub fn name(value: String) -> String {
  ascii.lowercase(trim(value))
}
"
  let assert [] = lint.lint_source("src/brazier/other.gleam", source)
    as "ASCII folding is the fix, not a violation"
}

pub fn case_folding_outside_src_is_not_checked_test() {
  let source =
    "import gleam/string
pub fn search(query: String) -> String {
  string.lowercase(query)
}
"
  // Tests (an oracle may fold in Unicode) and examples (application code)
  // are not checked.
  let assert [] = lint.lint_source("test/brazier/other_test.gleam", source)
    as "tests may fold in Unicode"
  let assert [] = lint.lint_source("examples/search/src/search.gleam", source)
    as "examples are application code"
}

pub fn allowed_module_with_a_reason_may_fold_in_unicode_test() {
  let source =
    "import gleam/string
pub fn search(query: String) -> String {
  string.lowercase(query)
}
"
  let allowed = [
    lint.CaseFoldingAllowance(
      path: "src/brazier/search.gleam",
      reason: "matches user text without case; the text is Unicode",
    ),
  ]
  let assert [] =
    lint.lint_case_folding("src/brazier/search.gleam", source, allowed)
    as "an allowed module is not flagged"
  // The allowance names one module, not its neighbours.
  let assert [v] =
    lint.lint_case_folding("src/brazier/other.gleam", source, allowed)
    as "a module not on the list is flagged"
  assert v.rule == "unicode-case-folding"
}

pub fn allowance_without_a_reason_is_violation_test() {
  let source =
    "import gleam/string
pub fn search(query: String) -> String {
  string.lowercase(query)
}
"
  let allowed = [
    lint.CaseFoldingAllowance(path: "src/brazier/search.gleam", reason: "  "),
  ]
  let assert [v] =
    lint.lint_case_folding("src/brazier/search.gleam", source, allowed)
    as "an allowance must say why its text is Unicode"
  assert v.rule == "unicode-case-folding"
  assert v.location == "file"
  assert str_contains(v.message, "gives no reason")
}

pub fn case_folding_allow_list_is_empty_test() {
  // Every case folding in src/ folds text that is ASCII by grammar. An
  // entry added here must come with its reason (the rule checks it); this
  // test makes adding one a deliberate change.
  assert lint.case_folding_allowed == []
}

pub fn lint_case_folding_reports_a_parse_error_test() {
  let assert [v] =
    lint.lint_case_folding("src/brazier/other.gleam", "pub fn (", [])
    as "unparseable source is a violation"
  assert v.rule == "parse-error"
}

// --- Helper ---

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "brazier_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool

@external(erlang, "brazier_test_ffi", "unique_ref")
fn unique_ref() -> String
