/// File uploads: bounded multipart/form-data reading, content sniffing
/// against an allow-list, collision-free storage and safe serving.
///
/// The client controls everything in a multipart request (the declared
/// Content-Type, the filename, the bytes), so nothing it says is trusted:
///
/// - A file's type is decided by its leading bytes (`sniff`), and must be in
///   the allow-list *and* agree with the declared Content-Type. A file whose
///   bytes match no supported signature is refused, so HTML, SVG and script
///   uploads cannot be stored, whatever they claim to be.
/// - Stored files get a random server-side name (`save`). The client's
///   filename is kept only as display metadata and never reaches the file
///   system. Files are created exclusively: an existing file is never
///   overwritten.
/// - `read_multipart` checks the declared Content-Length against
///   `max_request_bytes` before reading a single body byte, and reads exactly
///   that many bytes (chunked bodies are refused by the server), so a request
///   never buffers more than the cap. Each file is then held to `max_size`.
/// - `serve` answers with `Content-Disposition: attachment`, `nosniff` and a
///   sandboxing CSP, so a stored file is never rendered inline.
///
/// Patterns follow Plug.Upload (random names, exclusive create, an empty
/// filename means no file was chosen) and Phoenix `send_download`
/// (RFC 6266 attachment headers).
import brazier/internal/log_path
import brazier/log
import brazier/transport/http as transport_http
import brazier/transport/server.{type Connection, type ResponseBody, Bytes}
import gleam/bit_array
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// An uploaded file, as parsed from a multipart request.
pub type UploadedFile {
  UploadedFile(
    /// The client's filename, reduced to a display name (no directories,
    /// no control characters, at most 255 characters). Metadata only:
    /// never use it as a path.
    filename: String,
    /// The Content-Type the client declared for the part. Not trusted:
    /// `validate` compares it with the sniffed type.
    content_type: String,
    /// File contents as bytes.
    data: BitArray,
    /// File size in bytes.
    size: Int,
    /// The form field name the file was sent under.
    field_name: String,
  )
}

/// A parsed multipart form: text fields and validated files, in order.
pub type MultipartForm {
  MultipartForm(fields: List(#(String, String)), files: List(UploadedFile))
}

/// A file stored by `save`.
pub type StoredFile {
  StoredFile(
    /// Full path of the stored file.
    path: String,
    /// The random server-side name (`<32 hex>.<ext>`); pass it to `serve`.
    stored_name: String,
    /// The client's display name (metadata only).
    original_filename: String,
    /// The sniffed MIME type.
    content_type: String,
    /// Size in bytes.
    size: Int,
  )
}

/// A file type recognised by its signature (magic bytes).
pub type FileKind {
  Png
  Jpeg
  Gif
  Webp
  Pdf
}

/// Upload configuration.
pub type UploadConfig {
  UploadConfig(
    /// Maximum size of one file in bytes (default 10 MB).
    max_size: Int,
    /// Allowed MIME types. Each must be a supported kind (see `kind_mime`);
    /// an empty list allows nothing. Default: every supported kind.
    allowed_types: List(String),
    /// Maximum size of the whole multipart request body in bytes, checked
    /// against Content-Length before the body is read (default 11 MB).
    max_request_bytes: Int,
  )
}

/// Upload errors.
pub type UploadError {
  /// A file exceeds max size.
  FileTooLarge(max: Int, actual: Int)
  /// The sniffed type is not in the allow-list.
  TypeNotAllowed(content_type: String, allowed: List(String))
  /// No file was provided.
  NoFile
  /// The multipart body is malformed.
  ParseError(reason: String)
  /// The file's bytes match no supported signature.
  UnrecognizedContent(declared: String)
  /// The declared Content-Type disagrees with the file's bytes.
  ContentTypeMismatch(declared: String, detected: String)
  /// The client's filename cannot be used even as metadata.
  InvalidFilename(reason: String)
  /// The request is not multipart/form-data.
  NotMultipart(content_type: String)
  /// The declared request body exceeds `max_request_bytes`.
  RequestTooLarge(max: Int, actual: Int)
  /// The request body could not be read.
  BodyReadError(reason: String)
  /// Storing or reading a file failed.
  StorageError(reason: String)
  /// A stored name is not one `save` produced.
  InvalidStoredName(name: String)
  /// The upload configuration is invalid.
  InvalidConfig(reason: String)
}

const max_filename_length = 255

const max_boundary_length = 70

/// Every supported kind, in signature-check order.
pub fn supported_kinds() -> List(FileKind) {
  [Png, Jpeg, Gif, Webp, Pdf]
}

/// The canonical MIME type of a kind.
pub fn kind_mime(kind: FileKind) -> String {
  case kind {
    Png -> "image/png"
    Jpeg -> "image/jpeg"
    Gif -> "image/gif"
    Webp -> "image/webp"
    Pdf -> "application/pdf"
  }
}

/// The extension `save` gives a stored file of this kind.
pub fn kind_extension(kind: FileKind) -> String {
  case kind {
    Png -> "png"
    Jpeg -> "jpg"
    Gif -> "gif"
    Webp -> "webp"
    Pdf -> "pdf"
  }
}

/// Identify a file by its leading bytes.
pub fn sniff(data: BitArray) -> Result(FileKind, Nil) {
  case data {
    <<0x89, "PNG":utf8, 0x0D, 0x0A, 0x1A, 0x0A, _:bits>> -> Ok(Png)
    <<0xFF, 0xD8, 0xFF, _:bits>> -> Ok(Jpeg)
    <<"GIF87a":utf8, _:bits>> | <<"GIF89a":utf8, _:bits>> -> Ok(Gif)
    <<"RIFF":utf8, _:bytes-size(4), "WEBP":utf8, _:bits>> -> Ok(Webp)
    <<"%PDF-":utf8, _:bits>> -> Ok(Pdf)
    _ -> Error(Nil)
  }
}

/// Default upload config: 10 MB per file, 11 MB per request, every
/// supported kind allowed.
pub fn default_config() -> UploadConfig {
  UploadConfig(
    max_size: 10_485_760,
    allowed_types: list.map(supported_kinds(), kind_mime),
    max_request_bytes: 11_534_336,
  )
}

/// Set the maximum size of one file.
pub fn with_max_size(config: UploadConfig, bytes: Int) -> UploadConfig {
  UploadConfig(..config, max_size: bytes)
}

/// Set the allowed MIME types (each must be a supported kind).
pub fn with_allowed_types(
  config: UploadConfig,
  types: List(String),
) -> UploadConfig {
  UploadConfig(..config, allowed_types: types)
}

/// Set the maximum size of the whole multipart request body.
pub fn with_max_request_bytes(
  config: UploadConfig,
  bytes: Int,
) -> UploadConfig {
  UploadConfig(..config, max_request_bytes: bytes)
}

/// Check a configuration: positive limits and an allow-list of supported
/// MIME types only (a type that cannot be sniffed could never be accepted,
/// so listing one is a configuration bug).
pub fn validate_config(config: UploadConfig) -> Result(Nil, UploadError) {
  let supported = list.map(supported_kinds(), kind_mime)
  case
    config.max_size > 0,
    config.max_request_bytes > 0,
    list.find(config.allowed_types, fn(t) { !list.contains(supported, t) })
  {
    False, _, _ ->
      Error(InvalidConfig(
        "max_size must be positive, got " <> int.to_string(config.max_size),
      ))
    _, False, _ ->
      Error(InvalidConfig(
        "max_request_bytes must be positive, got "
        <> int.to_string(config.max_request_bytes),
      ))
    _, _, Ok(unsupported) ->
      Error(InvalidConfig(
        "allowed type "
        <> unsupported
        <> " cannot be verified by content; supported: "
        <> string.join(supported, ", "),
      ))
    True, True, Error(Nil) -> Ok(Nil)
  }
}

/// Validate an uploaded file: size, recognised content, declared type
/// agreeing with the content, and the sniffed type in the allow-list.
pub fn validate(
  file: UploadedFile,
  config: UploadConfig,
) -> Result(UploadedFile, UploadError) {
  use Nil <- result.try(validate_config(config))
  let size = bit_array.byte_size(file.data)
  let declared = media_type(file.content_type)
  let outcome = case size > config.max_size, sniff(file.data) {
    True, _ -> Error(FileTooLarge(max: config.max_size, actual: size))
    False, Error(Nil) -> Error(UnrecognizedContent(declared: file.content_type))
    False, Ok(kind) -> {
      let detected = kind_mime(kind)
      case declared == detected, list.contains(config.allowed_types, detected) {
        False, _ ->
          Error(ContentTypeMismatch(
            declared: file.content_type,
            detected: detected,
          ))
        True, False ->
          Error(TypeNotAllowed(
            content_type: detected,
            allowed: config.allowed_types,
          ))
        True, True -> Ok(UploadedFile(..file, size: size))
      }
    }
  }
  case outcome {
    Ok(_) -> Nil
    Error(error) ->
      log.warning(
        "brazier.upload",
        "Rejected upload field="
          <> string.inspect(file.field_name)
          <> " filename="
          <> string.inspect(file.filename)
          <> ": "
          <> error_to_string(error),
      )
  }
  outcome
}

/// Read and parse a multipart/form-data request, validating every file.
/// The Content-Type is checked before the body is touched, and the declared
/// Content-Length against `max_request_bytes` before any byte is read.
pub fn read_multipart(
  req: Request(Connection),
  config: UploadConfig,
) -> Result(MultipartForm, UploadError) {
  use Nil <- result.try(validate_config(config))
  let content_type = result.unwrap(request.get_header(req, "content-type"), "")
  use boundary <- result.try(boundary(content_type))
  use Nil <- result.try(check_declared_length(req, config.max_request_bytes))
  case transport_http.read_body(req, config.max_request_bytes) {
    Ok(body) -> parse_body(body, boundary, config)
    Error(reason) -> {
      log.warning(
        "brazier.upload",
        "Cannot read multipart body for "
          <> log_path.describe(req.path)
          <> ": "
          <> reason,
      )
      Error(BodyReadError(reason))
    }
  }
}

/// Parse an already-read multipart/form-data body, validating every file.
pub fn parse_multipart(
  body: BitArray,
  content_type: String,
  config: UploadConfig,
) -> Result(MultipartForm, UploadError) {
  use Nil <- result.try(validate_config(config))
  use boundary <- result.try(boundary(content_type))
  case bit_array.byte_size(body) > config.max_request_bytes {
    True ->
      Error(RequestTooLarge(
        max: config.max_request_bytes,
        actual: bit_array.byte_size(body),
      ))
    False -> parse_body(body, boundary, config)
  }
}

/// The first file sent under `field_name`.
pub fn file(
  form: MultipartForm,
  field_name: String,
) -> Result(UploadedFile, UploadError) {
  case list.find(form.files, fn(f) { f.field_name == field_name }) {
    Ok(found) -> Ok(found)
    Error(Nil) -> Error(NoFile)
  }
}

/// Store a file under a random name in `directory`. The file's content must
/// be a supported kind (it gives the extension). The file is created
/// exclusively, so nothing is ever overwritten. Call `validate` (or use
/// `read_multipart`) first to apply the allow-list and size limit.
pub fn save(
  file: UploadedFile,
  directory: String,
) -> Result(StoredFile, UploadError) {
  case sniff(file.data) {
    Error(Nil) -> {
      let error = UnrecognizedContent(declared: file.content_type)
      log.warning(
        "brazier.upload",
        "Refusing to store unrecognised content: " <> error_to_string(error),
      )
      Error(error)
    }
    Ok(kind) -> {
      let stored_name = random_token() <> "." <> kind_extension(kind)
      let path = directory <> "/" <> stored_name
      case write_new_file(path, file.data) {
        Ok(Nil) -> {
          log.info(
            "brazier.upload",
            "Stored upload "
              <> stored_name
              <> " ("
              <> int.to_string(bit_array.byte_size(file.data))
              <> " bytes, original "
              <> string.inspect(file.filename)
              <> ")",
          )
          Ok(StoredFile(
            path: path,
            stored_name: stored_name,
            original_filename: file.filename,
            content_type: kind_mime(kind),
            size: bit_array.byte_size(file.data),
          ))
        }
        Error(reason) -> {
          log.error(
            "brazier.upload",
            "Failed to store upload at " <> path <> ": " <> reason,
          )
          Error(StorageError("Failed to save " <> path <> ": " <> reason))
        }
      }
    }
  }
}

/// Serve a stored file as a download. `stored_name` must be a name `save`
/// produced (anything else, including traversal, is refused); the response
/// type comes from its extension, never from the request. The file is
/// always an attachment, with `nosniff` and a sandboxing CSP, so a browser
/// never renders it inline. `download_name` is the name the browser offers
/// (typically `StoredFile.original_filename`); it is reduced to a display
/// name and encoded per RFC 6266, and one with no usable name is refused.
pub fn serve(
  directory: String,
  stored_name: String,
  download_name: String,
) -> Result(Response(ResponseBody), UploadError) {
  use kind <- result.try(stored_name_kind(stored_name))
  use name <- result.try(case display_name(download_name) {
    Ok(name) -> Ok(name)
    Error(error) -> {
      log.warning(
        "brazier.upload",
        "Cannot serve " <> stored_name <> ": " <> error_to_string(error),
      )
      Error(error)
    }
  })
  let path = directory <> "/" <> stored_name
  case read_regular_file(path) {
    Ok(data) -> {
      log.debug("brazier.upload", "Serving stored upload " <> stored_name)
      Ok(
        response.new(200)
        |> response.set_header("content-type", kind_mime(kind))
        |> response.set_header("content-disposition", content_disposition(name))
        |> response.set_header("x-content-type-options", "nosniff")
        |> response.set_header(
          "content-security-policy",
          "default-src 'none'; sandbox",
        )
        |> response.set_header("cache-control", "private")
        |> response.set_body(Bytes(bytes_tree.from_bit_array(data))),
      )
    }
    Error(reason) -> {
      log.warning(
        "brazier.upload",
        "Cannot serve stored upload " <> path <> ": " <> reason,
      )
      Error(StorageError("Cannot read " <> path <> ": " <> reason))
    }
  }
}

/// The HTTP status that best describes an upload error.
pub fn error_status(error: UploadError) -> Int {
  case error {
    FileTooLarge(..) | RequestTooLarge(..) -> 413
    TypeNotAllowed(..)
    | UnrecognizedContent(..)
    | ContentTypeMismatch(..)
    | NotMultipart(..) -> 415
    NoFile
    | ParseError(..)
    | InvalidFilename(..)
    | BodyReadError(..)
    | InvalidStoredName(..) -> 400
    StorageError(..) | InvalidConfig(..) -> 500
  }
}

/// Describe an upload error.
pub fn error_to_string(error: UploadError) -> String {
  case error {
    FileTooLarge(max:, actual:) ->
      "file of "
      <> int.to_string(actual)
      <> " bytes exceeds the "
      <> int.to_string(max)
      <> " byte limit"
    TypeNotAllowed(content_type:, allowed:) ->
      "type "
      <> content_type
      <> " is not allowed (allowed: "
      <> string.join(allowed, ", ")
      <> ")"
    NoFile -> "no file provided"
    ParseError(reason:) -> "malformed multipart body: " <> reason
    UnrecognizedContent(declared:) ->
      "content matches no supported file type (declared "
      <> string.inspect(declared)
      <> ")"
    ContentTypeMismatch(declared:, detected:) ->
      "declared type "
      <> string.inspect(declared)
      <> " does not match the content ("
      <> detected
      <> ")"
    InvalidFilename(reason:) -> "invalid filename: " <> reason
    NotMultipart(content_type:) ->
      "expected multipart/form-data, got " <> string.inspect(content_type)
    RequestTooLarge(max:, actual:) ->
      "request body of "
      <> int.to_string(actual)
      <> " bytes exceeds the "
      <> int.to_string(max)
      <> " byte limit"
    BodyReadError(reason:) -> "cannot read request body: " <> reason
    StorageError(reason:) -> reason
    InvalidStoredName(name:) ->
      "not a stored upload name: " <> string.inspect(name)
    InvalidConfig(reason:) -> "invalid upload config: " <> reason
  }
}

/// Get the file extension from a filename.
pub fn extension(filename: String) -> Option(String) {
  case string.split(filename, ".") {
    [_] -> None
    parts ->
      case list.last(parts) {
        Ok(ext) -> Some(string.lowercase(ext))
        Error(Nil) -> None
      }
  }
}

/// Format file size for display.
pub fn format_size(bytes: Int) -> String {
  case bytes {
    b if b < 1024 -> int.to_string(b) <> " B"
    b if b < 1_048_576 -> int.to_string(b / 1024) <> " KB"
    b -> int.to_string(b / 1_048_576) <> " MB"
  }
}

// --- Request framing ---

fn check_declared_length(
  req: Request(Connection),
  max: Int,
) -> Result(Nil, UploadError) {
  case request.get_header(req, "content-length") {
    Ok(value) ->
      case int.parse(string.trim(value)) {
        Ok(length) if length > max -> {
          log.warning(
            "brazier.upload",
            "Multipart body of "
              <> int.to_string(length)
              <> " bytes exceeds the "
              <> int.to_string(max)
              <> " byte limit on "
              <> req.path,
          )
          Error(RequestTooLarge(max: max, actual: length))
        }
        // An unparseable or missing length is refused by read_body itself.
        _ -> Ok(Nil)
      }
    Error(Nil) -> Ok(Nil)
  }
}

/// Extract and check the boundary of a multipart/form-data Content-Type.
fn boundary(content_type: String) -> Result(String, UploadError) {
  case media_type(content_type) == "multipart/form-data" {
    False -> {
      log.warning(
        "brazier.upload",
        "Refusing non-multipart upload body: " <> string.inspect(content_type),
      )
      Error(NotMultipart(content_type))
    }
    True -> {
      let outcome = case parse_header_params(content_type) {
        Error(reason) -> Error(ParseError("Content-Type: " <> reason))
        Ok(#(_, params)) ->
          case list.key_find(params, "boundary") {
            Error(Nil) -> Error(ParseError("no boundary in Content-Type"))
            Ok(boundary) -> check_boundary(boundary)
          }
      }
      case outcome {
        Ok(_) -> Nil
        Error(error) ->
          log.warning(
            "brazier.upload",
            "Refusing multipart body: " <> error_to_string(error),
          )
      }
      outcome
    }
  }
}

/// RFC 2046 section 5.1.1: 1 to 70 bchars, not ending in a space.
fn check_boundary(boundary: String) -> Result(String, UploadError) {
  let length = string.length(boundary)
  let valid_chars =
    string.to_utf_codepoints(boundary)
    |> list.all(fn(cp) { is_bchar(string.utf_codepoint_to_int(cp)) })
  case
    length >= 1
    && length <= max_boundary_length
    && valid_chars
    && !string.ends_with(boundary, " ")
  {
    True -> Ok(boundary)
    False -> Error(ParseError("invalid boundary " <> string.inspect(boundary)))
  }
}

fn is_bchar(c: Int) -> Bool {
  { c >= 0x30 && c <= 0x39 }
  || { c >= 0x41 && c <= 0x5A }
  || { c >= 0x61 && c <= 0x7A }
  || list.contains([0x27, 0x28, 0x29, 0x2B, 0x5F, 0x2C, 0x2D, 0x2E], c)
  || list.contains([0x2F, 0x3A, 0x3D, 0x3F, 0x20], c)
}

/// Split the body into parts (RFC 2046 section 5.1.1). Each delimiter is
/// CRLF "--" boundary; the body's own leading delimiter has its CRLF
/// supplied here. A body without its close delimiter is truncated.
fn parse_body(
  body: BitArray,
  boundary: String,
  config: UploadConfig,
) -> Result(MultipartForm, UploadError) {
  let delimiter = <<"\r\n--":utf8, boundary:utf8>>
  case binary_split(<<"\r\n":utf8, body:bits>>, delimiter) {
    // The preamble before the first delimiter is ignored (RFC 2046).
    [_preamble, ..segments] -> parse_segments(segments, config, [], [])
    [] -> Error(ParseError("empty body"))
  }
}

fn parse_segments(
  segments: List(BitArray),
  config: UploadConfig,
  fields: List(#(String, String)),
  files: List(UploadedFile),
) -> Result(MultipartForm, UploadError) {
  case segments {
    [] -> {
      log.warning("brazier.upload", "Multipart body has no closing boundary")
      Error(ParseError("missing closing boundary"))
    }
    // The close delimiter; whatever follows is the ignored epilogue.
    [<<"--":utf8, _:bits>>, ..] -> {
      let form =
        MultipartForm(fields: list.reverse(fields), files: list.reverse(files))
      log.debug(
        "brazier.upload",
        "Parsed multipart form: "
          <> int.to_string(list.length(form.fields))
          <> " fields, "
          <> int.to_string(list.length(form.files))
          <> " files",
      )
      Ok(form)
    }
    [<<"\r\n":utf8, part:bits>>, ..rest] ->
      case parse_part(part) {
        Error(error) -> {
          log.warning(
            "brazier.upload",
            "Rejected multipart part: " <> error_to_string(error),
          )
          Error(error)
        }
        Ok(Field(name, value)) ->
          parse_segments(rest, config, [#(name, value), ..fields], files)
        Ok(EmptyFile(name)) -> {
          log.debug(
            "brazier.upload",
            "Field "
              <> string.inspect(name)
              <> " has no file chosen; skipping it",
          )
          parse_segments(rest, config, fields, files)
        }
        Ok(FilePart(file)) ->
          case validate(file, config) {
            Ok(file) -> parse_segments(rest, config, fields, [file, ..files])
            Error(error) -> Error(error)
          }
      }
    [_, ..] -> {
      log.warning("brazier.upload", "Multipart boundary not followed by CRLF")
      Error(ParseError("boundary is not followed by CRLF"))
    }
  }
}

type Part {
  Field(name: String, value: String)
  FilePart(UploadedFile)
  EmptyFile(name: String)
}

fn parse_part(part: BitArray) -> Result(Part, UploadError) {
  use #(header_bytes, data) <- result.try(
    case binary_split_once(part, <<"\r\n\r\n":utf8>>) {
      Ok(split) -> Ok(split)
      Error(Nil) ->
        case part {
          // A part with no headers at all starts with the blank line.
          <<"\r\n":utf8, data:bits>> -> Ok(#(<<>>, data))
          _ -> Error(ParseError("part headers are not terminated"))
        }
    },
  )
  use header_text <- result.try(
    bit_array.to_string(header_bytes)
    |> result.replace_error(ParseError("part headers are not UTF-8")),
  )
  use headers <- result.try(parse_part_headers(header_text))
  use disposition <- result.try(
    case list.key_find(headers, "content-disposition") {
      Ok(value) -> Ok(value)
      Error(Nil) -> Error(ParseError("part has no Content-Disposition"))
    },
  )
  use #(kind, params) <- result.try(
    parse_header_params(disposition)
    |> result.map_error(fn(reason) {
      ParseError("Content-Disposition: " <> reason)
    }),
  )
  use name <- result.try(
    case string.lowercase(kind), list.key_find(params, "name") {
      "form-data", Ok(name) -> Ok(name)
      "form-data", Error(Nil) -> Error(ParseError("part has no name"))
      _, _ -> Error(ParseError("part disposition is not form-data"))
    },
  )
  case list.key_find(params, "filename") {
    Error(Nil) ->
      case bit_array.to_string(data) {
        Ok(value) -> Ok(Field(name, value))
        Error(Nil) ->
          Error(ParseError("field " <> string.inspect(name) <> " is not UTF-8"))
      }
    // An empty filename is a file input with nothing chosen (Plug skips it).
    Ok("") -> Ok(EmptyFile(name))
    Ok(raw_filename) -> {
      use filename <- result.try(display_name(raw_filename))
      // RFC 7578 section 4.4: a part without Content-Type is text/plain.
      let content_type =
        result.unwrap(list.key_find(headers, "content-type"), "text/plain")
      Ok(
        FilePart(UploadedFile(
          filename: filename,
          content_type: content_type,
          data: data,
          size: bit_array.byte_size(data),
          field_name: name,
        )),
      )
    }
  }
}

/// Parse "Name: value" lines into lower-cased names. Duplicates of the
/// headers that decide how a part is read are ambiguous and refused.
fn parse_part_headers(
  text: String,
) -> Result(List(#(String, String)), UploadError) {
  let lines = case text {
    "" -> []
    _ -> string.split(text, "\r\n")
  }
  use headers <- result.try(
    list.try_map(lines, fn(line) {
      case string.split_once(line, ":") {
        Ok(#(name, value)) -> Ok(#(string.lowercase(name), string.trim(value)))
        Error(Nil) ->
          Error(ParseError("malformed part header " <> string.inspect(line)))
      }
    }),
  )
  let duplicated =
    list.find(["content-disposition", "content-type"], fn(name) {
      list.count(headers, fn(h) { h.0 == name }) > 1
    })
  case duplicated {
    Ok(name) -> Error(ParseError("duplicate " <> name <> " part header"))
    Error(Nil) -> Ok(headers)
  }
}

/// Parse `value; key=token; key="quoted"` into the value and lower-cased
/// parameter names. Quoted values end at the next quote: browsers
/// percent-encode quotes in filenames (HTML form submission) and send
/// backslashes literally.
fn parse_header_params(
  header: String,
) -> Result(#(String, List(#(String, String))), String) {
  case string.split_once(header, ";") {
    Error(Nil) -> Ok(#(string.trim(header), []))
    Ok(#(value, rest)) ->
      parse_params(rest, [])
      |> result.map(fn(params) { #(string.trim(value), params) })
  }
}

fn parse_params(
  rest: String,
  acc: List(#(String, String)),
) -> Result(List(#(String, String)), String) {
  case string.trim_start(rest) {
    "" -> Ok(list.reverse(acc))
    trimmed ->
      case string.split_once(trimmed, "=") {
        Error(Nil) -> Error("malformed parameter " <> string.inspect(trimmed))
        Ok(#(key, after)) -> {
          let key = string.lowercase(string.trim(key))
          case string.trim_start(after) {
            "\"" <> quoted ->
              case string.split_once(quoted, "\"") {
                Error(Nil) ->
                  Error("unterminated quoted parameter " <> string.inspect(key))
                Ok(#(value, tail)) ->
                  case string.trim_start(tail) {
                    "" -> Ok(list.reverse([#(key, value), ..acc]))
                    ";" <> more -> parse_params(more, [#(key, value), ..acc])
                    _ ->
                      Error(
                        "garbage after quoted parameter " <> string.inspect(key),
                      )
                  }
              }
            unquoted ->
              case string.split_once(unquoted, ";") {
                Ok(#(value, more)) ->
                  parse_params(more, [#(key, string.trim(value)), ..acc])
                Error(Nil) ->
                  Ok(list.reverse([#(key, string.trim(unquoted)), ..acc]))
              }
          }
        }
      }
  }
}

/// The media type of a Content-Type value, lower-cased, without parameters.
fn media_type(content_type: String) -> String {
  case string.split_once(content_type, ";") {
    Ok(#(media, _)) -> media
    Error(Nil) -> content_type
  }
  |> string.trim
  |> string.lowercase
}

// --- Names ---

/// Reduce a client filename to display metadata: the last path segment
/// (either separator), without control characters, at most 255 characters.
fn display_name(raw: String) -> Result(String, UploadError) {
  let base = case list.last(string.split(string.replace(raw, "\\", "/"), "/")) {
    Ok(segment) -> segment
    Error(Nil) -> raw
  }
  let cleaned =
    base
    |> string.to_utf_codepoints
    |> list.filter(fn(cp) {
      let c = string.utf_codepoint_to_int(cp)
      c >= 0x20 && c != 0x7F
    })
    |> string.from_utf_codepoints
    |> string.trim
    |> string.slice(0, max_filename_length)
  case cleaned {
    "" | "." | ".." ->
      Error(InvalidFilename(
        "no usable name in " <> string.inspect(raw) <> " after sanitizing",
      ))
    name -> Ok(name)
  }
}

/// The kind of a name `save` produced: 32 lower-case hex digits, a dot and
/// a supported extension. Everything else is refused.
fn stored_name_kind(name: String) -> Result(FileKind, UploadError) {
  let refuse = fn() {
    log.warning(
      "brazier.upload",
      "Refusing to serve non-stored name " <> string.inspect(name),
    )
    Error(InvalidStoredName(name))
  }
  case string.split(name, ".") {
    [token, ext] ->
      case
        string.length(token) == 32
        && list.all(string.to_graphemes(token), is_hex),
        list.find(supported_kinds(), fn(k) { kind_extension(k) == ext })
      {
        True, Ok(kind) -> Ok(kind)
        _, _ -> refuse()
      }
    _ -> refuse()
  }
}

fn is_hex(grapheme: String) -> Bool {
  string.contains("0123456789abcdef", grapheme) && grapheme != ""
}

/// RFC 6266 attachment header: an ASCII `filename` and the exact UTF-8
/// name in `filename*` (RFC 8187), as Phoenix `send_download` does.
/// `name` is already a display name (see `display_name`).
fn content_disposition(name: String) -> String {
  "attachment; filename=\""
  <> ascii_name(name)
  <> "\"; filename*=UTF-8''"
  <> rfc8187_encode(<<name:utf8>>, "")
}

fn ascii_name(name: String) -> String {
  string.to_utf_codepoints(name)
  |> list.map(fn(cp) {
    let c = string.utf_codepoint_to_int(cp)
    case c >= 0x20 && c < 0x7F && c != 0x22 && c != 0x5C {
      True -> string.from_utf_codepoints([cp])
      False -> "_"
    }
  })
  |> string.concat
}

/// Percent-encode every byte outside RFC 8187 attr-char.
fn rfc8187_encode(bytes: BitArray, acc: String) -> String {
  case bytes {
    <<byte, rest:bytes>> -> {
      let keep =
        { byte >= 0x30 && byte <= 0x39 }
        || { byte >= 0x41 && byte <= 0x5A }
        || { byte >= 0x61 && byte <= 0x7A }
        || list.contains([0x21, 0x23, 0x24, 0x26, 0x2B, 0x2D, 0x2E], byte)
        || list.contains([0x5E, 0x5F, 0x60, 0x7C, 0x7E], byte)
      let encoded = case keep {
        True -> {
          let assert Ok(text) = bit_array.to_string(<<byte>>)
            as "an ASCII attr-char byte is valid UTF-8"
          text
        }
        False -> "%" <> string.pad_start(int.to_base16(byte), 2, "0")
      }
      rfc8187_encode(rest, acc <> encoded)
    }
    _ -> acc
  }
}

@external(erlang, "brazier_upload_ffi", "random_token")
fn random_token() -> String

@external(erlang, "brazier_upload_ffi", "write_new_file")
fn write_new_file(path: String, data: BitArray) -> Result(Nil, String)

@external(erlang, "brazier_upload_ffi", "read_regular_file")
fn read_regular_file(path: String) -> Result(BitArray, String)

@external(erlang, "brazier_upload_ffi", "binary_split")
fn binary_split(data: BitArray, separator: BitArray) -> List(BitArray)

@external(erlang, "brazier_upload_ffi", "binary_split_once")
fn binary_split_once(
  data: BitArray,
  separator: BitArray,
) -> Result(#(BitArray, BitArray), Nil)
