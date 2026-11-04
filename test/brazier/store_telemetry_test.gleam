/// `[brazier, store, write]` from node-local stores. Writes emit in the
/// writing process, so each test forwards only its own events and drains
/// its mailbox without waiting.
import brazier/monitored
import brazier/pubsub
import brazier/store
import brazier/telemetry.{type Event}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list

const write_event = ["brazier", "store", "write"]

/// Run `run` with this process's own write events forwarded to it; the
/// handler is detached afterwards even if `run` crashes.
fn listen(run: fn(Subject(Event)) -> a) -> a {
  // Store writes notify watchers through pubsub, which must be running.
  pubsub.start()
  let id = "store_telemetry_" <> int.to_string(unique_integer())
  let events = process.new_subject()
  let owner = process.self()
  use <- monitored.with_handler(id, [write_event], fn(event) {
    case process.self() == owner {
      True -> process.send(events, event)
      False -> Nil
    }
  })
  run(events)
}

/// `#(store, op, mode, count)` for every write event so far, oldest first.
fn drain(events: Subject(Event)) -> List(#(String, String, String, Int)) {
  drain_loop(events, [])
}

fn drain_loop(
  events: Subject(Event),
  acc: List(#(String, String, String, Int)),
) -> List(#(String, String, String, Int)) {
  case process.receive(events, 0) {
    Error(Nil) -> list.reverse(acc)
    Ok(event) -> {
      let assert Ok(name) = telemetry.string(event, "store")
      let assert Ok(op) = telemetry.string(event, "op")
      let assert Ok(mode) = telemetry.string(event, "mode")
      let assert Ok(count) = telemetry.int(event, "count")
      drain_loop(events, [#(name, op, mode, count), ..acc])
    }
  }
}

pub fn local_key_value_writes_emit_store_write_test() {
  use events <- listen()
  let name = "telemetry_kv_" <> int.to_string(unique_integer())
  let kv = store.new(name)
  store.put(kv, "a", 1)
  store.delete(kv, "a")
  let assert [#(n1, "put", "local", 1), #(n2, "delete", "local", 1)] =
    drain(events)
  let assert True = n1 == name && n2 == name
}

pub fn local_list_writes_report_how_many_values_test() {
  use events <- listen()
  let name = "telemetry_list_" <> int.to_string(unique_integer())
  let messages = store.new_list(name)
  store.append(messages, "room", "hi")
  store.append_many(messages, "room", ["a", "b", "c"])
  store.delete_all(messages, "room")
  let assert [
    #(_, "append", "local", 1),
    #(_, "append", "local", 3),
    #(_, "delete_all", "local", 1),
  ] = drain(events)
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
