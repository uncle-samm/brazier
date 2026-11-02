/// The URL policy for attributes that a browser treats as a URL.
///
/// Every URL attribute (`href`, `src`, `action`, `formaction`, `poster`,
/// `cite`, `xlink:href`) is checked when the attribute is built and again
/// when it is rendered. A value whose scheme is not allowed is dropped by
/// the caller, which logs a warning. This follows React's blocking of
/// `javascript:` URLs.
///
/// The module is target-neutral: the client bundle renders through the same
/// code, so the browser applies the same policy.
///
/// Allowed:
/// - relative URLs (no scheme before the first `/`, `?` or `#`);
/// - `http:`, `https:`, `mailto:` and `tel:`;
/// - in `src` only, `data:image/png`, `data:image/gif`, `data:image/jpeg`
///   and `data:image/webp`. `data:image/svg+xml` is never allowed, because
///   an SVG document can run script.
///
/// Remaining hole, by design: `element.unsafe_raw_html` bypasses this check.
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
/// case-insensitive, as HTML attribute names are.
pub fn is_url_attribute(name: String) -> Bool {
  list.contains(url_attributes, string.lowercase(name))
}

/// Check `value` for attribute `name`. Attributes that are not URL
/// attributes always pass. The value is returned unchanged on success: the
/// normalised form is used only to decide.
pub fn check(name: String, value: String) -> Result(String, Blocked) {
  case is_url_attribute(name) {
    False -> Ok(value)
    True -> check_url(string.lowercase(name), value)
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
  let normalised = normalise(value)
  case scheme(normalised) {
    Error(Nil) -> Ok(value)
    Ok("data") ->
      case name == "src" && is_allowed_data(normalised) {
        True -> Ok(value)
        False -> Error(DisallowedData(attribute: name))
      }
    Ok(found) ->
      case list.contains(allowed_schemes, found) {
        True -> Ok(value)
        False -> Error(DisallowedScheme(scheme: found))
      }
  }
}

/// Strip leading and trailing whitespace and control characters, remove
/// tab, CR and LF anywhere, and lowercase. This mirrors what a browser does
/// before it reads the scheme, so `" JaVa\tScRiPt:"` reads as `javascript`.
///
/// The work is done on code points, not graphemes: `"\r\n"` is a single
/// grapheme, and a grapheme-based replace would miss the `\r` inside it.
fn normalise(value: String) -> String {
  value
  |> string.to_utf_codepoints
  |> list.filter(fn(codepoint) { !is_tab_or_newline(codepoint) })
  |> list.drop_while(is_space_or_control)
  |> list.reverse
  |> list.drop_while(is_space_or_control)
  |> list.reverse
  |> string.from_utf_codepoints
  |> string.lowercase
}

fn is_tab_or_newline(codepoint: UtfCodepoint) -> Bool {
  let code = string.utf_codepoint_to_int(codepoint)
  code == 0x09 || code == 0x0a || code == 0x0d
}

/// A C0 control character, space or DEL.
fn is_space_or_control(codepoint: UtfCodepoint) -> Bool {
  let code = string.utf_codepoint_to_int(codepoint)
  code <= 0x20 || code == 0x7f
}

/// The text before the first `:` when that `:` comes before any `/`, `?`
/// or `#`. Otherwise the URL is relative and has no scheme.
fn scheme(normalised: String) -> Result(String, Nil) {
  scan_scheme(string.to_graphemes(normalised), [])
}

fn scan_scheme(rest: List(String), acc: List(String)) -> Result(String, Nil) {
  case rest {
    [] -> Error(Nil)
    [":", ..] -> Ok(acc |> list.reverse |> string.concat)
    ["/", ..] | ["?", ..] | ["#", ..] -> Error(Nil)
    [grapheme, ..tail] -> scan_scheme(tail, [grapheme, ..acc])
  }
}

/// A `data:` URL whose media type, read up to the first `;` or `,`, is an
/// allowed raster image, and which has a `,` before its payload.
fn is_allowed_data(normalised: String) -> Bool {
  let body = string.drop_start(normalised, string.length("data:"))
  let media_type = read_media_type(string.to_graphemes(body), [])
  list.contains(allowed_data_types, media_type) && string.contains(body, ",")
}

fn read_media_type(rest: List(String), acc: List(String)) -> String {
  case rest {
    [] | [";", ..] | [",", ..] -> acc |> list.reverse |> string.concat
    [grapheme, ..tail] -> read_media_type(tail, [grapheme, ..acc])
  }
}
