//// Web Push: notifications on a phone or a computer, sent by your own
//// server, with no third party that can read them.
////
//// The standards this follows:
////
//// - RFC 8030, the push protocol: the server POSTs to the endpoint the
////   browser got from its push service (Google's, Mozilla's, Apple's,
////   Microsoft's), and the push service wakes the browser.
//// - RFC 8291 and RFC 8188, the payload's encryption (`aes128gcm`): only
////   the browser that subscribed can read what is sent. The push service
////   sees the endpoint, the size and the time, never the text.
//// - RFC 8292, VAPID: the server signs each request with its own key, and
////   the push service accepts only the key the browser subscribed with.
////
//// The pieces:
////
//// 1. The server has one key pair (`generate_keys`), kept for good:
////    browsers subscribe to its public key, and a new key means every
////    browser subscribes again. Keep the private key as you keep other
////    secrets (`encode_private_key`, `decode_private_key`).
//// 2. The page holds a subscribe button (`brazier/web_push/device`) and
////    loads `script_path`; the button registers the service worker at
////    `service_worker_path` and asks the browser to subscribe. `routes`
////    serves both scripts. The browser reports what happened as JSON;
////    `parse_report` reads it, and the server keeps each subscription.
//// 3. To notify, `request` builds the encrypted, signed HTTP request for
////    one subscription; send it with any HTTP client and read the answer
////    with `outcome`. A subscription the push service calls gone is
////    deleted.
//// 4. The service worker shows the notification and, when it is pressed,
////    opens the `url` it carries on the app's own origin.
////
//// Nothing here does IO except `routes`, which reads the two scripts from
//// Brazier's `priv` directory once. Every function that reads bytes from
//// outside (a stored key, a browser's report) returns an `Error` for bytes
//// it can't use.
////
//// On iPhone and iPad, Web Push works only in a web app added to the Home
//// Screen (iOS 16.4 and later), which needs a web app manifest with
//// `"display": "standalone"`. The device script reports
//// `Unsupported(NeedsHomeScreen)` in Safari's own tabs.
////
//// Reference: the `web-push` npm package and `pywebpush`, which implement
//// the same RFCs.

import brazier/api
import brazier/transport/server
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

// ------------------------------------------------------------------ limits

/// The record size written in the header. The message is one record, so
/// this only has to be at least its size.
pub const record_size = 4096

/// The header of an `aes128gcm` body: salt (16), record size (4), key id
/// length (1) and the server's public key (65).
const header_bytes = 86

/// AES-GCM's tag.
const tag_bytes = 16

/// The most plaintext one message holds: a push service must take a body
/// of 4096 bytes (RFC 8030 section 7.2), which is the header, the
/// plaintext, the padding delimiter and the tag (RFC 8291 section 4).
pub const max_payload_bytes = 3993

/// The longest endpoint taken from a browser. Real ones are under 600
/// bytes.
pub const max_endpoint_bytes = 2048

/// The longest user agent a report may carry.
pub const max_user_agent_bytes = 300

/// The most a report from the device script may be.
pub const max_report_bytes = 4096

/// The longest a push message may wait at the push service: four weeks,
/// the most push services keep one.
pub const max_ttl_seconds = 2_419_200

/// How long a VAPID token is good for. RFC 8292 allows 24 hours; one hour
/// is what Apple's push service is known to accept.
pub const vapid_token_seconds = 3600

/// Where `routes` serves the service worker. At the root, so its scope is
/// the whole origin; it has no fetch handler, so it never touches the
/// app's requests.
pub const service_worker_path = "/brazier-web-push-sw.js"

/// Where `routes` serves the script that runs the subscribe button
/// (`brazier/web_push/device`). Load it with `head_html`.
pub const script_path = "/brazier-web-push.js"

/// The push services browsers use today, as origin patterns: a `*.` host
/// matches any subdomain. A subscription to an endpoint anywhere else is
/// refused, so a forged report can't make the server POST to an address
/// of its choosing.
pub const default_push_services = [
  // Chrome, Edge (Chromium), Opera, Samsung Internet, Brave
  "https://fcm.googleapis.com",
  // Firefox
  "https://updates.push.services.mozilla.com",
  "https://*.push.services.mozilla.com",
  // Safari on macOS, iOS and iPadOS
  "https://web.push.apple.com",
  "https://*.push.apple.com",
  // Edge (legacy) and Windows
  "https://*.notify.windows.com",
]

// ------------------------------------------------------------------- types

/// Why bytes or text from outside can't be used.
pub type Error {
  InvalidKey(reason: String)
  InvalidSubscription(reason: String)
  InvalidSubject(reason: String)
  InvalidMessage(reason: String)
  InvalidReport(reason: String)
  InvalidPushServices(reason: String)
}

pub fn describe_error(error: Error) -> String {
  case error {
    InvalidKey(reason) -> "invalid VAPID key: " <> reason
    InvalidSubscription(reason) -> "invalid push subscription: " <> reason
    InvalidSubject(reason) -> "invalid VAPID subject: " <> reason
    InvalidMessage(reason) -> "invalid push message: " <> reason
    InvalidReport(reason) -> "invalid report from the device script: " <> reason
    InvalidPushServices(reason) -> "invalid push service pattern: " <> reason
  }
}

/// The server's P-256 key pair.
pub opaque type Keys {
  Keys(private: BitArray, public: BitArray)
}

/// One browser's subscription: where to POST, and the keys its messages
/// are encrypted to.
pub opaque type Subscription {
  Subscription(
    endpoint: String,
    /// `scheme://host[:port]` of the endpoint: the VAPID token's audience.
    origin: String,
    /// The browser's P-256 public key, 65 bytes uncompressed.
    p256dh: BitArray,
    /// The browser's authentication secret, 16 bytes.
    auth: BitArray,
  )
}

/// The push services subscriptions may point at (`push_services`).
pub opaque type PushServices {
  PushServices(patterns: List(Pattern))
}

type Pattern {
  Pattern(scheme: String, host: String, subdomains: Bool, port: Option(Int))
}

/// The server's identity for VAPID: its keys, and a contact the push
/// service can reach if something goes wrong (`mailto:` or `https:`).
pub opaque type Vapid {
  Vapid(keys: Keys, subject: String)
}

/// How soon the browser should be woken for a message (RFC 8030 section
/// 5.3). A phone on battery may hold `VeryLow` and `Low` back.
pub type Urgency {
  VeryLow
  Low
  Normal
  High
}

/// What the service worker shows.
pub type Message {
  Message(
    title: String,
    body: String,
    /// A path on the app's origin (`/agents/a1`) that pressing the
    /// notification opens.
    url: Option(String),
    /// A notification with the same tag replaces the one shown before.
    tag: Option(String),
    /// A path on the app's origin to an image shown with it.
    icon: Option(String),
    urgency: Urgency,
    /// How long the push service keeps it for a browser that is offline;
    /// 0 is now or never.
    ttl_seconds: Int,
    /// A message with the same topic replaces one still waiting at the
    /// push service: up to 32 letters, digits, `-` and `_`.
    topic: Option(String),
  )
}

/// A message with no link, tag, icon or topic, at normal urgency, kept a
/// day for a browser that is offline.
pub fn message(title title: String, body body: String) -> Message {
  Message(
    title:,
    body:,
    url: None,
    tag: None,
    icon: None,
    urgency: Normal,
    ttl_seconds: 86_400,
    topic: None,
  )
}

/// What the push service said about one request.
pub type Outcome {
  /// Accepted (201, or 200 and 202 from some push services).
  Delivered
  /// The subscription has expired or was taken back (404, 410): delete it,
  /// and send it nothing more.
  Gone
  /// Too many requests, or the push service failed (429, 5xx): try again,
  /// after `after_seconds` if the push service said.
  TryAgain(reason: String, after_seconds: Option(Int))
  /// Any other answer (a bad token, a payload too large): trying again
  /// won't help.
  Refused(reason: String)
}

/// What the device script says about this browser, as `parse_report` reads
/// it. The script reports when the button appears and after each press.
pub type Report {
  /// The browser is subscribed: keep the subscription (the same endpoint
  /// again is the same subscription). `user_agent` is the browser's own
  /// word, at most `max_user_agent_bytes`, for telling devices apart.
  Subscribed(subscription: Subscription, user_agent: String)
  /// The browser is not subscribed. `removed` is the endpoint it just
  /// unsubscribed from, if it did: delete that subscription.
  NotSubscribed(permission: Permission, removed: Option(String))
  /// This browser can't receive Web Push here.
  Unsupported(why: Unsupported)
  /// Subscribing or unsubscribing failed; `reason` is the browser's.
  Failed(reason: String)
}

/// Whether the browser may show this origin's notifications.
pub type Permission {
  /// Not asked yet: the button asks.
  NotAsked
  Granted
  /// Refused: only the browser's site settings can change it.
  Denied
}

pub type Unsupported {
  /// Safari on iPhone or iPad outside a web app on the Home Screen.
  NeedsHomeScreen
  /// The page is not on https (or localhost).
  NotSecure
  NoServiceWorker
  NoPushManager
  NoNotifications
}

// -------------------------------------------------------------------- keys

/// A new key pair. Keep it: browsers subscribe to its public key.
pub fn generate_keys() -> Keys {
  let #(public, private) = generate_keys_ffi()
  let assert 65 = bit_array.byte_size(public)
    as "OTP's P-256 public key is 65 bytes uncompressed"
  let assert 32 = bit_array.byte_size(private)
    as "OTP's P-256 private key is padded to 32 bytes"
  Keys(private:, public:)
}

/// The key pair of a 32-byte private key; the public key is derived.
pub fn keys_from_private(private: BitArray) -> Result(Keys, Error) {
  public_key_ffi(private)
  |> result.map(fn(public) { Keys(private:, public:) })
  |> result.map_error(InvalidKey)
}

/// The private key as base64url, to store.
pub fn encode_private_key(keys: Keys) -> String {
  bit_array.base64_url_encode(keys.private, False)
}

/// The keys of a private key stored with `encode_private_key`.
pub fn decode_private_key(text: String) -> Result(Keys, Error) {
  use private <- result.try(
    base64url(text) |> result.replace_error(InvalidKey("not base64url")),
  )
  keys_from_private(private)
}

/// The public key, 65 bytes uncompressed.
pub fn public_key(keys: Keys) -> BitArray {
  keys.public
}

/// The public key as base64url: the browser's `applicationServerKey`, and
/// what `brazier/web_push/device` takes.
pub fn public_key_base64(keys: Keys) -> String {
  bit_array.base64_url_encode(keys.public, False)
}

/// The server's VAPID identity. `subject` is `mailto:someone@example.com`
/// or an `https://` URL; Apple's push service refuses a request without
/// one.
pub fn vapid(keys: Keys, subject: String) -> Result(Vapid, Error) {
  use subject <- result.try(check_subject(subject))
  Ok(Vapid(keys:, subject:))
}

pub fn vapid_keys(vapid: Vapid) -> Keys {
  vapid.keys
}

fn check_subject(subject: String) -> Result(String, Error) {
  let no_space =
    !string.contains(subject, " ")
    && !string.contains(subject, "\n")
    && !string.contains(subject, "\"")
  case subject {
    _ if !no_space -> Error(InvalidSubject("it has a space or a quote"))
    "mailto:" <> address ->
      case string.split(address, "@") {
        [local, domain] if local != "" && domain != "" -> Ok(subject)
        _ -> Error(InvalidSubject("mailto: needs one address, got " <> subject))
      }
    "https://" <> _ ->
      case uri.parse(subject) {
        Ok(uri.Uri(host: Some(host), ..)) if host != "" -> Ok(subject)
        _ -> Error(InvalidSubject("not an https URL: " <> subject))
      }
    _ ->
      Error(InvalidSubject(
        "a VAPID subject is mailto: or https://, got " <> subject,
      ))
  }
}

// ----------------------------------------------------------- push services

/// Push services from origin patterns such as `https://fcm.googleapis.com`
/// or `https://*.notify.windows.com`. An `http://` pattern is for a test's
/// mock push service on the same machine.
pub fn push_services(patterns: List(String)) -> Result(PushServices, Error) {
  list.try_map(patterns, parse_pattern)
  |> result.map(PushServices)
}

/// `default_push_services`.
pub fn default_services() -> PushServices {
  let assert Ok(services) = push_services(default_push_services)
    as "default_push_services are valid patterns"
  services
}

fn parse_pattern(pattern: String) -> Result(Pattern, Error) {
  let bad = fn(why) { InvalidPushServices(pattern <> ": " <> why) }
  case uri.parse(pattern) {
    Ok(uri.Uri(
      scheme: Some(scheme),
      host: Some(host),
      port:,
      path: "",
      query: None,
      fragment: None,
      userinfo: None,
    ))
      if scheme == "https" || scheme == "http"
    ->
      case host {
        "*." <> rest if rest != "" ->
          Ok(Pattern(scheme:, host: rest, subdomains: True, port:))
        "" -> Error(bad("no host"))
        _ ->
          case string.contains(host, "*") {
            True -> Error(bad("a * only starts a host, as *.example.com"))
            False -> Ok(Pattern(scheme:, host:, subdomains: False, port:))
          }
      }
    _ -> Error(bad("an origin is http(s)://host[:port], with no path"))
  }
}

fn allowed(
  services: PushServices,
  scheme: String,
  host: String,
  port: Option(Int),
) -> Bool {
  list.any(services.patterns, fn(pattern) {
    pattern.scheme == scheme
    && pattern.port == port
    && case pattern.subdomains {
      False -> host == pattern.host
      True -> string.ends_with(host, "." <> pattern.host)
    }
  })
}

// ----------------------------------------------------------- subscriptions

/// A subscription from what a browser's `PushSubscription.toJSON()` holds:
/// the endpoint and the base64url `p256dh` and `auth` keys. The endpoint
/// must be on one of `services`.
pub fn subscription(
  services: PushServices,
  endpoint endpoint: String,
  p256dh p256dh: String,
  auth auth: String,
) -> Result(Subscription, Error) {
  let bad = InvalidSubscription
  use origin <- result.try(check_endpoint(services, endpoint))
  use p256dh <- result.try(
    base64url(p256dh) |> result.replace_error(bad("p256dh is not base64url")),
  )
  use auth <- result.try(
    base64url(auth) |> result.replace_error(bad("auth is not base64url")),
  )
  use <- guard(
    bit_array.byte_size(p256dh) != 65,
    bad(
      "p256dh is "
      <> int.to_string(bit_array.byte_size(p256dh))
      <> " bytes, not 65",
    ),
  )
  use <- guard(
    bit_array.byte_size(auth) != 16,
    bad(
      "auth is " <> int.to_string(bit_array.byte_size(auth)) <> " bytes, not 16",
    ),
  )
  // A point that is not on the curve can't be encrypted to: find out now,
  // not at the first notification.
  let probe = generate_keys()
  use _ <- result.try(
    ecdh_ffi(p256dh, probe.private)
    |> result.map_error(fn(why) { bad("p256dh is not a P-256 key: " <> why) }),
  )
  Ok(Subscription(endpoint:, origin:, p256dh:, auth:))
}

fn check_endpoint(
  services: PushServices,
  endpoint: String,
) -> Result(String, Error) {
  let bad = InvalidSubscription
  use <- guard(
    string.byte_size(endpoint) > max_endpoint_bytes,
    bad(
      "the endpoint is over " <> int.to_string(max_endpoint_bytes) <> " bytes",
    ),
  )
  case uri.parse(endpoint) {
    Ok(uri.Uri(
      scheme: Some(scheme),
      host: Some(host),
      port:,
      userinfo: None,
      fragment: None,
      ..,
    ))
      if host != ""
    ->
      case allowed(services, scheme, host, port) {
        True -> Ok(origin(scheme, host, port))
        False ->
          Error(bad(
            "the endpoint is not on a known push service: "
            <> origin(scheme, host, port),
          ))
      }
    _ -> Error(bad("the endpoint is not a URL with a host"))
  }
}

fn origin(scheme: String, host: String, port: Option(Int)) -> String {
  scheme
  <> "://"
  <> host
  <> case port {
    None -> ""
    Some(port) -> ":" <> int.to_string(port)
  }
}

pub fn endpoint(subscription: Subscription) -> String {
  subscription.endpoint
}

/// The browser's key as base64url, to store.
pub fn p256dh(subscription: Subscription) -> String {
  bit_array.base64_url_encode(subscription.p256dh, False)
}

/// The browser's authentication secret as base64url, to store.
pub fn auth(subscription: Subscription) -> String {
  bit_array.base64_url_encode(subscription.auth, False)
}

// ----------------------------------------------------------------- reports

/// Read what the device script reported. It is the browser's word, so
/// everything is checked: a subscription as `subscription` checks it.
pub fn parse_report(
  services: PushServices,
  text: String,
) -> Result(Report, Error) {
  use <- guard(
    string.byte_size(text) > max_report_bytes,
    InvalidReport("over " <> int.to_string(max_report_bytes) <> " bytes"),
  )
  use raw <- result.try(
    json.parse(text, report_decoder())
    |> result.map_error(fn(error) {
      InvalidReport("not a report: " <> string.inspect(error))
    }),
  )
  case raw {
    RawSubscribed(endpoint:, p256dh:, auth:, user_agent:) ->
      case string.byte_size(user_agent) > max_user_agent_bytes {
        True -> Error(InvalidReport("agent is too long"))
        False ->
          subscription(services, endpoint:, p256dh:, auth:)
          |> result.map(Subscribed(_, user_agent:))
      }
    RawNotSubscribed(permission:, removed:) ->
      case removed {
        Some(endpoint) if endpoint == "" ->
          Error(InvalidReport("removed is empty"))
        Some(endpoint) ->
          case string.byte_size(endpoint) > max_endpoint_bytes {
            True -> Error(InvalidReport("removed is too long"))
            False -> Ok(NotSubscribed(permission:, removed:))
          }
        None -> Ok(NotSubscribed(permission:, removed:))
      }
    RawUnsupported(why) -> Ok(Unsupported(why))
    RawFailed(reason) -> Ok(Failed(reason))
  }
}

type RawReport {
  RawSubscribed(
    endpoint: String,
    p256dh: String,
    auth: String,
    user_agent: String,
  )
  RawNotSubscribed(permission: Permission, removed: Option(String))
  RawUnsupported(why: Unsupported)
  RawFailed(reason: String)
}

fn report_decoder() -> decode.Decoder(RawReport) {
  use state <- decode.field("state", decode.string)
  case state {
    "subscribed" -> {
      use endpoint <- decode.field("endpoint", decode.string)
      use p256dh <- decode.field("p256dh", decode.string)
      use auth <- decode.field("auth", decode.string)
      use user_agent <- decode.optional_field("agent", "", decode.string)
      decode.success(RawSubscribed(endpoint:, p256dh:, auth:, user_agent:))
    }
    "not-subscribed" -> {
      use permission <- decode.field("permission", permission_decoder())
      use removed <- decode.optional_field(
        "removed",
        None,
        decode.optional(decode.string),
      )
      decode.success(RawNotSubscribed(permission:, removed:))
    }
    "unsupported" -> {
      use why <- decode.field("reason", unsupported_decoder())
      decode.success(RawUnsupported(why))
    }
    "failed" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(RawFailed(reason))
    }
    _ -> decode.failure(RawFailed(""), "a state the script reports")
  }
}

fn permission_decoder() -> decode.Decoder(Permission) {
  use permission <- decode.then(decode.string)
  case permission {
    "default" -> decode.success(NotAsked)
    "granted" -> decode.success(Granted)
    "denied" -> decode.success(Denied)
    _ -> decode.failure(NotAsked, "default, granted or denied")
  }
}

fn unsupported_decoder() -> decode.Decoder(Unsupported) {
  use why <- decode.then(decode.string)
  case why {
    "needs-home-screen" -> decode.success(NeedsHomeScreen)
    "not-secure" -> decode.success(NotSecure)
    "no-service-worker" -> decode.success(NoServiceWorker)
    "no-push-manager" -> decode.success(NoPushManager)
    "no-notifications" -> decode.success(NoNotifications)
    _ -> decode.failure(NoPushManager, "a reason the script reports")
  }
}

// ----------------------------------------------------------------- sending

/// The HTTP request that sends `message` to `to`: encrypted to its keys,
/// signed with the VAPID key, with a token good from `now_seconds` (Unix
/// time) for `vapid_token_seconds`. Send it with any HTTP client, and read
/// the answer with `outcome`.
pub fn request(
  vapid: Vapid,
  to: Subscription,
  message: Message,
  now_seconds: Int,
) -> Result(Request(BitArray), Error) {
  use payload <- result.try(payload(message))
  use body <- result.try(encrypt(payload, to))
  let assert Ok(base) = request.to(to.endpoint)
    as "a Subscription's endpoint was parsed as a URL when it was made"
  let base =
    base
    |> request.set_method(http.Post)
    |> request.set_body(body)
    |> request.set_header("ttl", int.to_string(message.ttl_seconds))
    |> request.set_header("urgency", urgency_name(message.urgency))
    |> request.set_header("content-encoding", "aes128gcm")
    |> request.set_header("content-type", "application/octet-stream")
    |> request.set_header(
      "authorization",
      vapid_authorization(vapid, to.origin, now_seconds + vapid_token_seconds),
    )
  Ok(case message.topic {
    None -> base
    Some(topic) -> request.set_header(base, "topic", topic)
  })
}

fn urgency_name(urgency: Urgency) -> String {
  case urgency {
    VeryLow -> "very-low"
    Low -> "low"
    Normal -> "normal"
    High -> "high"
  }
}

/// The JSON the service worker reads: `title`, `body`, and `url`, `tag`
/// and `icon` when set. Checked as `request` checks it.
pub fn payload(message: Message) -> Result(BitArray, Error) {
  let bad = InvalidMessage
  use <- guard(message.title == "", bad("the title is empty"))
  use <- guard(
    message.ttl_seconds < 0 || message.ttl_seconds > max_ttl_seconds,
    bad(
      "ttl_seconds is 0 to "
      <> int.to_string(max_ttl_seconds)
      <> ", got "
      <> int.to_string(message.ttl_seconds),
    ),
  )
  use _ <- result.try(check_path("url", message.url))
  use _ <- result.try(check_path("icon", message.icon))
  use _ <- result.try(case message.tag {
    Some(tag) if tag == "" -> Error(bad("the tag is empty"))
    Some(tag) ->
      case string.byte_size(tag) > 64 {
        True -> Error(bad("the tag is over 64 bytes"))
        False -> Ok(Nil)
      }
    None -> Ok(Nil)
  })
  use _ <- result.try(case message.topic {
    Some(topic) ->
      case is_topic(topic) {
        True -> Ok(Nil)
        False -> Error(bad("a topic is 1 to 32 letters, digits, - and _"))
      }
    None -> Ok(Nil)
  })
  let text =
    json.object(
      list.flatten([
        [
          #("title", json.string(message.title)),
          #("body", json.string(message.body)),
        ],
        optional_field("url", message.url),
        optional_field("tag", message.tag),
        optional_field("icon", message.icon),
      ]),
    )
    |> json.to_string
  let size = string.byte_size(text)
  case size > max_payload_bytes {
    True ->
      Error(bad(
        "the payload is "
        <> int.to_string(size)
        <> " bytes as JSON, over the "
        <> int.to_string(max_payload_bytes)
        <> " one record holds; shorten the body",
      ))
    False -> Ok(bit_array.from_string(text))
  }
}

fn optional_field(name: String, value: Option(String)) {
  case value {
    Some(value) -> [#(name, json.string(value))]
    None -> []
  }
}

/// A path on the app's own origin: `/` and not `//`, which a browser reads
/// as another host.
fn check_path(name: String, path: Option(String)) -> Result(Nil, Error) {
  case path {
    None -> Ok(Nil)
    Some("//" <> _) | Some("/\\" <> _) ->
      Error(InvalidMessage(name <> " must be a path on the app's origin"))
    Some("/" <> _ as path) ->
      case
        string.byte_size(path) > 2048
        || string.contains(path, "\n")
        || string.contains(path, "\r")
      {
        True -> Error(InvalidMessage(name <> " is too long or has a newline"))
        False -> Ok(Nil)
      }
    Some(_) ->
      Error(InvalidMessage(name <> " must be a path that starts with /"))
  }
}

fn is_topic(topic: String) -> Bool {
  let allowed =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  let graphemes = string.to_graphemes(topic)
  graphemes != []
  && list.length(graphemes) <= 32
  && list.all(graphemes, string.contains(allowed, _))
}

/// Read the push service's answer to a `request`.
pub fn outcome(response: Response(String)) -> Outcome {
  let said = fn() {
    "the push service answered "
    <> int.to_string(response.status)
    <> case string.trim(response.body) {
      "" -> ""
      body -> ": " <> string.slice(body, 0, 300)
    }
  }
  case response.status {
    200 | 201 | 202 -> Delivered
    404 | 410 -> Gone
    429 -> TryAgain(said(), retry_after(response))
    status if status >= 500 && status < 600 ->
      TryAgain(said(), retry_after(response))
    _ -> Refused(said())
  }
}

/// `Retry-After` in seconds. The HTTP-date form is not read: push services
/// send seconds.
fn retry_after(response: Response(String)) -> Option(Int) {
  case response.get_header(response, "retry-after") {
    Ok(value) ->
      case int.parse(string.trim(value)) {
        Ok(seconds) if seconds >= 0 -> Some(seconds)
        _ -> None
      }
    Error(Nil) -> None
  }
}

// ---------------------------------------------------------------- RFC 8291

/// `payload` encrypted to `to` as one `aes128gcm` record (RFC 8291), with
/// a new key pair and salt of its own.
pub fn encrypt(payload: BitArray, to: Subscription) -> Result(BitArray, Error) {
  encrypt_with(payload, to, generate_keys(), crypto.strong_random_bytes(16))
}

/// `encrypt` with the sender's key pair and the salt given, which RFC 8291's
/// example needs. Never reuse either: a new pair and salt for each message
/// is what keeps them apart.
@internal
pub fn encrypt_with(
  payload: BitArray,
  to: Subscription,
  sender: Keys,
  salt: BitArray,
) -> Result(BitArray, Error) {
  let size = bit_array.byte_size(payload)
  use <- guard(
    size > max_payload_bytes,
    InvalidMessage(
      "the payload is "
      <> int.to_string(size)
      <> " bytes, over "
      <> int.to_string(max_payload_bytes),
    ),
  )
  let assert 16 = bit_array.byte_size(salt) as "the salt is 16 bytes"
  use ecdh_secret <- result.try(
    ecdh_ffi(to.p256dh, sender.private)
    |> result.map_error(InvalidSubscription),
  )
  let key_info =
    bit_array.concat([
      <<"WebPush: info":utf8, 0>>,
      to.p256dh,
      sender.public,
    ])
  let ikm = hkdf(salt: to.auth, ikm: ecdh_secret, info: key_info, length: 32)
  let cek =
    hkdf(
      salt:,
      ikm:,
      info: <<"Content-Encoding: aes128gcm":utf8, 0>>,
      length: 16,
    )
  let nonce =
    hkdf(salt:, ikm:, info: <<"Content-Encoding: nonce":utf8, 0>>, length: 12)
  // One record, the last: the payload and the delimiter 2, with no padding.
  let ciphertext = aes128gcm_ffi(cek, nonce, <<payload:bits, 2>>)
  let assert True =
    bit_array.byte_size(ciphertext) == size + 1 + tag_bytes
    && header_bytes + size + 1 + tag_bytes <= 4096
    as "the body is the header, the payload, the delimiter and the tag, within 4096 bytes"
  let header = <<
    salt:bits,
    record_size:size(32),
    65:size(8),
    sender.public:bits,
  >>
  let assert True = bit_array.byte_size(header) == header_bytes
    as "the aes128gcm header is 86 bytes"
  Ok(<<header:bits, ciphertext:bits>>)
}

/// HKDF with SHA-256 (RFC 5869), for outputs of up to 32 bytes: one block
/// of the expand step is all Web Push needs.
fn hkdf(
  salt salt: BitArray,
  ikm ikm: BitArray,
  info info: BitArray,
  length length: Int,
) -> BitArray {
  let assert True = length > 0 && length <= 32
    as "hkdf here expands to one SHA-256 block"
  let prk = crypto.hmac(ikm, crypto.Sha256, salt)
  let okm = crypto.hmac(<<info:bits, 1>>, crypto.Sha256, prk)
  let assert Ok(out) = bit_array.slice(okm, 0, length)
    as "an HMAC-SHA-256 is 32 bytes"
  out
}

// ---------------------------------------------------------------- RFC 8292

/// The `Authorization` header for a push service at `audience`
/// (`scheme://host[:port]`): `vapid t=<JWT>, k=<public key>`, with a token
/// that expires at `expires_at` (Unix seconds).
pub fn vapid_authorization(
  vapid: Vapid,
  audience: String,
  expires_at: Int,
) -> String {
  let header =
    json.object([#("typ", json.string("JWT")), #("alg", json.string("ES256"))])
  let claims =
    json.object([
      #("aud", json.string(audience)),
      #("exp", json.int(expires_at)),
      #("sub", json.string(vapid.subject)),
    ])
  let signing_input =
    segment(json.to_string(header)) <> "." <> segment(json.to_string(claims))
  let signature =
    es256_sign_ffi(bit_array.from_string(signing_input), vapid.keys.private)
  let assert 64 = bit_array.byte_size(signature)
    as "an ES256 signature is R and S, 32 bytes each"
  "vapid t="
  <> signing_input
  <> "."
  <> bit_array.base64_url_encode(signature, False)
  <> ", k="
  <> public_key_base64(vapid.keys)
}

fn segment(text: String) -> String {
  bit_array.base64_url_encode(bit_array.from_string(text), False)
}

// ------------------------------------------------------------ the scripts

/// The `<script>` tag that loads the device script. Put it in the page's
/// head (`brazier.head_html`).
pub fn head_html() -> String {
  "<script defer src=\"" <> script_path <> "\"></script>"
}

/// The routes that serve the service worker and the device script, for
/// `brazier.api_routes` (with `api.routes`). Both are read from Brazier's
/// `priv/web_push` here, once; an error means Brazier's files are missing.
pub fn routes() -> Result(List(api.Route), String) {
  use worker <- result.try(priv_file_ffi("web_push/service_worker.js"))
  use device <- result.try(priv_file_ffi("web_push/device.js"))
  Ok([
    api.get(service_worker_path, fn(_) { script(worker) }),
    api.get(script_path, fn(_) { script(device) }),
  ])
}

fn script(source: BitArray) -> api.Response {
  api.empty(200)
  |> response.set_body(server.Bytes(bytes_tree.from_bit_array(source)))
  |> response.set_header("content-type", "text/javascript; charset=utf-8")
  // A service worker is checked for updates on navigation; no-cache makes
  // that check reach the server, so a new Brazier's worker is picked up.
  |> response.set_header("cache-control", "no-cache")
}

// --------------------------------------------------------------- helpers

/// base64url with or without padding, as browsers and RFCs write it, and
/// nothing else: no `+`, `/` or whitespace.
fn base64url(text: String) -> Result(BitArray, Nil) {
  let alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  let unpadded = case string.split_once(text, "=") {
    Ok(#(before, padding)) ->
      case padding == "" || padding == "=" {
        True -> Ok(before)
        False -> Error(Nil)
      }
    Error(Nil) -> Ok(text)
  }
  use unpadded <- result.try(unpadded)
  case
    unpadded != ""
    && list.all(string.to_graphemes(unpadded), string.contains(alphabet, _))
  {
    True -> bit_array.base64_url_decode(unpadded)
    False -> Error(Nil)
  }
}

fn guard(condition: Bool, error: Error, next: fn() -> Result(a, Error)) {
  case condition {
    True -> Error(error)
    False -> next()
  }
}

@external(erlang, "brazier_web_push_ffi", "generate_keys")
fn generate_keys_ffi() -> #(BitArray, BitArray)

@external(erlang, "brazier_web_push_ffi", "public_key")
fn public_key_ffi(private: BitArray) -> Result(BitArray, String)

@external(erlang, "brazier_web_push_ffi", "ecdh")
fn ecdh_ffi(
  their_public: BitArray,
  our_private: BitArray,
) -> Result(BitArray, String)

@external(erlang, "brazier_web_push_ffi", "aes128gcm_encrypt")
fn aes128gcm_ffi(
  key: BitArray,
  nonce: BitArray,
  plaintext: BitArray,
) -> BitArray

@external(erlang, "brazier_web_push_ffi", "es256_sign")
fn es256_sign_ffi(message: BitArray, private: BitArray) -> BitArray

@external(erlang, "brazier_web_push_ffi", "priv_file")
fn priv_file_ffi(name: String) -> Result(BitArray, String)
