//// Beacon's Erlang modules log through beacon_log_ffi, which formats the
//// line before it reaches logger. A raw logger:info(Format, Args) call
//// reaches the gleam `logging` formatter as a {Format, Args} tuple, which
//// it prints inspected instead of formatted. These tests render captured
//// FFI log lines through that formatter and OTP's, and check that no
//// module bypasses the helper.

import beacon/presence
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import simplifile

type Rendered {
  Rendered(gleam: String, otp: String, context: String)
}

@external(erlang, "beacon_ws8c_log_format_ffi", "capture")
fn capture(fun: fn() -> a) -> #(a, List(#(String, String, String)))

@external(erlang, "beacon_ws8c_log_format_ffi", "text_crash")
fn text_crash() -> Result(String, String)

@external(erlang, "beacon_log_ffi", "text")
fn log_text(context: String, format: String, args: List(a)) -> String

fn rendered(fun: fn() -> a) -> #(a, List(Rendered)) {
  let #(result, events) = capture(fun)
  #(result, list.map(events, fn(e) { Rendered(e.0, e.1, e.2) }))
}

/// A presence read on a tracker that is not running logs a warning from
/// beacon_presence_ffi in the calling process, with a formatted atom.
pub fn ffi_line_is_readable_under_the_gleam_formatter_test() {
  let assert Ok(tracker) =
    presence.handle(presence.new("ws8c_logfmt", json.string, decode.string))
  let #(result, logs) = rendered(fn() { presence.list(tracker, "room") })
  assert result == Error(presence.TrackerDown)

  let assert [line] =
    list.filter(logs, fn(l) { string.contains(l.gleam, "is missing") })
  assert line.gleam
    == "WARN [beacon.presence] Table beacon_presence_ws8c_logfmt_1 is missing: "
    <> "its shard is not running\n"
  assert line.context == "beacon.presence"
  // The bug this guards against: the inspected {Format, Args} tuple.
  assert !string.contains(line.gleam, "~p")
  assert !string.contains(line.gleam, "#(")
}

pub fn ffi_line_is_readable_under_the_otp_formatter_test() {
  let assert Ok(tracker) =
    presence.handle(presence.new("ws8c_logfmt_otp", json.string, decode.string))
  let #(_, logs) = rendered(fn() { presence.list(tracker, "room") })
  let assert [line] =
    list.filter(logs, fn(l) { string.contains(l.otp, "is missing") })
  assert line.otp
    == "warning [beacon.presence] Table beacon_presence_ws8c_logfmt_otp_1 is "
    <> "missing: its shard is not running\n"
}

pub fn text_has_the_gleam_log_shape_test() {
  assert log_text("beacon.http_conns", "started port=~p ids=~p", [8080, 3])
    == "[beacon.http_conns] started port=8080 ids=3"
}

/// A format string that does not match its arguments is a bug and crashes.
pub fn mismatched_format_crashes_test() {
  assert text_crash() == Error("badarg")
}

/// Every Erlang module in src logs through beacon_log_ffi. A direct
/// logger: call would bring the inspected-tuple output back.
pub fn no_module_calls_logger_directly_test() {
  let assert Ok(files) = simplifile.get_files("src")
  let offenders =
    files
    |> list.filter(fn(path) { string.ends_with(path, ".erl") })
    |> list.filter(fn(path) {
      !string.ends_with(path, "/beacon_log_ffi.erl")
      && !string.ends_with(path, "/beacon_lint_ffi.erl")
    })
    |> list.filter(fn(path) {
      let assert Ok(source) = simplifile.read(path)
      string.contains(source, "logger:")
    })
  assert offenders == []
}
