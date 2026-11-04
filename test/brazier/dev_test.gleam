/// Tests for dev mode's module reloading FFI. The file watcher and live
/// reload are covered by `dev_reload_test`.
import gleam/list
import gleam/string

const scratch = "build/brazier_dev_test"

pub fn reload_modules_missing_ebin_is_an_error_test() {
  let assert Error(reason) = reload_modules(scratch <> "/no-ebin")
  let assert True = string.contains(reason, "Cannot list")
}

pub fn reload_modules_skips_unchanged_modules_test() {
  // The test's own ebin is what is loaded, so nothing in it has changed.
  let assert Ok(reloaded) = reload_modules("build/dev/erlang/brazier/ebin")
  let assert False = list.contains(reloaded, "brazier_dev_ffi")
}

pub fn start_app_without_main_is_an_error_test() {
  let assert Error(reason) = start_app("brazier_dev_ffi")
  let assert True = string.contains(reason, "has no main/0;")
}

pub fn start_app_unknown_module_is_an_error_test() {
  let assert Error(reason) = start_app("brazier_dev_test_no_such_module")
  let assert True = string.contains(reason, "Cannot load the app module")
}

@external(erlang, "brazier_dev_ffi", "reload_modules")
fn reload_modules(ebin: String) -> Result(List(String), String)

@external(erlang, "brazier_dev_ffi", "start_app")
fn start_app(module: String) -> Result(Nil, String)
