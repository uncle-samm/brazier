/// IP address helpers: trusted-proxy CIDR lists and client address
/// resolution from `Forwarded` / `X-Forwarded-For`.
///
/// Forwarding headers are only honoured when the socket peer is a trusted
/// proxy. The client address is then the right-most hop that is NOT a
/// trusted proxy (RFC 7239 section 7.4; the same rule as Plug.RewriteOn /
/// Rails `remote_ip`). A client can prepend arbitrary hops to the header but
/// cannot forge the hops appended by the trusted proxies to their right.
import beacon/log
import gleam/list
import gleam/string

/// A parsed list of trusted proxy networks.
pub type TrustedProxies

/// Parse trusted proxy entries such as `"10.0.0.0/8"`, `"127.0.0.1"`,
/// or `"fd00::/8"`. Any invalid entry is an error — a typo in a proxy list
/// must never silently widen or narrow trust.
pub fn parse_trusted_proxies(
  entries: List(String),
) -> Result(TrustedProxies, String) {
  case ffi_parse_cidrs(entries) {
    Ok(parsed) -> {
      log.debug(
        "beacon.ip",
        "Parsed " <> string.inspect(list.length(entries)) <> " trusted proxies",
      )
      Ok(parsed)
    }
    Error(reason) -> {
      log.error("beacon.ip", "Invalid trusted proxy list: " <> reason)
      Error(reason)
    }
  }
}

/// An empty trusted proxy list: forwarding headers are never honoured.
pub fn no_trusted_proxies() -> TrustedProxies {
  let assert Ok(parsed) = ffi_parse_cidrs([])
    as "parsing an empty CIDR list cannot fail"
  parsed
}

/// Normalize a textual IP address (IPv4-mapped IPv6 becomes IPv4).
pub fn parse_ip(text: String) -> Result(String, Nil) {
  ffi_parse_ip(string.trim(text))
}

/// Is the (textual) address inside one of the trusted networks?
pub fn is_trusted(address: String, trusted: TrustedProxies) -> Bool {
  case ffi_parse_ip_tuple(address) {
    Ok(tuple) -> ffi_cidrs_match(tuple, trusted)
    Error(Nil) -> False
  }
}

/// Resolve the client address for a request.
///
/// `peer` is the socket peer address. `headers` are the request headers
/// (lower-case names). When the peer is not trusted the headers are ignored.
/// `Forwarded` takes precedence over `X-Forwarded-For` when present.
pub fn client_address(
  peer: String,
  headers: List(#(String, String)),
  trusted: TrustedProxies,
) -> String {
  case is_trusted(peer, trusted) {
    False -> peer
    True -> {
      let hops = case header_values(headers, "forwarded") {
        [] -> forwarded_for_hops(header_values(headers, "x-forwarded-for"))
        values -> forwarded_hops(values)
      }
      walk_hops(list.reverse(hops), peer, trusted)
    }
  }
}

/// A hop parsed from a forwarding header: a valid address or garbage.
type Hop {
  Address(String)
  Malformed(String)
}

fn walk_hops(
  reversed_hops: List(Hop),
  current: String,
  trusted: TrustedProxies,
) -> String {
  case reversed_hops {
    [] -> current
    [Malformed(raw), ..] -> {
      log.warning(
        "beacon.ip",
        "Malformed forwarding hop "
          <> string.inspect(raw)
          <> " behind trusted proxy "
          <> current
          <> " — using the proxy address",
      )
      current
    }
    [Address(address), ..rest] ->
      case is_trusted(address, trusted) {
        True -> walk_hops(rest, address, trusted)
        False -> address
      }
  }
}

fn header_values(
  headers: List(#(String, String)),
  name: String,
) -> List(String) {
  list.filter_map(headers, fn(header) {
    case header.0 == name {
      True -> Ok(header.1)
      False -> Error(Nil)
    }
  })
}

fn forwarded_for_hops(values: List(String)) -> List(Hop) {
  values
  |> list.flat_map(fn(value) { string.split(value, ",") })
  |> list.map(fn(raw) {
    let trimmed = string.trim(raw)
    case parse_ip(strip_port(trimmed)) {
      Ok(address) -> Address(address)
      Error(Nil) -> Malformed(trimmed)
    }
  })
}

/// RFC 7239: `Forwarded: for=192.0.2.60;proto=http, for="[2001:db8::1]:4711"`
fn forwarded_hops(values: List(String)) -> List(Hop) {
  values
  |> list.flat_map(fn(value) { string.split(value, ",") })
  |> list.map(fn(element) {
    let pairs = string.split(element, ";")
    let for_value =
      list.find_map(pairs, fn(pair) {
        case string.split_once(string.trim(pair), "=") {
          Ok(#(key, value)) ->
            case string.lowercase(string.trim(key)) {
              "for" -> Ok(unquote(string.trim(value)))
              _ -> Error(Nil)
            }
          Error(Nil) -> Error(Nil)
        }
      })
    case for_value {
      Ok(raw) ->
        case parse_ip(strip_port(raw)) {
          Ok(address) -> Address(address)
          Error(Nil) -> Malformed(raw)
        }
      Error(Nil) -> Malformed(string.trim(element))
    }
  })
}

fn unquote(value: String) -> String {
  case string.starts_with(value, "\""), string.ends_with(value, "\"") {
    True, True -> value |> string.drop_start(1) |> string.drop_end(1)
    _, _ -> value
  }
}

/// Strip `:port` from `1.2.3.4:80` and brackets/port from `[::1]:80`.
/// A bare IPv6 address (several colons, no brackets) is returned as-is.
fn strip_port(value: String) -> String {
  case string.starts_with(value, "[") {
    True ->
      case string.split_once(string.drop_start(value, 1), "]") {
        Ok(#(address, _port)) -> address
        Error(Nil) -> value
      }
    False ->
      case string.split(value, ":") {
        [address, _port] -> address
        _ -> value
      }
  }
}

type IpTuple

@external(erlang, "beacon_ip_ffi", "parse_cidrs")
fn ffi_parse_cidrs(entries: List(String)) -> Result(TrustedProxies, String)

@external(erlang, "beacon_ip_ffi", "parse_ip")
fn ffi_parse_ip(text: String) -> Result(String, Nil)

@external(erlang, "beacon_ip_ffi", "parse_ip_tuple_result")
fn ffi_parse_ip_tuple(text: String) -> Result(IpTuple, Nil)

@external(erlang, "beacon_ip_ffi", "cidrs_match")
fn ffi_cidrs_match(ip: IpTuple, trusted: TrustedProxies) -> Bool
