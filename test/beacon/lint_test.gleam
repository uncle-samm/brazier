import beacon/lint
import gleam/list

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
  let violations = lint.lint_source("src/beacon/other.gleam", source)
  let assert [v] = violations
  let assert "src/beacon/other.gleam" = v.file
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
  let violations = lint.lint_source("src/beacon/transport.gleam", source)
  let assert [v] = violations
  let assert "public-fn-must-log" = v.rule
}

pub fn public_fn_with_log_passes_test() {
  let source =
    "
import beacon/log
pub fn handle() { log.info(\"mod\", \"msg\") }
"
  let violations = lint.lint_source("src/beacon/runtime.gleam", source)
  let assert [] = violations
}

pub fn private_fn_not_checked_for_log_test() {
  let source =
    "
fn helper() { Nil }
"
  let violations = lint.lint_source("src/beacon/transport.gleam", source)
  let assert [] = violations
}

pub fn non_key_module_not_checked_for_log_test() {
  let source =
    "
pub fn handle() { Nil }
"
  let violations = lint.lint_source("src/beacon/form.gleam", source)
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
  let violations = lint.lint_source("src/beacon/other.gleam", source)
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
  let violations = lint.lint_source("src/beacon/other.gleam", source)
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
  let assert [] = lint.lint_source("src/beacon/other.gleam", source)
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
  let assert [v] = lint.lint_source("src/beacon/other.gleam", source)
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
  let assert [_] = lint.lint_source("src/beacon/other.gleam", source)
}

pub fn discard_outside_src_is_not_checked_test() {
  let source =
    "
pub fn save() {
  let _ = write()
  Nil
}
"
  let assert [] = lint.lint_source("test/beacon/other_test.gleam", source)
}

pub fn let_assert_discard_is_not_flagged_test() {
  let source =
    "
pub fn save() {
  let assert Ok(_) = write()
  Nil
}
"
  let assert [] = lint.lint_source("src/beacon/other.gleam", source)
}

pub fn removed_router_api_phrase_is_violation_test() {
  let source =
    "
pub fn note() -> String {
  \"beacon.router is not a supported API\"
}
"
  let violations = lint.lint_source("src/beacon/bad_route_doc.gleam", source)
  let assert [v] = violations
  let assert "no-degraded-path-phrases" = v.rule
}

pub fn low_level_route_api_in_example_is_violation_test() {
  let source =
    "
import beacon

pub fn start() {
  beacon.app(fn() { 1 }, fn(m, _msg) { m }, fn(m) { m })
  |> beacon.routes([\"/\"])
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

// --- Helper ---

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool
