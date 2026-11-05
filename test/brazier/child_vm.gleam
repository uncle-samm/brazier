//// One function call in a separate VM, killed with SIGKILL when it does not
//// answer in time.
////
//// On macOS, OTP's own directory listing never returns for a name that
//// starts with a combining mark, and no timer or halt in that VM runs
//// afterwards (docs/design/OTP_LIST_DIR_HANG.md). A test that lists or
//// deletes such a directory calls the code under test through `call`, so a
//// regression fails that test after `timeout_ms` instead of hanging the
//// suite. The child VM runs with `+fnu` (UTF-8 file names), the mode that
//// has the bug on macOS whatever the locale, and loads the same compiled
//// modules as the runner.

/// How long a child VM gets to start and answer one listing call.
pub const timeout_ms = 30_000

/// `module.function(args...)` in a new VM: `Ok` with what it returned, or
/// `Error` when the child crashed, exited without an answer, or did not
/// answer within `timeout` milliseconds (it is then killed with SIGKILL and
/// awaited). `module` is the Erlang name (`brazier@build@files`). The
/// result type is whatever the caller annotates: the call is untyped.
@external(erlang, "brazier_dir_test_ffi", "call_in_child")
pub fn call(
  module: String,
  function: String,
  args: List(String),
  timeout: Int,
) -> Result(a, String)

/// Delete `dir` and everything below it in a child VM, through
/// `files.delete_if_exists`, and fail the test if that does not succeed.
pub fn delete_tree(dir: String) -> Nil {
  let deleted: Result(Result(Nil, String), String) =
    call("brazier@build@files", "delete_if_exists", [dir], timeout_ms)
  let assert Ok(Ok(Nil)) = deleted as "the child VM deletes the test directory"
  Nil
}

/// True on macOS, where OTP's listing has the bug.
@external(erlang, "brazier_dir_test_ffi", "is_macos")
pub fn is_macos() -> Bool
