/// The URL policy for attributes that a browser treats as a URL.
///
/// Every URL attribute (`href`, `src`, `action`, `formaction`, `poster`,
/// `cite`, `xlink:href`) is checked when the attribute is built and again
/// when it is rendered. A value whose scheme is not allowed is dropped by
/// the caller, which logs a warning. This follows React's blocking of
/// `javascript:` URLs.
///
/// The scheme is read the way the WHATWG URL parser reads it, one code
/// point at a time, so the policy sees the same scheme the browser does.
///
/// The module is target-neutral: the client bundle renders through the same
/// code, so the browser applies the same policy.
///
/// Allowed:
/// - relative URLs (no scheme: the value does not start with an ASCII
///   letter followed by letters, digits, `+`, `-` or `.` up to a `:`);
/// - `http:`, `https:`, `mailto:` and `tel:`;
/// - in `src` only, `data:image/png`, `data:image/gif`, `data:image/jpeg`
///   and `data:image/webp`. `data:image/svg+xml` is never allowed, because
///   an SVG document can run script.
///
/// Remaining hole, by design: `element.unsafe_raw_html` bypasses this check.
import brazier/internal/ascii
import gleam/list
import gleam/string

/// Why a URL value was refused.
pub type Blocked {
  /// The value names a scheme outside the allowlist (e.g. `javascript`).
  DisallowedScheme(scheme: String)
  /// A `data:` URL whose media type is not an allowed raster image, or a
  /// `data:` URL in an attribute other than `src`.
  DisallowedData(attribute: String)
}

const url_attributes = [
  "href", "src", "action", "formaction", "poster", "cite", "xlink:href",
]

const allowed_schemes = ["http", "https", "mailto", "tel"]

const allowed_data_types = ["image/png", "image/gif", "image/jpeg", "image/webp"]

/// The longest value prefix a log line may contain.
const log_value_limit = 64

/// Whether the browser interprets attribute `name` as a URL. The match is
/// ASCII case-insensitive, as the HTML parser's is: it lowercases `A-Z` in
/// an attribute name and leaves every other character as it is (WHATWG
/// HTML, "attribute name state"), so `XLink:Href` is `xlink:href` and a
/// name holding a non-ASCII character, such as the Kelvin sign U+212A that
/// Unicode lowercases to `k`, never is a URL attribute.
pub fn is_url_attribute(name: String) -> Bool {
  list.contains(url_attributes, ascii.lowercase(name))
}

/// Check `value` for attribute `name`. Attributes that are not URL
/// attributes always pass. The value is returned unchanged on success: the
/// normalised form is used only to decide.
pub fn check(name: String, value: String) -> Result(String, Blocked) {
  let lower = ascii.lowercase(name)
  case list.contains(url_attributes, lower) {
    False -> Ok(value)
    True -> check_url(lower, value)
  }
}

/// A short, printable description of a refusal for log lines.
pub fn describe(blocked: Blocked) -> String {
  case blocked {
    DisallowedScheme(scheme:) -> "scheme `" <> scheme <> ":` is not allowed"
    DisallowedData(attribute: "src") ->
      "only data:image/png, gif, jpeg and webp are allowed"
    DisallowedData(attribute:) ->
      "data: URLs are not allowed in `" <> attribute <> "`"
  }
}

/// The first characters of `value`, for a log line.
pub fn truncate_for_log(value: String) -> String {
  case string.length(value) > log_value_limit {
    True -> string.slice(value, 0, log_value_limit) <> "..."
    False -> value
  }
}

fn check_url(name: String, value: String) -> Result(String, Blocked) {
  case scheme(normalise(value)) {
    Error(Nil) -> Ok(value)
    Ok(#("data", body)) ->
      case name == "src" && is_allowed_data(body) {
        True -> Ok(value)
        False -> Error(DisallowedData(attribute: name))
      }
    Ok(#(found, _body)) ->
      case list.contains(allowed_schemes, found) {
        True -> Ok(value)
        False -> Error(DisallowedScheme(scheme: found))
      }
  }
}

/// The value's code points with leading and trailing whitespace and control
/// characters stripped and tab, CR and LF removed anywhere. This mirrors
/// what a browser does before it reads the scheme, so `" java\tscript:"`
/// reads as `javascript`.
///
/// The work is done on code points, not graphemes. A grapheme can join a
/// character the browser reads on its own to the marks after it: `"\r\n"`
/// is one grapheme, and so is `:` followed by a combining mark such as
/// U+0E33, which would hide the scheme separator.
fn normalise(value: String) -> List(Int) {
  value
  |> string.to_utf_codepoints
  |> list.map(string.utf_codepoint_to_int)
  |> list.filter(fn(code) { !is_tab_or_newline(code) })
  |> list.drop_while(is_space_or_control)
  |> list.reverse
  |> list.drop_while(is_space_or_control)
  |> list.reverse
}

fn is_tab_or_newline(code: Int) -> Bool {
  code == 0x09 || code == 0x0a || code == 0x0d
}

/// A C0 control character, space or DEL.
fn is_space_or_control(code: Int) -> Bool {
  code <= 0x20 || code == 0x7f
}

/// The scheme, lowercased, and the code points after its `:`, read the way
/// the WHATWG URL parser's scheme start state and scheme state read it: an
/// ASCII letter, then ASCII letters, digits, `+`, `-` or `.`, up to a `:`.
/// Any other code point before the `:` (including a `/`, `?` or `#`) means
/// the URL has no scheme and is relative.
///
/// Reference: WHATWG URL Standard, "scheme start state" and "scheme state".
fn scheme(codes: List(Int)) -> Result(#(String, List(Int)), Nil) {
  case codes {
    [first, ..rest] ->
      case is_ascii_alpha(first) {
        True -> scan_scheme(rest, [ascii_lowercase_code(first)])
        False -> Error(Nil)
      }
    [] -> Error(Nil)
  }
}

fn scan_scheme(
  rest: List(Int),
  acc: List(Int),
) -> Result(#(String, List(Int)), Nil) {
  case rest {
    [] -> Error(Nil)
    [0x3a, ..body] -> Ok(#(ascii_to_string(list.reverse(acc)), body))
    [code, ..tail] ->
      case is_scheme_code(code) {
        True -> scan_scheme(tail, [ascii_lowercase_code(code), ..acc])
        False -> Error(Nil)
      }
  }
}

fn is_scheme_code(code: Int) -> Bool {
  is_ascii_alpha(code)
  || { code >= 0x30 && code <= 0x39 }
  || code == 0x2b
  || code == 0x2d
  || code == 0x2e
}

fn is_ascii_alpha(code: Int) -> Bool {
  { code >= 0x41 && code <= 0x5a } || { code >= 0x61 && code <= 0x7a }
}

/// Lowercase an ASCII letter. Every other code point is unchanged: the URL
/// parser lowercases schemes in ASCII only, so no non-ASCII code point may
/// turn into a letter here.
fn ascii_lowercase_code(code: Int) -> Int {
  case code >= 0x41 && code <= 0x5a {
    True -> code + 0x20
    False -> code
  }
}

fn ascii_to_string(codes: List(Int)) -> String {
  codes
  |> list.map(fn(code) {
    // Invariant: `scan_scheme` only accumulates ASCII letters, digits, `+`,
    // `-` and `.`, which are all valid code points.
    let assert Ok(codepoint) = string.utf_codepoint(code)
      as "brazier/internal/url: scheme code points are ASCII"
    codepoint
  })
  |> string.from_utf_codepoints
}

/// Whether the body of a `data:` URL (the code points after `data:`) is
/// allowed: its media type, read up to the first `;` or `,` and lowercased
/// in ASCII only, is an allowed raster image, and a `,` comes before its
/// payload.
fn is_allowed_data(body: List(Int)) -> Bool {
  let media_type = read_media_type(body, [])
  list.contains(body, 0x2c)
  && list.any(allowed_data_types, fn(allowed) {
    media_type
    == list.map(string.to_utf_codepoints(allowed), string.utf_codepoint_to_int)
  })
}

fn read_media_type(rest: List(Int), acc: List(Int)) -> List(Int) {
  case rest {
    [] | [0x3b, ..] | [0x2c, ..] -> list.reverse(acc)
    [code, ..tail] -> read_media_type(tail, [ascii_lowercase_code(code), ..acc])
  }
}
