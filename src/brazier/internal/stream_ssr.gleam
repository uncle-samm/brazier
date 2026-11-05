/// Streams in the dead render (docs/design/STREAMS.md 7.6).
///
/// `brazier/ssr` runs `init` and the route message without running their
/// effects. Their stream ops are taken out first and applied, one update
/// each, to windows that keep their items, with the same bounds the runtime
/// applies (`brazier/internal/stream_window`). The view is then rendered
/// with every stream container holding its items, each decoded with the
/// stream's decoder and rendered with its item function
/// (`render.render_item`), so the page holds the items the join's
/// `model_sync` will send. The windows are dropped after the render.
///
/// An item that does not decode, or whose item function breaks a rule of
/// 5.3, fails the render: the caller crashes the dead render, which serves
/// the 500 page, so an encoder and a decoder that do not agree fail on the
/// first page load, before any socket opens.
///
/// Reference: LiveView renders a stream's items in the dead render and
/// frees them after (`Phoenix.LiveView.stream/4`, `LiveStream`).
import brazier/effect.{type Effect}
import brazier/internal/render
import brazier/internal/stream_op.{type Op}
import brazier/internal/stream_window.{type Delta, type Limits, type Windows}
import brazier/log
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// Windows for one dead render: they keep their items.
pub fn new() -> Windows {
  stream_window.new(keep_items: True)
}

/// Take the stream ops out of `effect` and apply them to `windows` as one
/// update. Returns the windows after it and the effect without its ops.
///
/// An op on a name not in `names` (the build's declared streams) is refused
/// with the runtime's reason, `unknown_stream`, and logged at error, one
/// line per stream; the others go through the runtime's bounds. A refused
/// op is logged at error and not applied; an update over a per-update bound
/// is logged at error and none of its ops is applied, as the runtime does.
/// A delete of a key not in its window is logged at warning. `stage` and
/// `path` name the update in the logs.
///
/// No `[brazier, stream, refused]` event is emitted here: the connected
/// mount runs the same `init` again and the runtime emits it then, so the
/// dead render would count every refusal twice.
pub fn apply(
  windows: Windows,
  effect: Effect(msg),
  names: Set(String),
  limits: Limits,
  stage: String,
  path: String,
) -> #(Windows, Effect(msg)) {
  let #(ops, rest) = effect.take_stream_ops(effect)
  case ops {
    [] -> #(windows, rest)
    _ -> {
      let update = stage <> ", dead render of " <> path
      let #(known, unknown) =
        list.partition(ops, fn(op) { set.contains(names, op.name) })
      refuse_unknown(unknown, update)
      case known {
        [] -> #(windows, rest)
        _ -> #(apply_known(windows, known, limits, " (" <> update <> ")"), rest)
      }
    }
  }
}

/// Log the ops on names the build did not declare, one line per stream, in
/// the order of each stream's first op.
fn refuse_unknown(unknown: List(Op), update: String) -> Nil {
  let counts =
    list.fold(unknown, [], fn(counts, op) {
      case list.key_find(counts, op.name) {
        Ok(count) -> list.key_set(counts, op.name, count + 1)
        Error(Nil) -> list.append(counts, [#(op.name, 1)])
      }
    })
  list.each(counts, fn(entry) {
    let #(name, count) = entry
    log.error(
      "brazier.ssr",
      "Refused "
        <> int.to_string(count)
        <> " stream op(s) on stream "
        <> name
        <> " (unknown_stream, "
        <> update
        <> "): the build declared no stream with this name",
    )
  })
}

/// Apply `ops`, all on declared streams, as one update.
fn apply_known(
  windows: Windows,
  ops: List(Op),
  limits: Limits,
  context: String,
) -> Windows {
  case stream_window.apply_update(windows, ops, limits) {
    Error(refusal) -> {
      log.error(
        "brazier.ssr",
        "Refused every stream op"
          <> context
          <> ": "
          <> stream_window.describe_update_refusal(refusal),
      )
      windows
    }
    Ok(applied) -> {
      list.each(applied.refused, fn(refusal) {
        log.error(
          "brazier.ssr",
          "Refused stream op "
            <> int.to_string(refusal.index)
            <> " on stream "
            <> refusal.stream
            <> context
            <> ": "
            <> stream_window.describe_op_reason(refusal.reason),
        )
      })
      list.each(applied.unknown_deletes, fn(unknown) {
        log.warning(
          "brazier.ssr",
          "Stream op "
            <> int.to_string(unknown.index)
            <> " deletes key "
            <> unknown.key
            <> ", which stream "
            <> unknown.stream
            <> " does not hold"
            <> context,
        )
      })
      log.debug(
        "brazier.ssr",
        "Applied "
          <> int.to_string(list.length(ops) - list.length(applied.refused))
          <> " of "
          <> int.to_string(list.length(ops))
          <> " stream op(s)"
          <> context,
      )
      applied.windows
    }
  }
}

/// Render `node` with every stream container holding its stream's items.
/// `Error`, logged at error, when an item does not render; the caller
/// crashes the dead render.
pub fn render(
  node: render.Node(msg),
  windows: Windows,
  path: String,
) -> Result(String, String) {
  // Invariant: `new` makes windows that keep their items, and only `apply`
  // changes them, so the snapshot cannot be refused.
  let assert Ok(#(deltas, _without_items)) = stream_window.snapshot(windows)
    as "brazier/internal/stream_ssr: the dead render's windows do not keep their items"
  let by_name =
    list.fold(deltas, dict.new(), fn(acc, delta) {
      dict.insert(acc, delta.name, delta)
    })
  let rendered = render.render_filled(node, fill(_, by_name))
  case rendered {
    Ok(_) -> Nil
    Error(reason) ->
      log.error(
        "brazier.ssr",
        "A stream item does not render in the dead render of "
          <> path
          <> ", so the page fails with 500: "
          <> reason,
      )
  }
  rendered
}

/// The HTML of `container`'s items: none when no op filled its stream.
fn fill(
  container: render.Container(msg),
  deltas: Dict(String, Delta),
) -> Result(String, String) {
  case dict.get(deltas, container.name) {
    Error(Nil) -> Ok("")
    Ok(delta) -> {
      use Nil <- result.try(case delta.limit == container.limit {
        True -> Ok(Nil)
        False ->
          Error(
            "stream "
            <> container.name
            <> ": its ops use "
            <> stream_window.describe_limit(delta.limit)
            <> " and the view renders it with "
            <> stream_window.describe_limit(container.limit),
          )
      })
      use parts <- result.map(
        list.try_map(delta.inserts, fn(insert) {
          use item <- result.try(
            json.parse(insert.json, decode.dynamic)
            |> result.map_error(fn(_) {
              "stream "
              <> container.name
              <> ", item "
              <> insert.key
              <> ": the encoded item is not JSON"
            }),
          )
          use #(html, _handlers) <- result.map(render.render_item(
            container,
            insert.key,
            item,
          ))
          html
        }),
      )
      string.concat(parts)
    }
  }
}
