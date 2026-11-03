//// `internal_modules` in gleam.toml hides framework internals from the
//// generated docs (docs/design/API_REDESIGN.md section 2). These tests keep
//// the list in step with the source tree and keep app-facing modules public.

import beacon/build/analyzer
import gleam/list
import gleam/string
import simplifile
import tom

fn internal_modules() -> List(String) {
  let assert Ok(text) = simplifile.read("gleam.toml")
  let assert Ok(toml) = tom.parse(text)
  let assert Ok(entries) = tom.get_array(toml, ["internal_modules"])
  list.map(entries, fn(entry) {
    // Invariant: every entry in the list is a TOML string.
    let assert tom.String(name) = entry
    name
  })
}

fn is_internal(module: String, patterns: List(String)) -> Bool {
  list.any(patterns, fn(pattern) {
    case string.ends_with(pattern, "/*") {
      True -> string.starts_with(module, string.drop_end(pattern, 1))
      False -> module == pattern
    }
  })
}

pub fn every_internal_entry_names_existing_code_test() {
  let entries = internal_modules()
  let assert False = list.is_empty(entries)
  let missing =
    list.filter(entries, fn(entry) {
      let exists = case string.ends_with(entry, "/*") {
        True -> simplifile.is_directory("src/" <> string.drop_end(entry, 2))
        False -> simplifile.is_file("src/" <> entry <> ".gleam")
      }
      exists != Ok(True)
    })
  let assert [] = missing
}

pub fn framework_internals_are_listed_test() {
  let entries = internal_modules()
  let expected = [
    "beacon/application", "beacon/build", "beacon/build/analyzer",
    "beacon/debug", "beacon/internal/render", "beacon/patch",
    "beacon/rate_limit", "beacon/runtime", "beacon/ssr", "beacon/state_manager",
    "beacon/transport/ws",
  ]
  let assert [] = list.filter(expected, fn(m) { !is_internal(m, entries) })
}

pub fn app_facing_modules_stay_public_test() {
  let entries = internal_modules()
  let public = [
    "beacon",
    "beacon/effect",
    "beacon/router",
    "beacon/dev",
    "beacon/lint",
    // `beacon.security_limits`, `api_routes` and `ws_auth` take their types.
    "beacon/transport",
    "beacon/transport/server",
    ..analyzer.client_modules
  ]
  let assert [] = list.filter(public, fn(m) { is_internal(m, entries) })
}

pub fn wildcard_does_not_hide_the_parent_module_test() {
  let assert False = is_internal("beacon/build", ["beacon/build/*"])
  let assert True = is_internal("beacon/build/reach", ["beacon/build/*"])
  let assert False = is_internal("beacon/builder", ["beacon/build/*"])
}
