/// Tests for `project_toml.client_runtime_dir`: where the build reads the
/// client runtime for each way a project can get Beacon. A Hex package
/// carries only `src` and `priv`, so the runtime is at
/// `priv/beacon_client_src` there and at `beacon_client/src` in a checkout.
import beacon/build/project_toml
import gleam/list
import gleam/string
import simplifile

const element_marker = "src/beacon/element.gleam"

const ffi = "beacon_client_ffi.mjs"

fn fresh_tree(root: String, files: List(#(String, String))) -> Nil {
  let assert Ok(Nil) = case simplifile.delete(root) {
    Ok(Nil) -> Ok(Nil)
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
  list.each(files, fn(file) {
    let path = root <> "/" <> file.0
    let assert Ok(Nil) = simplifile.create_directory_all(parent(path))
    let assert Ok(Nil) = simplifile.write(path, file.1)
  })
}

fn parent(path: String) -> String {
  let assert Ok(#(_, dir)) = string.split_once(string.reverse(path), "/")
  string.reverse(dir)
}

fn app_toml(beacon_requirement: String) -> String {
  "name = \"my_app\"\nversion = \"1.0.0\"\n\n[dependencies]\nbeacon = "
  <> beacon_requirement
  <> "\n"
}

pub fn framework_repo_runtime_is_beacon_client_src_test() {
  assert project_toml.client_runtime_dir(".") == Ok("beacon_client/src")
}

pub fn path_dependency_runtime_is_in_the_checkout_test() {
  assert project_toml.client_runtime_dir("examples/counter")
    == Ok("examples/counter/../../beacon_client/src")
}

pub fn hex_dependency_runtime_is_in_priv_test() {
  let root = "build/beacon_test_runtime_dir_hex"
  let package = "build/packages/beacon/"
  fresh_tree(root, [
    #("gleam.toml", app_toml("\">= 0.1.0 and < 1.0.0\"")),
    #(package <> element_marker, ""),
    #(package <> project_toml.hex_client_runtime_dir <> "/" <> ffi, ""),
  ])
  assert project_toml.client_runtime_dir(root)
    == Ok(root <> "/build/packages/beacon/priv/beacon_client_src")
}

pub fn hex_dependency_ignores_a_beacon_client_dir_test() {
  // A Hex package never has `beacon_client/src`; the layout comes from the
  // dependency kind, so a stray copy there is not picked up instead.
  let root = "build/beacon_test_runtime_dir_hex_stray"
  let package = "build/packages/beacon/"
  fresh_tree(root, [
    #("gleam.toml", app_toml("\">= 0.1.0 and < 1.0.0\"")),
    #(package <> element_marker, ""),
    #(package <> "beacon_client/src/" <> ffi, ""),
  ])
  let assert Error(reason) = project_toml.client_runtime_dir(root)
  assert string.contains(
    reason,
    root <> "/build/packages/beacon/priv/beacon_client_src/" <> ffi,
  )
  assert string.contains(reason, "scripts/publish.sh")
}

pub fn git_dependency_runtime_is_in_the_checkout_test() {
  let root = "build/beacon_test_runtime_dir_git"
  let package = "build/packages/beacon/"
  fresh_tree(root, [
    #(
      "gleam.toml",
      app_toml("{ git = \"https://example.com/beacon.git\", ref = \"main\" }"),
    ),
    #(package <> element_marker, ""),
    #(package <> "beacon_client/src/" <> ffi, ""),
  ])
  assert project_toml.client_runtime_dir(root)
    == Ok(root <> "/build/packages/beacon/beacon_client/src")
}

pub fn checkout_without_runtime_is_an_error_test() {
  let root = "build/beacon_test_runtime_dir_no_runtime"
  fresh_tree(root, [
    #("gleam.toml", app_toml("{ path = \"beacon\" }")),
    #("beacon/" <> element_marker, ""),
  ])
  let assert Error(reason) = project_toml.client_runtime_dir(root)
  assert string.contains(reason, root <> "/beacon/beacon_client/src/" <> ffi)
  assert string.contains(reason, "checkout is incomplete")
}

pub fn missing_beacon_sources_is_an_error_test() {
  let root = "build/beacon_test_runtime_dir_no_sources"
  fresh_tree(root, [#("gleam.toml", app_toml("\">= 0.1.0 and < 1.0.0\""))])
  let assert Error(reason) = project_toml.client_runtime_dir(root)
  assert string.contains(reason, "Beacon sources not found")
}
