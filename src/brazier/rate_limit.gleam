/// Fixed-window rate limiting backed by an ETS table with an owner process.
///
/// Requests are counted per key (typically the client IP) per window of
/// `window_seconds`. Memory is bounded: the owner deletes counters of past
/// windows every window, and at most `max_keys` counters exist at once. When
/// the cap is reached a request from a key without a counter is refused
/// (fail closed) and the refusal is logged at error level.
///
/// The limiter's owner process is linked to, and monitors, the process that
/// called `new`: create limiters from a long-lived process (your `main`, or
/// a supervised worker), never from a request handler.
///
/// Pass a limiter to `middleware.rate_limit` to limit HTTP requests per
/// client IP, or call `check` from your own code.
///
/// Reference: Phoenix rate limiting (Hammer's fixed-window ETS backend),
/// OWASP rate limiting guidelines.
import brazier/log
import gleam/erlang/process
import gleam/int

/// Rate limit configuration.
pub type RateLimitConfig {
  RateLimitConfig(
    /// Maximum requests allowed per window. Must be at least 1.
    max_requests: Int,
    /// Window duration in seconds. Must be at least 1.
    window_seconds: Int,
  )
}

/// Default hard cap on live counters per limiter.
pub const default_max_keys = 100_000

/// A running rate limiter. Create one with `new` or `new_with_max_keys`,
/// which validate the settings; read them with `config` and `max_keys`.
pub opaque type RateLimiter {
  RateLimiter(handle: Handle, config: RateLimitConfig, max_keys: Int)
}

/// Result of a rate limit check.
pub type RateLimitResult {
  /// Request is allowed.
  Allowed(remaining: Int)
  /// Request is rate limited (over the limit, or refused because the
  /// limiter is at its key cap or no longer running).
  RateLimited
}

/// Opaque handle to the limiter's ETS table and owner.
pub type Handle

type IncrementError {
  AtCapacity(refused: Int)
  LimiterDown
}

/// Create a rate limiter with the default key cap.
/// Errors on invalid settings, an invalid name, or a name already in use.
pub fn new(
  name: String,
  config: RateLimitConfig,
) -> Result(RateLimiter, String) {
  new_with_max_keys(name, config, default_max_keys)
}

/// Create a rate limiter with an explicit cap on live counters.
pub fn new_with_max_keys(
  name: String,
  config: RateLimitConfig,
  max_keys: Int,
) -> Result(RateLimiter, String) {
  let settings = case config {
    RateLimitConfig(max_requests: n, ..) if n < 1 ->
      Error("max_requests must be at least 1, got " <> int.to_string(n))
    RateLimitConfig(window_seconds: n, ..) if n < 1 ->
      Error("window_seconds must be at least 1, got " <> int.to_string(n))
    _ if max_keys < 1 ->
      Error("max_keys must be at least 1, got " <> int.to_string(max_keys))
    _ -> Ok(Nil)
  }
  let started = case settings {
    Error(reason) -> Error(reason)
    Ok(Nil) -> ffi_start(name, config.window_seconds, max_keys)
  }
  case started {
    Ok(handle) -> {
      log.info(
        "brazier.rate_limit",
        "Created rate limiter "
          <> name
          <> " ("
          <> int.to_string(config.max_requests)
          <> " req/"
          <> int.to_string(config.window_seconds)
          <> "s, max "
          <> int.to_string(max_keys)
          <> " keys)",
      )
      Ok(RateLimiter(handle: handle, config: config, max_keys: max_keys))
    }
    Error(reason) -> {
      log.error(
        "brazier.rate_limit",
        "Could not create rate limiter " <> name <> ": " <> reason,
      )
      Error(reason)
    }
  }
}

/// Count a request from `key` and decide whether it is allowed.
pub fn check(limiter: RateLimiter, key: String) -> RateLimitResult {
  let settings = #(limiter.config.window_seconds, limiter.max_keys)
  case ffi_increment(limiter.handle, key, settings) {
    Ok(count) ->
      case count > limiter.config.max_requests {
        True -> {
          log.warning("brazier.rate_limit", "Rate limited: " <> key)
          RateLimited
        }
        False -> Allowed(remaining: limiter.config.max_requests - count)
      }
    Error(AtCapacity(refused)) -> {
      // Log the first refusal after each sweep immediately; the owner logs
      // the running total on every sweep, so a key flood cannot flood logs.
      case refused {
        1 ->
          log.error(
            "brazier.rate_limit",
            "Rate limiter at its cap of "
              <> int.to_string(limiter.max_keys)
              <> " keys: refusing new client "
              <> key,
          )
        _ -> Nil
      }
      RateLimited
    }
    Error(LimiterDown) -> {
      log.error(
        "brazier.rate_limit",
        "Rate limiter is not running (its owner exited): refusing " <> key,
      )
      RateLimited
    }
  }
}

/// Delete every counter for a key.
pub fn reset(limiter: RateLimiter, key: String) -> Result(Nil, Nil) {
  case ffi_delete_key(limiter.handle, key) {
    Ok(Nil) -> {
      log.debug("brazier.rate_limit", "Reset counters for " <> key)
      Ok(Nil)
    }
    Error(Nil) -> {
      log.error(
        "brazier.rate_limit",
        "Cannot reset " <> key <> ": the rate limiter is not running",
      )
      Error(Nil)
    }
  }
}

/// Number of live counters (one per key per active window).
pub fn key_count(limiter: RateLimiter) -> Result(Int, Nil) {
  ffi_key_count(limiter.handle)
}

/// Delete expired counters now instead of waiting for the next periodic
/// sweep. Returns how many counters were deleted.
pub fn sweep(limiter: RateLimiter) -> Result(Int, Nil) {
  case ffi_sweep_now(limiter.handle) {
    Ok(deleted) -> {
      log.debug(
        "brazier.rate_limit",
        "Swept " <> int.to_string(deleted) <> " expired counters",
      )
      Ok(deleted)
    }
    Error(Nil) -> {
      log.error("brazier.rate_limit", "Cannot sweep: limiter is not running")
      Error(Nil)
    }
  }
}

/// The limiter's settings.
pub fn config(limiter: RateLimiter) -> RateLimitConfig {
  limiter.config
}

/// The limiter's cap on live counters.
pub fn max_keys(limiter: RateLimiter) -> Int {
  limiter.max_keys
}

/// The owner process of the limiter's table.
@internal
pub fn owner(limiter: RateLimiter) -> process.Pid {
  ffi_owner(limiter.handle)
}

// --- FFI ---

@external(erlang, "brazier_rate_limit_ffi", "start")
fn ffi_start(
  name: String,
  window_seconds: Int,
  max_keys: Int,
) -> Result(Handle, String)

@external(erlang, "brazier_rate_limit_ffi", "increment")
fn ffi_increment(
  handle: Handle,
  key: String,
  settings: #(Int, Int),
) -> Result(Int, IncrementError)

@external(erlang, "brazier_rate_limit_ffi", "delete_key")
fn ffi_delete_key(handle: Handle, key: String) -> Result(Nil, Nil)

@external(erlang, "brazier_rate_limit_ffi", "key_count")
fn ffi_key_count(handle: Handle) -> Result(Int, Nil)

@external(erlang, "brazier_rate_limit_ffi", "sweep_now")
fn ffi_sweep_now(handle: Handle) -> Result(Int, Nil)

@external(erlang, "brazier_rate_limit_ffi", "owner")
fn ffi_owner(handle: Handle) -> process.Pid
