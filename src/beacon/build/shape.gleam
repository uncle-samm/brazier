/// Checks that an analyzed app has the shape the generated code supports, and
/// extracts the app module's client-visible source.
///
/// Beacon renders the first page on the server and then runs the view in the
/// browser from synced state, so the client needs the app's Model, Msg and
/// view compiled to JavaScript. Apps with Local state and no private Server
/// state also run `update` in the browser. Every shortfall is an error naming
/// what is missing; there is no reduced bundle.
import beacon/build/analyzer.{type Analysis}
import beacon/log
import glance
import gleam/list
import gleam/result
import gleam/string

/// The app module's client-visible source and what it provides.
pub type ClientApp {
  ClientApp(
    /// The app module reduced to the code the browser may run.
    source: String,
    /// True when the browser runs `update`: the app has no Server state and
    /// the client source has `pub fn update`.
    has_update: Bool,
  )
}

pub const unsupported_shape_message =
  "Unsupported app shape for client-state rendering. Beacon requires generated client-visible Model, Msg, update, and view code so SSR is only the first render and live updates are state sync/patch messages. Move those definitions into a supported client-visible module shape or extend the AST/codegen path before starting this app."

/// Check `analysis` of the app module `source`.
pub fn check(analysis: Analysis, source: String) -> Result(ClientApp, String) {
  use Nil <- result.try(analyzer.validate_codec_types(analysis))
  use Nil <- result.try(analyzer.validate_client_update_purity(source))
  let update_required = analysis.has_local && !analysis.has_server
  use client_source <- result.try(
    analyzer.extract_client_source_for_bundle(source, !analysis.has_server)
    |> result.map_error(fn(reason) {
      "Client source extraction failed: " <> reason
    }),
  )
  use client_module <- result.try(analyzer.parse(
    "client-visible app module",
    client_source,
  ))
  let has_update =
    !analysis.has_server && has_public_function(client_module, "update")
  let missing =
    [
      #(analysis.has_model, "a public Model record type"),
      #(
        !list.is_empty(analysis.msg_variants),
        "a Msg type with at least one variant handled by update",
      ),
      #(analysis.has_direct_view, "`pub fn view`"),
      #(
        !update_required || has_update,
        "a client-visible `pub fn update` (the app has Local state and no Server state, so update runs in the browser)",
      ),
      #(
        !analysis.has_local || has_public_function(client_module, "init_local"),
        "a client-visible `pub fn init_local` (the app has Local state)",
      ),
    ]
    |> list.filter_map(fn(requirement) {
      case requirement.0 {
        True -> Error(Nil)
        False -> Ok(requirement.1)
      }
    })
  case missing {
    [] -> {
      log.debug(
        "beacon.build.shape",
        "App shape supported; client update: " <> string.inspect(has_update),
      )
      Ok(ClientApp(source: client_source, has_update:))
    }
    _ -> {
      let message =
        unsupported_shape_message <> " Missing: " <> string.join(missing, "; ")
      log.error("beacon.build.shape", message)
      Error(message)
    }
  }
}

fn has_public_function(module: glance.Module, name: String) -> Bool {
  list.any(module.functions, fn(def) {
    def.definition.name == name && def.definition.publicity == glance.Public
  })
}
