/// Environment-based configuration for Brazier apps.
/// Reads from environment variables. A variable that is set but invalid is an
/// error, never silently replaced by a default.
import brazier/error.{type BrazierError}
import brazier/log
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The minimum secret_key length in bytes. Join tokens and session data are
/// signed with HMAC-SHA256, whose security needs a key of at least the hash
/// length (32 bytes; RFC 2104 section 3). Generate one with
/// `openssl rand -base64 48`.
pub const min_secret_key_bytes = 32

/// The secret this module used to return when SECRET_KEY was unset, from
/// before the package was renamed to `brazier`. It is public, so it is
/// refused like any other weak key; it keeps its old spelling because that
/// is the value deployments may still carry.
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
pub fn get_env_int(name: String, default: Int) -> Result(Int, BrazierError) {
  case env_get(name) {
    Error(Nil) -> Ok(default)
    Ok(value) ->
      case int.parse(value) {
        Ok(n) -> Ok(n)
        Error(Nil) -> {
          log.error(
            "brazier.config",
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
pub fn port() -> Result(Int, BrazierError) {
  case get_env_int("PORT", 8080) {
    Error(err) -> Error(err)
    Ok(port) if port >= 0 && port <= 65_535 -> Ok(port)
    Ok(port) -> {
      log.error("brazier.config", "PORT out of range: " <> int.to_string(port))
      Error(error.ConfigError(
        reason: "PORT must be in 0..65535, got " <> int.to_string(port),
      ))
    }
  }
}

/// Get the secret key from the SECRET_KEY env var. It must be set and pass
/// `validate_secret_key`; there is no built-in default.
pub fn secret_key() -> Result(String, BrazierError) {
  case env_get("SECRET_KEY") {
    Ok(key) -> validate_secret_key(key)
    Error(Nil) -> {
      log.error("brazier.config", "SECRET_KEY is not set")
      Error(error.ConfigError(
        reason: "SECRET_KEY is not set (generate one with `openssl rand -base64 48`)",
      ))
    }
  }
}

/// Check that a secret key is strong enough to sign tokens: at least
/// `min_secret_key_bytes` bytes and not the formerly built-in dev secret.
/// The key itself is never logged or included in the error.
pub fn validate_secret_key(key: String) -> Result(String, BrazierError) {
  let size = bit_array.byte_size(<<key:utf8>>)
  case size >= min_secret_key_bytes, key == published_dev_secret {
    _, True -> {
      log.error("brazier.config", "secret_key is the published dev secret")
      Error(error.ConfigError(
        reason: "secret_key is the published dev secret of earlier releases; generate a private one",
      ))
    }
    False, False -> {
      log.error(
        "brazier.config",
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

/// The environment variables Brazier itself reads. `refuse_renamed_env`
/// checks their pre-rename names when an application or cluster starts.
pub const framework_env_vars = ["BRAZIER_ENV", "BRAZIER_SHUTDOWN_TIMEOUT"]

/// The prefix of every Brazier environment variable.
pub const env_prefix = "BRAZIER_"

/// The prefix the same variables had before the package was renamed from
/// `beacon` to `brazier` (2026-11-04). Old names are refused, never read: a
/// deployment that still sets one would otherwise run with the default in
/// its place (a production node treated as dev, a drain timeout ignored).
const renamed_env_prefix = "BEACON_"

/// The name `name` (which starts with `BRAZIER_`) had before the rename.
@internal
pub fn renamed_env_name(name: String) -> String {
  // Callers pass the constant names of the variables they read; a name
  // without the prefix is a programming error in Brazier itself.
  let assert True = string.starts_with(name, env_prefix)
    as "refuse_renamed_env takes BRAZIER_ names only"
  renamed_env_prefix <> string.drop_start(name, string.length(env_prefix))
}

/// Refuse to start when the pre-rename name of any of `names` is set,
/// naming the variable to set instead. Only whether the old name is set is
/// checked: its value is never read, logged or used.
@internal
pub fn refuse_renamed_env(names: List(String)) -> Result(Nil, BrazierError) {
  let set =
    list.filter(names, fn(name) {
      case env_get(renamed_env_name(name)) {
        Ok(_) -> True
        Error(Nil) -> False
      }
    })
  case set {
    [] -> {
      log.debug(
        "brazier.config",
        "No renamed environment variable is set (checked "
          <> int.to_string(list.length(names))
          <> ")",
      )
      Ok(Nil)
    }
    _ -> {
      let renames =
        list.map(set, fn(name) {
          let old = renamed_env_name(name)
          log.error(
            "brazier.config",
            old
              <> " is set, but Brazier no longer reads it: rename it to "
              <> name,
          )
          old <> " (now " <> name <> ")"
        })
      Error(error.ConfigError(
        reason: "renamed environment variables are set: "
        <> string.join(renames, ", ")
        <> "; set the new names instead, the old ones are not read",
      ))
    }
  }
}

/// Check if running in production mode.
pub fn is_production() -> Bool {
  case get_env("BRAZIER_ENV") {
    Some("production") | Some("prod") -> True
    _ -> False
  }
}

@external(erlang, "brazier_config_ffi", "get_env")
fn env_get(name: String) -> Result(String, Nil)
