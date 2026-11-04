//// The FFI name checks and escapers of `brazier/internal/render` against
//// oracles, on pseudo-random strings that mix ASCII, markup characters and
//// multibyte text. `render_js_test` checks that the JavaScript FFI gives the
//// same results as this one on the same strings.
////
//// The name oracles are the grapheme-based Gleam checks the FFI replaced.
//// The escape oracles replace one code point at a time. They are not the
//// `string.replace` chains the FFI replaced: on Erlang `string.replace` is
//// grapheme-aware, so it left a `"`, `&` or `<` unescaped when a combining
//// mark followed it, which let an attribute value close its quotes.

import brazier/internal/render
import gleam/int
import gleam/list
import gleam/string

// --- Oracles ---

fn oracle_escape(text: String, replacement: fn(Int) -> Result(String, Nil)) {
  text
  |> string.to_utf_codepoints
  |> list.map(fn(codepoint) {
    case replacement(string.utf_codepoint_to_int(codepoint)) {
      Ok(entity) -> entity
      Error(Nil) -> string.from_utf_codepoints([codepoint])
    }
  })
  |> string.concat
}

fn oracle_escape_html(text: String) -> String {
  oracle_escape(text, fn(code) {
    case code {
      0x26 -> Ok("&amp;")
      0x3c -> Ok("&lt;")
      0x3e -> Ok("&gt;")
      _ -> Error(Nil)
    }
  })
}

fn oracle_escape_attr(text: String) -> String {
  oracle_escape(text, fn(code) {
    case code {
      0x26 -> Ok("&amp;")
      0x22 -> Ok("&quot;")
      0x3c -> Ok("&lt;")
      0x3e -> Ok("&gt;")
      _ -> Error(Nil)
    }
  })
}

fn oracle_tag_name(tag: String) -> Bool {
  tag != "" && list.all(string.to_graphemes(tag), oracle_name_grapheme)
}

fn oracle_event_name(name: String) -> Bool {
  name != ""
  && list.all(string.to_graphemes(name), fn(grapheme) {
    grapheme != ":" && grapheme != "." && oracle_name_grapheme(grapheme)
  })
}

fn oracle_name_grapheme(grapheme: String) -> Bool {
  case grapheme {
    "-" | "_" | ":" | "." -> True
    _ ->
      case string.to_utf_codepoints(grapheme) {
        [codepoint] -> {
          let code = string.utf_codepoint_to_int(codepoint)
          { code >= 0x30 && code <= 0x39 }
          || { code >= 0x41 && code <= 0x5a }
          || { code >= 0x61 && code <= 0x7a }
        }
        _ -> False
      }
  }
}

// --- Pseudo-random strings ---

/// Text pieces: plain ASCII, every escaped character, `'` (never escaped),
/// existing entities, two- three- and four-byte UTF-8, combining marks, a
/// CR LF grapheme and a NUL.
pub const text_pieces = [
  "a", "Z", "0", " ", "&", "<", ">", "\"", "'", "&amp;", "&lt;", "é", "ü", "日本",
  "😀", "\u{0E33}", "\u{0301}", "\r\n", "\u{0000}", "=", "/", ";",
]

/// Name pieces: every allowed name character, and characters just outside
/// the allowed ranges (`/`, `@`, `[`, `` ` ``, `{`), whitespace, quotes and
/// non-ASCII letters and marks.
pub const name_pieces = [
  "a", "z", "A", "Z", "0", "9", "-", "_", ":", ".", "/", "@", "[", "`", "{", " ",
  "\"", "=", "é", "\u{0301}", "\u{0E33}", "😀", "\t",
]

/// MINSTD (Park and Miller). The product stays below 2^53, so the sequence
/// is the same on both targets.
fn next(seed: Int) -> Int {
  seed * 48_271 % 2_147_483_647
}

fn random_string(
  seed: Int,
  pieces: List(String),
  max_length: Int,
) -> #(String, Int) {
  let seed = next(seed)
  let length = seed % { max_length + 1 }
  let count = list.length(pieces)
  let #(parts, seed) =
    int.range(from: 0, to: length, with: #([], seed), run: fn(acc, _) {
      let #(parts, seed) = acc
      let seed = next(seed)
      // Invariant: `seed % count` is in 0..count-1, so the piece exists.
      let assert Ok(piece) = list.first(list.drop(pieces, seed % count))
        as "render_test: piece index is in range"
      #([piece, ..parts], seed)
    })
  #(string.concat(parts), seed)
}

/// `count` pseudo-random strings of up to `max_length` pieces each, the same
/// on every run. `render_js_test` uses them too.
pub fn samples(
  pieces: List(String),
  max_length: Int,
  count: Int,
) -> List(String) {
  int.range(from: 0, to: count, with: #([], 7), run: fn(acc, _) {
    let #(found, seed) = acc
    let #(text, seed) = random_string(seed, pieces, max_length)
    #([text, ..found], seed)
  }).0
}

// --- Equivalence ---

pub fn escape_html_matches_oracle_on_random_text_test() {
  let texts = ["", "plain text", ..samples(text_pieces, 40, 3000)]
  list.each(texts, fn(text) {
    let assert True = render.escape_html(text) == oracle_escape_html(text)
      as { "escape_html differs from the oracle on " <> string.inspect(text) }
  })
}

pub fn escape_attr_matches_oracle_on_random_text_test() {
  let texts = ["", "plain text", ..samples(text_pieces, 40, 3000)]
  list.each(texts, fn(text) {
    let assert True = render.escape_attr(text) == oracle_escape_attr(text)
      as { "escape_attr differs from the oracle on " <> string.inspect(text) }
  })
}

pub fn name_checks_match_oracle_on_random_names_test() {
  let names = ["", "div", "my-element", "on", ..samples(name_pieces, 8, 5000)]
  list.each(names, fn(name) {
    let assert True = render.is_valid_tag_name(name) == oracle_tag_name(name)
      as { "is_valid_tag_name differs on " <> string.inspect(name) }
    let assert True =
      render.is_valid_event_name(name) == oracle_event_name(name)
      as { "is_valid_event_name differs on " <> string.inspect(name) }
  })
}

pub fn random_samples_cover_both_outcomes_test() {
  // The equivalence tests above mean little if every sample fell on one
  // side of a check.
  let names = samples(name_pieces, 8, 5000)
  let assert True = list.any(names, render.is_valid_tag_name)
  let assert True =
    list.any(names, fn(name) { !render.is_valid_tag_name(name) })
  let assert True = list.any(names, render.is_valid_event_name)
  let texts = samples(text_pieces, 40, 3000)
  let assert True =
    list.any(texts, fn(text) { render.escape_attr(text) == text && text != "" })
  let assert True =
    list.any(texts, fn(text) { render.escape_attr(text) != text })
}

// --- Fixed cases ---

pub fn escape_html_cases_test() {
  let assert "" = render.escape_html("")
  let assert "no change é 日本" = render.escape_html("no change é 日本")
  let assert "&amp;&lt;&gt;\"'" = render.escape_html("&<>\"'")
  let assert "&amp;amp;" = render.escape_html("&amp;")
  let assert "x&lt;😀&gt;y" = render.escape_html("x<😀>y")
  let assert "a&amp;" = render.escape_html("a&")
  let assert "&lt;a" = render.escape_html("<a")
}

pub fn escape_attr_cases_test() {
  let assert "" = render.escape_attr("")
  let assert "it's" = render.escape_attr("it's")
  let assert "&amp;&quot;&lt;&gt;'" = render.escape_attr("&\"<>'")
  let assert "&quot;&quot;" = render.escape_attr("\"\"")
  let assert "é&quot;" = render.escape_attr("é\"")
}

pub fn escape_does_not_skip_a_character_joined_to_a_combining_mark_test() {
  // `"` + U+0301 is one grapheme. A grapheme-aware replace left the quote
  // as it was, so the value closed its quotes and the rest became
  // attributes.
  let assert "x&quot;\u{0301} onmouseover=alert(1)" =
    render.escape_attr("x\"\u{0301} onmouseover=alert(1)")
  let assert "&amp;\u{0301}lt;" = render.escape_html("&\u{0301}lt;")
  let assert "&lt;\u{0E33}b&gt;\u{0301}" =
    render.escape_html("<\u{0E33}b>\u{0301}")
}

pub fn name_check_cases_test() {
  let assert True = render.is_valid_tag_name("linearGradient")
  let assert True = render.is_valid_tag_name("xlink:href")
  let assert False = render.is_valid_tag_name("dïv")
  let assert False = render.is_valid_tag_name("a\u{0301}")
  let assert False = render.is_valid_tag_name("a b")
  let assert False = render.is_valid_tag_name("a/")
  let assert False = render.is_valid_tag_name("a@")
  let assert False = render.is_valid_tag_name("a[")
  let assert False = render.is_valid_tag_name("a`")
  let assert False = render.is_valid_tag_name("a{")
  let assert True = render.is_valid_event_name("my-event_1")
  let assert False = render.is_valid_event_name("")
  let assert False = render.is_valid_event_name("a:b")
  let assert False = render.is_valid_event_name("a.b")
  let assert False = render.is_valid_event_name("clïck")
}

pub fn attribute_name_policy_test() {
  let assert False = render.is_valid_attribute_name("srcdoc")
  let assert False = render.is_valid_attribute_name("SrcDoc")
  let assert True = render.is_valid_attribute_name("data-srcdoc")
  let assert True = render.is_valid_attribute_name("srcdocs")
  let assert False = render.is_valid_attribute_name("onclick")
  let assert False = render.is_valid_attribute_name("ONCLICK")
  let assert False = render.is_valid_attribute_name("ïd")
}

pub fn attribute_name_href_animation_policy_test() {
  let assert False = render.is_allowed_attribute("attributeName", "href")
  let assert False = render.is_allowed_attribute("attributeName", "xlink:href")
  let assert False = render.is_allowed_attribute("attributename", "HREF")
  let assert False = render.is_allowed_attribute("ATTRIBUTENAME", " href ")
  let assert True = render.is_allowed_attribute("attributeName", "opacity")
  let assert True = render.is_allowed_attribute("attributeName", "")
  // Only `attributeName` is restricted by value.
  let assert True = render.is_allowed_attribute("title", "href")
  let assert True = render.is_allowed_attribute("data-attributename", "href")
  // The name policy still applies.
  let assert False = render.is_allowed_attribute("srcdoc", "x")
  let assert False = render.is_allowed_attribute("onload", "x")
}
