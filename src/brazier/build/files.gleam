/// File system helpers for the build. Every failure is an `Error` naming the
/// path and the operation, so a build step can never fail silently.
import brazier/log
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

/// Write `contents` to `path` unless the file already holds exactly that.
/// True when the file was written. Leaving an unchanged file untouched keeps
/// its modification time, so file watchers and `gleam build` see no change.
pub fn write_if_changed(
  path: String,
  contents: String,
) -> Result(Bool, String) {
  use exists <- result.try(is_file(path))
  use current <- result.try(case exists {
    True -> read(path) |> result.map(Ok)
    False -> Ok(Error(Nil))
  })
  case current == Ok(contents) {
    True -> Ok(False)
    False -> write(path, contents) |> result.map(fn(_: Nil) { True })
  }
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
      log.debug("brazier.build.files", "Deleting " <> path)
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

/// Join path segments with `/`, without doubling separators. A base of `.`
/// (the current directory) is dropped: `join(".", "src")` is `src`.
pub fn join(base: String, child: String) -> String {
  case base, string.ends_with(base, "/") {
    ".", _ -> child
    _, True -> base <> child
    _, False -> base <> "/" <> child
  }
}

/// `path` resolved against `base`: an absolute `path` as it is, a relative
/// one joined to `base`.
pub fn resolve(base: String, path: String) -> String {
  case string.starts_with(path, "/") {
    True -> path
    False -> join(base, path)
  }
}

/// The relative path from the directory `from` to `to`, both absolute:
/// `relative_path("/a/b/c", "/a/d")` is `../../d`. Both are normalised
/// lexically first (`.` dropped, `..` removed with the segment before it),
/// so the result is only as right as the paths are free of symlinked `..`.
/// A path that is not absolute, or a `..` above `/`, is an `Error`.
pub fn relative_path(from: String, to: String) -> Result(String, String) {
  use from_segments <- result.try(absolute_segments(from))
  use to_segments <- result.try(absolute_segments(to))
  let #(up, down) = drop_common_prefix(from_segments, to_segments)
  case list.append(list.map(up, fn(_) { ".." }), down) {
    [] -> Ok(".")
    segments -> Ok(string.join(segments, "/"))
  }
}

fn absolute_segments(path: String) -> Result(List(String), String) {
  case string.starts_with(path, "/") {
    False ->
      Error(
        "Cannot compute a relative path from " <> path <> ": it is not absolute",
      )
    True ->
      path
      |> string.split("/")
      |> list.try_fold([], fn(reversed, segment) {
        case segment, reversed {
          "", _ | ".", _ -> Ok(reversed)
          "..", [_, ..rest] -> Ok(rest)
          "..", [] -> Error("The path " <> path <> " climbs above /")
          _, _ -> Ok([segment, ..reversed])
        }
      })
      |> result.map(list.reverse)
  }
}

fn drop_common_prefix(
  a: List(String),
  b: List(String),
) -> #(List(String), List(String)) {
  case a, b {
    [x, ..a_rest], [y, ..b_rest] if x == y -> drop_common_prefix(a_rest, b_rest)
    _, _ -> #(a, b)
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
