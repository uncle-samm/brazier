/// Source locations for build-time diagnostics.
///
/// Glance reports positions as byte offsets. People read line and column
/// numbers, so every build and lint diagnostic converts offsets here before
/// it is shown.
import glance
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import glexer/token

/// A 1-based line and column within a source file.
pub type LineCol {
  LineCol(line: Int, column: Int)
}

/// Convert a byte offset into a 1-based line and column.
/// Offsets past the end of the source clamp to the end, because glance can
/// report the position just after the last token.
pub fn line_col(source: String, byte_offset: Int) -> LineCol {
  let bytes = <<source:utf8>>
  let size = bit_array.byte_size(bytes)
  let offset = int.clamp(byte_offset, 0, size)
  // Invariant: offset is clamped to [0, size], so the slice always exists.
  let assert Ok(prefix_bytes) = bit_array.slice(bytes, 0, offset)
  let prefix = case bit_array.to_string(prefix_bytes) {
    Ok(text) -> text
    // The offset falls inside a multi-byte code point. Walk back to the
    // nearest valid boundary so the column still points at that character.
    Error(Nil) -> valid_prefix(prefix_bytes)
  }
  let lines = string.split(prefix, "\n")
  // Invariant: string.split always returns at least one element.
  let assert Ok(last) = list.last(lines)
  LineCol(line: list.length(lines), column: string.length(last) + 1)
}

fn valid_prefix(bytes: BitArray) -> String {
  let size = bit_array.byte_size(bytes)
  case size {
    0 -> ""
    _ -> {
      // Invariant: size > 0, so a slice of size - 1 bytes always exists.
      let assert Ok(shorter) = bit_array.slice(bytes, 0, size - 1)
      case bit_array.to_string(shorter) {
        Ok(text) -> text
        Error(Nil) -> valid_prefix(shorter)
      }
    }
  }
}

/// Format a byte offset as `line:column`.
pub fn format_offset(source: String, byte_offset: Int) -> String {
  let LineCol(line:, column:) = line_col(source, byte_offset)
  int.to_string(line) <> ":" <> int.to_string(column)
}

/// Format a glance span as `line:column` of its start.
pub fn format_span(source: String, span: glance.Span) -> String {
  format_offset(source, span.start)
}

/// Return the full text of the line that precedes the line holding
/// `byte_offset`, or `Error(Nil)` when the offset is on the first line.
pub fn previous_line(source: String, byte_offset: Int) -> Result(String, Nil) {
  let LineCol(line:, ..) = line_col(source, byte_offset)
  case line {
    1 -> Error(Nil)
    _ ->
      source
      |> string.split("\n")
      |> list.drop(line - 2)
      |> list.first
  }
}

/// Describe a glance parse error with the file path, location and the
/// offending token, e.g. `src/app.gleam:3:7: unexpected token "="`.
pub fn describe_parse_error(
  path: String,
  source: String,
  error: glance.Error,
) -> String {
  case error {
    glance.UnexpectedEndOfInput ->
      path
      <> ":"
      <> format_offset(source, string.byte_size(source))
      <> ": unexpected end of input"
    glance.UnexpectedToken(token: tok, position: position) ->
      path
      <> ":"
      <> format_offset(source, position.byte_offset)
      <> ": unexpected token "
      <> string.inspect(token.to_source(tok))
  }
}
