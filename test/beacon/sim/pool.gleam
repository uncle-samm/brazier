/// Connection pool — spawns N real WebSocket connections, each executing
/// a scenario against a real Beacon server. Collects metrics atomically.
///
/// Every connect is a single attempt: there is no client retry, so a
/// refused or failed handshake is a failure the pool reports, with its
/// reason, instead of something hidden behind a backoff.
import beacon/await
import beacon/log
import beacon/sim/metrics.{type MetricsTable}
import beacon/sim/scenario.{
  type Action, type Scenario, AbruptDisconnect, AssertResponseContains, Connect,
  Disconnect, Join, ReceiveUntil, SendEvent, SendEventWithClock, SendMalformed,
  WaitForModelSync, WaitForPatch, WaitForResponse,
}
import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Pool configuration.
pub type PoolConfig {
  PoolConfig(
    /// Number of concurrent connections
    concurrency: Int,
    /// Target host
    host: String,
    /// Target port
    port: Int,
    /// Scenario each connection runs
    scenario: Scenario,
    /// Delay between worker spawns (ms). This is the load profile, not a
    /// synchronisation wait: it sets the arrival rate of new connections.
    stagger_ms: Int,
    /// Metrics table for recording results
    metrics: MetricsTable,
  )
}

/// Pool execution result.
pub type PoolResult {
  PoolResult(
    total: Int,
    succeeded: Int,
    failed: Int,
    /// WebSocket handshakes that completed (a scenario may connect more
    /// than once). Each is one server connection to wait for at teardown.
    upgraded: Int,
    /// Each distinct failure reason with how many workers failed with it.
    failures: List(#(String, Int)),
    duration_ms: Int,
  )
}

/// Opaque WebSocket handle.
pub type WsSocket

/// What a worker reports when its scenario ends.
type WorkerReport {
  WorkerReport(upgraded: Int, outcome: Result(Nil, String))
}

/// How long the pool waits for the next worker to report. A worker's
/// slowest step is a 10 s receive, so a silent 30 s means a hung worker.
const report_timeout_ms = 30_000

/// How long a graceful Disconnect waits for the server's close frame.
const close_timeout_ms = 5000

/// Run the pool: spawn N workers, each executing the scenario, and wait
/// for every report and for every worker process to exit.
///
/// Crashes if a worker hangs: a pool that cannot account for a worker
/// cannot say whether the server served it.
pub fn run(config: PoolConfig) -> PoolResult {
  let start = metrics.now_us()
  let reports = process.new_subject()

  let workers = spawn_workers(config.concurrency, config, reports, [])
  let collected = collect_reports(reports, config.concurrency, [])
  // A worker sends its report as its last act; waiting for the exits
  // keeps worker processes out of the caller's process-count snapshots.
  list.each(workers, fn(pid) { await.expect_down(pid, "sim pool worker") })

  let duration_us = metrics.now_us() - start
  let succeeded =
    list.count(collected, fn(report) { report.outcome == Ok(Nil) })
  let failures = failure_counts(collected)
  let result =
    PoolResult(
      total: config.concurrency,
      succeeded: succeeded,
      failed: config.concurrency - succeeded,
      upgraded: int.sum(list.map(collected, fn(report) { report.upgraded })),
      failures: failures,
      duration_ms: duration_us / 1000,
    )
  log.info(
    "beacon.sim.pool",
    config.scenario.name
      <> ": "
      <> int.to_string(succeeded)
      <> "/"
      <> int.to_string(config.concurrency)
      <> " succeeded in "
      <> int.to_string(result.duration_ms)
      <> " ms",
  )
  list.each(failures, fn(failure) {
    log.warning(
      "beacon.sim.pool",
      config.scenario.name
        <> ": "
        <> int.to_string(failure.1)
        <> " workers failed: "
        <> failure.0,
    )
  })
  result
}

fn spawn_workers(
  remaining: Int,
  config: PoolConfig,
  reports: Subject(WorkerReport),
  pids: List(Pid),
) -> List(Pid) {
  case remaining {
    0 -> pids
    _ -> {
      let metrics_table = config.metrics
      let host = config.host
      let port = config.port
      let actions = config.scenario.actions

      let pid =
        process.spawn(fn() {
          process.send(
            reports,
            execute_actions(host, port, actions, metrics_table, None, 0),
          )
        })

      case config.stagger_ms > 0 {
        True -> process.sleep(config.stagger_ms)
        False -> Nil
      }

      spawn_workers(remaining - 1, config, reports, [pid, ..pids])
    }
  }
}

fn collect_reports(
  reports: Subject(WorkerReport),
  remaining: Int,
  acc: List(WorkerReport),
) -> List(WorkerReport) {
  case remaining {
    0 -> acc
    _ ->
      case process.receive(reports, report_timeout_ms) {
        Ok(report) -> collect_reports(reports, remaining - 1, [report, ..acc])
        Error(Nil) -> {
          let message =
            int.to_string(remaining)
            <> " sim pool workers sent no report within "
            <> int.to_string(report_timeout_ms)
            <> " ms"
          log.error("beacon.sim.pool", message)
          panic as message
        }
      }
  }
}

fn failure_counts(reports: List(WorkerReport)) -> List(#(String, Int)) {
  list.fold(reports, dict.new(), fn(counts, report) {
    case report.outcome {
      Ok(Nil) -> counts
      Error(reason) ->
        dict.upsert(counts, reason, fn(existing) {
          case existing {
            Some(n) -> n + 1
            None -> 1
          }
        })
    }
  })
  |> dict.to_list
}

/// Execute a scenario's actions in order. Stops at the first failing
/// action and reports its reason.
fn execute_actions(
  host: String,
  port: Int,
  actions: List(Action),
  mt: MetricsTable,
  socket: Option(WsSocket),
  upgraded: Int,
) -> WorkerReport {
  case actions {
    [] -> {
      close_if_open(socket)
      WorkerReport(upgraded: upgraded, outcome: Ok(Nil))
    }
    [action, ..rest] -> {
      case execute_action(host, port, action, mt, socket) {
        Ok(new_socket) -> {
          let upgraded = case action {
            Connect -> upgraded + 1
            _ -> upgraded
          }
          execute_actions(host, port, rest, mt, new_socket, upgraded)
        }
        Error(reason) -> {
          close_if_open(socket)
          WorkerReport(
            upgraded: upgraded,
            outcome: Error(action_name(action) <> ": " <> reason),
          )
        }
      }
    }
  }
}

fn close_if_open(socket: Option(WsSocket)) -> Nil {
  case socket {
    Some(s) -> ws_close(s)
    None -> Nil
  }
}

fn action_name(action: Action) -> String {
  case action {
    Connect -> "connect"
    Join -> "join"
    SendEvent(..) -> "send_event"
    SendEventWithClock(..) -> "send_event_with_clock"
    ReceiveUntil(..) -> "receive_until"
    WaitForResponse(..) -> "wait_for_response"
    WaitForPatch(..) -> "wait_for_patch"
    WaitForModelSync(..) -> "wait_for_model_sync"
    AssertResponseContains(..) -> "assert_response_contains"
    SendMalformed(..) -> "send_malformed"
    Disconnect -> "disconnect"
    AbruptDisconnect -> "abrupt_disconnect"
  }
}

fn execute_action(
  host: String,
  port: Int,
  action: Action,
  mt: MetricsTable,
  socket: Option(WsSocket),
) -> Result(Option(WsSocket), String) {
  case action {
    Connect -> {
      metrics.increment(mt, "connections_opened")
      case ws_connect(host, port) {
        Ok(s) -> Ok(Some(s))
        Error(reason) -> {
          metrics.increment(mt, "connections_failed")
          Error(reason)
        }
      }
    }

    Join -> {
      case socket {
        Some(s) -> {
          let join_msg =
            "{\"type\":\"join\",\"token\":\"\",\"url\":\"http://"
            <> host
            <> ":"
            <> int.to_string(port)
            <> "/\"}"
          case ws_send(s, join_msg) {
            Ok(_) -> Ok(Some(s))
            Error(reason) -> Error(reason)
          }
        }
        None -> Error("No socket for Join")
      }
    }

    SendEvent(handler_id, data) -> send_event(mt, socket, handler_id, data, 1)

    SendEventWithClock(handler_id, data, clock) ->
      send_event(mt, socket, handler_id, data, clock)

    ReceiveUntil(timeout_ms, expected) ->
      case socket {
        Some(s) ->
          receive_until(mt, s, metrics.now_us() + timeout_ms * 1000, expected)
        None -> Error("No socket for ReceiveUntil")
      }

    WaitForResponse(timeout_ms) -> {
      case socket {
        Some(s) -> {
          case recv(mt, s, timeout_ms) {
            Ok(payload) -> {
              record_response(mt, payload)
              Ok(Some(s))
            }
            Error(reason) -> Error(reason)
          }
        }
        None -> Error("No socket for WaitForResponse")
      }
    }

    WaitForPatch(timeout_ms) -> {
      case socket {
        Some(s) -> {
          case recv(mt, s, timeout_ms) {
            Ok(payload) -> {
              record_response(mt, payload)
              case string.contains(payload, "\"type\":\"patch\"") {
                True -> Ok(Some(s))
                False ->
                  Error("Expected patch, got: " <> string.slice(payload, 0, 50))
              }
            }
            Error(reason) -> Error(reason)
          }
        }
        None -> Error("No socket for WaitForPatch")
      }
    }

    WaitForModelSync(timeout_ms) -> {
      case socket {
        Some(s) -> {
          case recv(mt, s, timeout_ms) {
            Ok(payload) -> {
              record_response(mt, payload)
              case string.contains(payload, "\"type\":\"model_sync\"") {
                True -> Ok(Some(s))
                False ->
                  Error(
                    "Expected model_sync, got: " <> string.slice(payload, 0, 50),
                  )
              }
            }
            Error(reason) -> Error(reason)
          }
        }
        None -> Error("No socket for WaitForModelSync")
      }
    }

    AssertResponseContains(timeout_ms, expected) -> {
      case socket {
        Some(s) -> {
          case recv(mt, s, timeout_ms) {
            Ok(payload) -> {
              record_response(mt, payload)
              case string.contains(payload, expected) {
                True -> Ok(Some(s))
                False ->
                  Error(
                    "Response missing '"
                    <> expected
                    <> "': "
                    <> string.slice(payload, 0, 80),
                  )
              }
            }
            Error(reason) -> Error(reason)
          }
        }
        None -> Error("No socket for AssertResponseContains")
      }
    }

    SendMalformed(payload) -> {
      case socket {
        Some(s) -> {
          case ws_send(s, payload) {
            Ok(Nil) -> Ok(Some(s))
            Error(reason) -> Error(reason)
          }
        }
        None -> Error("No socket for SendMalformed")
      }
    }

    Disconnect -> {
      case socket {
        Some(s) ->
          case ws_close_graceful(s, close_timeout_ms) {
            Ok(Nil) -> {
              metrics.increment(mt, "connections_closed")
              Ok(None)
            }
            Error(reason) -> Error(reason)
          }
        None -> Error("No socket for Disconnect")
      }
    }

    AbruptDisconnect -> {
      case socket {
        Some(s) -> {
          ws_close(s)
          metrics.increment(mt, "connections_closed")
          Ok(None)
        }
        None -> Error("No socket for AbruptDisconnect")
      }
    }
  }
}

fn send_event(
  mt: MetricsTable,
  socket: Option(WsSocket),
  handler_id: String,
  data: String,
  clock: Int,
) -> Result(Option(WsSocket), String) {
  case socket {
    Some(s) -> {
      let t0 = metrics.now_us()
      let event_msg =
        json.object([
          #("type", json.string("event")),
          #("name", json.string("click")),
          #("handler_id", json.string(handler_id)),
          // `data` is itself JSON, sent as a JSON string.
          #("data", json.string(data)),
          #("target_path", json.string("0")),
          #("clock", json.int(clock)),
        ])
        |> json.to_string
      case ws_send(s, event_msg) {
        Ok(Nil) -> {
          metrics.increment(mt, "events_sent")
          metrics.increment_by(mt, "bytes_sent", string.byte_size(event_msg))
          metrics.mark_event_send_start(t0)
          Ok(Some(s))
        }
        Error(reason) -> {
          metrics.increment(mt, "events_failed")
          Error(reason)
        }
      }
    }
    None -> Error("No socket for SendEvent")
  }
}

/// Receive responses until one contains `expected` or the deadline
/// (monotonic µs) passes.
fn receive_until(
  mt: MetricsTable,
  socket: WsSocket,
  deadline_us: Int,
  expected: String,
) -> Result(Option(WsSocket), String) {
  let remaining_ms = int.max(0, { deadline_us - metrics.now_us() } / 1000)
  case recv(mt, socket, remaining_ms) {
    Ok(payload) -> {
      case string.contains(payload, expected) {
        True -> {
          record_response(mt, payload)
          Ok(Some(socket))
        }
        False -> {
          track_response_type(mt, payload)
          receive_until(mt, socket, deadline_us, expected)
        }
      }
    }
    Error(reason) -> Error("waiting for '" <> expected <> "': " <> reason)
  }
}

/// Receive the next frame that is not a `title` frame. A browser applies a
/// title frame on its own (`document.title`); it answers no event, so the
/// simulated client counts its bytes and reads on, within the same
/// `timeout_ms`.
fn recv(
  mt: MetricsTable,
  socket: WsSocket,
  timeout_ms: Int,
) -> Result(String, String) {
  recv_before(mt, socket, metrics.now_us() + timeout_ms * 1000)
}

fn recv_before(
  mt: MetricsTable,
  socket: WsSocket,
  deadline_us: Int,
) -> Result(String, String) {
  let remaining_ms = int.max(0, { deadline_us - metrics.now_us() } / 1000)
  case ws_recv(socket, remaining_ms) {
    Ok(payload) ->
      case string.contains(payload, "\"type\":\"title\"") {
        True -> {
          metrics.increment_by(mt, "bytes_received", string.byte_size(payload))
          recv_before(mt, socket, deadline_us)
        }
        False -> Ok(payload)
      }
    Error(reason) -> Error(reason)
  }
}

/// Track response message type in metrics (patch/model_sync/mount/other).
fn track_response_type(mt: MetricsTable, payload: String) -> Nil {
  let bytes = string.byte_size(payload)
  metrics.increment_by(mt, "bytes_received", bytes)
  metrics.record_payload(mt, payload)
  case string.contains(payload, "\"type\":\"patch\"") {
    True -> {
      metrics.increment(mt, "patches_received")
      Nil
    }
    False ->
      case string.contains(payload, "\"type\":\"model_sync\"") {
        True -> {
          metrics.increment(mt, "model_syncs_received")
          Nil
        }
        False ->
          case string.contains(payload, "\"type\":\"mount\"") {
            True -> {
              metrics.increment(mt, "mounts_received")
              Nil
            }
            False -> Nil
          }
      }
  }
}

/// Track a response, and if this worker has an event in flight, count the
/// event as acknowledged and record its round trip. A response with no
/// event in flight (the join's model_sync, a server push) acknowledges
/// nothing.
fn record_response(mt: MetricsTable, payload: String) -> Nil {
  track_response_type(mt, payload)
  case metrics.take_event_send_start() {
    Ok(sent_at) -> {
      metrics.increment(mt, "events_acked")
      metrics.record_latency(mt, metrics.now_us() - sent_at)
    }
    Error(Nil) -> Nil
  }
}

// --- FFI ---

@external(erlang, "beacon_http_client_ffi", "ws_connect")
fn ws_connect(host: String, port: Int) -> Result(WsSocket, String)

@external(erlang, "beacon_http_client_ffi", "ws_send")
fn ws_send(socket: WsSocket, payload: String) -> Result(Nil, String)

@external(erlang, "beacon_http_client_ffi", "ws_recv")
fn ws_recv(socket: WsSocket, timeout: Int) -> Result(String, String)

@external(erlang, "beacon_http_client_ffi", "ws_close")
fn ws_close(socket: WsSocket) -> Nil

@external(erlang, "beacon_http_client_ffi", "ws_close_graceful")
fn ws_close_graceful(socket: WsSocket, timeout: Int) -> Result(Nil, String)
