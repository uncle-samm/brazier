/// Rebuilds the Beacon repository's prebuilt client runtime bundles from
/// `beacon_client/src`.
///
/// Usage, from the Beacon repository root:
///
/// ```sh
/// gleam run -m beacon/build/runtime_bundle
/// ```
///
/// It compiles the `beacon_client` package to JavaScript, then bundles with
/// the pinned esbuild:
///
/// - `beacon_client_ffi.mjs` (the runtime without an app) into
///   `priv/static/beacon_client_<hash>.js`, named by
///   `priv/static/beacon_client.manifest`.
/// - `beacon_client.mjs` into `beacon_client/bundle.js`.
///
/// Apps never use these: `gleam run -m beacon/build` bundles the runtime with
/// the app's own client code. Run this after changing `beacon_client/src`.
import beacon/build/client_bundle
import beacon/build/files
import beacon/build/program
import beacon/log
import gleam/result

const package_dir = "beacon_client"

const compiled_dir = "build/dev/javascript/beacon_client"

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

/// Build both bundles for the Beacon repository at `repo`.
pub fn build(repo: String) -> Result(client_bundle.Bundle, String) {
  let package = files.join(repo, package_dir)
  use Nil <- result.try(program.gleam_build(package))
  let runtime_out = "build/beacon_runtime_bundle.js"
  use Nil <- result.try(program.esbuild_bundle(
    package,
    compiled_dir <> "/beacon_client_ffi.mjs",
    runtime_out,
  ))
  use runtime <- result.try(files.read(files.join(package, runtime_out)))
  use bundle <- result.try(client_bundle.publish(
    files.join(repo, client_bundle.static_dir),
    runtime,
  ))
  use Nil <- result.try(program.esbuild_bundle(
    package,
    compiled_dir <> "/beacon_client.mjs",
    "bundle.js",
  ))
  log.info(
    "beacon.build.runtime_bundle",
    "Wrote " <> files.join(package, "bundle.js"),
  )
  Ok(bundle)
}
