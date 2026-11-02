/// Beacon's minimal HTTP/WebSocket server built on gen_tcp.
/// Replaces Mist — provides only the functionality Beacon needs:
/// listen, accept, HTTP/1.1 request parsing, WebSocket upgrade + frames.
///
/// ## Supervision
///
/// A listener is a small OTP tree modelled on ranch's listener supervisor:
///
/// ```text
/// listener supervisor (rest_for_one)
/// ├── connection owner   beacon_http_conns      (worker)
/// │     links every connection handler process, enforces the global and
/// │     per-IP connection caps, releases a slot when a handler exits
/// └── acceptors          beacon_http_acceptors_sup (supervisor, one_for_one)
///       owns the listen socket; N permanent acceptor processes
/// ```
///
/// A crashing handler only takes itself down (its slot is released by the
/// owner). A crashing acceptor is restarted and reported by its supervisor.
/// If the connection owner itself dies, rest_for_one restarts the acceptors
/// too, so no acceptor ever hands a socket to a dead owner.
///
/// Reference: RFC 6455 (WebSocket), RFC 9112 (HTTP/1.1), ranch.
import beacon/ip
import beacon/log
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/string

/// Connection type — used as the body parameter for gleam_http Request.
/// Carries the socket reference so handlers can read the request body.
pub type Connection {
  Connection(socket: Socket)
}

/// Response body type. Replaces mist.ResponseData.
pub type ResponseBody {
  /// Bytes response body wrapping a BytesTree.
  Bytes(BytesTree)
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
@external(erlang, "beacon_transport_ffi", "listen")
pub fn listen(port: Int, backlog: Int) -> Result(Socket, String)

/// Accept a connection on a listening socket (blocks until connection arrives).
@external(erlang, "beacon_transport_ffi", "accept")
pub fn accept(listen_socket: Socket) -> Result(Socket, String)

/// Send raw bytes over a socket.
@external(erlang, "beacon_transport_ffi", "tcp_send")
pub fn send_bytes(socket: Socket, data: BitArray) -> Result(Nil, String)

/// Close a socket.
@external(erlang, "beacon_transport_ffi", "close")
pub fn close(socket: Socket) -> Nil

/// Transfer socket ownership to another process.
@external(erlang, "beacon_transport_ffi", "controlling_process")
pub fn controlling_process(
  socket: Socket,
  pid: process.Pid,
) -> Result(Nil, String)

/// Set socket to {active, once} mode — delivers one {tcp,...} message.
@external(erlang, "beacon_transport_ffi", "set_active_once")
pub fn set_active_once(socket: Socket) -> Nil

/// The socket peer's IP address as a normalized string
/// (IPv4-mapped IPv6 addresses are reported as plain IPv4).
@external(erlang, "beacon_ip_ffi", "peer_ip")
pub fn get_peer_ip(socket: Socket) -> Result(String, String)

/// The local port a connected socket was accepted on. Equals the
/// listener's bound port, which differs from the configured port when the
/// listener was started on port 0.
@external(erlang, "beacon_ip_ffi", "local_port")
pub fn get_local_port(socket: Socket) -> Result(Int, String)

// --- WebSocket Operations ---

/// Encode text as a WebSocket text frame (server→client, unmasked).
@external(erlang, "beacon_transport_ffi", "ws_encode_text_frame")
fn ffi_ws_encode_text_frame(text: String) -> BitArray

/// Encode a WebSocket close frame.
@external(erlang, "beacon_transport_ffi", "ws_encode_close_frame")
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

/// Read exactly `length` bytes of the current request's body.
///
/// Reads go through the per-request body context registered by the
/// connection loop: a read can never go past the declared Content-Length,
/// never wait longer than the body read timeout or the total request
/// deadline, and fails loudly when called outside an active request.
/// Application code should normally use `beacon/transport/http.read_body`.
@external(erlang, "beacon_transport_ffi", "read_body")
pub fn read_body(socket: Socket, length: Int) -> Result(BitArray, String)

// --- TCP Message Classification ---

/// Classify a raw Erlang message into a TcpMsg.
/// Used with process.selecting_anything to decode {tcp,...} messages.
@external(erlang, "beacon_transport_ffi", "classify_tcp_message")
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
  )
}

/// Registered name of a listener's connection owner (an Erlang atom).
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
      log.error("beacon.server", "Invalid listener options: " <> reason)
      Error(reason)
    }
    Ok(#(name, builder)) ->
      case static_supervisor.start(builder) {
        Ok(started) -> {
          let port = ffi_conns_get_port(name)
          log.info(
            "beacon.server",
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
            "beacon.server",
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
      log.error("beacon.server", "Invalid listener options: " <> reason)
      Error(reason)
    }
    Ok(#(name, builder)) -> {
      log.debug(
        "beacon.server",
        "Prepared supervised listener for port " <> int.to_string(options.port),
      )
      Ok(
        supervision.supervisor(fn() {
          case static_supervisor.start(builder) {
            Ok(started) -> {
              let port = ffi_conns_get_port(name)
              log.info(
                "beacon.server",
                "Supervised listener on port " <> int.to_string(port),
              )
              Ok(actor.Started(
                pid: started.pid,
                data: Listener(supervisor: started.pid, conns: name, port: port),
              ))
            }
            Error(err) -> Error(err)
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
    "beacon.server",
    "Stopping listener on port " <> int.to_string(listener.port),
  )
  ffi_stop_supervisor(listener.supervisor)
  case ffi_conns_forget_port(listener.conns) {
    True ->
      log.debug(
        "beacon.server",
        "Forgot bound port " <> int.to_string(listener.port),
      )
    False ->
      log.warning(
        "beacon.server",
        "No remembered bound port for listener on port "
          <> int.to_string(listener.port)
          <> " (stopped twice?)",
      )
  }
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
  use trusted <- result_try(ip.parse_trusted_proxies(options.trusted_proxies))
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
      )
    })
    // The owner waits up to 5s for its connections to exit on shutdown.
    |> supervision.timeout(ms: 10_000)
  let acceptors =
    supervision.supervisor(fn() {
      ffi_acceptors_start_link(
        name,
        options.acceptors,
        options.backlog,
        options.send_timeout_ms,
      )
    })
  let builder =
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 10)
    |> static_supervisor.add(conns)
    |> static_supervisor.add(acceptors)
  Ok(#(name, builder))
}

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

@external(erlang, "beacon_http_conns", "new_name")
fn ffi_conns_new_name() -> ConnsName

@external(erlang, "beacon_http_conns", "start_link_gleam")
fn ffi_conns_start_link(
  name: ConnsName,
  port: Int,
  handler: fn(Socket) -> Nil,
  max_connections: Int,
  max_connections_per_ip: Int,
  trusted: ip.TrustedProxies,
) -> Result(actor.Started(ConnsName), actor.StartError)

@external(erlang, "beacon_http_acceptors_sup", "start_link_gleam")
fn ffi_acceptors_start_link(
  name: ConnsName,
  acceptors: Int,
  backlog: Int,
  send_timeout_ms: Int,
) -> Result(actor.Started(Nil), actor.StartError)

@external(erlang, "beacon_http_conns", "get_port")
fn ffi_conns_get_port(name: ConnsName) -> Int

@external(erlang, "beacon_http_conns", "forget_port")
fn ffi_conns_forget_port(name: ConnsName) -> Bool

@external(erlang, "beacon_http_conns", "count")
fn ffi_conns_count(name: ConnsName) -> Int

@external(erlang, "beacon_http_conns", "count_for_ip_text")
fn ffi_conns_count_for_ip(name: ConnsName, address: String) -> Result(Int, Nil)

@external(erlang, "beacon_http_conns", "children")
fn ffi_conns_children(name: ConnsName) -> List(process.Pid)

@external(erlang, "beacon_server_ffi", "whereis")
fn ffi_whereis(name: ConnsName) -> Result(process.Pid, Nil)

@external(erlang, "beacon_server_ffi", "stop_supervisor")
fn ffi_stop_supervisor(pid: process.Pid) -> Nil
