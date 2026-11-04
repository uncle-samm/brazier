/// Rebuilds the Brazier repository's prebuilt client runtime bundle from
/// `brazier_client/src`.
///
/// Usage, from the Brazier repository root:
///
/// ```sh
/// gleam run -m brazier/build/runtime_bundle
/// ```
///
/// It bundles the runtime (`brazier_client/src/brazier_client_ffi.mjs` and the
/// `brazier_client/*.mjs` modules it imports) with the pinned esbuild into
/// `priv/static/brazier_client_<hash>.js`, named by
/// `priv/static/brazier_client.manifest`. The bundle starts the runtime with no
/// generated app, so a page served with it reports in the console that it is
/// not interactive and does not connect.
///
/// Apps never use this bundle: `gleam run -m brazier/build` bundles the
/// runtime with the app's own client code. Run this after changing
/// `brazier_client/src`.
import brazier/build/client_bundle
import brazier/build/files
import brazier/build/program
import brazier/log
import gleam/result

/// The esbuild entry, relative to the repository.
const entry_path = "build/brazier_runtime_entry.mjs"

/// The esbuild output, relative to the repository.
const output_path = "build/brazier_runtime_bundle.js"

/// Starts the runtime without a generated app; see the module docs.
const entry =
  "import { start } from '../brazier_client/src/brazier_client_ffi.mjs';
start(undefined);
"

pub fn main() -> Nil {
  log.configure()
  case build(".") {
    Ok(bundle) ->
      log.info("brazier.build.runtime_bundle", "Runtime bundle " <> bundle.path)
    Error(reason) -> {
      log.error("brazier.build.runtime_bundle", reason)
      program.exit_failure(reason)
    }
  }
}

/// Build the runtime bundle for the Brazier repository at `repo`.
pub fn build(repo: String) -> Result(client_bundle.Bundle, String) {
  use Nil <- result.try(files.write(files.join(repo, entry_path), entry))
  use Nil <- result.try(program.esbuild_bundle(repo, entry_path, output_path))
  use runtime <- result.try(files.read(files.join(repo, output_path)))
  client_bundle.publish(files.join(repo, client_bundle.static_dir), runtime)
}
