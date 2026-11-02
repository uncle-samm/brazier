/// Connection pool — spawns N real WebSocket connections, each executing
/// a scenario against a real Beacon server. Collects metrics atomically.
import beacon/log
import beacon/sim/metrics.{type MetricsTable}
import beacon/sim/scenario.{
  type Action, type Scenario, AbruptDisconnect, AssertResponseContains, Connect,
  Disconnect, Join, SendEvent, SendMalformed, Sleep, WaitForModelSync,
  WaitForPatch, WaitForResponse,
}
import gleam/erlang/process
import gleam/int
import gleam/json
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
    /// Stagger delay between spawns (ms)
    stagger_ms: Int,
    /// Metrics table for recording results
    metrics: MetricsTable,
  )
}

/// Pool execution result.
pub type PoolResult {
  PoolResult(total: Int, succeeded: Int, failed: Int, duration_ms: Int)
}

/// Opaque WebSocket handle.
pub type WsSocket

/// Run the pool: spawn N processes, each executing the scenario.
pub fn run(config: PoolConfig) -> PoolResult {
  let start = metrics.now_us()
  let result_subject = process.new_subject()

  // Spawn N workers with stagger
  spawn_workers(config.concurrency, config, result_subject, 0)

  // Collect results
  let #(succeeded, failed) =
    collect_results(result_subject, config.concurrency, 0, 0)

  let duration_us = metrics.now_us() - start
  PoolResult(
    total: config.concurrency,
    succeeded: succeeded,
    failed: failed,
    duration_ms: duration_us / 1000,
  )
}

/// Run the pool with NO client retry — raw single-attempt WebSocket connects.
/// Used to test server availability without client-side mitigation.
pub fn run_no_retry(config: PoolConfig) -> PoolResult {
  let start = metrics.now_us()
  let result_subject = process.new_subject()

  spawn_workers_no_retry(config.concurrency, config, result_subject, 0)

  let #(succeeded, failed) =
    collect_results(result_subject, config.concurrency, 0, 0)

  let duration_us = metrics.now_us() - start
  PoolResult(
    total: config.concurrency,
    succeeded: succeeded,
    failed: failed,
    duration_ms: duration_us / 1000,
  )
}

fn spawn_workers_no_retry(
  remaining: Int,
  config: PoolConfig,
  result_subject: process.Subject(Bool),
  idx: Int,
) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      let metrics_table = config.metrics
      let host = config.host
      let port = config.port
      let actions = config.scenario.actions

      process.spawn(fn() {
        let ok = execute_scenario_no_retry(host, port, actions, metrics_table)
        process.send(result_subject, ok)
      })

      case config.stagger_ms > 0 {
        True -> process.sleep(config.stagger_ms)
        False -> Nil
      }

      spawn_workers_no_retry(remaining - 1, config, result_subject, idx + 1)
    }
  }
}

fn execute_scenario_no_retry(
  host: String,
  port: Int,
  actions: List(Action),
  metrics_table: MetricsTable,
) -> Bool {
  execute_actions_no_retry(host, port, actions, metrics_table, option_none())
}

fn execute_actions_no_retry(
  host: String,
  port: Int,
  actions: List(Action),
  mt: MetricsTable,
  socket: Option(WsSocket),
) -> Bool {
  case actions {
    [] -> {
      case socket {
        Some(s) -> {
          ws_close(s)
          Nil
        }
        None -> Nil
      }
      True
    }
    [action, ..rest] -> {
      case execute_action_no_retry(host, port, action, mt, socket) {
        Ok(new_socket) ->
          execute_actions_no_retry(host, port, rest, mt, new_socket)
        Error(_reason) -> {
          case socket {
            Some(s) -> {
              ws_close(s)
              Nil
            }
            None -> Nil
          }
          False
        }
      }
    }
  }
}

fn execute_action_no_retry(
  host: String,
  port: Int,
  action: Action,
  mt: MetricsTable,
  socket: Option(WsSocket),
) -> Result(Option(WsSocket), String) {
  case action {
    Connect -> {
      metrics.increment(mt, "connections_opened")
      case ws_connect_no_retry(host, port) {
        Ok(s) -> Ok(Some(s))
        Error(reason) -> {
          metrics.increment(mt, "connections_failed")
          Error(reason)
        }
      }
    }
    // All other actions are the same — delegate to execute_action
    _ -> execute_action(host, port, action, mt, socket)
  }
}

fn spawn_workers(
  remaining: Int,
  config: PoolConfig,
  result_subject: process.Subject(Bool),
  idx: Int,
) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      let metrics_table = config.metrics
      let host = config.host
      let port = config.port
      let actions = config.scenario.actions

      process.spawn(fn() {
        let ok = execute_scenario(host, port, actions, metrics_table)
        process.send(result_subject, ok)
      })

      case config.stagger_ms > 0 {
        True -> process.sleep(config.stagger_ms)
        False -> Nil
      }

      spawn_workers(remaining - 1, config, result_subject, idx + 1)
    }
  }
}

fn collect_results(
  subject: process.Subject(Bool),
  remaining: Int,
  succeeded: Int,
  failed: Int,
) -> #(Int, Int) {
  case remaining {
    0 -> #(succeeded, failed)
    _ -> {
      case process.receive(subject, 30_000) {
        Ok(True) ->
          collect_results(subject, remaining - 1, succeeded + 1, failed)
        Ok(False) ->
          collect_results(subject, remaining - 1, succeeded, failed + 1)
        Error(Nil) -> {
          // Timeout — count remaining as failed
          log.warning(
            "beacon.sim.pool",
            "Timeout waiting for " <> int.to_string(remaining) <> " workers",
          )
          #(succeeded, failed + remaining)
        }
      }
    }
  }
}

/// Execute a scenario's actions sequentially. Returns True on success.
fn execute_scenario(
  host: String,
  port: Int,
  actions: List(Action),
  metrics_table: MetricsTable,
) -> Bool {
  execute_actions(host, port, actions, metrics_table, option_none())
}

fn execute_actions(
  host: String,
  port: Int,
  actions: List(Action),
  mt: MetricsTable,
  socket: Option(WsSocket),
) -> Bool {
  case actions {
    [] -> {
      // Clean up socket if still open
      case socket {
        Some(s) -> {
          ws_close(s)
          Nil
        }
        None -> Nil
      }
      True
    }
    [action, ..rest] -> {
      case execute_action(host, port, action, mt, socket) {
        Ok(new_socket) -> execute_actions(host, port, rest, mt, new_socket)
        Error(_reason) -> {
          // Clean up on failure
          case socket {
            Some(s) -> {
              ws_close(s)
              Nil
            }
            None -> Nil
          }
          False
        }
      }
    }
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

    SendEvent(handler_id, data) -> {
      case socket {
        Some(s) -> {
          let t0 = metrics.now_us()
          let event_msg =
            "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\""
            <> handler_id
            <> "\",\"data\":"
            // `data` is itself JSON: encode it as a JSON string so the
            // quotes inside it are escaped and the message stays valid.
            <> json.to_string(json.string(data))
            <> ",\"target_path\":\"0\",\"clock\":1}"
          let msg_bytes = string.byte_size(event_msg)
          case ws_send(s, event_msg) {
            Ok(_) -> {
              metrics.increment(mt, "events_sent")
              metrics.increment_by(mt, "bytes_sent", msg_bytes)
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

    WaitForResponse(timeout_ms) -> {
      case socket {
        Some(s) -> {
          case ws_recv(s, timeout_ms) {
            Ok(payload) -> {
              metrics.increment(mt, "events_acked")
              record_round_trip_latency(mt)
              track_response_type(mt, payload)
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
          case ws_recv(s, timeout_ms) {
            Ok(payload) -> {
              metrics.increment(mt, "events_acked")
              record_round_trip_latency(mt)
              track_response_type(mt, payload)
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
          case ws_recv(s, timeout_ms) {
            Ok(payload) -> {
              metrics.increment(mt, "events_acked")
              record_round_trip_latency(mt)
              track_response_type(mt, payload)
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
          case ws_recv(s, timeout_ms) {
            Ok(payload) -> {
              metrics.increment(mt, "events_acked")
              record_round_trip_latency(mt)
              track_response_type(mt, payload)
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

    Sleep(ms) -> {
      process.sleep(ms)
      Ok(socket)
    }

    SendMalformed(payload) -> {
      case socket {
        Some(s) -> {
          let _ = ws_send(s, payload)
          Ok(Some(s))
        }
        None -> Error("No socket for SendMalformed")
      }
    }

    Disconnect -> {
      case socket {
        Some(s) -> {
          ws_close(s)
          metrics.increment(mt, "connections_closed")
          Ok(option_none())
        }
        None -> Ok(option_none())
      }
    }

    AbruptDisconnect -> {
      case socket {
        Some(s) -> {
          ws_close(s)
          metrics.increment(mt, "connections_closed")
          Ok(option_none())
        }
        None -> Ok(option_none())
      }
    }
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

fn record_round_trip_latency(mt: MetricsTable) -> Nil {
  let sent_at = metrics.take_event_send_start()
  case sent_at > 0 {
    True -> metrics.record_latency(mt, metrics.now_us() - sent_at)
    False -> Nil
  }
}

// --- Simple Option type (to avoid import issues with gleam/option) ---

type Option(a) {
  Some(a)
  None
}

fn option_none() -> Option(a) {
  None
}

// --- FFI ---

@external(erlang, "beacon_http_client_ffi", "ws_connect")
fn ws_connect(host: String, port: Int) -> Result(WsSocket, String)

@external(erlang, "beacon_http_client_ffi", "ws_connect_no_retry")
fn ws_connect_no_retry(host: String, port: Int) -> Result(WsSocket, String)

@external(erlang, "beacon_http_client_ffi", "ws_send")
fn ws_send(socket: WsSocket, payload: String) -> Result(Nil, String)

@external(erlang, "beacon_http_client_ffi", "ws_recv")
fn ws_recv(socket: WsSocket, timeout: Int) -> Result(String, String)

@external(erlang, "beacon_http_client_ffi", "ws_close")
fn ws_close(socket: WsSocket) -> Nil
