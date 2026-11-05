/// The join's build check over a real listener: the manifest is read when
/// the listener starts, never on a join, and a join without a build id is
/// warned about once per connection.
///
/// "Never on a join" is checked by tracing the connection's handler process
/// for every call into `file`, `prim_file` and simplifile while it handles a
/// join (`brazier_file_trace_test_ffi`), so any read or stat of the manifest
/// or the bundle fails the test, whichever API it goes through.
import brazier/cluster/log_capture
import brazier/raw_ws.{type RawSocket}
import brazier/ssr
import brazier/transport
import brazier/transport/server
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- Harness ---

type Observed {
  Connected(conn_id: String, handler: Pid)
  GotEvent(conn_id: String, msg: transport.ClientMessage)
  ClosedConn(conn_id: String)
}

@external(erlang, "brazier_file_trace_test_ffi", "start")
fn trace_file_calls(pid: Pid) -> Nil

@external(erlang, "brazier_file_trace_test_ffi", "stop")
fn traced_file_calls(pid: Pid) -> List(String)

fn start_server() -> #(server.Listener, Int, Subject(Observed)) {
  let observer = process.new_subject()
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_, _) { Nil },
      on_event: fn(_, _) { Nil },
      on_disconnect: fn(_) { Nil },
      page_html: None,
      middlewares: [],
      static_config: None,
      runtime_factory: Some(fn(conn_id, _runtime, _req) {
        process.send(observer, Connected(conn_id, process.self()))
        Ok(
          #(
            fn(cid, msg) { process.send(observer, GotEvent(cid, msg)) },
            fn(cid) { process.send(observer, ClosedConn(cid)) },
          ),
        )
      }),
      ws_auth: None,
      ssr_factory: None,
      security_limits: transport.default_security_limits(),
      api_handler: None,
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "the test listener must start"
  #(listener, server.get_port(listener), observer)
}

fn open(port: Int, observer: Subject(Observed)) -> #(RawSocket, Pid) {
  let socket = raw_ws.open(port, "%2F", [])
  let assert Ok(Connected(_conn_id, handler)) = process.receive(observer, 3000)
    as "the runtime factory must be called"
  #(socket, handler)
}

fn join_text(build: option.Option(String)) -> String {
  let build_field = case build {
    Some(id) -> ",\"build\":\"" <> id <> "\""
    None -> ""
  }
  "{\"type\":\"join\",\"token\":\"\",\"path\":\"/\"" <> build_field <> "}"
}

/// Send a join and wait until the runtime gets it.
fn join(
  socket: RawSocket,
  observer: Subject(Observed),
  build: option.Option(String),
) -> Nil {
  raw_ws.send_text(socket, join_text(build))
  let assert Ok(GotEvent(_, transport.ClientJoin(token: "", path: "/"))) =
    process.receive(observer, 3000)
    as "the join must be dispatched"
  Nil
}

/// The build id of the bundle the listener loaded at startup.
fn current_build() -> String {
  let assert Ok(bundle) = ssr.client_bundle()
    as "a started listener has loaded the client bundle"
  let assert "brazier_client_" <> rest = bundle
  string.drop_end(rest, 3)
}

fn no_build_warnings(lines: List(log_capture.Line)) -> Int {
  list.count(lines, fn(line) {
    line.level == "warning" && string.contains(line.message, "no build id")
  })
}

// --- A join reads no file ---

type Control {
  Ready(go: Subject(Nil), pid: Pid)
  Read
}

pub fn the_trace_sees_a_manifest_read_test() {
  // The control: reading the manifest, as every join did before it was
  // loaded at startup, shows up in the trace of the process that reads it,
  // traced the way a connection's handler is.
  let parent = process.new_subject()
  let finish = process.new_subject()
  process.spawn(fn() {
    let go = process.new_subject()
    process.send(parent, Ready(go, process.self()))
    let assert Ok(Nil) = process.receive(go, 3000) as "the test starts the read"
    let assert Ok(_) = ssr.client_bundle_name(ssr.client_assets_dir())
    process.send(parent, Read)
    // Alive until the trace is collected.
    let assert Ok(Nil) = process.receive(go, 3000) as "the test lets it exit"
    process.send(finish, Nil)
  })
  let assert Ok(Ready(go, reader)) = process.receive(parent, 3000)
  trace_file_calls(reader)
  process.send(go, Nil)
  let assert Ok(Read) = process.receive(parent, 3000)
  let calls = traced_file_calls(reader)
  process.send(go, Nil)
  let assert Ok(Nil) = process.receive(finish, 3000)
  let assert True = list.contains(calls, "simplifile_erl:read_bits/1")
    as "a manifest read must be seen by the trace"
}

pub fn a_join_from_the_current_build_reads_no_file_test() {
  let #(listener, port, observer) = start_server()
  let #(socket, handler) = open(port, observer)
  trace_file_calls(handler)
  join(socket, observer, Some(current_build()))
  let assert [] = traced_file_calls(handler)
  raw_ws.close(socket)
  server.stop(listener)
}

pub fn a_join_from_another_build_reads_no_file_test() {
  let #(listener, port, observer) = start_server()
  let #(socket, handler) = open(port, observer)
  trace_file_calls(handler)
  raw_ws.send_text(socket, join_text(Some("00000000deadbeef")))
  let assert raw_ws.Close(code: 4499, reason: "stale build") =
    raw_ws.recv(socket)
  let assert Ok(ClosedConn(_)) = process.receive(observer, 5000)
    as "on_close must run"
  // The handler may have exited by now; its trace is flushed either way:
  // the close was decided without a file call.
  let assert [] = traced_file_calls(handler)
  raw_ws.close(socket)
  server.stop(listener)
}

pub fn a_join_without_a_build_reads_no_file_test() {
  let #(listener, port, observer) = start_server()
  let #(socket, handler) = open(port, observer)
  trace_file_calls(handler)
  join(socket, observer, None)
  let assert [] = traced_file_calls(handler)
  raw_ws.close(socket)
  server.stop(listener)
}

// --- A join without a build id is warned about once per connection ---

pub fn a_join_without_a_build_warns_once_per_connection_test() {
  let #(listener, port, observer) = start_server()
  let #(Nil, lines) =
    log_capture.capture(fn() {
      let #(first, _) = open(port, observer)
      // A rejoin on the same socket is not warned about again.
      join(first, observer, None)
      join(first, observer, None)
      join(first, observer, None)
      let #(second, _) = open(port, observer)
      join(second, observer, None)
      raw_ws.close(first)
      raw_ws.close(second)
    })
  // One warning for each connection, not one for each join.
  let assert 2 = no_build_warnings(lines)
  let assert True =
    list.any(lines, fn(line) {
      line.level == "debug"
      && string.contains(line.message, "no build id again")
    })
  server.stop(listener)
}

pub fn a_join_with_a_build_after_one_without_is_still_checked_test() {
  // The warning flag only silences the warning: a later join that names
  // another build is refused as before.
  let #(listener, port, observer) = start_server()
  let #(socket, _) = open(port, observer)
  join(socket, observer, None)
  raw_ws.send_text(socket, join_text(Some("00000000deadbeef")))
  let assert raw_ws.Close(code: 4499, reason: "stale build") =
    raw_ws.recv(socket)
  raw_ws.close(socket)
  server.stop(listener)
}
