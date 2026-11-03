/// Rebuilds the Beacon repository's prebuilt client runtime bundle from
/// `beacon_client/src`.
///
/// Usage, from the Beacon repository root:
///
/// ```sh
/// gleam run -m beacon/build/runtime_bundle
/// ```
///
/// It bundles the runtime (`beacon_client/src/beacon_client_ffi.mjs` and the
/// `beacon_client/*.mjs` modules it imports) with the pinned esbuild into
/// `priv/static/beacon_client_<hash>.js`, named by
/// `priv/static/beacon_client.manifest`. The bundle starts the runtime with no
/// generated app, so a page served with it reports in the console that it is
/// not interactive and does not connect.
///
/// Apps never use this bundle: `gleam run -m beacon/build` bundles the
/// runtime with the app's own client code. Run this after changing
/// `beacon_client/src`.
import beacon/build/client_bundle
import beacon/build/files
import beacon/build/program
import beacon/log
import gleam/result

/// The esbuild entry, relative to the repository.
const entry_path = "build/beacon_runtime_entry.mjs"

/// The esbuild output, relative to the repository.
const output_path = "build/beacon_runtime_bundle.js"

/// Starts the runtime without a generated app; see the module docs.
const entry =
  "import { start } from '../beacon_client/src/beacon_client_ffi.mjs';
start(undefined);
"

pub fn main() -> Nil {
  log.configure()
  case build(".") {
    Ok(bundle) ->
      log.info("beacon.build.runtime_bundle", "Runtime bundle " <> bundle.path)
    Error(reason) -> {
      log.error("beacon.build.runtime_bundle", reason)
      program.exit_failure(reason)
    }
  }
}

/// Build the runtime bundle for the Beacon repository at `repo`.
pub fn build(repo: String) -> Result(client_bundle.Bundle, String) {
  use Nil <- result.try(files.write(files.join(repo, entry_path), entry))
  use Nil <- result.try(program.esbuild_bundle(repo, entry_path, output_path))
  use runtime <- result.try(files.read(files.join(repo, output_path)))
  client_bundle.publish(files.join(repo, client_bundle.static_dir), runtime)
}
