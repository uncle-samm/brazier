//// The JavaScript FFI of `brazier/internal/render` and the URL policy of
//// `brazier/internal/url` give the same results on JavaScript as on Erlang.
////
//// The browser renders the view with the same modules after the server
//// rendered it with the Erlang FFI. A difference between the targets is a
//// broken page at best, and at worst a name, escape or URL the server
//// refused that the client lets through.
////
//// The test writes a small JavaScript-target project in
//// `build/brazier_render_js_check` with copies of `render.gleam` (and the
//// `stream_op.gleam` it imports), `url.gleam`, `brazier_render_ffi.mjs` and
//// the client `brazier/log` shim,
//// as the client build copies them. It writes the inputs (the pseudo-random
//// strings of `render_test` plus URL payloads), runs the project under node,
//// and compares every result with the Erlang one. It needs `node`, like the
//// client build.

import brazier/build/client_shim
import brazier/build/files
import brazier/build/program
import brazier/internal/render
import brazier/internal/render_test
import brazier/internal/url
import gleam/int
import gleam/list
import gleam/string

const project = "build/brazier_render_js_check"

/// An eunit test with a timeout in seconds: `{timeout, Seconds, Fun}`. The
/// first run compiles the standard library for JavaScript.
pub type Timeout {
  Timeout(seconds: Int, test_: fn() -> Nil)
}

/// URL values around the scheme parser: case, control characters, combining
/// marks after the colon, non-ASCII in the scheme, data media types.
const url_payloads = [
  "", "/relative", "https://example.com/a?b=c", "JaVaScRiPt:alert(1)",
  " \t\njavascript:alert(1)", "\u{0000}javascript:alert(1)",
  "java\tscript:alert(1)", "java\r\nscript:alert(1)",
  "javascript:\u{0E33}alert(1)", "javascript:\u{0EB3}alert(1)",
  "javascript:\u{1885}alert(1)", "javascript:\u{1886}alert(1)",
  "javascript:\u{FF9E}alert(1)", "javascript:\u{FF9F}alert(1)",
  "javascript\u{0301}:alert(1)", "j\u{0301}avascript:alert(1)",
  "\u{00A0}javascript:alert(1)", "vbscript:msgbox(1)", "ms-msdt:x",
  "data:text/html,<script>alert(1)</script>", "data:\u{0E33}image/png,AA",
  "data:image/png;base64,AA", "data:IMAGE/PNG,AA", "data:image/png", "1http:x",
  "java script:x", "A+B.C:x", "\u{212A}http:x", "mailto:a@b.c",
]

pub fn javascript_ffi_matches_erlang_test_() -> Timeout {
  Timeout(180, fn() {
    let inputs =
      list.flatten([
        url_payloads,
        render_test.attribute_names,
        render_test.samples(render_test.text_pieces, 40, 1000),
        render_test.samples(render_test.name_pieces, 8, 1000),
      ])
    write_project(inputs)
    let assert Ok(output) =
      program.run(project, "gleam", ["run", "-m", "render_js_check"])
      as "render_js_test: the JavaScript check project runs"
    let results =
      output
      |> string.split("\n")
      |> list.filter_map(fn(line) {
        case line {
          "R:" <> result -> Ok(result)
          _ -> Error(Nil)
        }
      })
    let assert True = string.contains(output, "RENDER JS DONE")
      as "render_js_test: the check program finished"
    let assert True = list.length(results) == list.length(inputs)
      as "render_js_test: one result per input"
    list.each(list.zip(inputs, results), fn(pair) {
      let #(input, js) = pair
      let erlang = check(input)
      let assert True = js == erlang
        as {
          "render_js_test: the targets differ on "
          <> string.inspect(input)
          <> "\n  erlang: "
          <> erlang
          <> "\n  javascript: "
          <> js
        }
    })
    // The comparison covers refusals as well as values that pass.
    let assert True =
      list.any(url_payloads, fn(payload) {
        string.ends_with(check(payload), "error;error")
      })
    Nil
  })
}

/// Every result for one input, joined. The check program in the project
/// computes the same line; keep the two in step.
pub fn check(input: String) -> String {
  [
    encode(render.escape_html(input)),
    encode(render.escape_attr(input)),
    bool(render.is_valid_tag_name(input)),
    bool(render.is_valid_event_name(input)),
    bool(render.is_valid_attribute_name(input)),
    bool(render.is_allowed_attribute("attributeName", input)),
    bool(render.is_allowed_attribute(input, "x")),
    url_result(url.check("href", input)),
    url_result(url.check("src", input)),
  ]
  |> string.join(";")
}

fn url_result(result: Result(String, url.Blocked)) -> String {
  case result {
    Ok(value) -> "ok:" <> encode(value)
    Error(_) -> "error"
  }
}

fn bool(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

/// A string as comma-separated code points, so that control characters and
/// newlines survive the line-based exchange.
pub fn encode(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.map(fn(codepoint) {
    int.to_string(string.utf_codepoint_to_int(codepoint))
  })
  |> string.join(",")
}

fn write_project(inputs: List(String)) -> Nil {
  let copy = fn(from) {
    let assert Ok(text) = files.read(from)
      as "render_js_test: the framework sources are readable"
    text
  }
  let sources = [
    #("gleam.toml", gleam_toml),
    #(
      "src/brazier/internal/render.gleam",
      copy("src/brazier/internal/render.gleam"),
    ),
    #("src/brazier/internal/url.gleam", copy("src/brazier/internal/url.gleam")),
    #(
      "src/brazier/internal/stream_op.gleam",
      copy("src/brazier/internal/stream_op.gleam"),
    ),
    #("src/brazier_render_ffi.mjs", copy("src/brazier_render_ffi.mjs")),
    #("src/brazier/log.gleam", client_shim.log_module),
    #("src/render_js_check.gleam", check_source),
    #("src/render_js_check_ffi.mjs", check_ffi_source),
    #("inputs.txt", string.join(list.map(inputs, encode), "\n")),
  ]
  list.each(sources, fn(file) {
    let assert Ok(_written) =
      files.write_if_changed(project <> "/" <> file.0, file.1)
      as "render_js_test: the check project is writable"
  })
}

const gleam_toml =
  "name = \"render_js_check\"
version = \"0.1.0\"
target = \"javascript\"

[dependencies]
gleam_stdlib = { path = \"../packages/gleam_stdlib\" }
"

const check_ffi_source =
  "import { readFileSync } from \"node:fs\";

export function read_inputs() {
  return readFileSync(\"inputs.txt\", \"utf8\");
}
"

const check_source =
  "import brazier/internal/render
import brazier/internal/url
import gleam/int
import gleam/io
import gleam/list
import gleam/string

@external(javascript, \"./render_js_check_ffi.mjs\", \"read_inputs\")
fn read_inputs() -> String

pub fn main() -> Nil {
  read_inputs()
  |> string.split(\"\\n\")
  |> list.each(fn(line) { io.println(\"R:\" <> check(decode(line))) })
  io.println(\"RENDER JS DONE\")
}

fn check(input: String) -> String {
  [
    encode(render.escape_html(input)),
    encode(render.escape_attr(input)),
    bool(render.is_valid_tag_name(input)),
    bool(render.is_valid_event_name(input)),
    bool(render.is_valid_attribute_name(input)),
    bool(render.is_allowed_attribute(\"attributeName\", input)),
    bool(render.is_allowed_attribute(input, \"x\")),
    url_result(url.check(\"href\", input)),
    url_result(url.check(\"src\", input)),
  ]
  |> string.join(\";\")
}

fn url_result(result: Result(String, url.Blocked)) -> String {
  case result {
    Ok(value) -> \"ok:\" <> encode(value)
    Error(_) -> \"error\"
  }
}

fn bool(value: Bool) -> String {
  case value {
    True -> \"true\"
    False -> \"false\"
  }
}

fn encode(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.map(fn(codepoint) {
    int.to_string(string.utf_codepoint_to_int(codepoint))
  })
  |> string.join(\",\")
}

fn decode(line: String) -> String {
  line
  |> string.split(\",\")
  |> list.filter(fn(part) { part != \"\" })
  |> list.map(fn(part) {
    let assert Ok(code) = int.parse(part) as \"inputs are integers\"
    let assert Ok(codepoint) = string.utf_codepoint(code)
      as \"inputs are code points\"
    codepoint
  })
  |> string.from_utf_codepoints
}
"
