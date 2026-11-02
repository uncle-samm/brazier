/// Tests for dev mode's file watching and module reloading FFI.
import gleam/list
import gleam/string
import simplifile

const scratch = "build/beacon_dev_test"

fn fresh_dir(name: String) -> String {
  let dir = scratch <> "/" <> name
  let assert Ok(Nil) = case simplifile.delete(dir) {
    Ok(Nil) -> Ok(Nil)
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
  let assert Ok(Nil) = simplifile.create_directory_all(dir <> "/nested")
  dir
}

pub fn find_gleam_files_recurses_and_filters_test() {
  let dir = fresh_dir("find")
  let assert Ok(Nil) = simplifile.write(dir <> "/a.gleam", "")
  let assert Ok(Nil) = simplifile.write(dir <> "/nested/b.gleam", "")
  let assert Ok(Nil) = simplifile.write(dir <> "/notes.txt", "")
  let assert [a, b] = find_gleam_files(dir)
  let assert True = string.ends_with(a, "/a.gleam")
  let assert True = string.ends_with(b, "/nested/b.gleam")
}

pub fn find_gleam_files_unicode_path_test() {
  let dir = fresh_dir("ünïcode 日本")
  let assert Ok(Nil) = simplifile.write(dir <> "/nested/zoë.gleam", "")
  let assert [path] = find_gleam_files(dir)
  let assert True = path == dir <> "/nested/zoë.gleam"
  record_file_timestamps([dir])
  let assert False = check_for_changes([dir])
  let assert Ok(Nil) = simplifile.write(dir <> "/nested/zoë.gleam", "x")
  let assert Ok(Nil) = simplifile.delete(dir <> "/nested/zoë.gleam")
  let assert True = check_for_changes([dir])
}

pub fn find_gleam_files_missing_dir_test() {
  let assert [] = find_gleam_files(scratch <> "/does-not-exist")
}

pub fn no_change_after_recording_test() {
  let dir = fresh_dir("unchanged")
  let assert Ok(Nil) = simplifile.write(dir <> "/a.gleam", "")
  record_file_timestamps([dir])
  let assert False = check_for_changes([dir])
}

pub fn added_file_is_a_change_test() {
  let dir = fresh_dir("added")
  record_file_timestamps([dir])
  let assert Ok(Nil) = simplifile.write(dir <> "/new.gleam", "")
  let assert True = check_for_changes([dir])
  // The change is reported once.
  let assert False = check_for_changes([dir])
}

pub fn removed_file_is_a_change_test() {
  let dir = fresh_dir("removed")
  let assert Ok(Nil) = simplifile.write(dir <> "/gone.gleam", "")
  record_file_timestamps([dir])
  let assert Ok(Nil) = simplifile.delete(dir <> "/gone.gleam")
  let assert True = check_for_changes([dir])
}

pub fn reload_modules_missing_ebin_is_an_error_test() {
  let assert Error(reason) = reload_modules(scratch <> "/no-ebin")
  let assert True = string.contains(reason, "Cannot list")
}

pub fn reload_modules_skips_unchanged_modules_test() {
  // The test's own ebin is what is loaded, so nothing in it has changed.
  let assert Ok(reloaded) = reload_modules("build/dev/erlang/beacon/ebin")
  let assert False = list.contains(reloaded, "beacon_dev_ffi")
}

pub fn start_app_without_main_is_an_error_test() {
  let assert Error(reason) = start_app("beacon_dev_ffi")
  let assert True = string.contains(reason, "has no main/0;")
}

pub fn start_app_unknown_module_is_an_error_test() {
  let assert Error(reason) = start_app("beacon_dev_test_no_such_module")
  let assert True = string.contains(reason, "Cannot load the app module")
}

@external(erlang, "beacon_dev_ffi", "record_file_timestamps")
fn record_file_timestamps(dirs: List(String)) -> Nil

@external(erlang, "beacon_dev_ffi", "check_for_changes")
fn check_for_changes(dirs: List(String)) -> Bool

@external(erlang, "beacon_dev_ffi", "find_gleam_files")
fn find_gleam_files(dir: String) -> List(String)

@external(erlang, "beacon_dev_ffi", "reload_modules")
fn reload_modules(ebin: String) -> Result(List(String), String)

@external(erlang, "beacon_dev_ffi", "start_app")
fn start_app(module: String) -> Result(Nil, String)
