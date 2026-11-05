/// Static file serving — serves files from a directory with proper MIME types,
/// cache headers, and directory traversal prevention.
///
/// Path handling follows Plug.Static: the prefix only matches on a `/`
/// segment boundary, every remaining segment is percent-decoded and checked
/// on its own, and anything that could leave the directory (`..`, `.`,
/// separators, NUL, drive colons) is refused. Hidden files (a segment
/// starting with `.`) are never served.
///
/// Caching follows RFC 9110/9111: a strong ETag derived from the content
/// hash, `If-None-Match` lists (including `*` and weak tags) answered with
/// 304, and `X-Content-Type-Options: nosniff` on every response.
///
/// Reference: Plug.Static, cowboy_static, Phoenix static serving.
import brazier/internal/ascii
import brazier/internal/log_path
import brazier/log
import brazier/transport/server.{type ResponseBody, Bytes, File}
import gleam/bit_array
import gleam/bool
import gleam/bytes_tree
import gleam/crypto
import gleam/float
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/uri

/// Configuration for static file serving.
pub type StaticConfig {
  StaticConfig(
    /// Directory to serve files from (e.g., "priv/static").
    directory: String,
    /// URL path prefix (e.g., "/static"). Must start with `/`, must not end
    /// with `/`, and must not be `/` itself (see `validate_config`).
    prefix: String,
    /// Cache-Control max-age in seconds (0 = revalidate every time).
    max_age: Int,
  )
}

/// Seconds a fingerprinted (content-addressed) asset may be cached.
pub const immutable_max_age = 31_536_000

/// Default static config.
pub fn default_config() -> StaticConfig {
  StaticConfig(directory: "priv/static", prefix: "/static", max_age: 3600)
}

/// Reject configurations that would shadow every route or produce invalid
/// cache headers. Called by the transport at startup.
pub fn validate_config(config: StaticConfig) -> Result(Nil, String) {
  let problems =
    [
      #(
        !string.starts_with(config.prefix, "/"),
        "prefix must start with '/': " <> config.prefix,
      ),
      #(
        config.prefix == "/",
        "prefix must not be '/' (it would shadow every route)",
      ),
      #(
        config.prefix != "/" && string.ends_with(config.prefix, "/"),
        "prefix must not end with '/': " <> config.prefix,
      ),
      #(
        contains_traversal(config.prefix),
        "prefix must not contain traversal sequences: " <> config.prefix,
      ),
      #(
        string.byte_size(config.prefix) > max_prefix_bytes,
        "prefix must be at most "
          <> int.to_string(max_prefix_bytes)
          <> " bytes (its telemetry route pattern is capped at 255): "
          <> config.prefix,
      ),
      #(config.directory == "", "directory must not be empty"),
      #(
        config.max_age < 0,
        "max_age must not be negative: " <> int.to_string(config.max_age),
      ),
    ]
    |> list.filter(fn(check) { check.0 })
    |> list.map(fn(check) { check.1 })
  case problems {
    [] -> Ok(Nil)
    _ -> {
      let reason = string.join(problems, "; ")
      log.error("brazier.static", "Invalid static config: " <> reason)
      Error(reason)
    }
  }
}

/// Longest accepted prefix: the telemetry route pattern `<prefix>/*` must
/// fit `transport/http.max_route_tag_bytes` (255).
const max_prefix_bytes = 253

/// The route pattern a served static file reports to telemetry:
/// `<prefix>/*`, never the file path.
pub fn route_pattern(config: StaticConfig) -> String {
  config.prefix <> "/*"
}

/// True when `path` is inside the static prefix: equal to it or below it on
/// a `/` boundary. `/staticfoo` does not match the prefix `/static`.
pub fn matches_prefix(config: StaticConfig, path: String) -> Bool {
  path == config.prefix || string.starts_with(path, config.prefix <> "/")
}

/// Try to serve a static file for the given path.
/// Returns Ok(Response) if a file was found and served (or the path was
/// refused), Error(Nil) if the path is outside the static prefix or no such
/// file exists.
pub fn serve(
  config: StaticConfig,
  path: String,
) -> Result(Response(ResponseBody), Nil) {
  serve_with_etag_check(config, path, "")
}

/// Serve a static file with ETag/If-None-Match support.
/// `if_none_match` is the raw header value ("" when absent); a matching
/// entity tag (or `*`) yields 304 Not Modified.
pub fn serve_with_etag_check(
  config: StaticConfig,
  path: String,
  if_none_match: String,
) -> Result(Response(ResponseBody), Nil) {
  serve_with_cache_control(
    config,
    path,
    if_none_match,
    cache_control(config.max_age),
  )
}

/// Serve static files with an immutable cache (for fingerprinted assets).
/// Fingerprinted assets can be cached forever since the URL changes on
/// content change.
pub fn serve_immutable(
  config: StaticConfig,
  path: String,
) -> Result(Response(ResponseBody), Nil) {
  serve_with_cache_control(config, path, "", immutable_cache_control())
}

/// The Cache-Control value for a max-age: 0 means "store but revalidate".
pub fn cache_control(max_age: Int) -> String {
  case max_age > 0 {
    True -> "public, max-age=" <> int.to_string(max_age)
    False -> "no-cache"
  }
}

/// The Cache-Control value for content-addressed assets.
pub fn immutable_cache_control() -> String {
  "public, max-age=" <> int.to_string(immutable_max_age) <> ", immutable"
}

fn serve_with_cache_control(
  config: StaticConfig,
  path: String,
  if_none_match: String,
  cache: String,
) -> Result(Response(ResponseBody), Nil) {
  case matches_prefix(config, path) {
    False -> Error(Nil)
    True -> {
      let relative = string.drop_start(path, string.length(config.prefix))
      case resolve_relative(relative) {
        Error(NoFile) -> {
          log.debug(
            "brazier.static",
            "No file named by: " <> log_path.describe(path),
          )
          Error(Nil)
        }
        Error(Refused(reason)) -> {
          log.warning(
            "brazier.static",
            "Refused static path " <> log_path.describe(path) <> ": " <> reason,
          )
          Ok(plain_response(403, "Forbidden"))
        }
        Error(Undecodable) -> {
          log.warning(
            "brazier.static",
            "Undecodable static path: " <> log_path.describe(path),
          )
          Ok(plain_response(400, "Bad Request"))
        }
        Ok(segments) ->
          serve_file(
            config.directory <> "/" <> string.join(segments, "/"),
            cache,
            if_none_match,
          )
      }
    }
  }
}

/// Why a relative static path names no servable file.
type PathProblem {
  /// The path names the directory itself (no file).
  NoFile
  /// The path tries to leave the directory or reach a hidden file.
  Refused(reason: String)
  /// A segment is not valid percent-encoded UTF-8.
  Undecodable
}

/// Split the part of the path after the prefix into decoded, safe segments.
/// `relative` is "" or starts with "/" (guaranteed by `matches_prefix`).
fn resolve_relative(relative: String) -> Result(List(String), PathProblem) {
  use <- bool.guard(
    when: contains_traversal(relative),
    return: Error(Refused("traversal sequence")),
  )
  case string.split(relative, "/") {
    // "" is the prefix itself: no file.
    [""] -> Error(NoFile)
    ["", ..segments] ->
      case list.last(segments) {
        // A trailing slash names a directory: no file.
        Ok("") -> Error(NoFile)
        _ -> decode_segments(segments, [])
      }
    // matches_prefix only accepts "" or a leading "/".
    _ -> Error(Refused("path does not start at a segment boundary"))
  }
}

fn decode_segments(
  segments: List(String),
  acc: List(String),
) -> Result(List(String), PathProblem) {
  case segments {
    [] -> Ok(list.reverse(acc))
    [segment, ..rest] -> {
      use decoded <- result.try(
        uri.percent_decode(segment) |> result.replace_error(Undecodable),
      )
      use Nil <- result.try(check_segment(decoded))
      decode_segments(rest, [decoded, ..acc])
    }
  }
}

fn check_segment(segment: String) -> Result(Nil, PathProblem) {
  case segment {
    "" -> Error(Refused("empty path segment"))
    "." | ".." -> Error(Refused("relative path segment"))
    _ ->
      case
        string.starts_with(segment, "."),
        string.contains(segment, "/")
        || string.contains(segment, "\\")
        || string.contains(segment, ":")
        || string.contains(segment, "\u{0000}")
      {
        True, _ -> Error(Refused("hidden file"))
        _, True -> Error(Refused("separator or NUL inside a segment"))
        False, False -> Ok(Nil)
      }
  }
}

/// Why `file_digest_at` could not digest a path.
@internal
pub type DigestError {
  /// Missing, or not a regular file (a directory, FIFO, socket or device).
  NotAFile
  /// The file exists but could not be read.
  ReadFailed(String)
  /// The digest cache table could not be had (its owner is gone).
  CacheUnavailable(String)
}

/// A static file's length and the first `etag_hash_chars` lowercase hex
/// characters of its SHA-256, and where the hash came from.
@internal
pub type Digest {
  Digest(length: Int, hash: String, source: DigestSource)
}

@internal
pub type DigestSource {
  /// The cached hash was used: the stat data matched and is not racy.
  Cached
  /// The file was read and hashed, and the entry was (re)cached.
  Hashed(reason: HashReason)
}

/// Why the cached digest of a file was not used.
@internal
pub type HashReason {
  /// No entry for the path.
  NotCached
  /// Size, mtime, ctime, inode or device differ from the entry's.
  StatChanged
  /// The stat data matched, but the entry was recorded within the racy
  /// window of the file's last change, so an edit may not show in it.
  RacilyClean
}

@external(erlang, "brazier_static_ffi", "file_digest")
fn ffi_file_digest(
  path: String,
  hex_chars: Int,
  now_seconds: Int,
  capacity: Int,
) -> Result(Digest, DigestError)

@external(erlang, "brazier_static_ffi", "now_seconds")
fn now_seconds() -> Int

/// Entries in the digest cache. For tests.
@external(erlang, "brazier_static_ffi", "cache_size")
@internal
pub fn digest_cache_size() -> Int

/// Most digests kept. An entry is a path and a few integers, so a full
/// table stays well under a megabyte; past the cap entries are evicted.
@internal
pub const digest_cache_capacity = 2048

/// Characters of the content hash shown in an ETag (128 bits).
const etag_hash_chars = 32

/// The digest of the regular file at `path`, using the cache when its entry
/// is trusted at time `now_seconds`, and bounding the cache to `capacity`
/// entries. `serve_file` passes the clock and `digest_cache_capacity`; tests
/// pass their own to place an entry inside or outside the racy window.
@internal
pub fn file_digest_at(
  path: String,
  now_seconds: Int,
  capacity: Int,
) -> Result(Digest, DigestError) {
  let digest = ffi_file_digest(path, etag_hash_chars, now_seconds, capacity)
  case digest {
    Ok(Digest(source: Hashed(reason), ..)) ->
      log.debug(
        "brazier.static",
        "digest cache miss ("
          <> hash_reason_name(reason)
          <> "): "
          <> string.inspect(path),
      )
    Ok(Digest(source: Cached, ..)) | Error(_) -> Nil
  }
  digest
}

fn hash_reason_name(reason: HashReason) -> String {
  case reason {
    NotCached -> "not cached"
    StatChanged -> "stat changed"
    RacilyClean -> "racily clean"
  }
}

/// Serve a single file from the filesystem.
/// If `if_none_match` matches the file's ETag, returns 304 Not Modified.
///
/// The file is never loaded whole, and is not read at all while its cached
/// digest is trusted: the ETag is the content hash, cached against the
/// file's stat data under git's racy-clean rule (see brazier_static_ffi),
/// and the body is a `File` that the listener sends with `file:sendfile`.
/// The ETag stays content-based, so an edit that keeps the size and the
/// modification second is not answered 304. A stat-based tag as in
/// Plug.Static and cowboy_static (`phash2({size, mtime})`) would be.
fn serve_file(
  path: String,
  cache: String,
  if_none_match: String,
) -> Result(Response(ResponseBody), Nil) {
  case file_digest_at(path, now_seconds(), digest_cache_capacity) {
    Ok(Digest(length:, hash:, source: _)) -> {
      let mime = mime_type(path)
      let etag = "\"" <> hash <> "\""
      case etag_matches(if_none_match, etag) {
        True -> {
          log.debug(
            "brazier.static",
            "304 Not Modified: " <> string.inspect(path),
          )
          Ok(
            response.new(304)
            |> response.set_header("etag", etag)
            |> response.set_header("cache-control", cache)
            |> response.set_header("x-content-type-options", "nosniff")
            |> response.set_body(Bytes(bytes_tree.new())),
          )
        }
        False -> {
          log.debug(
            "brazier.static",
            "Serving: " <> string.inspect(path) <> " (" <> mime <> ")",
          )
          Ok(
            response.new(200)
            |> response.set_header("content-type", mime)
            |> response.set_header("cache-control", cache)
            |> response.set_header("etag", etag)
            |> response.set_header("x-content-type-options", "nosniff")
            |> response.set_body(File(path:, offset: 0, length:)),
          )
        }
      }
    }
    // A missing path, a directory or a special file is "no such static
    // file": the transport answers 404 for it.
    Error(NotAFile) -> {
      log.debug(
        "brazier.static",
        "No regular file at: " <> string.inspect(path),
      )
      Error(Nil)
    }
    Error(ReadFailed(reason)) -> {
      log.error(
        "brazier.static",
        "Cannot read static file " <> string.inspect(path) <> ": " <> reason,
      )
      Ok(plain_response(500, "Internal Server Error"))
    }
    Error(CacheUnavailable(reason)) -> {
      log.error(
        "brazier.static",
        "Cannot serve static file "
          <> string.inspect(path)
          <> ": digest cache unavailable: "
          <> reason,
      )
      Ok(plain_response(500, "Internal Server Error"))
    }
  }
}

fn plain_response(status: Int, body: String) -> Response(ResponseBody) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_body(Bytes(bytes_tree.from_string(body)))
}

/// A strong entity tag derived from the content (SHA-256, 128 bits shown).
/// A served static file carries the tag of its contents.
pub fn etag_for(contents: BitArray) -> String {
  "\"" <> content_hash(contents, etag_hash_chars) <> "\""
}

/// Lowercase hex of the SHA-256 of `contents`, truncated to `length` chars.
fn content_hash(contents: BitArray, length: Int) -> String {
  crypto.hash(crypto.Sha256, contents)
  |> bit_array.base16_encode
  |> ascii.lowercase
  |> string.slice(0, length)
}

/// RFC 9110 §13.1.2: If-None-Match uses the weak comparison, so `W/"x"`
/// matches `"x"`. `*` matches any current representation. The header may
/// carry a comma-separated list; "" means the header was absent.
pub fn etag_matches(if_none_match: String, etag: String) -> Bool {
  let wanted = strip_weak(etag)
  case string.trim(if_none_match) {
    "" -> False
    "*" -> True
    header ->
      header
      |> string.split(",")
      |> list.any(fn(candidate) { strip_weak(string.trim(candidate)) == wanted })
  }
}

fn strip_weak(tag: String) -> String {
  case tag {
    "W/" <> rest -> rest
    _ -> tag
  }
}

/// RFC 9110 §12.5.3: true when the Accept-Encoding header value accepts
/// gzip with a non-zero quality (explicitly, or via `*` when gzip is not
/// listed). "" (no header) means no content coding is requested.
pub fn accepts_gzip(accept_encoding: String) -> Bool {
  let codings =
    accept_encoding
    |> string.split(",")
    |> list.filter_map(parse_coding)
  case
    list.find(codings, fn(coding) { coding.0 == "gzip" || coding.0 == "x-gzip" })
  {
    Ok(#(_, quality)) -> quality >. 0.0
    Error(Nil) ->
      case list.find(codings, fn(coding) { coding.0 == "*" }) {
        Ok(#(_, quality)) -> quality >. 0.0
        Error(Nil) -> False
      }
  }
}

/// Parse one `coding;q=value` element. Malformed quality values make the
/// element unacceptable (q=0) rather than silently accepted. Codings and
/// parameter names are tokens, compared case-insensitively in ASCII
/// (RFC 9110 §8.4.1, §5.6.6), so a name holding any other character never
/// is `gzip` or `q`.
fn parse_coding(element: String) -> Result(#(String, Float), Nil) {
  case string.split(element, ";") {
    [name, ..params] ->
      case ascii.lowercase(string.trim(name)) {
        "" -> Error(Nil)
        coding -> Ok(#(coding, quality(params)))
      }
    [] -> Error(Nil)
  }
}

fn quality(params: List(String)) -> Float {
  case
    list.find_map(params, fn(param) {
      case string.split_once(string.trim(param), "=") {
        Ok(#(key, value)) ->
          case ascii.lowercase(string.trim(key)) {
            "q" -> Ok(parse_quality(string.trim(value)))
            _ -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    })
  {
    Ok(q) -> q
    Error(Nil) -> 1.0
  }
}

fn parse_quality(value: String) -> Float {
  case float.parse(value), int.parse(value) {
    Ok(q), _ -> q
    _, Ok(q) -> int.to_float(q)
    Error(Nil), Error(Nil) -> 0.0
  }
}

/// True for a client bundle file name produced by `brazier/build`:
/// `brazier_client_<8..64 hex digits>.js`, nothing else. This is the only
/// shape the transport will read from the client assets directory.
pub fn is_client_bundle_name(name: String) -> Bool {
  case name {
    "brazier_client_" <> rest ->
      case string.ends_with(rest, ".js") {
        True -> {
          let hash = string.drop_end(rest, 3)
          let length = string.length(hash)
          length >= 8 && length <= 64 && is_hex(hash)
        }
        False -> False
      }
    _ -> False
  }
}

fn is_hex(text: String) -> Bool {
  text
  |> string.to_graphemes
  |> list.all(fn(char) {
    case char {
      "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
      "a" | "b" | "c" | "d" | "e" | "f" -> True
      "A" | "B" | "C" | "D" | "E" | "F" -> True
      _ -> False
    }
  })
}

/// A client bundle prepared for serving: the raw bytes, their gzip encoding
/// and a strong ETag. Built once per file version and cached.
pub type ClientAsset {
  ClientAsset(raw: BitArray, gzip: BitArray, etag: String)
}

/// Why a client bundle could not be loaded.
pub type AssetError {
  /// No regular file exists at the path.
  AssetNotFound
  /// The file exists but could not be read.
  AssetReadFailed(reason: String)
}

/// A client bundle from `load_client_asset_at`, and where it came from.
@internal
pub type LoadedAsset {
  LoadedAsset(asset: ClientAsset, source: AssetSource)
}

@internal
pub type AssetSource {
  /// The cached bundle was used: the stat data matched and is not racy.
  AssetCached
  /// The file was read and compressed, and the entry was (re)cached.
  AssetBuilt(reason: HashReason)
}

/// Load a client bundle through the asset cache. The file is stat-ed on
/// every call and re-read and re-compressed when its size, mtime, ctime,
/// inode or device changed, or when the cached entry was recorded within
/// two seconds of the file's last change (git's racy-clean rule, as for the
/// static digest cache), so a rebuilt bundle is never served stale and is
/// picked up without a restart.
pub fn load_client_asset(path: String) -> Result(ClientAsset, AssetError) {
  case load_client_asset_at(path, now_seconds()) {
    Ok(LoadedAsset(asset:, source: _)) -> Ok(asset)
    Error(reason) -> Error(reason)
  }
}

/// `load_client_asset` at time `now_seconds`. Tests pass their own time to
/// place an entry inside or outside the racy window.
@internal
pub fn load_client_asset_at(
  path: String,
  now_seconds: Int,
) -> Result(LoadedAsset, AssetError) {
  case ffi_load_asset(path, now_seconds) {
    Ok(LoadedAsset(source: AssetCached, ..) as loaded) -> Ok(loaded)
    Ok(LoadedAsset(source: AssetBuilt(reason), ..) as loaded) -> {
      log.debug(
        "brazier.static",
        "Client asset cache miss ("
          <> hash_reason_name(reason)
          <> "): "
          <> string.inspect(path),
      )
      Ok(loaded)
    }
    Error(AssetNotFound) -> {
      log.warning(
        "brazier.static",
        "Client asset not found: " <> string.inspect(path),
      )
      Error(AssetNotFound)
    }
    Error(AssetReadFailed(reason)) -> {
      log.error(
        "brazier.static",
        "Cannot read client asset " <> string.inspect(path) <> ": " <> reason,
      )
      Error(AssetReadFailed(reason))
    }
  }
}

/// Paths currently held by the client asset cache (at most 4).
@external(erlang, "brazier_asset_cache_ffi", "cached_paths")
pub fn cached_client_asset_paths() -> List(String)

@external(erlang, "brazier_asset_cache_ffi", "load")
fn ffi_load_asset(
  path: String,
  now_seconds: Int,
) -> Result(LoadedAsset, AssetError)

/// Check if a path contains directory traversal sequences.
/// Catches: "..", backslash, null bytes, and encoded traversal (%2e, %2f, %5c).
/// A percent-escape is ASCII, so the path is lowercased in ASCII only.
pub fn contains_traversal(path: String) -> Bool {
  let lower = ascii.lowercase(path)
  string.contains(path, "..")
  || string.contains(path, "\\")
  || string.contains(path, "\u{0000}")
  || string.contains(lower, "%2e")
  || string.contains(lower, "%2f")
  || string.contains(lower, "%5c")
  || string.contains(lower, "%00")
}

/// Determine MIME type from file extension.
pub fn mime_type(path: String) -> String {
  let ext = file_extension(path)
  case ext {
    "html" | "htm" -> "text/html; charset=utf-8"
    "css" -> "text/css; charset=utf-8"
    "js" | "mjs" -> "application/javascript; charset=utf-8"
    "json" | "map" -> "application/json; charset=utf-8"
    "png" -> "image/png"
    "jpg" | "jpeg" -> "image/jpeg"
    "gif" -> "image/gif"
    "svg" -> "image/svg+xml"
    "ico" -> "image/x-icon"
    "webp" -> "image/webp"
    "avif" -> "image/avif"
    "woff" -> "font/woff"
    "woff2" -> "font/woff2"
    "ttf" -> "font/ttf"
    "otf" -> "font/otf"
    "txt" -> "text/plain; charset=utf-8"
    "xml" -> "application/xml"
    "pdf" -> "application/pdf"
    "zip" -> "application/zip"
    "wasm" -> "application/wasm"
    _ -> "application/octet-stream"
  }
}

/// Extract the file extension of the last path segment, lowercased in ASCII,
/// or "" when the name has no extension ("Makefile", ".env", "dir/"). The
/// extensions `mime_type` knows are ASCII; a character outside ASCII is
/// kept as it is, so such an extension is unknown (and keeps its length
/// for `fingerprint`).
fn file_extension(path: String) -> String {
  let name = case list.last(string.split(path, "/")) {
    Ok(segment) -> segment
    Error(Nil) -> path
  }
  case string.split(name, ".") {
    // No dot, or a dotfile with no further extension.
    [_] | ["", _] -> ""
    parts ->
      case list.last(parts) {
        Ok(ext) -> ascii.lowercase(ext)
        Error(Nil) -> ""
      }
  }
}

/// Generate a fingerprinted filename for cache busting from the content
/// hash: "app.js" → "app-<16 hex>.js", "LICENSE" → "LICENSE-<16 hex>".
pub fn fingerprint(path: String, contents: BitArray) -> String {
  let hash = content_hash(contents, 16)
  case file_extension(path) {
    "" -> path <> "-" <> hash
    ext -> {
      let base = string.drop_end(path, string.length(ext) + 1)
      base <> "-" <> hash <> "." <> ext
    }
  }
}
