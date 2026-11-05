/// Directory listing that cannot hang the VM (`brazier_dir_ffi`, through
/// `brazier/build/files`).
///
/// On macOS, OTP's own listing never returns for a name that starts with a
/// combining mark (docs/design/OTP_LIST_DIR_HANG.md). Every test that lists
/// or deletes such a name runs the call in a child VM (`child_vm.call`), so
/// a regression fails by a timeout instead of hanging the suite. Tests that
/// touch only plain names run in the suite's VM.
import brazier/build/client_bundle
import brazier/build/files
import brazier/child_vm
import brazier/lint
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/string
import simplifile

/// A leading combining mark: the name shape OTP cannot decode on macOS.
const leading_mark = "\u{0301}b"

/// A combining mark inside a name, which OTP composes (to `café.txt`)
/// when it decodes a listing on macOS.
const inner_mark = "cafe\u{0301}.txt"

fn temp_dir(tag: String) -> String {
  let dir = "build/dir_listing_test_" <> tag <> "_" <> unique_ref()
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
    as "the build directory is writable"
  dir
}

fn write(path: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(path, "x")
    as "the test directory is writable"
  Nil
}

fn cleanup(dir: String) -> Nil {
  let assert Ok(Nil) = files.delete_if_exists(dir) as "test directory cleanup"
  let assert Ok(False) = simplifile.is_directory(dir)
    as "the test directory is gone"
  Nil
}

fn cleanup_marked(dir: String) -> Nil {
  child_vm.delete_tree(dir)
  let assert Ok(False) = simplifile.is_directory(dir)
    as "the test directory is gone"
  Nil
}

/// A directory holding marked names at the top and one level down.
fn marked_tree(tag: String) -> String {
  let dir = temp_dir(tag)
  let assert Ok(Nil) = simplifile.create_directory_all(dir <> "/sub")
    as "the test directory is writable"
  write(dir <> "/" <> leading_mark)
  write(dir <> "/" <> inner_mark)
  write(dir <> "/plain.txt")
  write(dir <> "/sub/" <> leading_mark <> ".gleam")
  dir
}

// --- Names that start with a combining mark (child VM) ---

pub fn names_starting_with_a_combining_mark_are_listed_as_written_test() {
  let dir = marked_tree("list")
  let listed: Result(Result(List(String), String), String) =
    child_vm.call(
      "brazier@build@files",
      "list_directory",
      [dir],
      child_vm.timeout_ms,
    )
  cleanup_marked(dir)
  let assert Ok(Ok(names)) = listed as "the listing returns in the child VM"
  // The bytes on disk, not OTP's NFC composition (`café.txt`).
  assert names
    == list.sort([leading_mark, inner_mark, "plain.txt", "sub"], string.compare)
}

pub fn files_below_a_combining_mark_name_are_found_test() {
  let dir = marked_tree("files")
  let listed: Result(Result(List(String), String), String) =
    child_vm.call(
      "brazier@build@files",
      "list_files",
      [dir],
      child_vm.timeout_ms,
    )
  cleanup_marked(dir)
  let assert Ok(Ok(paths)) = listed as "the listing returns in the child VM"
  assert paths
    == list.sort(
      [
        dir <> "/" <> leading_mark,
        dir <> "/" <> inner_mark,
        dir <> "/plain.txt",
        dir <> "/sub/" <> leading_mark <> ".gleam",
      ],
      string.compare,
    )
}

pub fn a_tree_with_combining_mark_names_is_deleted_test() {
  let dir = marked_tree("delete")
  let deleted: Result(Result(Nil, String), String) =
    child_vm.call(
      "brazier@build@files",
      "delete_if_exists",
      [dir],
      child_vm.timeout_ms,
    )
  let assert Ok(Ok(Nil)) = deleted as "the delete returns in the child VM"
  let assert Ok(False) = simplifile.is_directory(dir)
    as "the whole tree is gone"
}

pub fn the_client_bundle_publishes_beside_a_combining_mark_name_test() {
  let static = temp_dir("publish")
  let old_bundle = static <> "/" <> client_bundle.bundle_prefix <> "0.js"
  let marked = static <> "/" <> leading_mark <> ".txt"
  write(old_bundle)
  write(marked)
  let published: Result(Result(Dynamic, String), String) =
    child_vm.call(
      "brazier@build@client_bundle",
      "publish",
      [static, "console.log(1)"],
      child_vm.timeout_ms,
    )
  let old_kept = simplifile.is_file(old_bundle)
  let marked_kept = simplifile.is_file(marked)
  cleanup_marked(static)
  let assert Ok(Ok(_bundle)) = published as "publish returns in the child VM"
  let assert Ok(False) = old_kept as "the replaced bundle is deleted"
  let assert Ok(True) = marked_kept as "an unrelated static file is kept"
}

pub fn lint_walks_a_tree_with_combining_mark_names_test() {
  let dir = marked_tree("lint")
  let linted: Result(List(lint.Violation), String) =
    child_vm.call(
      "brazier@lint",
      "lint_names_directory",
      [dir],
      child_vm.timeout_ms,
    )
  cleanup_marked(dir)
  let assert Ok([]) = linted as "lint returns in the child VM, with nothing"
}

pub fn dev_reload_lists_an_ebin_with_a_combining_mark_name_test() {
  let dir = marked_tree("reload")
  let reloaded: Result(Result(List(String), String), String) =
    child_vm.call(
      "brazier_dev_ffi",
      "reload_modules",
      [dir],
      child_vm.timeout_ms,
    )
  cleanup_marked(dir)
  let assert Ok(Ok([])) = reloaded
    as "reload returns in the child VM; there is no .beam to load"
}

// --- The OTP bug itself (child VM) ---

/// The OTP bug the find-based listing works around, checked where it lives.
/// When this fails on macOS, OTP's decoder has been fixed: the find-based
/// listing in `brazier_dir_ffi` can be retired for OTP releases with the
/// fix (docs/design/OTP_LIST_DIR_HANG.md).
pub fn otp_decoder_frees_the_name_it_returns_on_macos_test() {
  let probed: Result(Bool, String) =
    child_vm.call(
      "brazier_dir_test_ffi",
      "decoder_frees_its_result",
      [],
      child_vm.timeout_ms,
    )
  let assert Ok(frees) = probed as "the probe returns in the child VM"
  assert frees == child_vm.is_macos()
}

/// The hang itself, and the child VM runner's kill path: on macOS OTP's
/// `file:list_dir/1` does not return, and the runner kills the child.
pub fn otp_list_dir_hangs_on_macos_and_the_child_is_killed_test() {
  let dir = marked_tree("otp_hang")
  let listed: Result(Dynamic, String) =
    child_vm.call("file", "list_dir", [dir], 5000)
  cleanup_marked(dir)
  case child_vm.is_macos() {
    True -> {
      let assert Error(reason) = listed
        as "OTP's list_dir hangs on macOS; when it returns, OTP is fixed"
      assert string.contains(reason, "did not answer in 5000 ms")
      assert string.contains(reason, "killed it with SIGKILL")
    }
    False -> {
      let assert Ok(_) = listed as "OTP's list_dir returns off macOS"
      Nil
    }
  }
}

pub fn a_child_that_crashes_is_an_error_test() {
  let crashed: Result(Dynamic, String) =
    child_vm.call("erlang", "binary_to_atom", ["a", "b"], child_vm.timeout_ms)
  let assert Error(reason) = crashed as "a crash in the child is reported"
  assert string.contains(reason, "crashed in the child VM")
}

// --- Plain names (this VM) ---

pub fn a_missing_directory_is_an_error_naming_it_test() {
  let dir = "build/dir_listing_test_missing_" <> unique_ref()
  let assert Error(reason) = files.list_directory(dir)
    as "a missing directory is not an empty one"
  assert string.contains(reason, dir)
  assert string.contains(reason, "no such file or directory")
  let assert Error(_) = files.list_files(dir)
    as "a missing directory has no files to find"
}

pub fn a_file_is_not_a_directory_to_list_test() {
  let dir = temp_dir("not_dir")
  write(dir <> "/plain.txt")
  let listed = files.list_directory(dir <> "/plain.txt")
  let found = files.list_files(dir <> "/plain.txt")
  cleanup(dir)
  let assert Error(reason) = listed
    as "a file is an error, not an empty listing"
  assert string.contains(reason, dir <> "/plain.txt")
  assert string.contains(reason, "not a directory")
  let assert Error(_) = found as "a file is not a directory to search"
}

pub fn a_trailing_slash_and_an_empty_directory_are_listed_test() {
  let dir = temp_dir("slash")
  let assert Ok(Nil) = simplifile.create_directory_all(dir <> "/empty")
    as "the test directory is writable"
  write(dir <> "/a.txt")
  let slashed = files.list_directory(dir <> "/")
  let empty = files.list_directory(dir <> "/empty")
  let found = files.list_files(dir <> "/")
  cleanup(dir)
  let assert Ok(["a.txt", "empty"]) = slashed
  let assert Ok([]) = empty
  let assert Ok([path]) = found
  assert path == dir <> "/a.txt"
}

pub fn delete_removes_a_symlink_not_its_target_test() {
  let dir = temp_dir("symlink")
  let target = temp_dir("symlink_target")
  write(target <> "/kept.txt")
  let assert Ok(Nil) =
    simplifile.create_symlink("../" <> slug(target), dir <> "/link")
    as "the test directory is writable"
  let deleted = files.delete_if_exists(dir)
  let target_kept = simplifile.is_file(target <> "/kept.txt")
  cleanup(target)
  let assert Ok(Nil) = deleted
  let assert Ok(False) = simplifile.is_directory(dir)
  let assert Ok(True) = target_kept
    as "deleting a tree never follows a symlink out of it"
}

pub fn deleting_a_missing_path_is_not_an_error_test() {
  let assert Ok(Nil) =
    files.delete_if_exists("build/dir_listing_test_gone_" <> unique_ref())
}

// --- What find prints (pure) ---

pub fn a_name_that_is_not_utf8_is_an_error_naming_it_test() {
  // APFS refuses such a name, so the output find would print is fed in.
  let assert Error(reason) = parse_listing("x", <<"x/caf":utf8, 233, 0>>)
    as "a name a String cannot hold is refused, not skipped"
  assert string.contains(reason, "Cannot list x")
  assert string.contains(reason, "<<99,97,102,233>>")
  assert string.contains(reason, "not valid UTF-8")
}

pub fn output_that_is_not_the_listing_is_an_error_test() {
  let assert Error(stray) =
    parse_listing("x", <<"x/a":utf8, 0, "find: oops":utf8, 0>>)
    as "a line that is not an entry of the directory"
  assert string.contains(stray, "find printed find: oops")
  let assert Error(unterminated) = parse_listing("x", <<"x/a":utf8>>)
    as "an entry without its NUL"
  assert string.contains(unterminated, "does not end in a NUL")
  let assert Error(_) = parse_listing("x", <<"x/a/b":utf8, 0>>)
    as "a name with a slash is not a name"
  let assert Error(_) = parse_listing("x", <<"x/":utf8, 0>>)
    as "an empty name is not a name"
}

pub fn find_output_is_read_relative_to_the_root_given_test() {
  let assert Ok(["a", leading]) =
    parse_listing("x//", <<"x/a":utf8, 0, "x/\u{0301}b":utf8, 0>>)
  assert leading == leading_mark
  let assert Ok(["a"]) = parse_listing("-x", <<"./-x/a":utf8, 0>>)
    as "a path that starts with - is handed to find as ./-x"
  let assert Ok(["bin"]) = parse_listing("/", <<"/bin":utf8, 0>>)
  let assert Ok([]) = parse_listing("x", <<>>)
}

fn slug(path: String) -> String {
  let assert Ok(last) = list.last(string.split(path, "/"))
    as "a path has a last segment"
  last
}

@external(erlang, "brazier_dir_ffi", "parse_listing")
fn parse_listing(dir: String, output: BitArray) -> Result(List(String), String)

@external(erlang, "brazier_test_ffi", "unique_ref")
fn unique_ref() -> String
