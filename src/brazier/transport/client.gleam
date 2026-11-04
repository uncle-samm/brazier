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
///   a trusted proxy and the configured header carries one: `proto=` of the
///   client's `Forwarded` element, or `X-Forwarded-Proto` alongside
///   `X-Forwarded-For`. It must then be `http` or `https`.
///
/// Reference: Plug.RewriteOn / RemoteIp, Rails `remote_ip`, Django
/// `SECURE_PROXY_SSL_HEADER`.
import brazier/internal/log_path
import brazier/ip
import brazier/log
import brazier/transport/server.{type Connection, type Socket}
import gleam/http/request.{type Request}

/// The client IP for a request (normalized textual address).
/// Errors only when the socket peer address cannot be read (the peer left).
pub fn ip(
  req: Request(Connection),
  trusted: ip.TrustedProxies,
) -> Result(String, String) {
  log.debug(
    "brazier.client",
    "Resolving client IP for " <> log_path.describe(req.path),
  )
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
/// unusable scheme in the configured header.
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

/// Pure core of `scheme`: decide from the peer address and headers (see
/// `ip.client_scheme`).
pub fn scheme_from(
  peer: String,
  headers: List(#(String, String)),
  trusted: ip.TrustedProxies,
) -> Result(String, String) {
  log.debug("brazier.client", "Resolving the scheme for peer " <> peer)
  ip.client_scheme(peer, headers, trusted)
}
