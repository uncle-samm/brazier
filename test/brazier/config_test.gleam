import brazier/config
import brazier/error
import gleam/option
import gleam/string

pub fn get_env_missing_test() {
  let assert option.None = config.get_env("BRAZIER_TEST_NONEXISTENT_VAR")
}

pub fn get_env_or_default_test() {
  let assert "default" =
    config.get_env_or("BRAZIER_TEST_NONEXISTENT_VAR", "default")
}

pub fn get_env_int_default_test() {
  let assert Ok(8080) = config.get_env_int("BRAZIER_TEST_NONEXISTENT_VAR", 8080)
}

pub fn get_env_int_reads_a_set_value_test() {
  with_env("BRAZIER_TEST_INT", "4242", fn() {
    let assert Ok(4242) = config.get_env_int("BRAZIER_TEST_INT", 1)
  })
}

pub fn get_env_int_refuses_a_malformed_value_test() {
  with_env("BRAZIER_TEST_INT", "80 80", fn() {
    let assert Error(error.ConfigError(reason)) =
      config.get_env_int("BRAZIER_TEST_INT", 8080)
    let assert True = string.contains(reason, "BRAZIER_TEST_INT")
  })
}

pub fn port_validates_range_test() {
  with_env("PORT", "4000", fn() {
    let assert Ok(4000) = config.port()
  })
  with_env("PORT", "70000", fn() {
    let assert Error(error.ConfigError(_)) = config.port()
  })
  with_env("PORT", "-1", fn() {
    let assert Error(error.ConfigError(_)) = config.port()
  })
  with_env("PORT", "eighty", fn() {
    let assert Error(error.ConfigError(_)) = config.port()
  })
}

pub fn secret_key_must_be_strong_test() {
  let strong = "0123456789abcdef0123456789abcdef"
  with_env("SECRET_KEY", strong, fn() {
    let assert Ok(key) = config.secret_key()
    let assert True = key == strong
  })
  with_env("SECRET_KEY", "short", fn() {
    let assert Error(error.ConfigError(reason)) = config.secret_key()
    // The key itself never appears in the error.
    let assert False = string.contains(reason, "short")
  })
  with_env("SECRET_KEY", "beacon-dev-secret-change-in-production", fn() {
    let assert Error(error.ConfigError(_)) = config.secret_key()
  })
}

pub fn validate_secret_key_test() {
  let assert Error(error.ConfigError(_)) = config.validate_secret_key("")
  let assert Error(error.ConfigError(_)) =
    config.validate_secret_key(string.repeat("a", 31))
  let assert Ok(_) = config.validate_secret_key(string.repeat("a", 32))
  // Bytes, not characters: 16 two-byte characters are 32 bytes.
  let assert Ok(_) = config.validate_secret_key(string.repeat("\u{e9}", 16))
}

/// Each Brazier variable's pre-rename name is the same name with the old
/// package prefix.
pub fn renamed_env_name_test() {
  assert config.renamed_env_name("BRAZIER_ENV") == "BEACON_ENV"
  assert config.renamed_env_name("BRAZIER_SHUTDOWN_TIMEOUT")
    == "BEACON_SHUTDOWN_TIMEOUT"
  assert config.framework_env_vars
    == ["BRAZIER_ENV", "BRAZIER_SHUTDOWN_TIMEOUT"]
}

/// A variable set under its pre-rename name is refused, naming the variable
/// to set instead; its value never reaches the error. The new name alone,
/// or neither, is accepted. (A test-only name, so no concurrently starting
/// application sees it.)
pub fn refuse_renamed_env_refuses_the_old_name_test() {
  let names = ["BRAZIER_TEST_RENAMED", "BRAZIER_TEST_NONEXISTENT_VAR"]
  let assert Ok(Nil) = config.refuse_renamed_env(names)
  with_env("BRAZIER_TEST_RENAMED", "new-value", fn() {
    let assert Ok(Nil) = config.refuse_renamed_env(names)
  })
  with_env("BEACON_TEST_RENAMED", "old-value", fn() {
    let assert Error(error.ConfigError(reason)) =
      config.refuse_renamed_env(names)
    assert string.contains(
      reason,
      "BEACON_TEST_RENAMED (now BRAZIER_TEST_RENAMED)",
    )
    assert !string.contains(reason, "BRAZIER_TEST_NONEXISTENT_VAR")
    assert !string.contains(reason, "old-value")
    // Setting the new name too does not make the old one acceptable.
    with_env("BRAZIER_TEST_RENAMED", "new-value", fn() {
      let assert Error(error.ConfigError(_)) = config.refuse_renamed_env(names)
    })
  })
  let assert Ok(Nil) = config.refuse_renamed_env(names)
}

fn with_env(name: String, value: String, run: fn() -> a) -> Nil {
  let previous = put_env(name, value)
  run()
  restore_env(name, previous)
}

type Previous

@external(erlang, "brazier_config_test_ffi", "put_env")
fn put_env(name: String, value: String) -> Previous

@external(erlang, "brazier_config_test_ffi", "restore_env")
fn restore_env(name: String, previous: Previous) -> Nil
