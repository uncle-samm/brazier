/// Tests for `project_toml.client_runtime_dir`: where the build reads the
/// client runtime for each way a project can get Brazier. A Hex package
/// carries only `src` and `priv`, so the runtime is at
/// `priv/brazier_client_src` there and at `brazier_client/src` in a checkout.
import brazier/build/project_toml
import gleam/list
import gleam/string
import simplifile

const element_marker = "src/brazier/element.gleam"

const ffi = "brazier_client_ffi.mjs"

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

fn app_toml(brazier_requirement: String) -> String {
  "name = \"my_app\"\nversion = \"1.0.0\"\n\n[dependencies]\nbrazier = "
  <> brazier_requirement
  <> "\n"
}

pub fn framework_repo_runtime_is_brazier_client_src_test() {
  assert project_toml.client_runtime_dir(".") == Ok("brazier_client/src")
}

pub fn path_dependency_runtime_is_in_the_checkout_test() {
  assert project_toml.client_runtime_dir("examples/counter")
    == Ok("examples/counter/../../brazier_client/src")
}

pub fn hex_dependency_runtime_is_in_priv_test() {
  let root = "build/brazier_test_runtime_dir_hex"
  let package = "build/packages/brazier/"
  fresh_tree(root, [
    #("gleam.toml", app_toml("\">= 0.1.0 and < 1.0.0\"")),
    #(package <> element_marker, ""),
    #(package <> project_toml.hex_client_runtime_dir <> "/" <> ffi, ""),
  ])
  assert project_toml.client_runtime_dir(root)
    == Ok(root <> "/build/packages/brazier/priv/brazier_client_src")
}

pub fn hex_dependency_ignores_a_brazier_client_dir_test() {
  // A Hex package never has `brazier_client/src`; the layout comes from the
  // dependency kind, so a stray copy there is not picked up instead.
  let root = "build/brazier_test_runtime_dir_hex_stray"
  let package = "build/packages/brazier/"
  fresh_tree(root, [
    #("gleam.toml", app_toml("\">= 0.1.0 and < 1.0.0\"")),
    #(package <> element_marker, ""),
    #(package <> "brazier_client/src/" <> ffi, ""),
  ])
  let assert Error(reason) = project_toml.client_runtime_dir(root)
  assert string.contains(
    reason,
    root <> "/build/packages/brazier/priv/brazier_client_src/" <> ffi,
  )
  assert string.contains(reason, "scripts/publish.sh")
}

pub fn git_dependency_runtime_is_in_the_checkout_test() {
  let root = "build/brazier_test_runtime_dir_git"
  let package = "build/packages/brazier/"
  fresh_tree(root, [
    #(
      "gleam.toml",
      app_toml("{ git = \"https://example.com/brazier.git\", ref = \"main\" }"),
    ),
    #(package <> element_marker, ""),
    #(package <> "brazier_client/src/" <> ffi, ""),
  ])
  assert project_toml.client_runtime_dir(root)
    == Ok(root <> "/build/packages/brazier/brazier_client/src")
}

pub fn checkout_without_runtime_is_an_error_test() {
  let root = "build/brazier_test_runtime_dir_no_runtime"
  fresh_tree(root, [
    #("gleam.toml", app_toml("{ path = \"brazier\" }")),
    #("brazier/" <> element_marker, ""),
  ])
  let assert Error(reason) = project_toml.client_runtime_dir(root)
  assert string.contains(reason, root <> "/brazier/brazier_client/src/" <> ffi)
  assert string.contains(reason, "checkout is incomplete")
}

pub fn missing_brazier_sources_is_an_error_test() {
  let root = "build/brazier_test_runtime_dir_no_sources"
  fresh_tree(root, [#("gleam.toml", app_toml("\">= 0.1.0 and < 1.0.0\""))])
  let assert Error(reason) = project_toml.client_runtime_dir(root)
  assert string.contains(reason, "Brazier sources not found")
}
