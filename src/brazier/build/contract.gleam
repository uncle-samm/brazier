/// The client contract report, `build/brazier_contract.json`: what crosses the
/// wire for an app and what code reaches the browser, for review and tooling.
import brazier/build/analyzer.{type Analysis}
import brazier/build/app_call
import brazier/build/field_type
import brazier/build/files
import brazier/log
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string

pub const path = "build/brazier_contract.json"

/// The report as JSON.
pub fn report(source_path: String, analysis: Analysis) -> String {
  let call = analysis.call
  let ref = fn(ref: app_call.FunctionRef) {
    json.string(field_type.qualified_name(ref.module, ref.name))
  }
  json.object([
    #("source", json.string(source_path)),
    #("module", json.string(analysis.app_module)),
    #("kind", json.string(app_call.kind_name(call.kind))),
    #("view", ref(call.view)),
    #("client_update", case call.update {
      option.Some(update) -> ref(update)
      option.None -> json.null()
    }),
    #("local", case call.local {
      app_call.NoLocal -> json.null()
      app_call.LocalLayer(init:, update:) ->
        json.object([#("init", ref(init)), #("update", ref(update))])
    }),
    #("model", json.string(field_type.describe(analysis.model))),
    #(
      "msg",
      json.string(field_type.qualified_name(analysis.msg.0, analysis.msg.1)),
    ),
    #(
      "client_messages",
      analysis.codecs.allowed
        |> set.to_list
        |> list.map(fn(c) { field_type.qualified_name(c.0, c.1) })
        |> list.sort(string.compare)
        |> json.array(json.string),
    ),
    #(
      "client_modules",
      json.array(analysis.client, fn(emitted) { json.string(emitted.path) }),
    ),
  ])
  |> json.to_string
}

/// Write the report to `build/brazier_contract.json` of the project at
/// `project`.
pub fn write(
  project: String,
  source_path: String,
  analysis: Analysis,
) -> Result(Nil, String) {
  let output = files.join(project, path)
  use Nil <- result.try(files.write(output, report(source_path, analysis)))
  log.info("brazier.build.contract", "Wrote contract report " <> output)
  Ok(Nil)
}
