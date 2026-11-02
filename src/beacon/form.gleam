/// Form handling helpers for Beacon.
/// Provides form field binding, validation, and CSRF protection.
///
/// Reference: LiveView form handling, Livewire form validation.
import beacon/element.{type Attr, type Node}
import beacon/log
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/string

/// A form field with a value and optional validation errors.
pub type Field {
  Field(
    /// The field name (used as the HTML name attribute).
    name: String,
    /// The current value.
    value: String,
    /// Validation errors for this field (empty if valid).
    errors: List(String),
  )
}

/// A form with multiple fields and form-level errors.
pub type Form {
  Form(
    /// All fields in the form.
    fields: List(Field),
    /// Form-level errors (not tied to a specific field).
    form_errors: List(String),
    /// CSRF token for the form.
    csrf_token: String,
  )
}

/// Create a new empty form with a CSRF token (256 random bits).
/// `secret_key` is not needed for a random token; the parameter is kept so
/// existing callers compile.
pub fn new(_secret_key: String) -> Form {
  Form(fields: [], form_errors: [], csrf_token: generate_csrf_token())
}

/// Add a field to the form.
pub fn add_field(form: Form, name: String, value: String) -> Form {
  let field = Field(name: name, value: value, errors: [])
  Form(..form, fields: list.append(form.fields, [field]))
}

/// Get a field by name.
pub fn get_field(form: Form, name: String) -> Result(Field, Nil) {
  list.find(form.fields, fn(f) { f.name == name })
}

/// Get a field's value by name, returning empty string if not found.
pub fn get_value(form: Form, name: String) -> String {
  case get_field(form, name) {
    Ok(field) -> field.value
    Error(Nil) -> ""
  }
}

/// Set a field's value.
pub fn set_value(form: Form, name: String, value: String) -> Form {
  let new_fields =
    list.map(form.fields, fn(f) {
      case f.name == name {
        True -> Field(..f, value: value)
        False -> f
      }
    })
  Form(..form, fields: new_fields)
}

/// Add a validation error to a field.
pub fn add_error(form: Form, field_name: String, error: String) -> Form {
  let new_fields =
    list.map(form.fields, fn(f) {
      case f.name == field_name {
        True -> Field(..f, errors: list.append(f.errors, [error]))
        False -> f
      }
    })
  Form(..form, fields: new_fields)
}

/// Add a form-level error.
pub fn add_form_error(form: Form, error: String) -> Form {
  Form(..form, form_errors: list.append(form.form_errors, [error]))
}

/// Clear all errors from the form.
pub fn clear_errors(form: Form) -> Form {
  let new_fields = list.map(form.fields, fn(f) { Field(..f, errors: []) })
  Form(..form, fields: new_fields, form_errors: [])
}

/// Check if the form has any errors.
pub fn has_errors(form: Form) -> Bool {
  case form.form_errors {
    [_, ..] -> True
    [] ->
      list.any(form.fields, fn(f) {
        case f.errors {
          [_, ..] -> True
          [] -> False
        }
      })
  }
}

/// Check if a specific field has errors.
pub fn field_has_errors(form: Form, name: String) -> Bool {
  case get_field(form, name) {
    Ok(field) ->
      case field.errors {
        [_, ..] -> True
        [] -> False
      }
    Error(Nil) -> {
      log.debug(
        "beacon.form",
        "Field not found while checking errors: " <> name,
      )
      False
    }
  }
}

/// Validate that a field is not empty.
pub fn validate_required(form: Form, field_name: String) -> Form {
  case get_field(form, field_name) {
    Ok(field) -> {
      case string.is_empty(string.trim(field.value)) {
        True -> add_error(form, field_name, "This field is required")
        False -> form
      }
    }
    Error(Nil) -> add_error(form, field_name, "Field not found")
  }
}

/// Validate that a field's value has a minimum length.
pub fn validate_min_length(form: Form, field_name: String, min: Int) -> Form {
  case get_field(form, field_name) {
    Ok(field) -> {
      case string.length(field.value) < min {
        True ->
          add_error(
            form,
            field_name,
            "Must be at least " <> int.to_string(min) <> " characters",
          )
        False -> form
      }
    }
    Error(Nil) -> form
  }
}

/// Validate that a field matches a regex-like pattern (email format).
pub fn validate_email(form: Form, field_name: String) -> Form {
  case get_field(form, field_name) {
    Ok(field) -> {
      case
        string.contains(field.value, "@") && string.contains(field.value, ".")
      {
        True -> form
        False -> add_error(form, field_name, "Invalid email address")
      }
    }
    Error(Nil) -> form
  }
}

/// Validate that a field's value has a maximum length.
pub fn validate_max_length(form: Form, field_name: String, max: Int) -> Form {
  case get_field(form, field_name) {
    Ok(field) -> {
      case string.length(field.value) > max {
        True ->
          add_error(
            form,
            field_name,
            "Must be at most " <> int.to_string(max) <> " characters",
          )
        False -> form
      }
    }
    Error(Nil) -> form
  }
}

/// Validate that two fields match (e.g., password confirmation).
pub fn validate_matches(
  form: Form,
  field_name: String,
  other_field: String,
  error_msg: String,
) -> Form {
  let val1 = get_value(form, field_name)
  let val2 = get_value(form, other_field)
  case val1 == val2 {
    True -> form
    False -> add_error(form, field_name, error_msg)
  }
}

/// Validate a form by running multiple validation functions.
pub fn validate(form: Form, validators: List(fn(Form) -> Form)) -> Form {
  list.fold(validators, clear_errors(form), fn(f, validator) { validator(f) })
}

/// Render a password input field.
pub fn password_input(
  form: Form,
  name: String,
  attrs: List(Attr),
) -> Node(msg) {
  let value = get_value(form, name)
  let base_attrs = [
    element.attr("type", "password"),
    element.attr("name", name),
    element.attr("value", value),
    element.on("input", name),
  ]
  let all_attrs = list.append(base_attrs, attrs)
  element.el("input", all_attrs, [])
}

/// Render a textarea field.
pub fn textarea(form: Form, name: String, attrs: List(Attr)) -> Node(msg) {
  let value = get_value(form, name)
  let base_attrs = [
    element.attr("name", name),
    element.on("input", name),
  ]
  let all_attrs = list.append(base_attrs, attrs)
  element.el("textarea", all_attrs, [element.text(value)])
}

/// Render a select dropdown.
pub fn select(
  form: Form,
  name: String,
  options: List(#(String, String)),
  attrs: List(Attr),
) -> Node(msg) {
  let current = get_value(form, name)
  let base_attrs = [
    element.attr("name", name),
    element.on("change", name),
  ]
  let all_attrs = list.append(base_attrs, attrs)
  let option_nodes =
    list.map(options, fn(opt) {
      let #(value, label) = opt
      let selected_attrs = case value == current {
        True -> [
          element.attr("value", value),
          element.attr("selected", "selected"),
        ]
        False -> [element.attr("value", value)]
      }
      element.el("option", selected_attrs, [element.text(label)])
    })
  element.el("select", all_attrs, option_nodes)
}

/// Generate a CSRF token: 256 bits from the OS CSPRNG, hex-encoded. (The
/// token used to be SHA-256 of a sequential integer and the secret, which is
/// guessable whenever the secret is weak or leaked.)
fn generate_csrf_token() -> String {
  crypto.strong_random_bytes(32)
  |> bit_array.base16_encode
  |> string.lowercase
}

// NOTE: A stateless `verify_csrf(token)` cannot provide real CSRF protection —
// it has nothing to compare the token against. Use `generate_session_csrf` and
// `verify_session_csrf` below, which store the token server-side and consume it
// on use (one-time, replay-resistant).

/// Opaque ETS table for CSRF token storage.
pub type CsrfStore

/// Create a session-bound CSRF token store backed by ETS.
/// Tokens are one-time-use: consumed on verification.
pub fn create_csrf_store(name: String) -> CsrfStore {
  csrf_ets_new(name)
}

/// Generate a session-bound CSRF token (256 random bits) and store it in
/// ETS, replacing any earlier token for the session. Returns the token.
/// `secret` is not needed for a random token; the parameter is kept so
/// existing callers compile.
pub fn generate_session_csrf(
  store: CsrfStore,
  session_id: String,
  _secret: String,
) -> String {
  let token = generate_csrf_token()
  csrf_ets_put(store, session_id, token)
  token
}

/// Verify a session-bound CSRF token against the store.
/// The comparison is constant-time, and the token is consumed atomically on
/// success (one-time: of two concurrent requests with the same token, only
/// one succeeds). A wrong token does not consume the stored one.
/// Returns True if valid, False if invalid or already used.
pub fn verify_session_csrf(
  store: CsrfStore,
  session_id: String,
  token: String,
) -> Bool {
  case csrf_consume(store, session_id, token) {
    Ok(Nil) -> True
    Error(reason) -> {
      log.warning("beacon.form", "CSRF token rejected for session: " <> reason)
      False
    }
  }
}

@external(erlang, "beacon_csrf_ffi", "new_store")
fn csrf_ets_new(name: String) -> CsrfStore

@external(erlang, "beacon_csrf_ffi", "put_token")
fn csrf_ets_put(store: CsrfStore, key: String, value: String) -> Nil

@external(erlang, "beacon_csrf_ffi", "consume_token")
fn csrf_consume(
  store: CsrfStore,
  key: String,
  token: String,
) -> Result(Nil, String)

/// Render a hidden CSRF input field.
pub fn csrf_field(form: Form) -> Node(msg) {
  element.el(
    "input",
    [
      element.attr("type", "hidden"),
      element.attr("name", "_csrf_token"),
      element.attr("value", form.csrf_token),
    ],
    [],
  )
}

/// Render a text input field with error display.
pub fn text_input(form: Form, name: String, attrs: List(Attr)) -> Node(msg) {
  let value = get_value(form, name)
  let base_attrs = [
    element.attr("type", "text"),
    element.attr("name", name),
    element.attr("value", value),
    element.on("input", name),
  ]
  let all_attrs = list.append(base_attrs, attrs)
  let input = element.el("input", all_attrs, [])

  case get_field(form, name) {
    Ok(field) -> {
      case field.errors {
        [] -> input
        errors -> {
          let error_nodes =
            list.map(errors, fn(err) {
              element.el("span", [element.attr("class", "field-error")], [
                element.text(err),
              ])
            })
          element.el("div", [element.attr("class", "field-group")], [
            input,
            ..error_nodes
          ])
        }
      }
    }
    Error(Nil) -> input
  }
}
// --- Helpers ---
