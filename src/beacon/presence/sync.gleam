/// Presence data an app keeps: entries, the diffs that change them, and
/// `merge` to apply a diff (phoenix.js `Presence.syncDiff`).
///
/// These types are plain data with no server dependencies, so an app's
/// `Msg` can carry a `Diff` (the `on_presence` message of
/// `beacon.presence`) and its Model can hold `Entry` lists: both reach the
/// browser. The tracker itself is `beacon/presence`.
import gleam/list
import gleam/option.{type Option}
import gleam/string

/// One tracked entry's meta, from any node.
pub type Meta(meta) {
  Meta(value: meta, ref: String, ref_prev: Option(String), node: String)
}

/// Everything tracked under one key on a topic: one meta per tracking
/// process (several when the same key is tracked from several places).
pub type Entry(meta) {
  Entry(key: String, metas: List(Meta(meta)))
}

/// What changed on a topic. An update is a leave of the old meta and a
/// join of the new one.
pub type Diff(meta) {
  Diff(topic: String, joins: List(Entry(meta)), leaves: List(Entry(meta)))
}

/// Apply `diff` to `entries` (Phoenix.Presence's `syncDiff`): joins add
/// the metas whose refs are not there yet, then leaves remove the metas
/// with their refs, and keys left without metas are dropped. Applying a
/// diff twice changes nothing more. The result is ordered by key, like
/// `presence.list`.
///
/// ```gleam
/// OnlineChanged(diff) ->
///   Model(..model, online: sync.merge(model.online, diff))
/// ```
pub fn merge(
  entries: List(Entry(meta)),
  diff: Diff(meta),
) -> List(Entry(meta)) {
  let joined =
    list.fold(diff.joins, entries, fn(acc, join) {
      let #(same, others) =
        list.partition(acc, fn(entry) { entry.key == join.key })
      let present = list.flat_map(same, fn(entry) { entry.metas })
      let added =
        list.filter(join.metas, fn(meta) {
          !list.any(present, fn(existing) { existing.ref == meta.ref })
        })
      [Entry(key: join.key, metas: list.append(present, added)), ..others]
    })
  let leaving =
    list.flat_map(diff.leaves, fn(entry) {
      list.map(entry.metas, fn(meta) { meta.ref })
    })
  joined
  |> list.map(fn(entry) {
    Entry(
      ..entry,
      metas: list.filter(entry.metas, fn(meta) {
        !list.contains(leaving, meta.ref)
      }),
    )
  })
  |> list.filter(fn(entry) { entry.metas != [] })
  |> list.sort(fn(a, b) { string.compare(a.key, b.key) })
}
