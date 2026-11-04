//// The one rule for a same-origin path: what a navigation, a redirect or a
//// live mount may name.
////
//// `brazier/router.check_local_path` exposes it to apps' effects; the
//// transport (the page a WebSocket mounts, the path of a navigation or a
//// join) and the runtime (a client navigation, a hard navigation it sends)
//// use it from here, because `brazier/router` depends on
//// `brazier/transport`. The client checks the same rule
//// (`localPathRefusal` in `brazier_client/patch.mjs`; the parity test is
//// `brazier_client/test/local_path_parity.mjs`).

import gleam/list
import gleam/string

/// `Ok(Nil)` when `path` is a same-origin absolute path, else why not.
///
/// A browser resolves more than `//host` to another origin: it reads `\`
/// as `/`, and strips tab, newline and carriage return anywhere in a URL, so
/// `/\evil.com` and `/<tab>/evil.com` both load `evil.com`. The rule is
/// Phoenix's `validate_local_url` (no leading `//`, no `\`, no `/%09`) plus
/// every ASCII control character.
pub fn check(path: String) -> Result(Nil, String) {
  case path {
    "//" <> _ | "/\\" <> _ ->
      Error("it starts with two slashes, which a browser reads as another host")
    "/" <> _ ->
      case
        string.contains(path, "\\"),
        string.contains(path, "/%09"),
        has_control_character(path)
      {
        True, _, _ ->
          Error("it contains a backslash, which a browser reads as \"/\"")
        _, True, _ ->
          Error("it contains \"/%09\", an encoded tab some browsers strip")
        _, _, True ->
          Error(
            "it contains a control character, which a browser may strip (a tab between two slashes leaves \"//\")",
          )
        False, False, False -> Ok(Nil)
      }
    _ -> Error("it does not start with \"/\"")
  }
}

/// Whether `text` holds an ASCII control character (U+0000 to U+001F, or
/// U+007F).
fn has_control_character(text: String) -> Bool {
  string.to_utf_codepoints(text)
  |> list.any(fn(codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    code < 0x20 || code == 0x7F
  })
}
