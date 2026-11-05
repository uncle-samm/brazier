import logging

pub fn main() -> Nil {
  // Suppress logs during tests — only show critical errors
  logging.set_level(logging.Critical)
  suppress_otp_logs()
  // gleeunit.main, plus a check after each test that it left no message in
  // the test process's mailbox, and after each module that its tests left
  // no telemetry handler attached (see brazier_test_runner_ffi).
  run_tests()
}

/// Suppress OTP/Erlang logger output during tests
@external(erlang, "brazier_test_ffi", "suppress_logs")
fn suppress_otp_logs() -> Nil

@external(erlang, "brazier_test_runner_ffi", "run")
fn run_tests() -> Nil
