//// brazier/web_push: RFC 8291's example to the byte, a round trip through
//// a decryption written apart from the module, the VAPID token's
//// signature and claims, and every input that must be refused.

import brazier/api
import brazier/transport/server.{Bytes}
import brazier/web_push
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// RFC 8291 section 5 and appendix A.
const rfc_auth = "BTBZMqHH6r4Tts7J_aSIgg"

const rfc_ua_private = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"

const rfc_ua_public =
  "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"

const rfc_as_private = "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"

const rfc_as_public =
  "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"

const rfc_salt = "DGv6ra1nlYgDCS1FRnbzlw"

const rfc_body =
  "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

const endpoint = "https://push.example.net/push/JzLQ3raZJfFBR0aqvOMsLrt54w4rJUsV"

fn bytes(text: String) -> BitArray {
  let assert Ok(bits) = bit_array.base64_url_decode(text)
  bits
}

fn services() -> web_push.PushServices {
  let assert Ok(services) = web_push.push_services(["https://push.example.net"])
  services
}

fn rfc_subscription() -> web_push.Subscription {
  let assert Ok(subscription) =
    web_push.subscription(
      services(),
      endpoint:,
      p256dh: rfc_ua_public,
      auth: rfc_auth,
    )
  subscription
}

fn vapid() -> web_push.Vapid {
  let assert Ok(vapid) =
    web_push.vapid(web_push.generate_keys(), "mailto:sam@example.com")
  vapid
}

// --------------------------------------------------------------- RFC 8291

pub fn rfc_8291_example_test() {
  let assert Ok(sender) = web_push.keys_from_private(bytes(rfc_as_private))
  assert web_push.public_key_base64(sender) == rfc_as_public
  let assert Ok(body) =
    web_push.encrypt_with(
      <<"When I grow up, I want to be a watermelon":utf8>>,
      rfc_subscription(),
      sender,
      bytes(rfc_salt),
    )
  assert bit_array.base64_url_encode(body, False) == rfc_body
}

pub fn encrypt_round_trip_test() {
  let payload = <<"{\"title\":\"a1 is waiting for you\"}":utf8>>
  let assert Ok(first) = web_push.encrypt(payload, rfc_subscription())
  let assert Ok(second) = web_push.encrypt(payload, rfc_subscription())
  // A new key and salt each time.
  assert first != second
  assert decrypt(first, bytes(rfc_ua_private), bytes(rfc_auth)) == Ok(payload)
  assert decrypt(second, bytes(rfc_ua_private), bytes(rfc_auth)) == Ok(payload)
  // The wrong secret doesn't open it.
  let assert Error(_) = decrypt(first, bytes(rfc_ua_private), <<0:128>>)
}

pub fn largest_payload_test() {
  let largest = bit_array.from_string(string.repeat("x", 3993))
  let assert Ok(body) = web_push.encrypt(largest, rfc_subscription())
  assert bit_array.byte_size(body) == 4096
  assert decrypt(body, bytes(rfc_ua_private), bytes(rfc_auth)) == Ok(largest)
  let assert Error(web_push.InvalidMessage(_)) =
    web_push.encrypt(<<largest:bits, "x":utf8>>, rfc_subscription())
}

// ------------------------------------------------------------------- keys

pub fn keys_test() {
  let keys = web_push.generate_keys()
  assert bit_array.byte_size(web_push.public_key(keys)) == 65
  let assert Ok(again) =
    web_push.decode_private_key(web_push.encode_private_key(keys))
  assert web_push.public_key_base64(again) == web_push.public_key_base64(keys)
  assert web_push.generate_keys() != keys
}

pub fn bad_private_keys_test() {
  let assert Error(web_push.InvalidKey(_)) =
    web_push.keys_from_private(<<1:248>>)
  let assert Error(web_push.InvalidKey(_)) =
    web_push.keys_from_private(<<0:256>>)
  // Past the curve's order.
  let assert Error(web_push.InvalidKey(_)) =
    web_push.keys_from_private(<<-1:256>>)
  let assert Error(web_push.InvalidKey(_)) =
    web_push.decode_private_key("not base64!")
  let assert Error(web_push.InvalidKey(_)) = web_push.decode_private_key("")
}

pub fn subject_test() {
  let keys = web_push.generate_keys()
  let assert Ok(_) = web_push.vapid(keys, "mailto:sam@example.com")
  let assert Ok(_) = web_push.vapid(keys, "https://modorra.example")
  let assert Error(web_push.InvalidSubject(_)) = web_push.vapid(keys, "")
  let assert Error(web_push.InvalidSubject(_)) =
    web_push.vapid(keys, "mailto:nobody")
  let assert Error(web_push.InvalidSubject(_)) =
    web_push.vapid(keys, "http://insecure.example")
  let assert Error(web_push.InvalidSubject(_)) =
    web_push.vapid(keys, "mailto:a b@example.com")
}

// ---------------------------------------------------------- subscriptions

pub fn default_services_test() {
  let defaults = web_push.default_services()
  let ok = fn(endpoint) {
    web_push.subscription(
      defaults,
      endpoint:,
      p256dh: rfc_ua_public,
      auth: rfc_auth,
    )
  }
  let assert Ok(_) = ok("https://fcm.googleapis.com/fcm/send/abc:def")
  let assert Ok(_) = ok("https://web.push.apple.com/QGuQyavXutnMH")
  let assert Ok(_) = ok("https://updates.push.services.mozilla.com/wpush/v2/x")
  let assert Ok(_) = ok("https://wns2-db5p.notify.windows.com/w/?token=x")
  // Not a push service, a lookalike, plain http, a port, userinfo.
  let assert Error(web_push.InvalidSubscription(_)) =
    ok("https://example.com/push")
  let assert Error(web_push.InvalidSubscription(_)) =
    ok("https://evilnotify.windows.com/x")
  let assert Error(web_push.InvalidSubscription(_)) =
    ok("https://notify.windows.com.evil.example/x")
  let assert Error(web_push.InvalidSubscription(_)) =
    ok("http://fcm.googleapis.com/fcm/send/x")
  let assert Error(web_push.InvalidSubscription(_)) =
    ok("https://fcm.googleapis.com:8443/fcm/send/x")
  let assert Error(web_push.InvalidSubscription(_)) =
    ok("https://me@fcm.googleapis.com/fcm/send/x")
  let assert Error(web_push.InvalidSubscription(_)) =
    ok("https://fcm.googleapis.com/" <> string.repeat("x", 2048))
  let assert Error(web_push.InvalidSubscription(_)) = ok("not a url")
}

pub fn push_services_test() {
  let assert Ok(local) = web_push.push_services(["http://127.0.0.1:8123"])
  let assert Ok(_) =
    web_push.subscription(
      local,
      endpoint: "http://127.0.0.1:8123/push/1",
      p256dh: rfc_ua_public,
      auth: rfc_auth,
    )
  let assert Error(web_push.InvalidSubscription(_)) =
    web_push.subscription(
      local,
      endpoint: "http://127.0.0.1:8124/push/1",
      p256dh: rfc_ua_public,
      auth: rfc_auth,
    )
  let assert Error(web_push.InvalidPushServices(_)) =
    web_push.push_services(["https://fcm.googleapis.com/fcm"])
  let assert Error(web_push.InvalidPushServices(_)) =
    web_push.push_services(["ftp://push.example"])
  let assert Error(web_push.InvalidPushServices(_)) =
    web_push.push_services(["https://push.*.example"])
}

pub fn subscription_keys_test() {
  let with = fn(p256dh, auth) {
    web_push.subscription(services(), endpoint:, p256dh:, auth:)
  }
  let assert Ok(subscription) = with(rfc_ua_public, rfc_auth)
  assert web_push.endpoint(subscription) == endpoint
  assert web_push.p256dh(subscription) == rfc_ua_public
  assert web_push.auth(subscription) == rfc_auth
  // Padded base64url is the same key.
  let assert Ok(_) = with(rfc_ua_public <> "=", rfc_auth <> "==")
  // Too short, standard base64, not on the curve, a short secret.
  let assert Error(web_push.InvalidSubscription(_)) =
    with(string.drop_end(rfc_ua_public, 4), rfc_auth)
  let assert Error(web_push.InvalidSubscription(_)) =
    with(string.replace(rfc_ua_public, "_", "/"), rfc_auth)
  let off_curve = bit_array.base64_url_encode(<<4, 1:512>>, False)
  let assert Error(web_push.InvalidSubscription(_)) = with(off_curve, rfc_auth)
  let assert Error(web_push.InvalidSubscription(_)) =
    with(rfc_ua_public, "BTBZMqHH6r4Tts7J")
  let assert Error(web_push.InvalidSubscription(_)) = with(rfc_ua_public, "")
}

// ---------------------------------------------------------------- reports

pub fn reports_test() {
  let parse = web_push.parse_report(services(), _)
  let assert Ok(web_push.Subscribed(subscription, user_agent)) =
    parse(
      json.object([
        #("state", json.string("subscribed")),
        #("endpoint", json.string(endpoint)),
        #("p256dh", json.string(rfc_ua_public)),
        #("auth", json.string(rfc_auth)),
        #("agent", json.string("Mozilla/5.0 (iPhone)")),
      ])
      |> json.to_string,
    )
  assert web_push.endpoint(subscription) == endpoint
  assert user_agent == "Mozilla/5.0 (iPhone)"
  let assert Ok(web_push.Subscribed(_, "")) =
    parse(
      "{\"state\":\"subscribed\",\"endpoint\":\""
      <> endpoint
      <> "\",\"p256dh\":\""
      <> rfc_ua_public
      <> "\",\"auth\":\""
      <> rfc_auth
      <> "\"}",
    )
  assert parse("{\"state\":\"not-subscribed\",\"permission\":\"default\"}")
    == Ok(web_push.NotSubscribed(web_push.NotAsked, None))
  assert parse(
      "{\"state\":\"not-subscribed\",\"permission\":\"granted\",\"removed\":\"https://x/1\"}",
    )
    == Ok(web_push.NotSubscribed(web_push.Granted, Some("https://x/1")))
  assert parse("{\"state\":\"not-subscribed\",\"permission\":\"denied\"}")
    == Ok(web_push.NotSubscribed(web_push.Denied, None))
  assert parse("{\"state\":\"unsupported\",\"reason\":\"needs-home-screen\"}")
    == Ok(web_push.Unsupported(web_push.NeedsHomeScreen))
  assert parse("{\"state\":\"failed\",\"reason\":\"AbortError\"}")
    == Ok(web_push.Failed("AbortError"))
}

pub fn bad_reports_test() {
  let parse = web_push.parse_report(services(), _)
  let assert Error(web_push.InvalidReport(_)) = parse("")
  let assert Error(web_push.InvalidReport(_)) = parse("{\"state\":\"maybe\"}")
  let assert Error(web_push.InvalidReport(_)) =
    parse("{\"state\":\"not-subscribed\",\"permission\":\"sometimes\"}")
  let assert Error(web_push.InvalidReport(_)) =
    parse("{\"state\":\"unsupported\",\"reason\":\"tuesday\"}")
  let assert Error(web_push.InvalidReport(_)) =
    parse(
      "{\"state\":\"not-subscribed\",\"permission\":\"granted\",\"removed\":\"\"}",
    )
  let assert Error(web_push.InvalidReport(_)) =
    parse(
      "{\"state\":\"failed\",\"reason\":\""
      <> string.repeat("x", web_push.max_report_bytes)
      <> "\"}",
    )
  let assert Error(web_push.InvalidReport(_)) =
    parse(
      "{\"state\":\"subscribed\",\"endpoint\":\""
      <> endpoint
      <> "\",\"p256dh\":\""
      <> rfc_ua_public
      <> "\",\"auth\":\""
      <> rfc_auth
      <> "\",\"agent\":\""
      <> string.repeat("a", 301)
      <> "\"}",
    )
  // A subscription is checked as `subscription` checks one.
  let assert Error(web_push.InvalidSubscription(_)) =
    parse(
      "{\"state\":\"subscribed\",\"endpoint\":\"https://evil.example/x\",\"p256dh\":\""
      <> rfc_ua_public
      <> "\",\"auth\":\""
      <> rfc_auth
      <> "\"}",
    )
}

// ---------------------------------------------------------------- sending

pub fn request_test() {
  let vapid = vapid()
  let message =
    web_push.Message(
      ..web_push.message(title: "a1 is waiting for you", body: "Which DB?"),
      url: Some("/agents/a1"),
      tag: Some("a1"),
      urgency: web_push.High,
      ttl_seconds: 600,
      topic: Some("a1-waiting"),
    )
  let assert Ok(req) =
    web_push.request(vapid, rfc_subscription(), message, 1_800_000_000)
  assert req.method == http.Post
  assert request.to_uri(req).host == Some("push.example.net")
  assert req.path == "/push/JzLQ3raZJfFBR0aqvOMsLrt54w4rJUsV"
  assert request.get_header(req, "ttl") == Ok("600")
  assert request.get_header(req, "urgency") == Ok("high")
  assert request.get_header(req, "topic") == Ok("a1-waiting")
  assert request.get_header(req, "content-encoding") == Ok("aes128gcm")
  let assert Ok(payload) =
    decrypt(req.body, bytes(rfc_ua_private), bytes(rfc_auth))
  let assert Ok(text) = bit_array.to_string(payload)
  let decoder = {
    use title <- decode.field("title", decode.string)
    use body <- decode.field("body", decode.string)
    use url <- decode.field("url", decode.string)
    use tag <- decode.field("tag", decode.string)
    decode.success(#(title, body, url, tag))
  }
  assert json.parse(text, decoder)
    == Ok(#("a1 is waiting for you", "Which DB?", "/agents/a1", "a1"))
  // No topic header unless one is set.
  let assert Ok(plain) =
    web_push.request(
      vapid,
      rfc_subscription(),
      web_push.message(title: "t", body: ""),
      1_800_000_000,
    )
  assert request.get_header(plain, "topic") == Error(Nil)
  assert request.get_header(plain, "urgency") == Ok("normal")
  assert request.get_header(plain, "ttl") == Ok("86400")
}

pub fn vapid_token_test() {
  let vapid = vapid()
  let keys = web_push.vapid_keys(vapid)
  let header =
    web_push.vapid_authorization(
      vapid,
      "https://push.example.net",
      1_800_003_600,
    )
  let assert "vapid t=" <> rest = header
  let assert Ok(#(token, key)) = string.split_once(rest, ", k=")
  assert key == web_push.public_key_base64(keys)
  let assert [head, claims, signature] = string.split(token, ".")
  let assert True =
    es256_verify(
      bit_array.from_string(head <> "." <> claims),
      bytes(signature),
      web_push.public_key(keys),
    )
  let assert False =
    es256_verify(
      bit_array.from_string(head <> "." <> claims <> "x"),
      bytes(signature),
      web_push.public_key(keys),
    )
  let assert Ok(head) = bit_array.to_string(bytes(head))
  assert head == "{\"typ\":\"JWT\",\"alg\":\"ES256\"}"
  let assert Ok(claims) = bit_array.to_string(bytes(claims))
  let decoder = {
    use aud <- decode.field("aud", decode.string)
    use exp <- decode.field("exp", decode.int)
    use sub <- decode.field("sub", decode.string)
    decode.success(#(aud, exp, sub))
  }
  assert json.parse(claims, decoder)
    == Ok(#("https://push.example.net", 1_800_003_600, "mailto:sam@example.com"))
}

pub fn request_token_audience_test() {
  let assert Ok(local) = web_push.push_services(["http://127.0.0.1:8123"])
  let assert Ok(subscription) =
    web_push.subscription(
      local,
      endpoint: "http://127.0.0.1:8123/push/1",
      p256dh: rfc_ua_public,
      auth: rfc_auth,
    )
  let assert Ok(req) =
    web_push.request(
      vapid(),
      subscription,
      web_push.message(title: "t", body: ""),
      100,
    )
  let assert Ok("vapid t=" <> rest) = request.get_header(req, "authorization")
  let assert [_, claims, ..] = string.split(rest, ".")
  let assert Ok(claims) = bit_array.to_string(bytes(claims))
  assert claims
    == "{\"aud\":\"http://127.0.0.1:8123\",\"exp\":3700,\"sub\":\"mailto:sam@example.com\"}"
}

pub fn bad_messages_test() {
  let check = fn(message) {
    web_push.request(vapid(), rfc_subscription(), message, 0)
  }
  let base = web_push.message(title: "t", body: "b")
  let refused = fn(message) {
    let assert Error(web_push.InvalidMessage(_)) = check(message)
    Nil
  }
  refused(web_push.message(title: "", body: "b"))
  refused(web_push.Message(..base, url: Some("//evil.example/x")))
  refused(web_push.Message(..base, url: Some("/\\evil.example")))
  refused(web_push.Message(..base, url: Some("https://evil.example/x")))
  refused(web_push.Message(..base, url: Some("javascript:alert(1)")))
  refused(web_push.Message(..base, url: Some("/a\nb")))
  refused(web_push.Message(..base, icon: Some("https://evil.example/i.png")))
  refused(web_push.Message(..base, tag: Some("")))
  refused(web_push.Message(..base, tag: Some(string.repeat("t", 65))))
  refused(web_push.Message(..base, topic: Some("has space")))
  refused(web_push.Message(..base, topic: Some(string.repeat("t", 33))))
  refused(web_push.Message(..base, ttl_seconds: -1))
  refused(web_push.Message(..base, ttl_seconds: web_push.max_ttl_seconds + 1))
  refused(web_push.Message(..base, body: string.repeat("x", 4000)))
  let assert Ok(_) =
    check(web_push.Message(..base, url: Some("/"), icon: Some("/icon.png")))
}

pub fn outcome_test() {
  let answer = fn(status, headers: List(#(String, String)), body) {
    web_push.outcome(response.Response(status:, headers:, body:))
  }
  assert answer(201, [], "") == web_push.Delivered
  assert answer(200, [], "") == web_push.Delivered
  assert answer(202, [], "") == web_push.Delivered
  assert answer(410, [], "") == web_push.Gone
  assert answer(404, [], "") == web_push.Gone
  let assert web_push.TryAgain(_, Some(30)) =
    answer(429, [#("retry-after", "30")], "")
  let assert web_push.TryAgain(_, None) =
    answer(429, [#("retry-after", "Wed, 21 Oct 2026 07:28:00 GMT")], "")
  let assert web_push.TryAgain(reason, None) = answer(503, [], "down")
  assert string.contains(reason, "503: down")
  let assert web_push.Refused(reason) =
    answer(403, [], "{\"reason\":\"BadJwtToken\"}")
  assert string.contains(reason, "BadJwtToken")
  let assert web_push.Refused(_) = answer(413, [], "")
  let assert web_push.Refused(_) = answer(400, [], "")
}

// ---------------------------------------------------------------- scripts

pub fn routes_test() {
  let assert Ok(routes) = web_push.routes()
  let handler = api.routes(routes)
  let get = fn(path) {
    let assert Some(answer) =
      handler(
        request.new()
        |> request.set_method(http.Get)
        |> request.set_path(path)
        |> request.set_body(server.Connection(
          socket: dead_socket(),
          resolved: None,
        )),
      )
    answer
  }
  list.each(
    [
      #(web_push.service_worker_path, "notificationclick"),
      #(web_push.script_path, "registerHook"),
    ],
    fn(pair) {
      let answer = get(pair.0)
      assert answer.status == 200
      assert response.get_header(answer, "content-type")
        == Ok("text/javascript; charset=utf-8")
      assert response.get_header(answer, "cache-control") == Ok("no-cache")
      let assert Bytes(tree) = answer.body
      let assert Ok(text) = bit_array.to_string(bytes_tree.to_bit_array(tree))
      assert string.contains(text, pair.1)
    },
  )
  assert web_push.head_html()
    == "<script defer src=\"/brazier-web-push.js\"></script>"
}

@external(erlang, "brazier_web_push_test_ffi", "decrypt")
fn decrypt(
  body: BitArray,
  ua_private: BitArray,
  auth: BitArray,
) -> Result(BitArray, String)

@external(erlang, "brazier_web_push_test_ffi", "es256_verify")
fn es256_verify(
  message: BitArray,
  signature: BitArray,
  public: BitArray,
) -> Bool

@external(erlang, "brazier_client_ip_test_ffi", "dead_socket")
fn dead_socket() -> server.Socket
