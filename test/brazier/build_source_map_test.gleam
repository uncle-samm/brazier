/// Tests for `source_map`: segments of definitions copied out of a source,
/// and positions in a copy mapped back through them.
import brazier/build/source_map.{Generated, InSource, Segment}
import gleam/string

const source = "import x\n\npub fn a() {\n  1\n}\n\n@internal pub fn b() { 2 }\n"

pub fn segment_records_where_a_definition_starts_test() {
  // `pub fn a` starts at byte 10, line 3, column 1, and spans 3 lines.
  let assert Ok(Segment(
    copy_line: 4,
    lines: 3,
    source_line: 3,
    source_column: 1,
  )) =
    source_map.segment(
      copy_line: 4,
      text: "pub fn a() {\n  1\n}",
      source:,
      start: 10,
    )
  // `pub fn b` starts after `@internal ` on line 7, at column 11.
  let assert Ok(Segment(
    copy_line: 1,
    lines: 1,
    source_line: 7,
    source_column: 11,
  )) =
    source_map.segment(
      copy_line: 1,
      text: "pub fn b() { 2 }",
      source:,
      start: 40,
    )
}

pub fn segment_counts_columns_in_code_points_test() {
  // `é` decomposed is two code points and three bytes, so the six bytes
  // before `pub` are five code points and `pub` is at column 6.
  let text = "\"e\u{0301}\" pub fn c() { 3 }"
  let assert Ok(Segment(source_line: 1, source_column: 6, ..)) =
    source_map.segment(
      copy_line: 1,
      text: "pub fn c() { 3 }",
      source: text,
      start: 6,
    )
}

pub fn segment_refuses_text_that_is_not_the_source_test() {
  let assert Error(reason) =
    source_map.segment(copy_line: 1, text: "pub fn z() {", source:, start: 10)
  let assert True = string.contains(reason, "Invariant violated")
  let assert True =
    string.contains(reason, "is not the text of its source at its offset")
  let assert True = string.contains(reason, "byte offset 10")
}

pub fn segment_refuses_an_offset_outside_the_source_test() {
  let assert Error(reason) =
    source_map.segment(copy_line: 1, text: "pub fn a", source:, start: 1000)
  let assert True = string.contains(reason, "does not start on a character")
  let assert Error(reason) =
    source_map.segment(
      copy_line: 1,
      text: "pub fn b() { 2 }\n and more",
      source:,
      start: 40,
    )
  let assert True = string.contains(reason, "runs past the end")
}

pub fn segment_refuses_an_offset_inside_a_character_test() {
  // Byte 2 is inside the two-byte `é`.
  let assert Error(reason) =
    source_map.segment(copy_line: 1, text: "", source: "aé", start: 2)
  let assert True = string.contains(reason, "does not start on a character")
}

pub fn segment_refuses_a_line_before_the_copy_test() {
  let assert Error(reason) =
    source_map.segment(copy_line: 0, text: "pub fn a", source:, start: 10)
  let assert True = string.contains(reason, "before the copy's first line")
}

pub fn locate_maps_lines_inside_segments_test() {
  let segments = [
    Segment(copy_line: 3, lines: 3, source_line: 10, source_column: 1),
    Segment(copy_line: 7, lines: 2, source_line: 20, source_column: 11),
  ]
  // The first line of a segment shifts the column by where it started.
  let assert InSource(line: 10, column: 4) = source_map.locate(segments, 3, 4)
  let assert InSource(line: 20, column: 14) = source_map.locate(segments, 7, 4)
  // Later lines keep their column.
  let assert InSource(line: 12, column: 4) = source_map.locate(segments, 5, 4)
  let assert InSource(line: 21, column: 2) = source_map.locate(segments, 8, 2)
}

pub fn locate_says_lines_outside_segments_are_generated_test() {
  let segments = [
    Segment(copy_line: 3, lines: 3, source_line: 10, source_column: 1),
    Segment(copy_line: 7, lines: 2, source_line: 20, source_column: 1),
  ]
  // Imports before the first, the blank line between, past the last.
  let assert Generated = source_map.locate(segments, 1, 1)
  let assert Generated = source_map.locate(segments, 6, 1)
  let assert Generated = source_map.locate(segments, 9, 1)
  let assert Generated = source_map.locate([], 1, 1)
}

pub fn newlines_counts_line_breaks_test() {
  let assert 0 = source_map.newlines("")
  let assert 0 = source_map.newlines("a")
  let assert 2 = source_map.newlines("a\n\nb")
}
