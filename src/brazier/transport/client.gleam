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
import gleam/option.{Some}

/// The client IP for a request (normalized textual address).
/// Errors only when the socket peer address cannot be read (the peer left).
///
/// A request whose client was already resolved against the same trusted
/// proxies (`Connection.resolved`, set by a WebSocket upgrade) reuses that
/// resolution: the forwarding header is not parsed, or logged, again.
/// Against other proxies the answer may differ, so it is resolved afresh.
pub fn ip(
  req: Request(Connection),
  trusted: ip.TrustedProxies,
) -> Result(String, String) {
  case req.body.resolved {
    Some(ip.Resolved(trusted: resolved_against, client:))
      if resolved_against == trusted
    -> {
      log.debug(
        "brazier.client",
        "Reusing the resolved client "
          <> client.address
          <> " for "
          <> log_path.describe(req.path),
      )
      Ok(client.address)
    }
    _ -> {
      log.debug(
        "brazier.client",
        "Resolving client IP for " <> log_path.describe(req.path),
      )
      ip_for_socket(req.body.socket, req.headers, trusted)
    }
  }
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

/// The client IP and scheme together, from one parse of the forwarding
/// header (`ip.client`), so a WebSocket upgrade that needs both logs a
/// problem in that header once. Errors only when the socket peer address
/// cannot be read; the scheme is a `Result` of its own.
pub fn ip_and_scheme(
  socket: Socket,
  headers: List(#(String, String)),
  trusted: ip.TrustedProxies,
) -> Result(ip.Client, String) {
  case server.get_peer_ip(socket) {
    Error(reason) -> {
      log.warning("brazier.client", "Cannot read peer address: " <> reason)
      Error(reason)
    }
    Ok(peer) -> {
      let resolved = ip.client(peer, headers, trusted)
      case resolved.address == peer {
        True -> Nil
        False ->
          log.debug(
            "brazier.client",
            "Client " <> resolved.address <> " via trusted proxy " <> peer,
          )
      }
      Ok(resolved)
    }
  }
}

/// The scheme the client used to reach the server, `http` or `https`,
/// decided from the peer address and headers (see `ip.client_scheme`).
/// Errors when a trusted proxy sent an unusable scheme in the configured
/// header. A caller that also needs the address uses `ip_and_scheme`.
pub fn scheme_from(
  peer: String,
  headers: List(#(String, String)),
  trusted: ip.TrustedProxies,
) -> Result(String, String) {
  log.debug("brazier.client", "Resolving the scheme for peer " <> peer)
  ip.client_scheme(peer, headers, trusted)
}
