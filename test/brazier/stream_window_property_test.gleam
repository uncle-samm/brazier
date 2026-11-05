//// Seeded property test of `brazier/internal/stream_window`: random
//// updates of random ops on two streams, checked after every update
//// against a naive model of the window rules (`stream_reference.Model`),
//// and the encoded delta applied to the client's copy with the reference
//// applier, which must give the new window, items included. Deterministic:
//// each seed drives a small linear congruential generator.

import brazier/internal/stream_op.{type Op, Op}
import brazier/internal/stream_window.{type Windows}
import brazier/stream_reference.{type Model, type Store, Model, Store}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/set

const seeds = 300

const updates_per_seed = 25

type Rng {
  Rng(state: Int)
}

fn next(rng: Rng, below: Int) -> #(Int, Rng) {
  let state = { rng.state * 1_103_515_245 + 12_345 } % 2_147_483_648
  #({ state / 65_536 } % below, Rng(state))
}

type Stream {
  Stream(name: String, limit: stream_op.Limit)
}

/// The test's view of one stream: the naive window and the client's store.
type Track {
  Track(model: Model, store: Store)
}

pub fn random_updates_match_the_model_test() {
  int.range(from: 1, to: seeds + 1, with: Nil, run: fn(_, seed) {
    run_seed(seed)
  })
}

fn run_seed(seed: Int) -> Nil {
  let rng = Rng(seed)
  let #(a, rng) = random_stream(rng, "a")
  let #(b, rng) = random_stream(rng, "b")
  let streams = [a, b]
  let tracks =
    list.fold(streams, dict.new(), fn(tracks, s) {
      dict.insert(
        tracks,
        s.name,
        Track(
          model: Model(limit: s.limit, items: [], trimmed: 0),
          store: Store(
            name: s.name,
            keep: stream_op.keep_to_string(s.limit.keep),
            limit: s.limit.count,
            items: [],
          ),
        ),
      )
    })
  let windows = stream_window.new(keep_items: seed % 2 == 0)
  let #(windows, tracks, _) =
    int.range(
      from: 0,
      to: updates_per_seed,
      with: #(windows, tracks, rng),
      run: fn(state, update) {
        let #(windows, tracks, rng) = state
        let #(ops, rng) = random_ops(rng, streams, seed * 1000 + update)
        let #(windows, tracks) = check_update(windows, tracks, ops)
        #(windows, tracks, rng)
      },
    )
  case stream_window.snapshot(windows) {
    Error(stream_window.ItemsNotKept) -> {
      let assert True = seed % 2 == 1 as "only odd seeds drop items"
      Nil
    }
    Ok(#(deltas, _)) -> check_snapshot(deltas, tracks)
  }
}

/// The kept items are the model's: every non-empty window, in name order.
fn check_snapshot(
  deltas: List(stream_window.Delta),
  tracks: Dict(String, Track),
) -> Nil {
  let expected =
    ["a", "b"]
    |> list.filter_map(fn(name) {
      let assert Ok(track) = dict.get(tracks, name)
      case track.model.items {
        [] -> Error(Nil)
        items -> Ok(#(name, items))
      }
    })
  let actual =
    list.map(deltas, fn(delta) {
      let assert True = delta.reset as "a snapshot entry is a reset"
      #(
        delta.name,
        list.map(delta.inserts, fn(insert) { #(insert.key, insert.json) }),
      )
    })
  let assert True = actual == expected as "the snapshot holds the model's items"
  Nil
}

fn random_stream(rng: Rng, name: String) -> #(Stream, Rng) {
  let #(count, rng) = next(rng, 5)
  let #(keep, rng) = next(rng, 2)
  let keep = case keep {
    0 -> stream_op.First
    _ -> stream_op.Last
  }
  #(Stream(name, stream_op.Limit(keep, count + 1)), rng)
}

fn random_ops(rng: Rng, streams: List(Stream), tag: Int) -> #(List(Op), Rng) {
  let #(count, rng) = next(rng, 7)
  int.range(from: 0, to: count, with: #([], rng), run: fn(acc, index) {
    let #(ops, rng) = acc
    let #(op, rng) = random_op(rng, streams, tag * 10 + index)
    #([op, ..ops], rng)
  })
  |> fn(acc: #(List(Op), Rng)) { #(list.reverse(acc.0), acc.1) }
}

fn random_op(rng: Rng, streams: List(Stream), tag: Int) -> #(Op, Rng) {
  let #(which, rng) = next(rng, list.length(streams))
  let s = case list.drop(streams, which) {
    [s, ..] -> s
    [] -> panic as "stream_window_property_test: no stream at the index"
  }
  let #(kind, rng) = next(rng, 10)
  let #(key, rng) = random_key(rng)
  let json = item(key, tag)
  let #(action, rng) = case kind {
    0 | 1 | 2 | 3 -> #(stream_op.Insert(key, json, stream_op.Back), rng)
    4 | 5 | 6 -> #(stream_op.Insert(key, json, stream_op.Front), rng)
    7 | 8 -> #(stream_op.Delete(key), rng)
    _ -> {
      let #(size, rng) = next(rng, 5)
      let #(items, rng) =
        int.range(from: 0, to: size, with: #([], rng), run: fn(acc, i) {
          let #(items, rng) = acc
          let #(key, rng) = random_key(rng)
          #([#(key, item(key, tag * 10 + i)), ..items], rng)
        })
      #(stream_op.Reset(list.reverse(items)), rng)
    }
  }
  #(Op(name: s.name, limit: s.limit, action: action), rng)
}

fn random_key(rng: Rng) -> #(String, Rng) {
  let #(n, rng) = next(rng, 8)
  #("k" <> int.to_string(n), rng)
}

/// An item whose JSON text is the same before and after a decode and
/// encode, so the reference applier's items compare as text.
fn item(key: String, tag: Int) -> String {
  "{\"k\":\"" <> key <> "\",\"t\":" <> int.to_string(tag) <> "}"
}

fn check_update(
  windows: Windows,
  tracks: Dict(String, Track),
  ops: List(Op),
) -> #(Windows, Dict(String, Track)) {
  let assert Ok(applied) =
    stream_window.apply_update(windows, ops, stream_window.default_limits())
    as "the update is within every bound"
  let assert [] = applied.refused
  // The model, op by op, and the unknown deletes it expects.
  let #(models, unknown, _) =
    list.fold(
      ops,
      #(dict.map_values(tracks, fn(_, t) { t.model }), [], 0),
      fn(acc, op) {
        let #(models, unknown, index) = acc
        let assert Ok(model) = dict.get(models, op.name)
        let #(model, missing) = stream_reference.model_apply(model, op.action)
        let unknown = case missing, op.action {
          True, stream_op.Delete(key) -> [
            stream_window.UnknownDelete(index: index, stream: op.name, key: key),
            ..unknown
          ]
          _, _ -> unknown
        }
        #(dict.insert(models, op.name, model), unknown, index + 1)
      },
    )
  let assert True = applied.unknown_deletes == list.reverse(unknown)
    as "unknown deletes match the model"
  // Decode the wire text the client would receive.
  let assert Ok(entries) =
    json.parse(applied.streams_json, decode.dynamic)
    |> result_or_crash
    |> stream_reference.decode_streams
  let by_name =
    list.fold(entries, dict.new(), fn(by_name, entry) {
      let assert False = dict.has_key(by_name, entry.name)
        as "at most one entry per stream"
      dict.insert(by_name, entry.name, entry)
    })
  let touched = touched_keys(ops)
  let tracks =
    dict.map_values(tracks, fn(name, track) {
      let assert Ok(model) = dict.get(models, name)
      let model_keys = list.map(model.items, fn(i) { i.0 })
      // The window equals the naive model.
      let assert True = window_keys(applied.windows, name) == model_keys
        as "the window keys equal the model's"
      let store = case dict.get(by_name, name) {
        Error(Nil) -> {
          // No entry: the client's items are already the model's.
          let assert True = track.store.items == model.items
            as "an omitted entry means no change"
          track.store
        }
        Ok(entry) -> {
          let assert Ok(store) =
            stream_reference.apply_entry(track.store, entry)
            as "the delta applies without a fault"
          let assert True = store.items == model.items
            as "the old items plus the delta give the new ones"
          check_minimal(entry, track.store, touched, name)
          check_counts(applied, entry, model, track.model)
          store
        }
      }
      Track(model: model, store: store)
    })
  #(applied.windows, tracks)
}

/// A key the client held, that stays and was not inserted again, is never
/// resent; a delete is always of a key the client held.
fn check_minimal(
  entry: stream_reference.Entry,
  old: Store,
  touched: set.Set(#(String, String)),
  name: String,
) -> Nil {
  case entry.reset {
    True -> {
      let assert [] = entry.deletes
      Nil
    }
    False ->
      list.each(entry.inserts, fn(insert) {
        let #(key, _, _) = insert
        let held = list.key_find(old.items, key) != Error(Nil)
        let deleted = list.contains(entry.deletes, key)
        let assert True =
          !held || deleted || set.contains(touched, #(name, key))
          as "an untouched stable key is not resent"
      })
  }
}

fn check_counts(
  applied: stream_window.Applied,
  entry: stream_reference.Entry,
  model: Model,
  before: Model,
) -> Nil {
  let assert Ok(change) =
    list.find(applied.changes, fn(change) { change.delta.name == entry.name })
  let assert True = change.trimmed == model.trimmed - before.trimmed
    as "the trim count equals the model's"
  Nil
}

fn touched_keys(ops: List(Op)) -> set.Set(#(String, String)) {
  list.fold(ops, set.new(), fn(touched, op) {
    case op.action {
      stream_op.Insert(key, _, _) -> set.insert(touched, #(op.name, key))
      stream_op.Delete(_) -> touched
      stream_op.Reset(items) ->
        list.fold(items, touched, fn(touched, item) {
          set.insert(touched, #(op.name, item.0))
        })
    }
  })
}

fn window_keys(windows: Windows, name: String) -> List(String) {
  case stream_window.keys(windows, name) {
    Ok(keys) -> keys
    Error(Nil) -> []
  }
}

fn result_or_crash(parsed: Result(Dynamic, json.DecodeError)) -> Dynamic {
  let assert Ok(value) = parsed as "the streams text is JSON"
  value
}
