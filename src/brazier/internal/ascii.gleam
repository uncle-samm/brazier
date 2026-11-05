//// ASCII case folding and the token check for protocol text.
////
//// HTTP field names, tokens and media types (RFC 9110 §5.1, §5.6.2,
//// §8.3.1), URI schemes and hosts (RFC 3986 §3.1, §3.2.2), cookie names
//// (RFC 6265 §4.1.1) and HTML attribute names are ASCII by their grammars,
//// and each compares case-insensitively in ASCII only.
////
//// `string.lowercase` is not used for them. It lowercases in Unicode,
//// where the Kelvin sign U+212A becomes `k`, so `"\u{212A}eep-alive"` would
//// compare equal to `keep-alive`, a token no HTTP peer reads that way. On
//// Erlang it is also slow: OTP's `string:lowercase/1` raises and catches an
//// exception internally for each string that is already lowercase.
////
//// The module is target-neutral, because the client bundle renders through
//// `brazier/internal/url`, which uses it.

/// `text` with `A-Z` lowercased and every other byte (UTF-16 code unit on
/// JavaScript) unchanged. A character outside ASCII is kept as it is, so
/// a string holding one never equals an ASCII string it does not already
/// equal. Text with no `A-Z` is returned without a copy.
///
/// This is the one ASCII folding on each target (`brazier_ascii_ffi`); the
/// render folds every attribute name of every render with it, so it scans
/// bytes (code units) in the FFI rather than walking a `BitArray` here.
@external(erlang, "brazier_ascii_ffi", "lowercase")
@external(javascript, "../../brazier_ascii_ffi.mjs", "lowercase")
pub fn lowercase(text: String) -> String

/// `code` lowercased if it is `A-Z`, and unchanged otherwise: the same
/// folding as `lowercase`, for a parser that reads code points one at a
/// time (the URL scheme and `data:` media type in `brazier/internal/url`).
/// No code point outside ASCII turns into a letter.
pub fn lowercase_code(code: Int) -> Int {
  case code >= 0x41 && code <= 0x5a {
    True -> code + 0x20
    False -> code
  }
}

/// Whether `text` is an RFC 9110 token (§5.6.2): one or more of the
/// visible ASCII characters other than the delimiters `"(),/:;<=>?@[\]{}`.
/// Field names are tokens, so a name holding a space, a control character
/// or any character outside ASCII is not one.
pub fn is_token(text: String) -> Bool {
  text != "" && token_bytes(<<text:utf8>>)
}

fn token_bytes(bytes: BitArray) -> Bool {
  case bytes {
    <<byte, rest:bytes>> ->
      case is_token_byte(byte) {
        True -> token_bytes(rest)
        False -> False
      }
    _ -> {
      // Invariant: the bytes are a string's UTF-8 encoding, which is whole
      // bytes, so what is left past the last byte is nothing.
      let assert <<>> = bytes
        as "brazier/internal/ascii: a string's bytes are whole bytes"
      True
    }
  }
}

/// tchar (RFC 9110 §5.6.2): ALPHA, DIGIT and ``!#$%&'*+-.^_`|~``.
fn is_token_byte(byte: Int) -> Bool {
  case byte {
    _ if byte >= 0x61 && byte <= 0x7a -> True
    _ if byte >= 0x41 && byte <= 0x5a -> True
    _ if byte >= 0x30 && byte <= 0x39 -> True
    0x21 | 0x23 | 0x24 | 0x25 | 0x26 | 0x27 | 0x2a | 0x2b | 0x2d | 0x2e -> True
    0x5e | 0x5f | 0x60 | 0x7c | 0x7e -> True
    _ -> False
  }
}
