//// The build folds Gleam names in ASCII (`brazier/internal/ascii`), not in
//// Unicode: a Gleam name is ASCII by grammar (glexer starts an upper name
//// with `A-Z` and continues it with `A-Z a-z 0-9`), so ASCII folding is the
//// name's whole lowercase. These tests pin the grammar the build relies
//// on, and the names the build derives.

import brazier/build/codec_gen
import brazier/build/field_type
import glance
import gleam/dict
import gleam/set

pub fn a_gleam_name_outside_ascii_does_not_parse_test() {
  // A non-ASCII letter starts no name: glance refuses the module, so no
  // such name reaches the build's folding.
  let assert Error(_) = glance.module("pub type Ärger { Ärger }\n")
    as "glance refuses a type name starting outside ASCII"
  let assert Error(_) = glance.module("pub type Kelvin { \u{212A}elvin }\n")
    as "glance refuses a variant name starting with the Kelvin sign"
  let assert Error(_) = glance.module("pub type Mass { Gramé }\n")
    as "glance refuses a variant name continuing outside ASCII"
  let assert Ok(_) = glance.module("pub type Mass { Gram Kelvin }\n")
    as "glance parses ASCII names"
  Nil
}

pub fn enum_wire_name_folds_ascii_test() {
  assert field_type.enum_wire_name("Codex") == "codex"
  assert field_type.enum_wire_name("HTTPError") == "httperror"
  assert field_type.enum_wire_name("Gemini2") == "gemini2"
  // Only `A-Z` is folded: Unicode folding would map the Kelvin sign to
  // `k`. The grammar keeps such a name out (above); the folding does not
  // depend on it.
  assert field_type.enum_wire_name("\u{212A}elvin") == "\u{212A}elvin"
}

pub fn helper_names_snake_case_type_names_in_ascii_test() {
  let codecs =
    codec_gen.Codecs(type_defs: dict.new(), sent: set.new(), allowed: set.new())
  assert codec_gen.encoder_name(codecs, "app/types", "AgentRunStatus")
    == "encode_type__app__types__agent_run_status"
  assert codec_gen.decoder_name(codecs, "app", "HTTPError")
    == "decode_type__app__h_t_t_p_error"
  assert codec_gen.encoder_name(codecs, "app", "Model")
    == "encode_type__app__model"
  // A character outside ASCII is neither folded nor split off.
  assert codec_gen.encoder_name(codecs, "app", "Big\u{212A}")
    == "encode_type__app__big\u{212A}"
}
