/// Brazier's minimal HTTP/WebSocket server built on gen_tcp.
/// Replaces Mist — provides only the functionality Brazier needs:
/// listen, accept, HTTP/1.1 request parsing, WebSocket upgrade + frames.
///
/// ## Supervision
///
/// A listener is a small OTP tree modelled on ranch's listener supervisor:
///
/// ```text
/// listener supervisor (rest_for_one)
/// ├── connection owner   brazier_http_conns      (worker)
/// │     links every connection handler process, enforces the global and
/// │     per-IP connection caps, releases a slot when a handler exits
/// ├── listen socket      brazier_http_listen_socket (worker)
/// │     opens the listen socket, traps exits, closes it in terminate
/// └── acceptors          brazier_http_acceptors_sup (supervisor, one_for_one)
///       N transient acceptor processes on that socket
/// ```
///
/// Stopping the listener stops the acceptors first (no new connection is
/// accepted), then closes the listen socket, then the connection owner
/// drains: it sends every handler a drain message and waits, without
/// polling, up to `drain_timeout_ms` for them to exit. An idle keep-alive
/// connection closes at once, a request in progress finishes and is
/// answered with `connection: close`, a WebSocket closes with 1001.
/// Handlers still running at the deadline are killed and logged as an
/// error.
///
/// The listen socket has an owner of its own because the runtime closes a
/// port asynchronously after its owner exits: a listener restarted at once
/// could find the port still bound (`eaddrinuse`). Closing the socket in
/// the owner's terminate makes the port free before the owner is reported
/// down. Ranch keeps the socket in its acceptor supervisor and never closes
/// it; Thousand Island gives it a dedicated listener process, as here.
///
/// A crashing handler only takes itself down (its slot is released by the
/// owner). A crashing acceptor is restarted and reported by its supervisor.
/// If the connection owner itself dies, rest_for_one restarts the socket
/// owner and the acceptors too, so no acceptor ever hands a socket to a dead
/// owner; if the socket owner dies, the acceptors restart on its new socket.
///
/// Reference: RFC 6455 (WebSocket), RFC 9112 (HTTP/1.1), ranch.
import brazier/ip
import brazier/log
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/string

/// Connection type — used as the body parameter for gleam_http Request.
/// Carries the socket reference so handlers can read the request body.
pub type Connection {
  Connection(
    socket: Socket,
    /// The upgrade's one resolution of the client (address and scheme
    /// behind the trusted proxies). A WebSocket upgrade resolves its client
    /// once, for the per-IP cap and the Origin check, and sets this before
    /// the middleware gate runs; every gate on that request must reuse it
    /// rather than parse the forwarding header again (`client.ip` does).
    /// `None` on a plain HTTP request, which nothing has resolved yet.
    resolved: Option(ip.Resolved),
  )
}

/// Response body type.
///
/// Reference: mist's `ResponseData` (`Bytes` and `File`), Plug's
/// `send_file/5`.
pub type ResponseBody {
  /// Bytes response body wrapping a BytesTree.
  Bytes(BytesTree)
  /// `length` bytes of the file at `path`, starting at byte `offset`. The
  /// listener writes them with `file:sendfile`, so they never enter the
  /// BEAM heap. Content-Length is `length`. If the file holds fewer bytes
  /// when it is sent, the response is cut short and the connection closed.
  /// Static files are served this way (`brazier/static`).
  File(path: String, offset: Int, length: Int)
}

/// Opaque socket type wrapping an Erlang gen_tcp socket (port).
pub type Socket

/// TCP message classification — used to decode raw Erlang {tcp,...} messages.
pub type TcpMsg {
  /// TCP data received from the socket.
  TcpData(BitArray)
  /// TCP connection was closed by the peer.
  TcpClosed
  /// TCP error occurred.
  TcpError(String)
}

// --- TCP Operations (FFI wrappers) ---

/// Listen on a port with the given backlog size.
@external(erlang, "brazier_transport_ffi", "listen")
pub fn listen(port: Int, backlog: Int) -> Result(Socket, String)

/// Accept a connection on a listening socket (blocks until connection arrives).
@external(erlang, "brazier_transport_ffi", "accept")
pub fn accept(listen_socket: Socket) -> Result(Socket, String)

/// Send raw bytes over a socket.
@external(erlang, "brazier_transport_ffi", "tcp_send")
pub fn send_bytes(socket: Socket, data: BitArray) -> Result(Nil, String)

/// Close a socket.
@external(erlang, "brazier_transport_ffi", "close")
pub fn close(socket: Socket) -> Nil

/// Transfer socket ownership to another process.
@external(erlang, "brazier_transport_ffi", "controlling_process")
pub fn controlling_process(
  socket: Socket,
  pid: process.Pid,
) -> Result(Nil, String)

/// Set socket to {active, once} mode — delivers one {tcp,...} message.
@external(erlang, "brazier_transport_ffi", "set_active_once")
pub fn set_active_once(socket: Socket) -> Nil

/// The socket peer's IP address as a normalized string
/// (IPv4-mapped IPv6 addresses are reported as plain IPv4).
@external(erlang, "brazier_ip_ffi", "peer_ip")
pub fn get_peer_ip(socket: Socket) -> Result(String, String)

/// The local port a connected socket was accepted on. Equals the
/// listener's bound port, which differs from the configured port when the
/// listener was started on port 0.
@external(erlang, "brazier_ip_ffi", "local_port")
pub fn get_local_port(socket: Socket) -> Result(Int, String)

// --- WebSocket Operations ---

/// Encode text as a WebSocket text frame (server→client, unmasked).
@external(erlang, "brazier_transport_ffi", "ws_encode_text_frame")
fn ffi_ws_encode_text_frame(text: String) -> BitArray

/// Encode a WebSocket close frame.
@external(erlang, "brazier_transport_ffi", "ws_encode_close_frame")
fn ffi_ws_encode_close_frame() -> BitArray

/// Send a WebSocket text frame.
pub fn send_text_frame(socket: Socket, text: String) -> Result(Nil, String) {
  let frame = ffi_ws_encode_text_frame(text)
  send_bytes(socket, frame)
}

/// Send a WebSocket close frame.
pub fn send_close_frame(socket: Socket) -> Result(Nil, String) {
  let frame = ffi_ws_encode_close_frame()
  send_bytes(socket, frame)
}

// --- HTTP Body Reading ---

/// Why `read_body` returned no bytes. After any of these but
/// `NoActiveRequest` and `ReadPastBody` the body is marked failed: the
/// connection answers and closes, because the rest of the body can no
/// longer be found in the stream.
pub type BodyReadError {
  /// No request body context: `read_body` was called outside an active
  /// HTTP request. A programming error.
  NoActiveRequest
  /// An earlier read of this body failed.
  BodyUnavailable
  /// The read asked for a negative count or for more bytes than remain of
  /// the declared Content-Length. A programming error.
  ReadPastBody(requested: Int, remaining: Int)
  /// No bytes arrived within `body_read_timeout_ms`.
  BodyReadTimeout
  /// The request ran past `request_timeout_ms` before the body arrived.
  RequestDeadlineExceeded
  /// The socket failed: the peer closed it or reset it.
  SocketFailed(reason: String)
}

/// A one-line description of a `BodyReadError`, for logs and replies.
pub fn describe_body_read_error(error: BodyReadError) -> String {
  case error {
    NoActiveRequest -> "read_body called outside an active HTTP request"
    BodyUnavailable -> "request body unavailable after an earlier read failure"
    ReadPastBody(requested:, remaining:) ->
      "requested "
      <> int.to_string(requested)
      <> " body bytes with "
      <> int.to_string(remaining)
      <> " left of the declared Content-Length"
    BodyReadTimeout ->
      "body_read_timeout_ms passed before the request body arrived"
    RequestDeadlineExceeded ->
      "request_timeout_ms passed before the request body arrived"
    SocketFailed(reason:) -> "request body read failed: " <> reason
  }
}

/// Read exactly `length` bytes of the current request's body.
///
/// Reads go through the per-request body context registered by the
/// connection loop: a read can never go past the declared Content-Length,
/// never wait longer than the body read timeout or the total request
/// deadline, and fails loudly when called outside an active request.
/// Application code should normally use `brazier/transport/http.read_body`.
@external(erlang, "brazier_transport_ffi", "http_body_read")
pub fn read_body(socket: Socket, length: Int) -> Result(BitArray, BodyReadError)

// --- TCP Message Classification ---

/// Classify a raw Erlang message into a TcpMsg.
/// Used with process.selecting_anything to decode {tcp,...} messages.
@external(erlang, "brazier_transport_ffi", "classify_tcp_message")
pub fn classify_tcp_message(raw: Dynamic) -> Result(TcpMsg, Nil)

// --- Listener ---

/// Options for starting a listener.
pub type ListenerOptions {
  ListenerOptions(
    /// Port to bind. `0` binds an OS-assigned free port; read it back with
    /// `get_port`.
    port: Int,
    /// Number of acceptor processes.
    acceptors: Int,
    /// Listen backlog.
    backlog: Int,
    /// Maximum live connections on this listener. Further connections are
    /// answered with 503 and closed by the acceptor.
    max_connections: Int,
    /// Maximum live connections from one peer IP.
    max_connections_per_ip: Int,
    /// Peers in these networks (reverse proxies) are exempt from the
    /// per-IP cap, because every client behind them shares their address.
    trusted_proxies: List(String),
    /// Socket send timeout. A peer that stops reading is disconnected
    /// instead of blocking its handler forever.
    send_timeout_ms: Int,
    /// How long a stopping listener waits for its connections to finish
    /// before killing them, in milliseconds. `0` kills them at once.
    drain_timeout_ms: Int,
  )
}

/// Default listener options for a port.
pub fn default_listener_options(port: Int) -> ListenerOptions {
  ListenerOptions(
    port: port,
    acceptors: 10,
    backlog: 1024,
    max_connections: 10_000,
    max_connections_per_ip: 256,
    trusted_proxies: [],
    send_timeout_ms: 30_000,
    drain_timeout_ms: 5000,
  )
}

/// Name of a listener's connection owner: `{via, brazier_http_conns, Ref}`,
/// a reference rather than an atom, so starting a listener creates no atom
/// (see `brazier_http_conns:new_name/0`).
type ConnsName

/// A running listener.
pub opaque type Listener {
  Listener(supervisor: process.Pid, conns: ConnsName, port: Int)
}

/// Start a supervised listener. The listener's supervisor is linked to the
/// calling process.
pub fn start(
  options: ListenerOptions,
  handler: fn(Socket) -> Nil,
) -> Result(Listener, String) {
  case build(options, handler) {
    Error(reason) -> {
      log.error("brazier.server", "Invalid listener options: " <> reason)
      Error(reason)
    }
    Ok(#(name, builder)) ->
      case static_supervisor.start(builder) {
        Ok(started) -> {
          let port = ffi_conns_get_port(name)
          log.info(
            "brazier.server",
            "Listening on port "
              <> int.to_string(port)
              <> " with "
              <> int.to_string(options.acceptors)
              <> " acceptors",
          )
          Ok(Listener(supervisor: started.pid, conns: name, port: port))
        }
        Error(err) -> {
          let reason = describe_start_error(err)
          log.error(
            "brazier.server",
            "Failed to start listener on port "
              <> int.to_string(options.port)
              <> ": "
              <> reason,
          )
          Error(reason)
        }
      }
  }
}

/// A child specification for embedding a listener in another supervision
/// tree (for example the application supervisor).
pub fn supervised(
  options: ListenerOptions,
  handler: fn(Socket) -> Nil,
) -> Result(supervision.ChildSpecification(Listener), String) {
  case build(options, handler) {
    Error(reason) -> {
      log.error("brazier.server", "Invalid listener options: " <> reason)
      Error(reason)
    }
    Ok(#(name, builder)) -> {
      log.debug(
        "brazier.server",
        "Prepared supervised listener for port " <> int.to_string(options.port),
      )
      Ok(
        supervision.supervisor(fn() {
          case static_supervisor.start(builder) {
            Ok(started) -> {
              let port = ffi_conns_get_port(name)
              // Same line as `start`: operators and the browser
              // conformance harness wait for "Listening on port".
              log.info(
                "brazier.server",
                "Listening on port "
                  <> int.to_string(port)
                  <> " with "
                  <> int.to_string(options.acceptors)
                  <> " acceptors (supervised)",
              )
              Ok(actor.Started(
                pid: started.pid,
                data: Listener(supervisor: started.pid, conns: name, port: port),
              ))
            }
            Error(err) -> {
              log.error(
                "brazier.server",
                "Supervised listener failed to start: "
                  <> describe_start_error(err),
              )
              Error(err)
            }
          }
        }),
      )
    }
  }
}

/// Stop a listener started with `start`: closes the listen socket, shuts
/// down every live connection, and forgets the remembered port.
pub fn stop(listener: Listener) -> Nil {
  log.info(
    "brazier.server",
    "Stopping listener on port " <> int.to_string(listener.port),
  )
  ffi_stop_supervisor(listener.supervisor)
  case release(listener) {
    True -> Nil
    False ->
      log.warning(
        "brazier.server",
        "No remembered bound port for listener on port "
          <> int.to_string(listener.port)
          <> " (stopped twice?)",
      )
  }
}

/// Forget the remembered bound port of a listener that has stopped for
/// good. A restarted listener rebinds the port it bound first (so a port-0
/// listener keeps its port across restarts); once its parent tree has been
/// stopped, that memory must go. `stop` calls this itself. Returns whether
/// a port was remembered: a caller that knows the listener ran warns when
/// it was not.
pub fn release(listener: Listener) -> Bool {
  let forgot = ffi_conns_forget_port(listener.conns)
  log.debug(
    "brazier.server",
    case forgot {
      True -> "Forgot bound port "
      False -> "No bound port remembered for port "
    }
      <> int.to_string(listener.port),
  )
  forgot
}

/// The port the listener is bound to (the OS-assigned one for port 0).
pub fn get_port(listener: Listener) -> Int {
  listener.port
}

/// The listener's supervisor pid.
pub fn get_supervisor(listener: Listener) -> process.Pid {
  listener.supervisor
}

/// Number of live connections on this listener.
pub fn get_connection_count(listener: Listener) -> Int {
  ffi_conns_count(listener.conns)
}

/// Number of live connections from one peer IP (textual address).
pub fn get_connection_count_for_ip(
  listener: Listener,
  address: String,
) -> Result(Int, Nil) {
  ffi_conns_count_for_ip(listener.conns, address)
}

/// Number of live WebSockets on this listener from one client IP: the
/// address the per-IP WebSocket cap counts, which behind a trusted proxy is
/// the forwarded client.
pub fn get_ws_connection_count_for_ip(
  listener: Listener,
  address: String,
) -> Int {
  ffi_conns_ws_count_for_ip(listener.conns, address)
}

/// Pids of the live connection handler processes.
pub fn get_connection_pids(listener: Listener) -> List(process.Pid) {
  ffi_conns_children(listener.conns)
}

/// Pid of the listener's current connection owner process.
pub fn get_connection_owner(listener: Listener) -> Result(process.Pid, Nil) {
  ffi_whereis(listener.conns)
}

fn build(
  options: ListenerOptions,
  handler: fn(Socket) -> Nil,
) -> Result(#(ConnsName, static_supervisor.Builder), String) {
  use Nil <- result_try(validate_options(options))
  use trusted <- result_try(ip.parse_proxy_networks(options.trusted_proxies))
  let name = ffi_conns_new_name()
  let conns =
    supervision.worker(fn() {
      ffi_conns_start_link(
        name,
        options.port,
        handler,
        options.max_connections,
        options.max_connections_per_ip,
        trusted,
        options.drain_timeout_ms,
      )
    })
    // The owner drains for up to drain_timeout_ms, then kills the
    // stragglers and waits for their exits: the margin covers that.
    |> supervision.timeout(ms: options.drain_timeout_ms + conns_stop_margin_ms)
  let listen_socket =
    supervision.worker(fn() {
      ffi_listen_socket_start_link(
        name,
        options.backlog,
        options.send_timeout_ms,
      )
    })
  let acceptors =
    supervision.supervisor(fn() {
      ffi_acceptors_start_link(name, options.acceptors)
    })
  let builder =
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 10)
    |> static_supervisor.add(conns)
    |> static_supervisor.add(listen_socket)
    |> static_supervisor.add(acceptors)
  Ok(#(name, builder))
}

/// Time the connection owner gets on top of its drain timeout to kill the
/// remaining handlers and collect their exits before its supervisor kills
/// it.
const conns_stop_margin_ms = 5000

/// Largest receive timeout (2^32 - 1 ms).
const max_drain_timeout_ms = 4_294_967_295

fn validate_options(options: ListenerOptions) -> Result(Nil, String) {
  case options {
    ListenerOptions(port: port, ..) if port < 0 || port > 65_535 ->
      Error("port must be between 0 and 65535, got " <> int.to_string(port))
    ListenerOptions(acceptors: n, ..) if n < 1 ->
      Error("acceptors must be at least 1, got " <> int.to_string(n))
    ListenerOptions(backlog: n, ..) if n < 1 ->
      Error("backlog must be at least 1, got " <> int.to_string(n))
    ListenerOptions(max_connections: n, ..) if n < 1 ->
      Error("max_connections must be at least 1, got " <> int.to_string(n))
    ListenerOptions(max_connections_per_ip: n, ..) if n < 1 ->
      Error(
        "max_connections_per_ip must be at least 1, got " <> int.to_string(n),
      )
    ListenerOptions(send_timeout_ms: n, ..) if n < 1 ->
      Error("send_timeout_ms must be at least 1, got " <> int.to_string(n))
    ListenerOptions(drain_timeout_ms: n, ..)
      if n < 0 || n > max_drain_timeout_ms
    ->
      Error(
        "drain_timeout_ms must be between 0 and "
        <> int.to_string(max_drain_timeout_ms)
        <> ", got "
        <> int.to_string(n),
      )
    _ -> Ok(Nil)
  }
}

fn result_try(
  result: Result(a, String),
  next: fn(a) -> Result(b, String),
) -> Result(b, String) {
  case result {
    Ok(value) -> next(value)
    Error(reason) -> Error(reason)
  }
}

fn describe_start_error(err: actor.StartError) -> String {
  case err {
    actor.InitFailed(reason) -> reason
    actor.InitTimeout -> "listener start timed out"
    actor.InitExited(reason) ->
      "listener exited during start: " <> string.inspect(reason)
  }
}

@external(erlang, "brazier_http_conns", "new_name")
fn ffi_conns_new_name() -> ConnsName

@external(erlang, "brazier_http_conns", "start_link_gleam")
fn ffi_conns_start_link(
  name: ConnsName,
  port: Int,
  handler: fn(Socket) -> Nil,
  max_connections: Int,
  max_connections_per_ip: Int,
  trusted: ip.ProxyNetworks,
  drain_timeout_ms: Int,
) -> Result(actor.Started(ConnsName), actor.StartError)

@external(erlang, "brazier_http_listen_socket", "start_link_gleam")
fn ffi_listen_socket_start_link(
  name: ConnsName,
  backlog: Int,
  send_timeout_ms: Int,
) -> Result(actor.Started(Nil), actor.StartError)

@external(erlang, "brazier_http_acceptors_sup", "start_link_gleam")
fn ffi_acceptors_start_link(
  name: ConnsName,
  acceptors: Int,
) -> Result(actor.Started(Nil), actor.StartError)

@external(erlang, "brazier_http_conns", "get_port")
fn ffi_conns_get_port(name: ConnsName) -> Int

@external(erlang, "brazier_http_conns", "forget_port")
fn ffi_conns_forget_port(name: ConnsName) -> Bool

@external(erlang, "brazier_http_conns", "count")
fn ffi_conns_count(name: ConnsName) -> Int

@external(erlang, "brazier_http_conns", "count_for_ip_text")
fn ffi_conns_count_for_ip(name: ConnsName, address: String) -> Result(Int, Nil)

@external(erlang, "brazier_http_conns", "ws_count_for_ip")
fn ffi_conns_ws_count_for_ip(name: ConnsName, address: String) -> Int

@external(erlang, "brazier_http_conns", "children")
fn ffi_conns_children(name: ConnsName) -> List(process.Pid)

@external(erlang, "brazier_http_conns", "owner_pid")
fn ffi_whereis(name: ConnsName) -> Result(process.Pid, Nil)

@external(erlang, "brazier_server_ffi", "stop_supervisor")
fn ffi_stop_supervisor(pid: process.Pid) -> Nil
