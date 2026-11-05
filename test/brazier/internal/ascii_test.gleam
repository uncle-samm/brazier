import brazier/internal/ascii
import gleam/int
import gleam/list
import gleam/string

pub fn lowercase_folds_ascii_letters_only_test() {
  assert ascii.lowercase("Content-Type") == "content-type"
  assert ascii.lowercase("ABCXYZ@[`{") == "abcxyz@[`{"
  assert ascii.lowercase("already lower 09") == "already lower 09"
  assert ascii.lowercase("") == ""
}

/// The two characters outside ASCII whose Unicode lowercase is ASCII stay
/// as they are, so a Kelvin sign never reads as a `k`, nor a dotted capital
/// I as an `i`.
pub fn lowercase_keeps_characters_outside_ascii_test() {
  assert ascii.lowercase("\u{212A}EEP-ALIVE") == "\u{212A}eep-alive"
  assert ascii.lowercase("\u{0130}D") == "\u{0130}d"
  assert ascii.lowercase("\u{00C0}B") == "\u{00C0}b"
  assert ascii.lowercase("\u{212A}eep-alive") != "keep-alive"
  assert string.lowercase("\u{212A}eep-alive") == "keep-alive"
}

pub fn lowercase_code_folds_ascii_letters_only_test() {
  assert ascii.lowercase_code(0x41) == 0x61
  assert ascii.lowercase_code(0x5a) == 0x7a
  assert ascii.lowercase_code(0x40) == 0x40
  assert ascii.lowercase_code(0x5b) == 0x5b
  assert ascii.lowercase_code(0x61) == 0x61
  assert ascii.lowercase_code(0x212a) == 0x212a
  assert ascii.lowercase_code(0x130) == 0x130
}

/// The code point folding and the string folding agree on every code point
/// up to U+2FFF (ASCII, Latin, and the Kelvin sign's block), so the URL
/// parser and the rest of the server fold the same way.
pub fn lowercase_code_agrees_with_lowercase_test() {
  int.range(from: 1, to: 0x3000, with: Nil, run: fn(_, code) {
    case string.utf_codepoint(code) {
      Ok(codepoint) -> {
        let text = string.from_utf_codepoints([codepoint])
        let assert Ok(folded) = string.utf_codepoint(ascii.lowercase_code(code))
          as "ascii_test: a folded code point is a code point"
        let assert True =
          ascii.lowercase(text) == string.from_utf_codepoints([folded])
          as { "ascii_test: code point " <> string.inspect(code) }
        Nil
      }
      // Surrogates are not code points a string can hold.
      Error(Nil) -> Nil
    }
  })
}

pub fn is_token_accepts_tchars_test() {
  assert ascii.is_token("Content-Type")
  assert ascii.is_token("x")
  assert ascii.is_token("0")
  assert ascii.is_token("!#$%&'*+-.^_`|~")
  list.each(string.to_graphemes("!#$%&'*+-.^_`|~"), fn(special) {
    let assert True = ascii.is_token("a" <> special <> "z")
      as { "ascii_test: " <> special <> " is a tchar" }
  })
}

pub fn is_token_refuses_delimiters_controls_and_non_ascii_test() {
  assert !ascii.is_token("")
  assert !ascii.is_token("Content Type")
  assert !ascii.is_token("Content-Type ")
  list.each(string.to_graphemes("\"(),/:;<=>?@[\\]{}"), fn(delimiter) {
    let assert False = ascii.is_token("a" <> delimiter <> "z")
      as { "ascii_test: " <> delimiter <> " is a delimiter" }
  })
  assert !ascii.is_token("a\u{0000}z")
  assert !ascii.is_token("a\tz")
  assert !ascii.is_token("a\u{001F}z")
  assert !ascii.is_token("a\u{007F}z")
  assert !ascii.is_token("\u{212A}eep-alive")
  assert !ascii.is_token("caf\u{00E9}")
  assert !ascii.is_token("a\u{0080}")
}
