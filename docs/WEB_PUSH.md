# Web Push

`brazier/web_push` sends notifications to phones and computers from your
own server, with no third party that can read them. A browser subscribes
through its own push service (Google's for Chrome, Mozilla's for Firefox,
Apple's for Safari, Microsoft's for Edge on Windows); the server POSTs each
notification there, encrypted for that browser and signed with the server's
key, and the push service wakes the browser, whose service worker shows it.

It follows the standards and nothing else: RFC 8030 (the push protocol),
RFC 8291 and RFC 8188 (the payload's `aes128gcm` encryption: the push
service sees the endpoint, the size and the time, never the text) and RFC
8292 (VAPID: the push service accepts only requests signed with the key the
browser subscribed with). The cryptography is OTP's `crypto` (P-256 ECDH,
HKDF-SHA-256, AES-128-GCM, ES256), and the payload encryption matches RFC
8291's worked example byte for byte (`test/brazier/web_push_test.gleam`).

`brazier/web_push` does no IO except `routes`, which reads the two scripts
once; sending is one HTTP request that you make with the client you
already use.

## The pieces

| Piece | Where | What it does |
|-------|-------|--------------|
| The server's key pair | `web_push.generate_keys`, `encode_private_key`, `decode_private_key`, `vapid` | Made once and kept. Browsers subscribe to its public key; a new key means every browser subscribes again |
| The device script | `web_push.head_html` loads `/brazier-web-push.js` | Runs the buttons below: registers the service worker, asks for permission, subscribes, and reports this browser's state |
| The buttons | `brazier/web_push/device`: `control`, `subscribe`, `unsubscribe`, `check` | Attributes for the element that holds them, and for each button |
| The service worker | `/brazier-web-push-sw.js` | Shows a notification on `push`, and on a press focuses or opens its `url` on your origin. It has no `fetch` handler, so it never stands between the page and the server |
| The routes | `web_push.routes` | Serves both scripts, for `brazier.api_routes` |
| The report | `web_push.parse_report` | Reads what the device script said, which is the browser's word: an endpoint off the push services' list, a key that is not a P-256 point, or a report too long is an `Error` |
| Sending | `web_push.request`, `web_push.outcome` | The encrypted, signed request for one subscription, and what the push service's answer means |

## The key

Make the key once, keep the private half as you keep other secrets, and
read it back at each start. `vapid` adds the subject, a `mailto:` or
`https:` URL the push services can reach you at:

<!-- docs-check: module web_push_guide/keys -->
```gleam
import brazier/web_push

/// The text to keep, sealed or encrypted the way the app keeps secrets.
pub fn new_key() -> String {
  web_push.encode_private_key(web_push.generate_keys())
}

/// The key the app signs with, from what it kept.
pub fn signing_key(kept: String) -> Result(web_push.Vapid, String) {
  case web_push.decode_private_key(kept) {
    Ok(keys) ->
      case web_push.vapid(keys, "mailto:ops@example.com") {
        Ok(vapid) -> Ok(vapid)
        Error(error) -> Error(web_push.describe_error(error))
      }
    Error(error) -> Error(web_push.describe_error(error))
  }
}

/// What the page gives the buttons, and what a browser subscribes to.
pub fn public_key(vapid: web_push.Vapid) -> String {
  web_push.public_key_base64(web_push.vapid_keys(vapid))
}
```

## The page

Serve the scripts and load the device script in the page's head:

<!-- docs-check: module web_push_guide/app -->
```gleam
import brazier
import brazier/api
import brazier/web_push
import gleam/result

/// `app` with Web Push's two scripts served and the device script loaded.
/// `head` is the rest of the page's head.
pub fn with_web_push(
  app: brazier.App(state, model, local, msg),
  head: String,
) -> Result(brazier.App(state, model, local, msg), String) {
  use routes <- result.map(web_push.routes())
  app
  |> brazier.api_routes(api.routes(routes))
  |> brazier.head_html(head <> web_push.head_html())
}
```

`brazier.api_routes` takes one handler, so an app with routes of its own
puts them in the same list: `api.routes([api.get("/manifest.webmanifest",
manifest), ..routes])`.

The buttons go in one element, which `device.control` marks. The script
reports when the element appears, after each press, and when the public
key in it changes; each report is a message with the JSON as a `String`:

<!-- docs-check: module web_push_guide/view -->
```gleam
import brazier/attribute
import brazier/element.{type Element}
import brazier/html
import brazier/web_push/device

pub type Msg {
  PushReported(report: String)
}

/// This browser's notifications: `on` is what the last report said.
pub fn notifications(public_key: String, on: Bool) -> Element(Msg) {
  html.div(device.control(public_key:, on_report: PushReported), [
    case on {
      False ->
        html.button([device.subscribe(), attribute.type_("button")], [
          html.text("Turn on notifications"),
        ])
      True ->
        html.button([device.unsubscribe(), attribute.type_("button")], [
          html.text("Turn off notifications"),
        ])
    },
  ])
}
```

The report is a `String` and not a typed value because the codecs carry
only the app's own types between the browser and the server. `update`
reads it with `parse_report`, on the server, and keeps or forgets the
subscription:

<!-- docs-check: module web_push_guide/update -->
```gleam
import brazier/web_push
import gleam/option.{Some}

/// What to do with a report. Keep a subscription by its endpoint: the same
/// endpoint again is the same browser.
pub type Change {
  Keep(endpoint: String, p256dh: String, auth: String, user_agent: String)
  Forget(endpoint: String)
  Nothing
  Problem(String)
}

pub fn reported(text: String) -> Change {
  case web_push.parse_report(web_push.default_services(), text) {
    Ok(web_push.Subscribed(subscription:, user_agent:)) ->
      Keep(
        endpoint: web_push.endpoint(subscription),
        p256dh: web_push.p256dh(subscription),
        auth: web_push.auth(subscription),
        user_agent:,
      )
    Ok(web_push.NotSubscribed(removed: Some(endpoint), ..)) -> Forget(endpoint)
    Ok(web_push.NotSubscribed(..)) -> Nothing
    Ok(web_push.Unsupported(why: web_push.NeedsHomeScreen)) ->
      Problem("Add this page to the Home Screen, and open it from there")
    Ok(web_push.Unsupported(..)) -> Problem("This browser has no Web Push")
    Ok(web_push.Failed(reason:)) -> Problem(reason)
    Error(error) -> Problem(web_push.describe_error(error))
  }
}
```

`NotSubscribed`'s `permission` is `Denied` when the browser blocks the
site's notifications, which only the browser's own settings can change;
say so, and offer a `device.check()` button for after.

## Sending

Keep each subscription as its three strings, and make it a `Subscription`
again with `web_push.subscription` when sending: it checks them as
`parse_report` did. `request` builds the request (the payload is at most
3993 bytes of JSON, so cut long bodies), and `outcome` reads the answer:

<!-- docs-check: module web_push_guide/send -->
```gleam
import brazier/web_push
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{Some}

/// Sends one notification to one kept subscription with `send`, the app's
/// own HTTP client (gleam_httpc's `dispatch_bits` with a timeout, the
/// answer's body read as text).
pub fn notify(
  vapid: web_push.Vapid,
  kept: #(String, String, String),
  title: String,
  body: String,
  now_seconds: Int,
  send: fn(Request(BitArray)) -> Result(Response(String), String),
) -> Result(web_push.Outcome, String) {
  let #(endpoint, p256dh, auth) = kept
  let message =
    web_push.Message(
      ..web_push.message(title:, body:),
      url: Some("/inbox"),
      tag: Some("inbox"),
      urgency: web_push.High,
    )
  let services = web_push.default_services()
  case web_push.subscription(services, endpoint:, p256dh:, auth:) {
    Error(error) -> Error(web_push.describe_error(error))
    Ok(to) ->
      case web_push.request(vapid, to, message, now_seconds) {
        Error(error) -> Error(web_push.describe_error(error))
        Ok(push) ->
          case send(push) {
            Ok(answer) -> Ok(web_push.outcome(answer))
            Error(problem) -> Error(problem)
          }
      }
  }
}
```

A `tag` replaces an earlier notification with the same tag on the device,
and `url` is a path on your origin that a press opens; the service worker
refuses any other.

What each outcome asks of you:

| Outcome | The push service said | Do |
|---------|----------------------|----|
| `Delivered` | 201 (or 200, 202) | Nothing |
| `Gone` | 404 or 410: the subscription expired or was taken back | Delete it; send it nothing more |
| `TryAgain(reason, after_seconds)` | 429 or 5xx | Try again later, after `after_seconds` when it says (`Retry-After`) |
| `Refused(reason)` | Anything else: a bad signature, a payload too large | Log it; trying again won't help |

## The push services

A subscription's endpoint is where the server POSTs, and it comes from the
browser. `default_services()` allows only the push services browsers use,
over https: `fcm.googleapis.com`, `updates.push.services.mozilla.com` and
`*.push.services.mozilla.com`, `web.push.apple.com` and `*.push.apple.com`,
and `*.notify.windows.com`. Anything else is refused, so a page cannot make
the server send requests to an address of its choosing. `push_services`
makes another list, for a push service of your own.

## iPhone and iPad

Safari on an iPhone or iPad gives Web Push only to a web app added to the
Home Screen (iOS 16.4 and later), and only once it is opened from there.
The page needs a web app manifest with `"display": "standalone"` (and
`<link rel="manifest">` in its head); without it, the script reports
`Unsupported(NeedsHomeScreen)`, so the page can say what to do. Behind a
sign-in proxy, let the manifest and its icons through without a session:
the phone fetches them without the page's cookies.

## Limits

| Limit | Value | Why |
|-------|-------|-----|
| `max_payload_bytes` | 3993 | One 4096-byte record, less the padding delimiter and the tag |
| `max_endpoint_bytes` | 2048 | Longer than any push service's endpoint |
| `max_user_agent_bytes` | 300 | What the report carries to tell devices apart |
| `max_report_bytes` | 4096 | A report longer than this is refused before it is parsed |
| `max_ttl_seconds` | 2419200 (28 days) | What push services keep a message for at most |
| `vapid_token_seconds` | 3600 | How long each signed token is good for; a new one is made per request |
