/// The client contract report, `build/beacon_contract.json`: what state and
/// messages cross the wire for an app, for review and tooling.
import beacon/build/analyzer.{type Analysis, type MsgVariant, type TypeField}
import beacon/build/files
import beacon/log
import gleam/json
import gleam/result

pub const path = "build/beacon_contract.json"

/// The report as JSON.
pub fn report(
  source_path: String,
  module_path: String,
  analysis: Analysis,
) -> String {
  json.object([
    #("source", json.string(source_path)),
    #("module", json.string(module_path)),
    #("rendering", json.string("ssr-first-then-client-state")),
    #("model", fields_json(analysis.model_fields)),
    #("local", fields_json(analysis.local_fields)),
    #("server", fields_json(analysis.server_fields)),
    #("has_local", json.bool(analysis.has_local)),
    #("has_server", json.bool(analysis.has_server)),
    #("messages", variants_json(analysis.msg_variants)),
    #(
      "client_messages",
      variants_json(analyzer.client_event_variants(analysis)),
    ),
    #(
      "external_messages",
      json.array(analysis.external_msg_types, fn(info) {
        json.object([
          #("module", json.string(info.module)),
          #("variants", variants_json(info.variants)),
        ])
      }),
    ),
    #(
      "generated_codecs",
      json.array(
        [
          "encode_model", "decode_model", "decode_event", "encode_msg",
          "render_model",
        ],
        json.string,
      ),
    ),
    #("summary", json.string(analyzer.client_contract_summary(analysis))),
    #("skipped_server_state", json.bool(analysis.has_server)),
  ])
  |> json.to_string
}

/// Write the report to `build/beacon_contract.json` of the project at
/// `project`.
pub fn write(
  project: String,
  source_path: String,
  module_path: String,
  analysis: Analysis,
) -> Result(Nil, String) {
  let output = files.join(project, path)
  use Nil <- result.try(files.write(
    output,
    report(source_path, module_path, analysis),
  ))
  log.info("beacon.build.contract", "Wrote contract report " <> output)
  Ok(Nil)
}

fn fields_json(fields: List(TypeField)) -> json.Json {
  json.array(fields, fn(field) {
    json.object([
      #("name", json.string(field.name)),
      #("type", json.string(field.type_name)),
      #("inner_type", json.string(field.inner_type)),
      #("module", json.string(field.module)),
      #("inner_module", json.string(field.inner_module)),
    ])
  })
}

fn variants_json(variants: List(MsgVariant)) -> json.Json {
  json.array(variants, fn(variant) {
    json.object([
      #("name", json.string(variant.name)),
      #("fields", fields_json(variant.fields)),
      #("affects_model", json.bool(variant.affects_model)),
      #("affects_local", json.bool(variant.affects_local)),
      #(
        "impact",
        json.string(analyzer.msg_impact_label(analyzer.msg_impact(variant))),
      ),
    ])
  })
}
