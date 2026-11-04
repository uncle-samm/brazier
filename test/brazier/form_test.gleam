import brazier/element
import brazier/form

pub fn new_form_test() {
  let f = form.new("secret")
  let assert [] = f.fields
  let assert [] = f.form_errors
  let assert True = str_len(f.csrf_token) > 10
}

pub fn add_and_get_field_test() {
  let f =
    form.new("secret")
    |> form.add_field("name", "Alice")
  let assert Ok(field) = form.get_field(f, "name")
  let assert "Alice" = field.value
  let assert [] = field.errors
}

pub fn get_value_test() {
  let f =
    form.new("secret")
    |> form.add_field("email", "alice@test.com")
  let assert "alice@test.com" = form.get_value(f, "email")
}

pub fn get_value_missing_field_test() {
  let f = form.new("secret")
  let assert "" = form.get_value(f, "nonexistent")
}

pub fn set_value_test() {
  let f =
    form.new("secret")
    |> form.add_field("name", "old")
    |> form.set_value("name", "new")
  let assert "new" = form.get_value(f, "name")
}

pub fn add_error_test() {
  let f =
    form.new("secret")
    |> form.add_field("name", "")
    |> form.add_error("name", "Required")
  let assert True = form.field_has_errors(f, "name")
  let assert True = form.has_errors(f)
}

pub fn clear_errors_test() {
  let f =
    form.new("secret")
    |> form.add_field("name", "")
    |> form.add_error("name", "Required")
    |> form.clear_errors
  let assert False = form.has_errors(f)
}

pub fn validate_required_empty_test() {
  let f =
    form.new("secret")
    |> form.add_field("name", "")
    |> form.validate_required("name")
  let assert True = form.field_has_errors(f, "name")
}

pub fn validate_required_filled_test() {
  let f =
    form.new("secret")
    |> form.add_field("name", "Alice")
    |> form.validate_required("name")
  let assert False = form.field_has_errors(f, "name")
}

pub fn validate_min_length_too_short_test() {
  let f =
    form.new("secret")
    |> form.add_field("password", "ab")
    |> form.validate_min_length("password", 8)
  let assert True = form.field_has_errors(f, "password")
}

pub fn validate_min_length_ok_test() {
  let f =
    form.new("secret")
    |> form.add_field("password", "longpassword123")
    |> form.validate_min_length("password", 8)
  let assert False = form.field_has_errors(f, "password")
}

pub fn form_level_error_test() {
  let f =
    form.new("secret")
    |> form.add_form_error("Something went wrong")
  let assert True = form.has_errors(f)
}

pub fn csrf_field_renders_hidden_input_test() {
  let f = form.new("secret")
  let node = form.csrf_field(f)
  let html = element.to_string(node)
  let assert True = str_contains(html, "type=\"hidden\"")
  let assert True = str_contains(html, "name=\"_csrf_token\"")
}

pub fn text_input_renders_test() {
  let f =
    form.new("secret")
    |> form.add_field("username", "alice")
  let node = form.text_input(f, "username", [])
  let html = element.to_string(node)
  let assert True = str_contains(html, "name=\"username\"")
  let assert True = str_contains(html, "value=\"alice\"")
}

pub fn text_input_with_errors_renders_error_span_test() {
  let f =
    form.new("secret")
    |> form.add_field("username", "")
    |> form.add_error("username", "Required")
  let node = form.text_input(f, "username", [])
  let html = element.to_string(node)
  let assert True = str_contains(html, "field-error")
  let assert True = str_contains(html, "Required")
}

// --- Session-bound CSRF tests ---

pub fn session_csrf_generate_and_verify_test() {
  let store = form.create_csrf_store("test_csrf_" <> unique_id())
  let token = form.generate_session_csrf(store, "session_1", "secret!!")
  let assert True = form.verify_session_csrf(store, "session_1", token)
}

pub fn session_csrf_consumed_on_use_test() {
  let store = form.create_csrf_store("test_csrf_used_" <> unique_id())
  let token = form.generate_session_csrf(store, "session_2", "secret!!")
  // First verify succeeds
  let assert True = form.verify_session_csrf(store, "session_2", token)
  // Second verify fails (token consumed)
  let assert False = form.verify_session_csrf(store, "session_2", token)
}

pub fn session_csrf_wrong_token_fails_test() {
  let store = form.create_csrf_store("test_csrf_wrong_" <> unique_id())
  let _token = form.generate_session_csrf(store, "session_3", "secret!!")
  let assert False = form.verify_session_csrf(store, "session_3", "wrong_token")
}

pub fn session_csrf_wrong_session_fails_test() {
  let store = form.create_csrf_store("test_csrf_sess_" <> unique_id())
  let token = form.generate_session_csrf(store, "session_4", "secret!!")
  let assert False = form.verify_session_csrf(store, "other_session", token)
}

pub fn validate_email_valid_test() {
  let f =
    form.new("secret")
    |> form.add_field("email", "user@example.com")
    |> form.validate_email("email")
  let assert False = form.has_errors(f)
}

pub fn validate_email_invalid_test() {
  let f =
    form.new("secret")
    |> form.add_field("email", "not-an-email")
    |> form.validate_email("email")
  let assert True = form.has_errors(f)
}

pub fn validate_max_length_test() {
  let f =
    form.new("secret")
    |> form.add_field("name", "toolongvalue")
    |> form.validate_max_length("name", 5)
  let assert True = form.has_errors(f)
}

pub fn validate_matches_test() {
  let f =
    form.new("secret")
    |> form.add_field("password", "abc123")
    |> form.add_field("confirm", "abc123")
    |> form.validate_matches("confirm", "password", "Passwords must match")
  let assert False = form.has_errors(f)
}

pub fn validate_matches_mismatch_test() {
  let f =
    form.new("secret")
    |> form.add_field("password", "abc123")
    |> form.add_field("confirm", "xyz789")
    |> form.validate_matches("confirm", "password", "Passwords must match")
  let assert True = form.has_errors(f)
}

pub fn validate_pipeline_test() {
  let f =
    form.new("secret")
    |> form.add_field("name", "")
    |> form.add_field("email", "bad")
    |> form.validate([
      form.validate_required(_, "name"),
      form.validate_email(_, "email"),
    ])
  let assert True = form.has_errors(f)
  let assert True = form.field_has_errors(f, "name")
  let assert True = form.field_has_errors(f, "email")
}

fn unique_id() -> String {
  do_unique_id()
}

@external(erlang, "brazier_test_ffi", "unique_ref")
fn do_unique_id() -> String

// --- Helpers ---

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "brazier_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool

fn str_len(s: String) -> Int {
  do_str_len(s)
}

@external(erlang, "erlang", "byte_size")
fn do_str_len(s: String) -> Int
