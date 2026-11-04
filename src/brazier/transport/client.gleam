/// Who sent a request, and over which scheme, honouring forwarding headers
/// only from trusted proxies.
///
/// This is the single place Brazier resolves a client's address and scheme:
/// the HTTP rate limiter, the per-IP WebSocket cap and the WebSocket Origin
/// check all call it, so they can never disagree about who a client is.
///
/// - The client IP is the socket peer, unless the peer is a trusted proxy:
///   then it is the right-most hop of the one configured forwarding header
///   (`Forwarded` or `X-Forwarded-For`) that is not itself a trusted proxy
///   (see `brazier/ip`). A direct client cannot spoof its address with
///   these headers, and a client behind the proxy cannot pick the header.
/// - The scheme is `http` (Brazier does not terminate TLS), unless the peer is
///   a trusted proxy that sent `X-Forwarded-Proto`, which must then be
///   `http` or `https`.
///
/// Reference: Plug.RewriteOn / RemoteIp, Rails `remote_ip`.
import brazier/ip
import brazier/log
import brazier/transport/server.{type Connection, type Socket}
import gleam/http/request.{type Request}
import gleam/list
import gleam/string

/// The client IP for a request (normalized textual address).
/// Errors only when the socket peer address cannot be read (the peer left).
pub fn ip(
  req: Request(Connection),
  trusted: ip.TrustedProxies,
) -> Result(String, String) {
  log.debug("brazier.client", "Resolving client IP for " <> req.path)
  ip_for_socket(req.body.socket, req.headers, trusted)
}

/// `ip`, for callers that hold the socket and headers separately.
pub fn ip_for_socket(
  socket: Socket,
  headers: List(#(String, String)),
  trusted: ip.TrustedProxies,
) -> Result(String, String) {
  case server.get_peer_ip(socket) {
    Error(reason) -> {
      log.warning("brazier.client", "Cannot read peer address: " <> reason)
      Error(reason)
    }
    Ok(peer) -> {
      let address = ip.client_address(peer, headers, trusted)
      case address == peer {
        True -> Nil
        False ->
          log.debug(
            "brazier.client",
            "Client " <> address <> " via trusted proxy " <> peer,
          )
      }
      Ok(address)
    }
  }
}

/// The scheme the client used to reach the server: `http` or `https`.
/// Errors when the peer address cannot be read, or a trusted proxy sent an
/// unusable `X-Forwarded-Proto`.
pub fn scheme(
  req: Request(Connection),
  trusted: ip.TrustedProxies,
) -> Result(String, String) {
  case server.get_peer_ip(req.body.socket) {
    Error(reason) -> {
      log.warning("brazier.client", "Cannot read peer address: " <> reason)
      Error(reason)
    }
    Ok(peer) -> scheme_from(peer, req.headers, trusted)
  }
}

/// Pure core of `scheme`: decide from the peer address and headers.
pub fn scheme_from(
  peer: String,
  headers: List(#(String, String)),
  trusted: ip.TrustedProxies,
) -> Result(String, String) {
  let proto =
    list.filter_map(headers, fn(header) {
      case header.0 == "x-forwarded-proto" {
        True -> Ok(header.1)
        False -> Error(Nil)
      }
    })
  case ip.is_trusted(peer, trusted), proto {
    False, [] -> Ok("http")
    False, [_, ..] -> {
      log.debug(
        "brazier.client",
        "Ignoring X-Forwarded-Proto from untrusted peer " <> peer,
      )
      Ok("http")
    }
    True, [] -> Ok("http")
    True, [value] -> forwarded_proto(value)
    True, [_, _, ..] -> {
      log.warning(
        "brazier.client",
        "Trusted proxy " <> peer <> " sent several X-Forwarded-Proto headers",
      )
      Error("duplicate X-Forwarded-Proto")
    }
  }
}

/// The first token of X-Forwarded-Proto (the scheme the client used to
/// reach the outermost proxy).
fn forwarded_proto(value: String) -> Result(String, String) {
  let first = case string.split(value, ",") {
    [token, ..] -> string.lowercase(string.trim(token))
    [] -> ""
  }
  case first {
    "http" | "https" -> Ok(first)
    _ -> {
      log.warning(
        "brazier.client",
        "Invalid X-Forwarded-Proto \"" <> value <> "\"",
      )
      Error("invalid X-Forwarded-Proto \"" <> value <> "\"")
    }
  }
}
