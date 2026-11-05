//// L453: one connection's backpressure close never closes another.
////
//// A cascade of backpressure lines was seen once, when many tests failed
//// together. This test opens six WebSockets on one listener and, at once:
//// kills two handlers (handlers that fail), leaves one handler suspended
//// while more than `ws_max_outbound_queue` messages queue up for it (a slow
//// reader), and keeps three healthy. The slow one is closed with 1013 and
//// reported once; the killed ones lose only their own sockets; the healthy
//// ones keep receiving and are closed only by their clients.
////
//// Ordering, not timing: every telemetry event, log line and `on_close`
//// of a connection is sent by its own handler process, in that order, so
//// once its `on_close` has arrived everything it reported is in this
//// process's mailbox. A killed handler reports nothing.

import brazier/await
import brazier/cluster/log_capture as node_log
import brazier/monitored
import brazier/telemetry.{type Event}
import brazier/transport
import brazier/transport/server
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub fn one_backpressure_close_affects_only_its_connection_test() {
  let server = start_server()
  let #(Nil, logs) =
    node_log.capture(fn() {
      use events <- monitored.listening([
        ["brazier", "ws", "backpressure"],
        ["brazier", "ws", "close"],
      ])
      let probes = list.map(list.repeat(Nil, 6), fn(_) { open(server) })
      let assert [killed_a, killed_b, slow, ..healthy] = probes
      let ids = list.map(probes, fn(probe) { probe.conn_id })

      // Two handlers fail: their sockets close without a close frame.
      kill(killed_a)
      kill(killed_b)

      // The slow reader: the first message it handles sees 1001 more queued,
      // over the default limit of 1000.
      let assert Ok(Nil) = suspend(slow.handler)
      list.index_map(list.repeat(Nil, 1002), fn(_, n) {
        process.send(slow.runtime, transport.SendTitle(int.to_string(n)))
      })
      let assert Ok(Nil) = resume(slow.handler)
      assert expect_closed(slow.socket, 5000) == Ok(1013)
      await_closed(server.observer, slow.conn_id)

      // The healthy connections still deliver, and nothing closed them.
      list.each(healthy, fn(probe) {
        process.send(probe.runtime, transport.SendTitle("after"))
        assert recv_text(probe.socket)
          == "{\"type\":\"title\",\"title\":\"after\"}"
      })
      list.each(healthy, fn(probe) {
        raw_close(probe.socket)
        await_closed(server.observer, probe.conn_id)
      })

      // A killed handler runs no cleanup: no on_close, no close event.
      let observed = await.drain(server.observer)
      assert list.filter(observed, fn(o) {
          case o {
            ClosedConn(cid) -> list.contains(ids, cid)
            Connected(..) -> False
          }
        })
        == []
        as string.inspect(observed)

      let mine =
        list.filter(await.drain(events), fn(event) {
          case telemetry.string(event, "connection_id") {
            Ok(cid) -> list.contains(ids, cid)
            Error(Nil) -> False
          }
        })
      assert summaries(mine)
        == [
          #(["brazier", "ws", "backpressure"], slow.conn_id, "outbound_queue"),
          #(["brazier", "ws", "close"], slow.conn_id, "1013 server_overloaded"),
          ..list.map(healthy, fn(probe) {
            #(["brazier", "ws", "close"], probe.conn_id, "1006 tcp_closed")
          })
        ]
        as string.inspect(mine)
      assert backpressure_count(mine) == 1
    })

  // One warning, naming the slow connection; no runtime-requested close.
  let warnings =
    list.filter(logs, fn(line) {
      string.contains(line.message, "Outbound queue for ")
    })
  assert list.length(warnings) == 1 as string.inspect(warnings)
  assert list.filter(logs, fn(line) {
      string.contains(line.message, "Closing slow connection")
    })
    == []
  server.stop(server.listener)
}

/// Event name, connection and the reason it carries (close events also
/// carry their code), in arrival order.
fn summaries(events: List(Event)) -> List(#(List(String), String, String)) {
  list.map(events, fn(event) {
    let assert Ok(cid) = telemetry.string(event, "connection_id")
      as "every ws event names its connection"
    let assert Ok(reason) = telemetry.string(event, "reason")
      as "every ws close and backpressure event carries a reason"
    let detail = case telemetry.int(event, "close_code") {
      Ok(code) -> int.to_string(code) <> " " <> reason
      Error(Nil) -> reason
    }
    #(event.name, cid, detail)
  })
}

fn backpressure_count(events: List(Event)) -> Int {
  list.count(events, fn(event) {
    event.name == ["brazier", "ws", "backpressure"]
  })
}

// --- Harness -----------------------------------------------------------------

type RawSocket

type Observed {
  Connected(
    conn_id: String,
    runtime: Subject(transport.InternalMessage),
    handler: Pid,
  )
  ClosedConn(conn_id: String)
}

type Server {
  Server(port: Int, observer: Subject(Observed), listener: server.Listener)
}

type Probe {
  Probe(
    socket: RawSocket,
    conn_id: String,
    runtime: Subject(transport.InternalMessage),
    handler: Pid,
  )
}

const host = "127.0.0.1"

/// A listener whose runtime factory reports each handler (from the handler
/// process itself) and each `on_close`. Default limits apart from the
/// per-IP cap, so `ws_max_outbound_queue` is the shipped 1000.
fn start_server() -> Server {
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
      runtime_factory: Some(fn(conn_id, runtime, _req) {
        process.send(observer, Connected(conn_id, runtime, process.self()))
        Ok(
          #(fn(_, _) { Nil }, fn(cid) {
            process.send(observer, ClosedConn(cid))
          }),
        )
      }),
      ws_auth: None,
      ssr_factory: None,
      security_limits: transport.SecurityLimits(
        ..transport.default_security_limits(),
        max_ws_connections_per_ip: 10_000,
      ),
      api_handler: None,
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "the test listener must start"
  assert transport.default_security_limits().ws_max_outbound_queue == 1000
  Server(
    port: server.get_port(listener),
    observer: observer,
    listener: listener,
  )
}

/// Upgrade on `/`, expect the 101 and wait for the runtime factory.
fn open(server: Server) -> Probe {
  let authority = host <> ":" <> int.to_string(server.port)
  let headers = [
    #("Upgrade", "websocket"),
    #("Connection", "Upgrade"),
    #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
    #("Sec-WebSocket-Version", "13"),
    #("Origin", "http://" <> authority),
  ]
  let assert Ok(socket) = raw_connect(host, server.port)
    as "test client must connect to the listener"
  let assert Ok(Nil) =
    raw_send(socket, raw_upgrade_request("/ws?path=%2F", authority, headers))
    as "test client send must succeed"
  let assert Ok(#(-1, head)) = raw_recv_frame(socket, 3000)
    as "the server must answer the upgrade"
  let assert Ok(head) = bit_array.to_string(head) as "the response head is text"
  assert string.slice(head, 9, 3) == "101"
  let assert Connected(conn_id, runtime, handler) =
    await.expect(server.observer, "the runtime factory call", matching: fn(o) {
      case o {
        Connected(..) -> True
        ClosedConn(_) -> False
      }
    })
  Probe(socket: socket, conn_id: conn_id, runtime: runtime, handler: handler)
}

/// Kill the handler; its socket closes with no close frame.
fn kill(probe: Probe) -> Nil {
  process.kill(probe.handler)
  await.expect_down(probe.handler, "the killed WebSocket handler")
  assert expect_closed(probe.socket, 5000) == Ok(-1)
}

fn await_closed(observer: Subject(Observed), conn_id: String) -> Nil {
  let _ =
    await.expect(observer, "on_close for " <> conn_id, matching: fn(o) {
      o == ClosedConn(conn_id)
    })
  Nil
}

/// The next text frame; a ping before it is skipped.
fn recv_text(socket: RawSocket) -> String {
  case raw_recv_frame(socket, 3000) {
    Ok(#(1, payload)) -> {
      let assert Ok(text) = bit_array.to_string(payload)
        as "a text frame is text"
      text
    }
    Ok(#(9, _ping)) -> recv_text(socket)
    Ok(#(opcode, _)) ->
      panic as { "expected a text frame, got opcode " <> int.to_string(opcode) }
    Error(reason) -> panic as { "expected a text frame: " <> reason }
  }
}

@external(erlang, "brazier_ws_test_ffi", "raw_connect")
fn raw_connect(host: String, port: Int) -> Result(RawSocket, String)

@external(erlang, "brazier_ws_test_ffi", "raw_send")
fn raw_send(socket: RawSocket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "brazier_ws_test_ffi", "raw_recv_frame")
fn raw_recv_frame(
  socket: RawSocket,
  timeout: Int,
) -> Result(#(Int, BitArray), String)

@external(erlang, "brazier_ws_test_ffi", "raw_close")
fn raw_close(socket: RawSocket) -> Nil

@external(erlang, "brazier_ws_test_ffi", "raw_upgrade_request")
fn raw_upgrade_request(
  path: String,
  host: String,
  headers: List(#(String, String)),
) -> BitArray

@external(erlang, "brazier_ws_test_ffi", "expect_closed")
fn expect_closed(socket: RawSocket, timeout: Int) -> Result(Int, String)

@external(erlang, "brazier_ws_test_ffi", "suspend")
fn suspend(pid: Pid) -> Result(Nil, Nil)

@external(erlang, "brazier_ws_test_ffi", "resume")
fn resume(pid: Pid) -> Result(Nil, Nil)
