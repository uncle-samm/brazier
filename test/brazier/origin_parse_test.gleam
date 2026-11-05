//// The Origin and Host parsing of `brazier/transport` splits and trims
//// without compiling a pattern per call (`split_once_bytes`,
//// `trim_whitespace`). These tests hold it to the parser it replaced, which
//// used `string.split`, `string.split_once` and `string.trim`: a copy of
//// that parser (`old_*` below) is run on every combination of a corpus of
//// origin and host pieces, and the two must agree on the decision and the
//// reason. The one difference, a delimiter followed by a combining mark,
//// is tested on its own.

import brazier/transport
import gleam/int
import gleam/list
import gleam/result
import gleam/string

const schemes = ["http", "HTTPS", "https", "ftp", "", "http:", "Http"]

const separators = ["://", ":/", "//", "", ":///", ":"]

const hosts = [
  "localhost", "LocalHost", "", "[::1]", "[", "]", "[]", "[::1", "[::1]x",
  "[::1]:", "a:b", ":", "::", "a@b", "a b", "a?b", "a#b", "a\\b", "\u{00FC}",
  "\u{212A}itchen", "example.com.", "127.0.0.1", "x\r\ny",
]

const ports = ["", ":", ":80", ":8080", ":0", ":65536", ":x", "::80", ":443"]

const paths = ["", "/", "/a", "/a/b", "?q", "#f", "/\u{00E9}"]

const surrounds = ["", " ", "\t", "\u{0085}", "\u{200E}"]

/// An eunit test with a timeout in seconds: `{timeout, Seconds, Fun}`. The
/// corpus is some ten thousand values, each parsed by both parsers.
pub type Timeout {
  Timeout(seconds: Int, test_: fn() -> Nil)
}

/// Every scheme and separator before every authority; every authority
/// with every path after `http://`; and every authority, inside the
/// whitespace a trim takes off or keeps, after `http://`.
fn origin_corpus() -> List(String) {
  let authorities =
    list.flat_map(hosts, fn(host) { list.map(ports, fn(port) { host <> port }) })
  let prefixed =
    list.flat_map(schemes, fn(scheme) {
      list.flat_map(separators, fn(separator) {
        list.map(authorities, fn(authority) { scheme <> separator <> authority })
      })
    })
  let with_paths =
    list.flat_map(authorities, fn(authority) {
      list.map(paths, fn(path) { "http://" <> authority <> path })
    })
  let surrounded =
    list.flat_map(authorities, fn(authority) {
      list.map(surrounds, fn(around) {
        around <> "http://" <> authority <> around
      })
    })
  list.flatten([prefixed, with_paths, surrounded])
}

pub fn origin_check_agrees_with_the_grapheme_parser_test_() -> Timeout {
  use <- Timeout(120)
  let origins = origin_corpus()
  let assert Ok(none) = transport.parse_allowed_origins([])
  list.each(origins, fn(value) {
    let new = transport.origin_allowed(value, "http", "localhost:8080", none)
    let old = old_origin_allowed(value, "http", "localhost:8080")
    let assert True = new == old
      as {
        "origin_parse_test: Origin "
        <> string.inspect(value)
        <> " new "
        <> string.inspect(new)
        <> " old "
        <> string.inspect(old)
      }
    let entry_new =
      transport.parse_allowed_origins([value]) |> result.replace(Nil)
    let entry_old = old_parse_allowed_entry(value)
    let assert True = entry_new == entry_old
      as {
        "origin_parse_test: allowed origin "
        <> string.inspect(value)
        <> " new "
        <> string.inspect(entry_new)
        <> " old "
        <> string.inspect(entry_old)
      }
  })
  // Some of the corpus passes and some is refused for each reason, so the
  // comparison covers every branch of the authority parser.
  let reasons =
    list.filter_map(origins, fn(origin) {
      case transport.origin_allowed(origin, "http", "localhost:8080", none) {
        Ok(Nil) -> Ok("allowed")
        Error(reason) -> Ok(reason_kind(reason))
      }
    })
  list.each(
    [
      "allowed", "Origin mismatch", "invalid Origin: origin has no scheme",
      "invalid Origin: unsupported scheme", "invalid Origin: empty host",
      "invalid Origin: empty IPv6 host", "invalid Origin: malformed IPv6 host",
      "invalid Origin: malformed host", "invalid Origin: invalid port",
      "invalid Origin: invalid characters in host",
      "invalid Origin: non-ASCII characters in host",
    ],
    fn(kind) {
      let assert True = list.contains(reasons, kind)
        as { "origin_parse_test: the corpus never gives " <> kind }
    },
  )
}

pub fn host_check_agrees_with_the_grapheme_parser_test_() -> Timeout {
  use <- Timeout(120)
  let request_hosts =
    list.flat_map(hosts, fn(host) {
      list.flat_map(ports, fn(port) {
        list.map(surrounds, fn(around) { around <> host <> port <> around })
      })
    })
  let assert Ok(none) = transport.parse_allowed_origins([])
  list.each(request_hosts, fn(host) {
    list.each(["http://localhost:8080", "https://localhost"], fn(origin) {
      list.each(["http", "HTTPS", "ws"], fn(scheme) {
        let new = transport.origin_allowed(origin, scheme, host, none)
        let old = old_origin_allowed(origin, scheme, host)
        let assert True = new == old
          as {
            "origin_parse_test: Host "
            <> string.inspect(host)
            <> " scheme "
            <> scheme
            <> " new "
            <> string.inspect(new)
            <> " old "
            <> string.inspect(old)
          }
      })
    })
  })
}

/// A `://` or `/` followed by a combining mark is one grapheme to
/// `string.split`, so the old parser found no delimiter there. The bytes
/// are a delimiter, as they are to a browser's URL parser. Both parsers
/// refuse a combining mark after `://` (for different reasons); a combining
/// mark at the start of the tolerated path is now a path like any other.
pub fn delimiter_before_a_combining_mark_test() {
  let assert Ok(none) = transport.parse_allowed_origins([])
  let assert Error("invalid Origin: origin has no scheme") =
    old_origin_allowed(
      "http://\u{0301}localhost:8080",
      "http",
      "localhost:8080",
    )
  let assert Error(reason) =
    transport.origin_allowed(
      "http://\u{0301}localhost:8080",
      "http",
      "localhost:8080",
      none,
    )
  assert string.starts_with(
    reason,
    "invalid Origin: non-ASCII characters in host",
  )
  let assert Error(_) =
    old_origin_allowed(
      "http://localhost:8080/\u{0301}",
      "http",
      "localhost:8080",
    )
  let assert Ok(Nil) =
    transport.origin_allowed(
      "http://localhost:8080/\u{0301}",
      "http",
      "localhost:8080",
      none,
    )
  // As a path that starts with any other character always was.
  let assert Ok(Nil) =
    old_origin_allowed(
      "http://localhost:8080/a\u{0301}",
      "http",
      "localhost:8080",
    )
  let assert Error(reason) =
    transport.parse_allowed_origins(["https://app.example/\u{0301}"])
  assert string.starts_with(
    reason,
    "ws_allowed_origins entry must not contain a path",
  )
}

/// `trim_whitespace`, the trim of `brazier/transport`, is `string.trim` for
/// every code point up to U+2FFF (past the last whitespace one, U+2029) at
/// the start, at the end and at both, and before a combining mark, which
/// makes a whitespace character part of a grapheme that is not whitespace.
pub fn trim_is_string_trim_test_() -> Timeout {
  use <- Timeout(120)
  list.each(
    int.range(from: 0, to: 0x3000, with: [], run: list.prepend),
    fn(code) {
      let assert Ok(codepoint) = string.utf_codepoint(code)
        as "origin_parse_test: no surrogate is below U+3000"
      let c = string.from_utf_codepoints([codepoint])
      list.each(
        [
          c,
          c <> "host",
          "host" <> c,
          c <> "host" <> c,
          c <> c <> "x" <> c <> c,
          c <> "\u{0301}x",
          "x " <> c,
          c <> " x",
          "\r\n" <> c <> "x" <> c <> "\r\n",
        ],
        fn(text) {
          let assert True = trim_whitespace(text) == string.trim(text)
            as { "origin_parse_test: trim differs on " <> string.inspect(text) }
        },
      )
    },
  )
  // Nothing to trim: the same string comes back.
  assert trim_whitespace("") == ""
  assert trim_whitespace("http://localhost:8080") == "http://localhost:8080"
}

fn reason_kind(reason: String) -> String {
  case reason {
    "invalid Origin: unsupported scheme" <> _ ->
      "invalid Origin: unsupported scheme"
    "invalid Origin: invalid port" <> _ -> "invalid Origin: invalid port"
    "invalid Origin: non-ASCII characters in host" <> _ ->
      "invalid Origin: non-ASCII characters in host"
    other -> other
  }
}

// --- The parser before the byte splits, as it was ---

type OldOrigin {
  OldOrigin(scheme: String, host: String, port: Int, has_path: Bool)
}

fn old_origin_allowed(
  origin: String,
  request_scheme: String,
  request_host: String,
) -> Result(Nil, String) {
  use parsed <- result.try(
    old_parse_origin(origin)
    |> result.map_error(fn(reason) { "invalid Origin: " <> reason }),
  )
  let same = OldOrigin(..parsed, has_path: False)
  let request_scheme = old_ascii_lowercase(request_scheme)
  use port <- result.try(old_default_port(request_scheme))
  use #(host, port) <- result.try(
    old_parse_authority(string.trim(request_host), port)
    |> result.map_error(fn(reason) { "invalid Host: " <> reason }),
  )
  let own =
    OldOrigin(scheme: request_scheme, host: host, port: port, has_path: False)
  case own == same {
    True -> Ok(Nil)
    False -> Error("Origin mismatch")
  }
}

fn old_parse_allowed_entry(entry: String) -> Result(Nil, String) {
  case old_parse_origin(entry) {
    Ok(OldOrigin(has_path: False, ..)) -> Ok(Nil)
    Ok(OldOrigin(has_path: True, ..)) ->
      Error(
        "ws_allowed_origins entry must not contain a path: "
        <> string.inspect(entry),
      )
    Error(reason) ->
      Error(
        "invalid ws_allowed_origins entry "
        <> string.inspect(entry)
        <> ": "
        <> reason,
      )
  }
}

fn old_default_port(scheme: String) -> Result(Int, String) {
  case scheme {
    "http" -> Ok(80)
    "https" -> Ok(443)
    other -> Error("unsupported scheme " <> string.inspect(other))
  }
}

fn old_parse_origin(value: String) -> Result(OldOrigin, String) {
  case string.split_once(string.trim(value), "://") {
    Error(Nil) -> Error("origin has no scheme")
    Ok(#(raw_scheme, rest)) -> {
      let scheme = old_ascii_lowercase(raw_scheme)
      use port <- result.try(old_default_port(scheme))
      let #(authority, has_path) = case string.split_once(rest, "/") {
        Ok(#(authority, _path)) -> #(authority, True)
        Error(Nil) -> #(rest, False)
      }
      use #(host, port) <- result.try(old_parse_authority(authority, port))
      Ok(OldOrigin(scheme: scheme, host: host, port: port, has_path: has_path))
    }
  }
}

fn old_parse_authority(
  authority: String,
  default: Int,
) -> Result(#(String, Int), String) {
  case old_authority_refusal(<<authority:utf8>>) {
    Error(reason) -> Error(reason)
    Ok(Nil) ->
      case authority {
        "" -> Error("empty host")
        "[" <> ipv6_rest ->
          case string.split_once(ipv6_rest, "]") {
            Ok(#("", _)) -> Error("empty IPv6 host")
            Ok(#(address, "")) ->
              Ok(#("[" <> old_ascii_lowercase(address) <> "]", default))
            Ok(#(address, ":" <> port_text)) -> {
              use port <- result.try(old_parse_port(port_text))
              Ok(#("[" <> old_ascii_lowercase(address) <> "]", port))
            }
            _ -> Error("malformed IPv6 host")
          }
        _ ->
          case string.split(authority, ":") {
            [""] | ["", _] -> Error("empty host")
            [host] -> Ok(#(old_ascii_lowercase(host), default))
            [host, port_text] -> {
              use port <- result.try(old_parse_port(port_text))
              Ok(#(old_ascii_lowercase(host), port))
            }
            _ -> Error("malformed host")
          }
      }
  }
}

fn old_authority_refusal(bytes: BitArray) -> Result(Nil, String) {
  case bytes {
    <<byte, rest:bytes>> ->
      case byte {
        0x40 | 0x3f | 0x23 | 0x5c | 0x7f -> Error("invalid characters in host")
        _ if byte <= 0x20 -> Error("invalid characters in host")
        _ if byte >= 0x80 ->
          Error(
            "non-ASCII characters in host (an internationalized name is sent in its ASCII form, xn--)",
          )
        _ -> old_authority_refusal(rest)
      }
    _ -> Ok(Nil)
  }
}

fn old_parse_port(text: String) -> Result(Int, String) {
  case int.parse(text) {
    Ok(port) if port >= 1 && port <= 65_535 -> Ok(port)
    _ -> Error("invalid port " <> string.inspect(text))
  }
}

@external(erlang, "brazier_render_ffi", "ascii_lowercase")
fn old_ascii_lowercase(text: String) -> String

/// The trim `brazier/transport` uses for Origin and Host, which is private
/// there.
@external(erlang, "brazier_transport_ffi", "trim_whitespace")
fn trim_whitespace(text: String) -> String
