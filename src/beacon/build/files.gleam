/// File system helpers for the build. Every failure is an `Error` naming the
/// path and the operation, so a build step can never fail silently.
import beacon/log
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub fn read(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(err) { failure("read", path, err) })
}

/// Write `contents` to `path`, creating the parent directory first.
pub fn write(path: String, contents: String) -> Result(Nil, String) {
  use Nil <- result.try(ensure_parent(path))
  simplifile.write(path, contents)
  |> result.map_error(fn(err) { failure("write", path, err) })
}

/// Copy the file at `from` to `to`, creating the parent directory of `to`.
pub fn copy(from: String, to: String) -> Result(Nil, String) {
  use Nil <- result.try(ensure_parent(to))
  simplifile.copy_file(from, to)
  |> result.map_error(fn(err) {
    "Failed to copy " <> from <> " to " <> to <> ": " <> string.inspect(err)
  })
}

pub fn create_directory(path: String) -> Result(Nil, String) {
  simplifile.create_directory_all(path)
  |> result.map_error(fn(err) { failure("create directory", path, err) })
}

pub fn is_file(path: String) -> Result(Bool, String) {
  simplifile.is_file(path)
  |> result.map_error(fn(err) { failure("inspect", path, err) })
}

pub fn is_directory(path: String) -> Result(Bool, String) {
  simplifile.is_directory(path)
  |> result.map_error(fn(err) { failure("inspect", path, err) })
}

/// Delete a file or directory. A path that does not exist is not an error;
/// a path that exists but cannot be deleted is.
pub fn delete_if_exists(path: String) -> Result(Nil, String) {
  use file <- result.try(is_file(path))
  use directory <- result.try(is_directory(path))
  case file || directory {
    False -> Ok(Nil)
    True -> {
      log.debug("beacon.build.files", "Deleting " <> path)
      simplifile.delete(path)
      |> result.map_error(fn(err) { failure("delete", path, err) })
    }
  }
}

/// Every file below `dir`, recursively, sorted for a stable build order.
pub fn list_files(dir: String) -> Result(List(String), String) {
  simplifile.get_files(dir)
  |> result.map(list.sort(_, string.compare))
  |> result.map_error(fn(err) { failure("list", dir, err) })
}

/// The entries directly inside `dir`, sorted.
pub fn list_directory(dir: String) -> Result(List(String), String) {
  simplifile.read_directory(dir)
  |> result.map(list.sort(_, string.compare))
  |> result.map_error(fn(err) { failure("list", dir, err) })
}

/// The directory part of a `/`-separated path: `a/b/c.txt` -> `a/b`, and
/// `c.txt` -> `.`.
pub fn parent(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_] | [] -> "."
    [_, ..rest] ->
      case list.reverse(rest) |> string.join("/") {
        "" -> "/"
        dir -> dir
      }
  }
}

/// Join path segments with `/`, without doubling separators.
pub fn join(base: String, child: String) -> String {
  case string.ends_with(base, "/") {
    True -> base <> child
    False -> base <> "/" <> child
  }
}

fn ensure_parent(path: String) -> Result(Nil, String) {
  create_directory(parent(path))
}

fn failure(
  operation: String,
  path: String,
  err: simplifile.FileError,
) -> String {
  "Failed to "
  <> operation
  <> " "
  <> path
  <> ": "
  <> simplifile.describe_error(err)
}
