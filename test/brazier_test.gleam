import gleeunit
import logging

pub fn main() -> Nil {
  // Suppress logs during tests — only show critical errors
  logging.set_level(logging.Critical)
  suppress_otp_logs()
  gleeunit.main()
}

/// Suppress OTP/Erlang logger output during tests
@external(erlang, "brazier_test_ffi", "suppress_logs")
fn suppress_otp_logs() -> Nil
