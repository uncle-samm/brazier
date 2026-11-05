//// `brazier/internal/wire_decode` reads the wire format the same way on
//// Erlang (the server codec) and JavaScript (the client entry), with the
//// errors `gleam/dynamic/decode` reports for the same value.
////
//// The cases are in `wire_decode_cases`. The JavaScript run writes a small
//// JavaScript-target project in `build/brazier_wire_decode_js_check` with
//// copies of `wire_decode.gleam`, its `.mjs` FFI and the cases module, as
//// the client build copies them, and runs it under node.

import brazier/build/files
import brazier/build/program
import brazier/internal/wire_decode
import brazier/internal/wire_decode_cases.{Erlang}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/string

const project = "build/brazier_wire_decode_js_check"

/// An eunit test with a timeout in seconds: `{timeout, Seconds, Fun}`. The
/// first run compiles the standard library for JavaScript.
pub type Timeout {
  Timeout(seconds: Int, test_: fn() -> Nil)
}

pub fn erlang_cases_test() {
  let failures = wire_decode_cases.check_all(Erlang)
  let assert [] = failures
    as {
      "wire_decode_test: Erlang cases failed:\n  "
      <> string.join(failures, "\n  ")
    }
  // The cases cover failures as well as values that decode.
  let assert True =
    list.any(wire_decode_cases.cases(), fn(case_) {
      string.starts_with(case_.expected, "error:")
    })
  let assert True =
    list.any(wire_decode_cases.cases(), fn(case_) {
      string.starts_with(case_.expected, "ok:")
    })
}

pub fn javascript_cases_test_() -> Timeout {
  Timeout(180, fn() {
    write_project()
    let assert Ok(output) =
      program.run(project, "gleam", ["run", "-m", "wire_decode_js_check"])
      as "wire_decode_test: the JavaScript check project runs"
    let assert True = string.contains(output, "WIRE JS DONE")
      as "wire_decode_test: the check program finished"
    let failures =
      output
      |> string.split("\n")
      |> list.filter_map(fn(line) {
        case line {
          "F:" <> failure -> Ok(failure)
          _ -> Error(Nil)
        }
      })
    let assert [] = failures
      as {
        "wire_decode_test: JavaScript cases failed:\n  "
        <> string.join(failures, "\n  ")
      }
    Nil
  })
}

/// A tuple element index outside the tuple is a bug in the generated
/// decoder, not bad input: it crashes instead of reporting a decode error.
pub fn element_index_outside_the_tuple_crashes_test() {
  let data = dynamic.list([dynamic.int(1), dynamic.int(2)])
  let assert Ok(Ok(2)) =
    rescue(fn() { wire_decode.element(data, 1, 2, wire_decode.int) })
  let assert Error(#("error", _)) =
    rescue(fn() { wire_decode.element(data, 2, 2, wire_decode.int) })
  let assert Error(#("error", _)) =
    rescue(fn() { wire_decode.element(data, -1, 2, wire_decode.int) })
  Nil
}

/// `failure` reports what was found the way `dynamic.classify` names it.
pub fn failure_classifies_the_value_test() {
  let decode_error = wire_decode.failure("Int", dynamic.string("seven"))
  let assert "Int" = decode_error.expected
  let assert "String" = decode_error.found
  let assert [] = decode_error.path
  Nil
}

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, Dynamic))

fn write_project() -> Nil {
  let copy = fn(from) {
    let assert Ok(text) = files.read(from)
      as "wire_decode_test: the framework sources are readable"
    text
  }
  let sources = [
    #("gleam.toml", gleam_toml),
    #(
      "src/brazier/internal/wire_decode.gleam",
      copy("src/brazier/internal/wire_decode.gleam"),
    ),
    #(
      "src/brazier_wire_decode_ffi.mjs",
      copy("src/brazier_wire_decode_ffi.mjs"),
    ),
    #(
      "src/brazier/internal/wire_decode_cases.gleam",
      copy("test/brazier/internal/wire_decode_cases.gleam"),
    ),
    #("src/wire_decode_js_check.gleam", check_source),
  ]
  list.each(sources, fn(file) {
    let assert Ok(_written) =
      files.write_if_changed(project <> "/" <> file.0, file.1)
      as "wire_decode_test: the check project is writable"
  })
}

const gleam_toml =
  "name = \"wire_decode_js_check\"
version = \"0.1.0\"
target = \"javascript\"

[dependencies]
gleam_stdlib = { path = \"../packages/gleam_stdlib\" }
gleam_json = { path = \"../packages/gleam_json\" }
"

const check_source =
  "import brazier/internal/wire_decode_cases.{Javascript}
import gleam/io
import gleam/list

pub fn main() -> Nil {
  list.each(wire_decode_cases.check_all(Javascript), fn(failure) {
    io.println(\"F:\" <> failure)
  })
  io.println(\"WIRE JS DONE\")
}
"
