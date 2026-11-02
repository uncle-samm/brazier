/// Environment-based configuration for Beacon apps.
/// Reads from environment variables. A variable that is set but invalid is an
/// error, never silently replaced by a default.
import beacon/error.{type BeaconError}
import beacon/log
import gleam/bit_array
import gleam/int
import gleam/option.{type Option, None, Some}

/// The minimum secret_key length in bytes. Join tokens and session data are
/// signed with HMAC-SHA256, whose security needs a key of at least the hash
/// length (32 bytes; RFC 2104 section 3). Generate one with
/// `openssl rand -base64 48`.
pub const min_secret_key_bytes = 32

/// The secret this module used to return when SECRET_KEY was unset. It is
/// public, so it is refused like any other weak key.
const published_dev_secret = "beacon-dev-secret-change-in-production"

/// Get an environment variable, returning None if not set.
pub fn get_env(name: String) -> Option(String) {
  case env_get(name) {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

/// Get an environment variable with a default for when it is unset.
pub fn get_env_or(name: String, default: String) -> String {
  case env_get(name) {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

/// Get an integer environment variable. Unset gives `default`; set to
/// something that is not an integer is an error (a typo in PORT must not
/// quietly start the server elsewhere).
pub fn get_env_int(name: String, default: Int) -> Result(Int, BeaconError) {
  case env_get(name) {
    Error(Nil) -> Ok(default)
    Ok(value) ->
      case int.parse(value) {
        Ok(n) -> Ok(n)
        Error(Nil) -> {
          log.error(
            "beacon.config",
            name <> " is set but is not an integer: " <> value,
          )
          Error(error.ConfigError(
            reason: name <> " must be an integer, got \"" <> value <> "\"",
          ))
        }
      }
  }
}

/// Get the port from PORT env var, defaulting to 8080 when unset. A set
/// value must be an integer in 0..65535.
pub fn port() -> Result(Int, BeaconError) {
  case get_env_int("PORT", 8080) {
    Error(err) -> Error(err)
    Ok(port) if port >= 0 && port <= 65_535 -> Ok(port)
    Ok(port) -> {
      log.error("beacon.config", "PORT out of range: " <> int.to_string(port))
      Error(error.ConfigError(
        reason: "PORT must be in 0..65535, got " <> int.to_string(port),
      ))
    }
  }
}

/// Get the secret key from the SECRET_KEY env var. It must be set and pass
/// `validate_secret_key`; there is no built-in default.
pub fn secret_key() -> Result(String, BeaconError) {
  case env_get("SECRET_KEY") {
    Ok(key) -> validate_secret_key(key)
    Error(Nil) -> {
      log.error("beacon.config", "SECRET_KEY is not set")
      Error(error.ConfigError(
        reason: "SECRET_KEY is not set (generate one with `openssl rand -base64 48`)",
      ))
    }
  }
}

/// Check that a secret key is strong enough to sign tokens: at least
/// `min_secret_key_bytes` bytes and not the formerly built-in dev secret.
/// The key itself is never logged or included in the error.
pub fn validate_secret_key(key: String) -> Result(String, BeaconError) {
  let size = bit_array.byte_size(<<key:utf8>>)
  case size >= min_secret_key_bytes, key == published_dev_secret {
    _, True -> {
      log.error("beacon.config", "secret_key is the published dev secret")
      Error(error.ConfigError(
        reason: "secret_key is the published Beacon dev secret; generate a private one",
      ))
    }
    False, False -> {
      log.error(
        "beacon.config",
        "secret_key is too short: "
          <> int.to_string(size)
          <> " bytes, need at least "
          <> int.to_string(min_secret_key_bytes),
      )
      Error(error.ConfigError(
        reason: "secret_key must be at least "
        <> int.to_string(min_secret_key_bytes)
        <> " bytes, got "
        <> int.to_string(size),
      ))
    }
    True, False -> Ok(key)
  }
}

/// Check if running in production mode.
pub fn is_production() -> Bool {
  case get_env("BEACON_ENV") {
    Some("production") | Some("prod") -> True
    _ -> False
  }
}

@external(erlang, "beacon_config_ffi", "get_env")
fn env_get(name: String) -> Result(String, Nil)
