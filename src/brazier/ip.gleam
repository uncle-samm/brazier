/// IP address helpers: trusted-proxy CIDR lists and client address
/// resolution from the one forwarding header the operator configured.
///
/// The operator names exactly one header that their proxies set:
/// `Forwarded` (RFC 7239), `X-Forwarded-For`, or neither. Brazier never
/// guesses between them: a proxy that rewrites one header passes the other
/// through from the client untouched, so honouring "whichever is present"
/// would let the client choose its own address. Plug.RewriteOn likewise
/// takes an explicit list of the headers to believe, and Rails `RemoteIp`
/// raises `IpSpoofAttackError` when the two headers disagree.
///
/// The configured header is only read when the socket peer is a trusted
/// proxy. The client address is then the right-most hop that is NOT a
/// trusted proxy (RFC 7239 section 7.4; the same rule as Rails
/// `remote_ip`). A client can prepend arbitrary hops to the header but
/// cannot forge the hops appended by the trusted proxies to their right.
import brazier/log
import gleam/list
import gleam/string

/// Which forwarding header the trusted proxies set.
pub type ForwardingHeader {
  /// RFC 7239 `Forwarded: for=...`.
  Forwarded
  /// `X-Forwarded-For: client, proxy1, ...`.
  XForwardedFor
  /// No header is read: the socket peer is always the client address.
  /// Proxies may still be listed: they are exempt from the per-IP
  /// connection cap, and their `X-Forwarded-Proto` is believed.
  NoForwardingHeader
}

/// A parsed list of trusted proxy networks, without a header. The listener
/// uses it to exempt proxies from the per-IP connection cap.
pub type ProxyNetworks

/// Trusted proxy networks and the one forwarding header they set.
pub opaque type TrustedProxies {
  TrustedProxies(networks: ProxyNetworks, header: ForwardingHeader)
}

/// The header name, for logs and error messages.
pub fn forwarding_header_to_string(header: ForwardingHeader) -> String {
  case header {
    Forwarded -> "Forwarded"
    XForwardedFor -> "X-Forwarded-For"
    NoForwardingHeader -> "none"
  }
}

/// Parse trusted proxy entries such as `"10.0.0.0/8"`, `"127.0.0.1"`,
/// or `"fd00::/8"`, with the header those proxies set. Any invalid entry is
/// an error: a typo in a proxy list must never silently widen or narrow
/// trust. A header with no proxies is an error too: it would never be read,
/// and the operator plainly expected it to be.
pub fn parse_trusted_proxies(
  entries: List(String),
  header: ForwardingHeader,
) -> Result(TrustedProxies, String) {
  case parse_proxy_networks(entries), entries, header {
    Error(reason), _, _ -> Error(reason)
    Ok(_), [], Forwarded | Ok(_), [], XForwardedFor -> {
      let reason =
        "forwarding header "
        <> forwarding_header_to_string(header)
        <> " is configured but no trusted proxies are listed, so it would never be read"
      log.error("brazier.ip", "Invalid trusted proxy configuration: " <> reason)
      Error(reason)
    }
    Ok(networks), _, _ -> {
      let count = string.inspect(list.length(entries))
      case entries, header {
        [_, ..], NoForwardingHeader ->
          log.info(
            "brazier.ip",
            count
              <> " trusted proxies and no forwarding header: the socket peer is always the client address",
          )
        _, _ ->
          log.debug(
            "brazier.ip",
            "Parsed "
              <> count
              <> " trusted proxies, forwarding header "
              <> forwarding_header_to_string(header),
          )
      }
      Ok(TrustedProxies(networks: networks, header: header))
    }
  }
}

/// Parse trusted proxy networks without a header, for the listener's
/// per-IP cap exemption. Any invalid entry is an error.
pub fn parse_proxy_networks(
  entries: List(String),
) -> Result(ProxyNetworks, String) {
  case ffi_parse_cidrs(entries) {
    Ok(parsed) -> Ok(parsed)
    Error(reason) -> {
      log.error("brazier.ip", "Invalid trusted proxy list: " <> reason)
      Error(reason)
    }
  }
}

/// No trusted proxies: forwarding headers are never honoured.
pub fn no_trusted_proxies() -> TrustedProxies {
  // Invariant: the FFI only fails on an invalid entry, and there are none.
  let assert Ok(networks) = ffi_parse_cidrs([])
    as "parsing an empty CIDR list cannot fail"
  TrustedProxies(networks: networks, header: NoForwardingHeader)
}

/// Normalize a textual IP address (IPv4-mapped IPv6 becomes IPv4).
pub fn parse_ip(text: String) -> Result(String, Nil) {
  ffi_parse_ip(string.trim(text))
}

/// Is the (textual) address inside one of the trusted networks?
pub fn is_trusted(address: String, trusted: TrustedProxies) -> Bool {
  case ffi_parse_ip_tuple(address) {
    Ok(tuple) -> ffi_cidrs_match(tuple, trusted.networks)
    Error(Nil) -> False
  }
}

/// Resolve the client address for a request.
///
/// `peer` is the socket peer address. `headers` are the request headers
/// (lower-case names). When the peer is not trusted the headers are
/// ignored. When it is, only the configured header is read. The other
/// forwarding header is never read; it is logged as a warning, because a
/// proxy that sets one header passes the other through from the client.
pub fn client_address(
  peer: String,
  headers: List(#(String, String)),
  trusted: TrustedProxies,
) -> String {
  case is_trusted(peer, trusted) {
    False -> peer
    True -> {
      let forwarded = header_values(headers, "forwarded")
      let x_forwarded_for = header_values(headers, "x-forwarded-for")
      case trusted.header {
        NoForwardingHeader -> {
          case forwarded, x_forwarded_for {
            [], [] -> Nil
            _, _ ->
              log.debug(
                "brazier.ip",
                "Ignoring forwarding headers from trusted proxy "
                  <> peer
                  <> ": no forwarding header is configured",
              )
          }
          peer
        }
        Forwarded -> {
          warn_unconfigured(x_forwarded_for, "X-Forwarded-For", peer)
          resolve(forwarded_hops(forwarded), peer, trusted)
        }
        XForwardedFor -> {
          warn_unconfigured(forwarded, "Forwarded", peer)
          resolve(forwarded_for_hops(x_forwarded_for), peer, trusted)
        }
      }
    }
  }
}

/// A trusted proxy delivered the forwarding header it is not configured to
/// set, so the client (or a proxy it controls) sent it. It is not read. A
/// correct deployment never produces this, and Rails treats the same
/// situation as an IP spoofing attempt, so it is a warning, not debug.
fn warn_unconfigured(values: List(String), name: String, peer: String) -> Nil {
  case values {
    [] -> Nil
    _ ->
      log.warning(
        "brazier.ip",
        "Ignoring "
          <> name
          <> " "
          <> string.inspect(string.join(values, ", "))
          <> " from trusted proxy "
          <> peer
          <> ": it is not the configured forwarding header (possible spoofing)",
      )
  }
}

fn resolve(hops: List(Hop), peer: String, trusted: TrustedProxies) -> String {
  case hops {
    [] -> {
      log.debug(
        "brazier.ip",
        "Trusted proxy "
          <> peer
          <> " sent no "
          <> forwarding_header_to_string(trusted.header)
          <> " header; it is the client",
      )
      peer
    }
    _ -> walk_hops(list.reverse(hops), peer, trusted)
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
        "brazier.ip",
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

@external(erlang, "brazier_ip_ffi", "parse_cidrs")
fn ffi_parse_cidrs(entries: List(String)) -> Result(ProxyNetworks, String)

@external(erlang, "brazier_ip_ffi", "parse_ip")
fn ffi_parse_ip(text: String) -> Result(String, Nil)

@external(erlang, "brazier_ip_ffi", "parse_ip_tuple_result")
fn ffi_parse_ip_tuple(text: String) -> Result(IpTuple, Nil)

@external(erlang, "brazier_ip_ffi", "cidrs_match")
fn ffi_cidrs_match(ip: IpTuple, networks: ProxyNetworks) -> Bool
