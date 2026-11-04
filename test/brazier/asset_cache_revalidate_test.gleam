//// The client asset cache revalidates its entry against the file on every
//// load: the full stat data (size, mtime, ctime, inode, device) and git's
//// racy-clean rule (Documentation/technical/racy-git.txt), as the static
//// digest cache does. It used to compare size and mtime only, so a
//// same-size rewrite within the same second was served stale.
////
//// Times are taken from the file itself and injected, so no test depends
//// on how fast it runs.

import brazier/static
import gleam/int
import simplifile

/// A fresh bundle with `contents`, and the time of its last change.
fn fixture(name: String, contents: String) -> #(String, String, Int) {
  let dir = "/tmp/brazier_asset_revalidate_" <> name <> "_" <> unique_id()
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
    as "the temp directory is creatable"
  let path = dir <> "/bundle.js"
  let assert Ok(Nil) = simplifile.write(path, contents)
    as "the bundle is writable"
  #(dir, path, last_change(path))
}

fn last_change(path: String) -> Int {
  let assert Ok(info) = simplifile.file_info(path) as "the bundle exists"
  int.max(info.mtime_seconds, info.ctime_seconds)
}

fn cleanup(dir: String) -> Nil {
  let assert Ok(Nil) = simplifile.delete(dir) as "the temp directory exists"
  Nil
}

pub fn trusted_entry_is_served_from_cache_test() {
  let #(dir, path, changed) = fixture("hit", "one")
  let trusted = changed + 2
  let assert Ok(first) = static.load_client_asset_at(path, trusted)
  let assert static.AssetBuilt(static.NotCached) = first.source
  let assert Ok(second) = static.load_client_asset_at(path, trusted)
  let assert static.AssetCached = second.source
  assert second.asset == first.asset
  cleanup(dir)
}

/// The regression: same size, same mtime second. Only the racy rule can
/// catch it, because every stat field the cache compares may be unchanged.
pub fn same_size_rewrite_in_the_same_second_is_not_served_stale_test() {
  let #(dir, path, changed) = fixture("same_second", "aaaa")
  let assert Ok(info) = simplifile.file_info(path) as "the bundle exists"
  // Cached in the second the file was written: racily clean.
  let assert Ok(before) = static.load_client_asset_at(path, changed)
  let assert <<"aaaa":utf8>> = before.asset.raw
  // Rewrite in place (same inode, same size) and put the mtime back.
  let assert Ok(Nil) = simplifile.write(path, "bbbb")
    as "the bundle is writable"
  let assert Ok(Nil) = set_mtime(path, info.mtime_seconds)
  let assert Ok(after) = static.load_client_asset_at(path, changed)
  let assert static.AssetBuilt(_) = after.source
  let assert <<"bbbb":utf8>> = after.asset.raw
  assert after.asset.etag != before.asset.etag
  let assert <<"bbbb":utf8>> = gunzip(after.asset.gzip)
  cleanup(dir)
}

/// Inside the racy window an unchanged file is rebuilt, never trusted.
pub fn racily_clean_entry_is_rebuilt_test() {
  let #(dir, path, changed) = fixture("racy", "aaaa")
  let racy = changed + 1
  let assert Ok(first) = static.load_client_asset_at(path, racy)
  let assert static.AssetBuilt(static.NotCached) = first.source
  let assert Ok(second) = static.load_client_asset_at(path, racy)
  let assert static.AssetBuilt(static.RacilyClean) = second.source
  assert second.asset == first.asset
  // Once an entry is recorded outside the window it is trusted.
  let assert Ok(third) = static.load_client_asset_at(path, changed + 2)
  let assert static.AssetBuilt(static.RacilyClean) = third.source
  let assert Ok(fourth) = static.load_client_asset_at(path, changed + 2)
  let assert static.AssetCached = fourth.source
  cleanup(dir)
}

/// A trusted entry is dropped as soon as any stat field differs: here the
/// mtime alone, with the size unchanged.
pub fn mtime_change_rebuilds_a_trusted_entry_test() {
  let #(dir, path, changed) = fixture("mtime", "aaaa")
  let trusted = changed + 10
  let assert Ok(_) = static.load_client_asset_at(path, trusted)
  let assert Ok(static.LoadedAsset(source: static.AssetCached, ..)) =
    static.load_client_asset_at(path, trusted)
  let assert Ok(Nil) = set_mtime(path, changed - 100)
  let assert Ok(after) = static.load_client_asset_at(path, trusted)
  let assert static.AssetBuilt(static.StatChanged) = after.source
  cleanup(dir)
}

/// A new bundle renamed over the old one (how build tools publish
/// atomically) has a new inode; with the same size and mtime the inode
/// alone must invalidate the entry.
pub fn atomic_replace_with_same_size_and_mtime_rebuilds_test() {
  let #(dir, path, changed) = fixture("rename", "aaaa")
  let assert Ok(info) = simplifile.file_info(path) as "the bundle exists"
  let trusted = changed + 10
  let assert Ok(before) = static.load_client_asset_at(path, trusted)
  let assert Ok(static.LoadedAsset(source: static.AssetCached, ..)) =
    static.load_client_asset_at(path, trusted)
  let staged = dir <> "/bundle.js.new"
  let assert Ok(Nil) = simplifile.write(staged, "bbbb")
    as "the staged bundle is writable"
  let assert Ok(Nil) = set_mtime(staged, info.mtime_seconds)
  let assert Ok(Nil) = simplifile.rename(staged, path)
    as "the staged bundle can replace the bundle"
  let assert Ok(after) = static.load_client_asset_at(path, trusted)
  let assert static.AssetBuilt(static.StatChanged) = after.source
  let assert <<"bbbb":utf8>> = after.asset.raw
  assert after.asset.etag != before.asset.etag
  cleanup(dir)
}

@external(erlang, "brazier_static_test_ffi", "set_mtime")
fn set_mtime(path: String, mtime: Int) -> Result(Nil, String)

@external(erlang, "zlib", "gunzip")
fn gunzip(data: BitArray) -> BitArray

fn unique_id() -> String {
  do_unique_id()
}

@external(erlang, "brazier_test_ffi", "unique_ref")
fn do_unique_id() -> String
