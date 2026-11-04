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
///
/// The scheme comes from the same configured header and no other (see
/// `client_scheme`): `Forwarded` gives the `proto=` of the element that
/// names the client, `X-Forwarded-For` pairs with `X-Forwarded-Proto`, and
/// no header means plain `http`. Plug.RewriteOn rewrites the scheme only
/// from the headers it is told to believe, and Django's
/// `SECURE_PROXY_SSL_HEADER` names the one header that carries it.
import brazier/log
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Which forwarding header the trusted proxies set.
pub type ForwardingHeader {
  /// RFC 7239 `Forwarded: for=...;proto=...`.
  Forwarded
  /// `X-Forwarded-For: client, proxy1, ...`, with `X-Forwarded-Proto` for
  /// the scheme.
  XForwardedFor
  /// No header is read: the socket peer is always the client address and
  /// the scheme is always `http`. Proxies may still be listed: they are
  /// exempt from the per-IP connection cap.
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
          resolve(forwarded_elements(forwarded), peer, trusted).address
        }
        XForwardedFor -> {
          warn_unconfigured(forwarded, "Forwarded", peer)
          resolve(forwarded_for_hops(x_forwarded_for), peer, trusted).address
        }
      }
    }
  }
}

/// The scheme the client used to reach the outermost trusted proxy:
/// `http` or `https`.
///
/// When the peer is not trusted, or no forwarding header is configured,
/// no header is read and the scheme is `http` (Brazier does not terminate
/// TLS). Otherwise only the configured header's scheme is read:
///
/// - `Forwarded`: the `proto=` of the element that names the client (the
///   element `client_address` stops at), since the trusted proxy that
///   appended it saw the client's connection. An element without `proto=`
///   is `http`. `X-Forwarded-Proto` is not read.
/// - `X-Forwarded-For`: the left-most value of the one `X-Forwarded-Proto`
///   header, as Django's `SECURE_PROXY_SSL_HEADER` reads it, so the
///   outermost proxy must overwrite that header. `Forwarded` is not read.
///
/// Errors when the scheme read is not `http` or `https`, the header is sent
/// twice, or an element repeats `proto=` (RFC 7239 section 4).
pub fn client_scheme(
  peer: String,
  headers: List(#(String, String)),
  trusted: TrustedProxies,
) -> Result(String, String) {
  let forwarded = header_values(headers, "forwarded")
  let x_forwarded_proto = header_values(headers, "x-forwarded-proto")
  case is_trusted(peer, trusted), trusted.header {
    False, _ -> {
      ignore_scheme_headers(
        forwarded,
        x_forwarded_proto,
        "untrusted peer",
        peer,
      )
      Ok("http")
    }
    True, NoForwardingHeader -> {
      ignore_scheme_headers(
        forwarded,
        x_forwarded_proto,
        "trusted proxy (no forwarding header is configured)",
        peer,
      )
      Ok("http")
    }
    True, Forwarded -> {
      warn_unconfigured(x_forwarded_proto, "X-Forwarded-Proto", peer)
      forwarded_scheme(forwarded, peer, trusted)
    }
    True, XForwardedFor -> {
      // `client_address` already warns about a Forwarded header here.
      case forwarded {
        [] -> Nil
        [_, ..] ->
          log.debug(
            "brazier.ip",
            "Ignoring Forwarded proto= from trusted proxy "
              <> peer
              <> ": the configured header is X-Forwarded-For",
          )
      }
      x_forwarded_proto_scheme(x_forwarded_proto, peer)
    }
  }
}

fn ignore_scheme_headers(
  forwarded: List(String),
  x_forwarded_proto: List(String),
  who: String,
  peer: String,
) -> Nil {
  case forwarded, x_forwarded_proto {
    [], [] -> Nil
    _, _ ->
      log.debug(
        "brazier.ip",
        "Ignoring the forwarded scheme from " <> who <> " " <> peer,
      )
  }
}

fn forwarded_scheme(
  values: List(String),
  peer: String,
  trusted: TrustedProxies,
) -> Result(String, String) {
  case resolve(forwarded_elements(values), peer, trusted).tag {
    // No Forwarded header (`resolve` logged it): the proxy did not say.
    None -> Ok("http")
    Some([]) -> {
      log.debug(
        "brazier.ip",
        "The client's Forwarded element from "
          <> peer
          <> " has no proto=; scheme http",
      )
      Ok("http")
    }
    Some([proto]) -> parse_scheme(unquote(proto), "Forwarded proto=")
    Some([_, _, ..]) -> {
      log.warning(
        "brazier.ip",
        "Trusted proxy "
          <> peer
          <> " sent a Forwarded element with several proto= parameters",
      )
      Error("duplicate proto= in a Forwarded element")
    }
  }
}

fn x_forwarded_proto_scheme(
  values: List(String),
  peer: String,
) -> Result(String, String) {
  case values {
    [] -> Ok("http")
    [value] ->
      case string.split_once(value, ",") {
        Ok(#(first, _rest)) -> parse_scheme(first, "X-Forwarded-Proto")
        Error(Nil) -> parse_scheme(value, "X-Forwarded-Proto")
      }
    [_, _, ..] -> {
      log.warning(
        "brazier.ip",
        "Trusted proxy " <> peer <> " sent several X-Forwarded-Proto headers",
      )
      Error("duplicate X-Forwarded-Proto")
    }
  }
}

/// `http` or `https`, case-insensitive; anything else is an error. The
/// value is client-reachable text, so it is quoted (SEC-11).
fn parse_scheme(raw: String, source: String) -> Result(String, String) {
  let scheme = string.lowercase(string.trim(raw))
  case scheme {
    "http" | "https" -> Ok(scheme)
    _ -> {
      let reason = "invalid " <> source <> " " <> string.inspect(raw)
      log.warning("brazier.ip", "Trusted proxy sent an " <> reason)
      Error(reason)
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

/// Where the right-to-left walk over the hops stopped: the client address,
/// and the tag of the hop it stopped at (`None` only when there are no
/// hops).
type Stop(tag) {
  Stop(address: String, tag: Option(tag))
}

fn resolve(
  hops: List(#(Hop, tag)),
  peer: String,
  trusted: TrustedProxies,
) -> Stop(tag) {
  case list.reverse(hops) {
    [] -> {
      log.debug(
        "brazier.ip",
        "Trusted proxy "
          <> peer
          <> " sent no "
          <> forwarding_header_to_string(trusted.header)
          <> " header; it is the client",
      )
      Stop(address: peer, tag: None)
    }
    [last, ..rest] -> walk_hops(last, rest, peer, trusted)
  }
}

/// A hop parsed from a forwarding header: a valid address or garbage.
type Hop {
  Address(String)
  Malformed(String)
}

/// The client is the right-most hop that is not a trusted proxy. When every
/// hop is trusted it is the left-most one; at a malformed hop it is the
/// trusted proxy that appended that hop. Either way the walk stops at the
/// hop the outermost trusted proxy appended, whose tag `client_scheme`
/// reads.
fn walk_hops(
  hop: #(Hop, tag),
  rest: List(#(Hop, tag)),
  current: String,
  trusted: TrustedProxies,
) -> Stop(tag) {
  case hop.0 {
    Malformed(raw) -> {
      log.warning(
        "brazier.ip",
        "Malformed forwarding hop "
          <> string.inspect(raw)
          <> " behind trusted proxy "
          <> current
          <> " — using the proxy address",
      )
      Stop(address: current, tag: Some(hop.1))
    }
    Address(address) ->
      case is_trusted(address, trusted), rest {
        True, [next, ..more] -> walk_hops(next, more, address, trusted)
        True, [] | False, _ -> Stop(address: address, tag: Some(hop.1))
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

fn forwarded_for_hops(values: List(String)) -> List(#(Hop, Nil)) {
  values
  |> list.flat_map(fn(value) { string.split(value, ",") })
  |> list.map(fn(raw) {
    let trimmed = string.trim(raw)
    case parse_ip(strip_port(trimmed)) {
      Ok(address) -> #(Address(address), Nil)
      Error(Nil) -> #(Malformed(trimmed), Nil)
    }
  })
}

/// RFC 7239: `Forwarded: for=192.0.2.60;proto=http, for="[2001:db8::1]:4711"`.
/// Each element is its `for=` hop, tagged with its `proto=` values.
fn forwarded_elements(values: List(String)) -> List(#(Hop, List(String))) {
  values
  |> list.flat_map(fn(value) { string.split(value, ",") })
  |> list.map(fn(element) {
    let pairs =
      list.filter_map(string.split(element, ";"), fn(pair) {
        case string.split_once(string.trim(pair), "=") {
          Ok(#(key, value)) ->
            Ok(#(string.lowercase(string.trim(key)), string.trim(value)))
          Error(Nil) -> Error(Nil)
        }
      })
    let parameter = fn(name) {
      list.filter_map(pairs, fn(pair) {
        case pair.0 == name {
          True -> Ok(pair.1)
          False -> Error(Nil)
        }
      })
    }
    let hop = case parameter("for") {
      [raw, ..] -> {
        let raw = unquote(raw)
        case parse_ip(strip_port(raw)) {
          Ok(address) -> Address(address)
          Error(Nil) -> Malformed(raw)
        }
      }
      [] -> Malformed(string.trim(element))
    }
    #(hop, parameter("proto"))
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
