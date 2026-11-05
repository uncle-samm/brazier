/// Raw-socket fuzzing and concurrent keep-alive load against the HTTP
/// server. The fuzz inputs come from a fixed seed (see
/// brazier_http_fuzz_ffi), so any failure is reproducible.
import brazier/await
import brazier/transport
import brazier/transport/http as transport_http
import brazier/transport/server.{type Connection, Bytes}
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/float
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const fuzz_seed = 20_261_102

const fuzz_cases = 400

/// Every status the server may answer a fuzzed request with. A 500 would
/// mean the server crashed on its input, so it is not in the list.
const allowed_statuses = [
  100, 200, 204, 400, 404, 408, 413, 414, 417, 431, 501, 505,
]

fn handler(
  req: Request(Connection),
) -> option.Option(response.Response(server.ResponseBody)) {
  case req.path {
    "/echo" ->
      case transport_http.read_body(req, 1_000_000) {
        Ok(body) -> Some(text(200, bit_array.inspect(body)))
        Error(error) ->
          Some(text(400, transport_http.describe_read_body_error(error)))
      }
    _ -> {
      let host = case request.get_header(req, "host") {
        Ok(host) -> host
        Error(Nil) -> "-"
      }
      Some(text(200, req.path <> "|" <> host))
    }
  }
}

fn text(status: Int, body: String) -> response.Response(server.ResponseBody) {
  response.new(status)
  |> response.set_header("content-type", "text/plain")
  |> response.set_body(Bytes(bytes_tree.from_string(body)))
}

fn start_server() -> server.Listener {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      pre_upgrade_timeout_ms: 300,
      keepalive_idle_timeout_ms: 300,
      body_read_timeout_ms: 300,
      request_timeout_ms: 1000,
      // brazier_http_fuzz_ffi names the hosts "test" and "other".
      allowed_hosts: ["test", "other"],
    )
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_id, _subject) { Nil },
      on_event: fn(_id, _msg) { Nil },
      on_disconnect: fn(_id) { Nil },
      page_html: None,
      middlewares: [],
      static_config: None,
      runtime_factory: None,
      ws_auth: None,
      ssr_factory: None,
      security_limits: limits,
      api_handler: Some(handler),
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "fuzz listener must bind an OS-assigned port"
  listener
}

pub fn fuzzed_requests_never_crash_or_hang_the_server_test() {
  let listener = start_server()
  let port = server.get_port(listener)
  let acceptors_before = acceptor_pids(server.get_supervisor(listener))
  let inputs = fuzz_inputs(fuzz_seed, fuzz_cases)
  let assert True = list.length(inputs) == fuzz_cases

  list.index_map(inputs, fn(input, index) {
    let reply = case fuzz_exchange(port, input, 2000) {
      Ok(reply) -> reply
      Error(reason) -> {
        report(failure(index, input, reason))
        panic as "server hung or failed on a fuzz input"
      }
    }
    case first_status(reply) {
      // Closing without a reply is allowed for input that never forms a
      // complete request head.
      Ok(None) -> Nil
      Ok(Some(status)) ->
        case list.contains(allowed_statuses, status) {
          True -> Nil
          False -> {
            report(failure(index, input, "status " <> int.to_string(status)))
            panic as "unexpected status for a fuzz input"
          }
        }
      Error(Nil) -> {
        report(failure(
          index,
          input,
          "malformed reply " <> string.inspect(reply),
        ))
        panic as "server sent a malformed reply to a fuzz input"
      }
    }
  })

  // No connection slot leaked and no acceptor died.
  await_count(listener, 0)
  let assert True =
    acceptor_pids(server.get_supervisor(listener)) == acceptors_before
  // The server still answers a normal request.
  let assert Ok(reply) =
    fuzz_exchange(port, <<"GET /after HTTP/1.1\r\nHost: test\r\n\r\n">>, 2000)
  let assert Ok(Some(200)) = first_status(reply)
  server.stop(listener)
}

pub fn concurrent_keep_alive_load_test() {
  let listener = start_server()
  let clients = 32
  let requests = 100
  let assert Ok(#(total, elapsed_us)) =
    load(server.get_port(listener), clients, requests, 20_000)
  let assert True = total == clients * requests
  let per_second =
    int.to_float(total) *. 1_000_000.0 /. int.to_float(elapsed_us)
  report(
    "[http_fuzz_test] keep-alive load: "
    <> int.to_string(total)
    <> " requests over "
    <> int.to_string(clients)
    <> " connections in "
    <> int.to_string(elapsed_us / 1000)
    <> " ms ("
    <> int.to_string(float.round(per_second))
    <> " req/s)",
  )
  // Each client reused one socket for all its requests and closed it.
  await_count(listener, 0)
  server.stop(listener)
}

/// The status code of the first response in `reply`. Ok(None) for an
/// empty reply, Error(Nil) when the reply is not an HTTP/1.1 response.
fn first_status(reply: BitArray) -> Result(option.Option(Int), Nil) {
  case reply {
    <<>> -> Ok(None)
    <<"HTTP/1.1 ":utf8, code:bytes-size(3), " ":utf8, _:bits>> ->
      case bit_array.to_string(code) {
        Ok(digits) ->
          case int.parse(digits) {
            Ok(status) -> Ok(Some(status))
            Error(Nil) -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn failure(index: Int, input: BitArray, reason: String) -> String {
  "[http_fuzz_test] seed "
  <> int.to_string(fuzz_seed)
  <> " case "
  <> int.to_string(index)
  <> ": "
  <> reason
  <> "\ninput: "
  <> bit_array.inspect(input)
}

/// Return once the listener has exactly `expected` live connections. The
/// connection owner takes a slot before the acceptor emits
/// `[brazier, http, connection, accepted]` and releases it before it emits
/// `closed`, so each of those events is a point to re-check the count.
fn await_count(listener: server.Listener, expected: Int) -> Nil {
  await.until_telemetry(
    [
      ["brazier", "http", "connection", "accepted"],
      ["brazier", "http", "connection", "closed"],
    ],
    int.to_string(expected) <> " live connections",
    fn() { server.get_connection_count(listener) == expected },
  )
}

@external(erlang, "brazier_http_fuzz_ffi", "cases")
fn fuzz_inputs(seed: Int, count: Int) -> List(BitArray)

@external(erlang, "brazier_http_fuzz_ffi", "exchange")
fn fuzz_exchange(
  port: Int,
  data: BitArray,
  timeout_ms: Int,
) -> Result(BitArray, String)

@external(erlang, "brazier_http_fuzz_ffi", "load")
fn load(
  port: Int,
  clients: Int,
  requests: Int,
  timeout_ms: Int,
) -> Result(#(Int, Int), String)

@external(erlang, "brazier_http_fuzz_ffi", "report")
fn report(line: String) -> Nil

@external(erlang, "brazier_http_raw_ffi", "acceptor_pids")
fn acceptor_pids(listener_supervisor: process.Pid) -> List(process.Pid)
