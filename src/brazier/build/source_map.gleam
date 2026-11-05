/// Positions in the client project's sliced copy of a module, mapped back to
/// the module's own source file.
///
/// The client build copies each reached definition of a module byte for
/// byte, in source order (`reach.emit`), and writes the rest of the copy
/// itself: the imports the definitions use, an `@external(javascript, ...)`
/// line before an external, and the blank lines between definitions. The
/// copy's line numbers are not the original's, so a compiler warning in it
/// names a line the user cannot find.
///
/// A `Segment` records, for one copied definition, the copy line it starts
/// on, how many lines it spans, and the line and column it starts at in the
/// original. This is a source map whose segments are whole definitions (a
/// JavaScript source map records one segment per token instead, because a
/// compiler rewrites the text; the slice does not). Because the text is
/// verbatim, a position inside a segment maps exactly: its line shifts by a
/// constant, and its column is unchanged except on the segment's first line,
/// where the definition may not start at column 1 of the original (an
/// attribute the copy drops can sit before it on that line). A position
/// outside every segment is in text the build wrote, which has no place in
/// the original; `locate` says so rather than guessing a nearby line.
///
/// Columns count Unicode code points, as the Gleam compiler counts them in
/// its diagnostics.
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// One definition copied verbatim into a sliced module.
pub type Segment {
  Segment(
    /// The 1-based line of the copy the definition's first character is on.
    copy_line: Int,
    /// How many lines the definition spans, at least 1.
    lines: Int,
    /// The 1-based line of the original the definition starts on.
    source_line: Int,
    /// The 1-based column, in code points, it starts at there.
    source_column: Int,
  )
}

/// Where a position in a copy is in the original.
pub type Position {
  /// At this 1-based line and column (in code points) of the original.
  InSource(line: Int, column: Int)
  /// In a line the build wrote (an import, an `@external` attribute, or the
  /// blank line between two definitions): not in the original.
  Generated
}

/// The segment of `text`, copied from `source` at byte offset `start` to
/// line `copy_line` of the copy.
///
/// An `Error` when `text` is not the bytes of `source` at `start`, or when
/// `start` does not fall on a character of `source`: a segment of anything
/// else would map positions to the wrong place.
pub fn segment(
  copy_line copy_line: Int,
  text text: String,
  source source: String,
  start start: Int,
) -> Result(Segment, String) {
  let bytes = <<source:utf8>>
  let size = string.byte_size(text)
  let invalid = fn(reason) {
    Error(
      "Invariant violated: a sliced definition "
      <> reason
      <> " (copy line "
      <> int.to_string(copy_line)
      <> ", byte offset "
      <> int.to_string(start)
      <> ")",
    )
  }
  case copy_line >= 1 {
    False -> invalid("starts before the copy's first line")
    True ->
      case
        bit_array.slice(bytes, 0, start)
        |> result.try(bit_array.to_string),
        bit_array.slice(bytes, start, size)
      {
        Ok(before), Ok(copied) ->
          case copied == <<text:utf8>> {
            False -> invalid("is not the text of its source at its offset")
            True -> {
              // Invariant: `string.split` returns at least one element.
              let assert Ok(line_prefix) = list.last(string.split(before, "\n"))
                as "source_map.segment: string.split returns at least one element"
              Ok(Segment(
                copy_line:,
                lines: newlines(text) + 1,
                source_line: newlines(before) + 1,
                source_column: list.length(string.to_utf_codepoints(line_prefix))
                  + 1,
              ))
            }
          }
        Error(Nil), _ -> invalid("does not start on a character of its source")
        _, Error(Nil) -> invalid("runs past the end of its source")
      }
  }
}

/// Where line `line`, column `column` of a copy (1-based, as the compiler
/// prints them) is in the original, given the copy's `segments`.
pub fn locate(segments: List(Segment), line: Int, column: Int) -> Position {
  case
    list.find(segments, fn(segment) {
      line >= segment.copy_line && line < segment.copy_line + segment.lines
    })
  {
    Ok(segment) if line == segment.copy_line ->
      InSource(
        line: segment.source_line,
        column: segment.source_column + column - 1,
      )
    Ok(segment) ->
      InSource(line: segment.source_line + line - segment.copy_line, column:)
    Error(Nil) -> Generated
  }
}

/// The number of `\n` in `text`, so the number of lines it spans minus one.
pub fn newlines(text: String) -> Int {
  list.length(string.split(text, "\n")) - 1
}
