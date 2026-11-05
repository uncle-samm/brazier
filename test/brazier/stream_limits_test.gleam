//// The five stream fields of `SecurityLimits` (docs/design/STREAMS.md
//// 7.4, decision D4): their defaults, the bounds `transport.stream_limits`
//// hands the runtime and the dead render, and their validation.

import brazier/internal/stream_window
import brazier/transport

pub fn defaults_are_the_d4_bounds_test() {
  let limits = transport.default_security_limits()
  assert limits.stream_max_limit == 1000
  assert limits.stream_item_max_bytes == 65_536
  assert limits.stream_ops_max_per_update == 1000
  assert limits.stream_frame_max_bytes == 1_048_576
  assert limits.stream_key_max_bytes == 256
  assert transport.stream_limits(limits) == stream_window.default_limits()
}

pub fn stream_limits_reads_each_field_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      stream_max_limit: 10,
      stream_item_max_bytes: 20,
      stream_ops_max_per_update: 30,
      stream_frame_max_bytes: 40,
      stream_key_max_bytes: 50,
    )
  let assert Ok(Nil) = transport.validate_security_limits(limits)
  assert transport.stream_limits(limits)
    == stream_window.Limits(
      max_limit: 10,
      item_max_bytes: 20,
      ops_max_per_update: 30,
      frame_max_bytes: 40,
      key_max_bytes: 50,
    )
}

pub fn every_stream_field_must_be_positive_test() {
  let base = transport.default_security_limits()
  let assert Error("stream_max_limit must be > 0") =
    transport.validate_security_limits(
      transport.SecurityLimits(..base, stream_max_limit: 0),
    )
  let assert Error("stream_item_max_bytes must be > 0") =
    transport.validate_security_limits(
      transport.SecurityLimits(..base, stream_item_max_bytes: 0),
    )
  let assert Error("stream_ops_max_per_update must be > 0") =
    transport.validate_security_limits(
      transport.SecurityLimits(..base, stream_ops_max_per_update: -1),
    )
  let assert Error("stream_frame_max_bytes must be > 0") =
    transport.validate_security_limits(
      transport.SecurityLimits(..base, stream_frame_max_bytes: 0),
    )
  let assert Error("stream_key_max_bytes must be > 0") =
    transport.validate_security_limits(
      transport.SecurityLimits(..base, stream_key_max_bytes: 0),
    )
  Nil
}

pub fn stream_max_limit_is_at_most_the_wire_bound_test() {
  let base = transport.default_security_limits()
  let assert Ok(Nil) =
    transport.validate_security_limits(
      transport.SecurityLimits(
        ..base,
        stream_max_limit: transport.stream_wire_max_limit,
      ),
    )
  let assert Error(
    "stream_max_limit must be <= 1000 (the largest limit the client accepts)",
  ) =
    transport.validate_security_limits(
      transport.SecurityLimits(
        ..base,
        stream_max_limit: transport.stream_wire_max_limit + 1,
      ),
    )
  Nil
}
