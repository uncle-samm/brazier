import beacon/transport/server
import beacon/upload
import gleam/bit_array
import gleam/bytes_tree
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- Fixtures ---

fn png_bytes() -> BitArray {
  <<0x89, "PNG":utf8, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR":utf8>>
}

fn jpeg_bytes() -> BitArray {
  <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF":utf8>>
}

fn html_bytes() -> BitArray {
  <<"<html><script>alert(document.cookie)</script></html>":utf8>>
}

fn svg_bytes() -> BitArray {
  <<"<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"alert(1)\"/>":utf8>>
}

fn file_of(data: BitArray, content_type: String) -> upload.UploadedFile {
  upload.UploadedFile(
    filename: "photo.png",
    content_type: content_type,
    data: data,
    size: bit_array.byte_size(data),
    field_name: "file",
  )
}

fn png_file() -> upload.UploadedFile {
  file_of(png_bytes(), "image/png")
}

// --- Sniffing ---

pub fn sniff_recognises_supported_kinds_test() {
  let assert Ok(upload.Png) = upload.sniff(png_bytes())
  let assert Ok(upload.Jpeg) = upload.sniff(jpeg_bytes())
  let assert Ok(upload.Gif) = upload.sniff(<<"GIF89a":utf8, 1, 0>>)
  let assert Ok(upload.Gif) = upload.sniff(<<"GIF87a":utf8>>)
  let assert Ok(upload.Webp) =
    upload.sniff(<<"RIFF":utf8, 36, 0, 0, 0, "WEBPVP8 ":utf8>>)
  let assert Ok(upload.Pdf) = upload.sniff(<<"%PDF-1.7\n":utf8>>)
}

pub fn sniff_refuses_markup_and_truncated_signatures_test() {
  let assert Error(Nil) = upload.sniff(html_bytes())
  let assert Error(Nil) = upload.sniff(svg_bytes())
  let assert Error(Nil) = upload.sniff(<<>>)
  let assert Error(Nil) = upload.sniff(<<0x89, "PNG":utf8>>)
  let assert Error(Nil) = upload.sniff(<<"RIFF":utf8, 0, 0, 0, 0, "WAVE":utf8>>)
  let assert Error(Nil) = upload.sniff(<<"GIF88a":utf8>>)
}

// --- Validation ---

pub fn validate_ok_test() {
  let assert Ok(file) = upload.validate(png_file(), upload.default_config())
  let assert 16 = file.size
}

pub fn validate_recomputes_a_lying_size_test() {
  let file = upload.UploadedFile(..png_file(), size: 1)
  let config = upload.default_config() |> upload.with_max_size(10)
  let assert Error(upload.FileTooLarge(max: 10, actual: 16)) =
    upload.validate(file, config)
}

pub fn validate_too_large_test() {
  let config = upload.default_config() |> upload.with_max_size(3)
  let assert Error(upload.FileTooLarge(max: 3, actual: 16)) =
    upload.validate(png_file(), config)
}

pub fn validate_type_allowed_test() {
  let config =
    upload.default_config()
    |> upload.with_allowed_types(["image/png", "image/jpeg"])
  let assert Ok(_) = upload.validate(png_file(), config)
}

pub fn validate_type_not_allowed_test() {
  let config =
    upload.default_config()
    |> upload.with_allowed_types(["application/pdf"])
  let assert Error(upload.TypeNotAllowed(content_type: "image/png", ..)) =
    upload.validate(png_file(), config)
}

pub fn validate_empty_allow_list_allows_nothing_test() {
  let config = upload.default_config() |> upload.with_allowed_types([])
  let assert Error(upload.TypeNotAllowed(..)) =
    upload.validate(png_file(), config)
}

pub fn validate_rejects_html_claiming_to_be_png_test() {
  let assert Error(upload.UnrecognizedContent(declared: "image/png")) =
    upload.validate(file_of(html_bytes(), "image/png"), upload.default_config())
}

pub fn validate_rejects_svg_test() {
  let assert Error(upload.UnrecognizedContent(..)) =
    upload.validate(
      file_of(svg_bytes(), "image/svg+xml"),
      upload.default_config(),
    )
}

pub fn validate_rejects_declared_type_disagreeing_with_content_test() {
  let assert Error(upload.ContentTypeMismatch(
    declared: "image/gif",
    detected: "image/png",
  )) =
    upload.validate(file_of(png_bytes(), "image/gif"), upload.default_config())
  // A JPEG renamed and declared as PNG.
  let assert Error(upload.ContentTypeMismatch(detected: "image/jpeg", ..)) =
    upload.validate(file_of(jpeg_bytes(), "image/png"), upload.default_config())
  let assert Error(upload.ContentTypeMismatch(..)) =
    upload.validate(
      file_of(png_bytes(), "application/octet-stream"),
      upload.default_config(),
    )
}

pub fn validate_declared_type_ignores_case_and_parameters_test() {
  let assert Ok(_) =
    upload.validate(
      file_of(png_bytes(), " IMAGE/PNG; name=x"),
      upload.default_config(),
    )
}

pub fn validate_config_refuses_unverifiable_types_test() {
  let config =
    upload.default_config()
    |> upload.with_allowed_types(["image/png", "text/html"])
  let assert Error(upload.InvalidConfig(_)) = upload.validate_config(config)
  let assert Error(upload.InvalidConfig(_)) =
    upload.validate(png_file(), config)
  let assert Error(upload.InvalidConfig(_)) =
    upload.validate_config(upload.default_config() |> upload.with_max_size(0))
  let assert Error(upload.InvalidConfig(_)) =
    upload.validate_config(
      upload.default_config() |> upload.with_max_request_bytes(-1),
    )
  let assert Ok(Nil) = upload.validate_config(upload.default_config())
}

// --- Saving ---

pub fn save_uses_a_random_name_and_keeps_the_original_as_metadata_test() {
  let dir = fresh_dir()
  let file = upload.UploadedFile(..png_file(), filename: "../../etc/passwd")
  let assert Ok(stored) = upload.save(file, dir)
  let assert True = stored.path == dir <> "/" <> stored.stored_name
  let assert [token, "png"] = string.split(stored.stored_name, ".")
  let assert 32 = string.length(token)
  let assert "../../etc/passwd" = stored.original_filename
  let assert "image/png" = stored.content_type
  let assert 16 = stored.size
  let assert Ok(written) = read_file(stored.path)
  let assert True = written == png_bytes()
  let assert [_] = list_dir(dir)
  remove_dir(dir)
}

pub fn save_never_reuses_a_name_test() {
  let dir = fresh_dir()
  let assert Ok(first) = upload.save(png_file(), dir)
  let assert Ok(second) = upload.save(png_file(), dir)
  let assert True = first.stored_name != second.stored_name
  let assert 2 = list.length(list_dir(dir))
  remove_dir(dir)
}

pub fn save_extension_comes_from_content_not_the_filename_test() {
  let dir = fresh_dir()
  let file =
    upload.UploadedFile(
      ..file_of(jpeg_bytes(), "image/jpeg"),
      filename: "evil.html",
    )
  let assert Ok(stored) = upload.save(file, dir)
  let assert True = string.ends_with(stored.stored_name, ".jpg")
  remove_dir(dir)
}

pub fn save_refuses_unrecognised_content_test() {
  let dir = fresh_dir()
  let assert Error(upload.UnrecognizedContent(..)) =
    upload.save(file_of(html_bytes(), "image/png"), dir)
  let assert [] = list_dir(dir)
  remove_dir(dir)
}

pub fn save_into_a_missing_directory_fails_loudly_test() {
  let dir = fresh_dir()
  let assert Error(upload.StorageError(_)) =
    upload.save(png_file(), dir <> "/missing")
  remove_dir(dir)
}

pub fn save_refuses_a_traversing_directory_test() {
  let dir = fresh_dir()
  let assert Error(upload.StorageError(_)) =
    upload.save(png_file(), dir <> "/../" <> "x")
  remove_dir(dir)
}

pub fn exclusive_create_never_overwrites_test() {
  let dir = fresh_dir()
  let path = dir <> "/existing.png"
  write_file(path, <<"original":utf8>>)
  let assert Error(_) = write_new_file(path, png_bytes())
  let assert Ok(<<"original":utf8>>) = read_file(path)
  // A planted symlink is not followed either.
  let target = dir <> "/target"
  write_file(target, <<"target":utf8>>)
  make_symlink(target, dir <> "/link.png")
  let assert Error(_) = write_new_file(dir <> "/link.png", png_bytes())
  let assert Ok(<<"target":utf8>>) = read_file(target)
  remove_dir(dir)
}

// --- Serving ---

pub fn serve_is_an_attachment_with_nosniff_test() {
  let dir = fresh_dir()
  let assert Ok(stored) = upload.save(png_file(), dir)
  let assert Ok(resp) = upload.serve(dir, stored.stored_name, "photo.png")
  let assert 200 = resp.status
  let assert Ok("image/png") = response.get_header(resp, "content-type")
  let assert Ok(
    "attachment; filename=\"photo.png\"; filename*=UTF-8''photo.png",
  ) = response.get_header(resp, "content-disposition")
  let assert Ok("nosniff") = response.get_header(resp, "x-content-type-options")
  let assert Ok("default-src 'none'; sandbox") =
    response.get_header(resp, "content-security-policy")
  let assert True = body_of(resp) == png_bytes()
  remove_dir(dir)
}

pub fn serve_encodes_the_download_name_test() {
  let dir = fresh_dir()
  let assert Ok(stored) = upload.save(png_file(), dir)
  let assert Ok(resp) =
    upload.serve(
      dir,
      stored.stored_name,
      "C:\\docs\\r\u{e9}sum\u{e9} \"x\";\r\n.png",
    )
  let assert Ok(disposition) = response.get_header(resp, "content-disposition")
  let assert "attachment; filename=\"r_sum_ _x_;.png\"; filename*=UTF-8''r%C3%A9sum%C3%A9%20%22x%22%3B.png" =
    disposition
  remove_dir(dir)
}

pub fn serve_refuses_names_save_did_not_produce_test() {
  let dir = fresh_dir()
  let hex = "0123456789abcdef0123456789abcdef"
  write_file(dir <> "/" <> hex <> ".html", html_bytes())
  write_file(dir <> "/" <> hex <> ".svg", svg_bytes())
  list.each(
    [
      "../" <> hex <> ".png",
      hex <> ".html",
      hex <> ".svg",
      hex <> ".png.html",
      "0123456789ABCDEF0123456789abcdef.png",
      "short.png",
      hex,
      "",
    ],
    fn(name) {
      let assert Error(upload.InvalidStoredName(_)) =
        upload.serve(dir, name, "x.png")
    },
  )
  remove_dir(dir)
}

pub fn serve_refuses_missing_files_and_symlinks_test() {
  let dir = fresh_dir()
  let hex = "0123456789abcdef0123456789abcdef"
  let assert Error(upload.StorageError(_)) =
    upload.serve(dir, hex <> ".png", "x.png")
  write_file(dir <> "/secret", <<"secret":utf8>>)
  make_symlink(dir <> "/secret", dir <> "/" <> hex <> ".pdf")
  let assert Error(upload.StorageError(_)) =
    upload.serve(dir, hex <> ".pdf", "x.pdf")
  remove_dir(dir)
}

pub fn serve_refuses_an_unusable_download_name_test() {
  let dir = fresh_dir()
  let assert Ok(stored) = upload.save(png_file(), dir)
  let assert Error(upload.InvalidFilename(_)) =
    upload.serve(dir, stored.stored_name, "a/")
  remove_dir(dir)
}

// --- Multipart parsing ---

const boundary = "----TestBoundary123"

fn content_type() -> String {
  "multipart/form-data; boundary=" <> boundary
}

fn file_part(name: String, filename: String, ctype: String, data: BitArray) {
  <<
    "--":utf8,
    boundary:utf8,
    "\r\nContent-Disposition: form-data; name=\"":utf8,
    name:utf8,
    "\"; filename=\"":utf8,
    filename:utf8,
    "\"\r\nContent-Type: ":utf8,
    ctype:utf8,
    "\r\n\r\n":utf8,
    data:bits,
    "\r\n":utf8,
  >>
}

fn field_part(name: String, value: String) -> BitArray {
  <<
    "--":utf8,
    boundary:utf8,
    "\r\nContent-Disposition: form-data; name=\"":utf8,
    name:utf8,
    "\"\r\n\r\n":utf8,
    value:utf8,
    "\r\n":utf8,
  >>
}

fn close() -> BitArray {
  <<"--":utf8, boundary:utf8, "--\r\n":utf8>>
}

fn parse(body: BitArray) {
  upload.parse_multipart(body, content_type(), upload.default_config())
}

pub fn parse_multipart_not_multipart_test() {
  let assert Error(upload.NotMultipart("application/json")) =
    upload.parse_multipart(<<>>, "application/json", upload.default_config())
  let assert Error(upload.NotMultipart(_)) =
    upload.parse_multipart(
      <<>>,
      "text/plain; x=multipart/form-data",
      upload.default_config(),
    )
}

pub fn parse_multipart_no_boundary_test() {
  let assert Error(upload.ParseError(..)) =
    upload.parse_multipart(<<>>, "multipart/form-data", upload.default_config())
}

pub fn parse_multipart_invalid_boundary_test() {
  let assert Error(upload.ParseError(..)) =
    upload.parse_multipart(
      close(),
      "multipart/form-data; boundary=" <> string.repeat("a", 71),
      upload.default_config(),
    )
  let assert Error(upload.ParseError(..)) =
    upload.parse_multipart(
      close(),
      "multipart/form-data; boundary=a<b",
      upload.default_config(),
    )
}

pub fn parse_multipart_binary_safe_test() {
  let body = <<
    file_part("file", "test.png", "image/png", png_bytes()):bits,
    close():bits,
  >>
  let assert Ok(upload.MultipartForm(fields: [], files: [file])) = parse(body)
  let assert "test.png" = file.filename
  let assert "image/png" = file.content_type
  let assert "file" = file.field_name
  let assert 16 = file.size
  let assert True = file.data == png_bytes()
}

pub fn parse_multipart_keeps_data_ending_in_crlf_test() {
  let data = <<png_bytes():bits, "\r\n\r\n":utf8>>
  let body = <<
    file_part("file", "a.png", "image/png", data):bits,
    close():bits,
  >>
  let assert Ok(upload.MultipartForm(files: [file], ..)) = parse(body)
  let assert True = file.data == data
}

pub fn parse_multipart_fields_and_files_in_order_test() {
  let body = <<
    "preamble to ignore\r\n":utf8,
    field_part("csrf", "tok"):bits,
    file_part("a", "a.png", "image/png", png_bytes()):bits,
    field_part("title", "Caf\u{e9}"):bits,
    file_part("b", "b.jpg", "image/jpeg", jpeg_bytes()):bits,
    close():bits,
    "epilogue":utf8,
  >>
  let assert Ok(form) = parse(body)
  let assert [#("csrf", "tok"), #("title", "Caf\u{e9}")] = form.fields
  let assert [a, b] = form.files
  let assert "a" = a.field_name
  let assert "b" = b.field_name
  let assert Ok(found) = upload.file(form, "b")
  let assert "b.jpg" = found.filename
  let assert Error(upload.NoFile) = upload.file(form, "missing")
}

pub fn parse_multipart_skips_an_empty_file_input_test() {
  let body = <<
    file_part("file", "", "application/octet-stream", <<>>):bits,
    close():bits,
  >>
  let assert Ok(upload.MultipartForm(fields: [], files: [])) = parse(body)
}

pub fn parse_multipart_rejects_a_fake_content_type_test() {
  let body = <<
    file_part("file", "x.png", "image/png", html_bytes()):bits,
    close():bits,
  >>
  let assert Error(upload.UnrecognizedContent(declared: "image/png")) =
    parse(body)
}

pub fn parse_multipart_defaults_part_type_to_text_plain_test() {
  let body = <<
    "--":utf8,
    boundary:utf8,
    "\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.png\"\r\n\r\n":utf8,
    png_bytes():bits,
    "\r\n":utf8,
    close():bits,
  >>
  let assert Error(upload.ContentTypeMismatch(declared: "text/plain", ..)) =
    parse(body)
}

pub fn parse_multipart_reduces_filenames_to_display_names_test() {
  let body = <<
    file_part("f", "../../etc/pass\u{0001}wd.png", "image/png", png_bytes()):bits,
    close():bits,
  >>
  let assert Ok(upload.MultipartForm(files: [file], ..)) = parse(body)
  let assert "passwd.png" = file.filename
  let windows = <<
    file_part("f", "C:\\Users\\me\\a.png", "image/png", png_bytes()):bits,
    close():bits,
  >>
  let assert Ok(upload.MultipartForm(files: [file], ..)) = parse(windows)
  let assert "a.png" = file.filename
  let long = <<
    file_part("f", string.repeat("a", 300), "image/png", png_bytes()):bits,
    close():bits,
  >>
  let assert Ok(upload.MultipartForm(files: [file], ..)) = parse(long)
  let assert 255 = string.length(file.filename)
}

pub fn parse_multipart_rejects_filenames_with_no_usable_name_test() {
  list.each(["/", "..", "a/..", "\u{0001}"], fn(name) {
    let body = <<
      file_part("f", name, "image/png", png_bytes()):bits,
      close():bits,
    >>
    let assert Error(upload.InvalidFilename(_)) = parse(body)
  })
}

pub fn parse_multipart_rejects_malformed_bodies_test() {
  let truncated = file_part("f", "a.png", "image/png", png_bytes())
  let assert Error(upload.ParseError("missing closing boundary")) =
    parse(truncated)
  let no_crlf = <<"--":utf8, boundary:utf8, "garbage":utf8, close():bits>>
  let assert Error(upload.ParseError(..)) = parse(no_crlf)
  let no_disposition = <<
    "--":utf8,
    boundary:utf8,
    "\r\nContent-Type: image/png\r\n\r\nx\r\n":utf8,
    close():bits,
  >>
  let assert Error(upload.ParseError(..)) = parse(no_disposition)
  let not_form_data = <<
    "--":utf8,
    boundary:utf8,
    "\r\nContent-Disposition: attachment; name=\"a\"\r\n\r\nx\r\n":utf8,
    close():bits,
  >>
  let assert Error(upload.ParseError(..)) = parse(not_form_data)
  let unnamed = <<
    "--":utf8,
    boundary:utf8,
    "\r\nContent-Disposition: form-data\r\n\r\nx\r\n":utf8,
    close():bits,
  >>
  let assert Error(upload.ParseError(..)) = parse(unnamed)
  let unterminated_quote = <<
    "--":utf8,
    boundary:utf8,
    "\r\nContent-Disposition: form-data; name=\"a\r\n\r\nx\r\n":utf8,
    close():bits,
  >>
  let assert Error(upload.ParseError(..)) = parse(unterminated_quote)
  let duplicate_type = <<
    "--":utf8,
    boundary:utf8,
    "\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.png\"\r\nContent-Type: image/png\r\nContent-Type: text/html\r\n\r\n":utf8,
    png_bytes():bits,
    "\r\n":utf8,
    close():bits,
  >>
  let assert Error(upload.ParseError(..)) = parse(duplicate_type)
  let binary_field = <<
    "--":utf8,
    boundary:utf8,
    "\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n":utf8,
    0xFF,
    0xFE,
    "\r\n":utf8,
    close():bits,
  >>
  let assert Error(upload.ParseError(..)) = parse(binary_field)
  let assert Error(upload.ParseError("missing closing boundary")) = parse(<<>>)
}

pub fn parse_multipart_accepts_a_quoted_boundary_test() {
  let body = <<
    file_part("file", "a.png", "image/png", png_bytes()):bits,
    close():bits,
  >>
  let assert Ok(upload.MultipartForm(files: [_], ..)) =
    upload.parse_multipart(
      body,
      "Multipart/Form-Data; charset=utf-8; boundary=\"" <> boundary <> "\"",
      upload.default_config(),
    )
}

pub fn parse_multipart_enforces_the_request_cap_test() {
  let body = <<
    file_part("file", "a.png", "image/png", png_bytes()):bits,
    close():bits,
  >>
  let config = upload.default_config() |> upload.with_max_request_bytes(10)
  let assert Error(upload.RequestTooLarge(max: 10, ..)) =
    upload.parse_multipart(body, content_type(), config)
}

pub fn parse_multipart_enforces_the_file_cap_test() {
  let body = <<
    file_part("file", "a.png", "image/png", png_bytes()):bits,
    close():bits,
  >>
  let config = upload.default_config() |> upload.with_max_size(10)
  let assert Error(upload.FileTooLarge(max: 10, actual: 16)) =
    upload.parse_multipart(body, content_type(), config)
}

// --- Misc ---

pub fn error_status_test() {
  let assert 413 = upload.error_status(upload.FileTooLarge(1, 2))
  let assert 413 = upload.error_status(upload.RequestTooLarge(1, 2))
  let assert 415 = upload.error_status(upload.UnrecognizedContent("x"))
  let assert 415 = upload.error_status(upload.ContentTypeMismatch("x", "y"))
  let assert 415 = upload.error_status(upload.NotMultipart("x"))
  let assert 400 = upload.error_status(upload.ParseError("x"))
  let assert 400 = upload.error_status(upload.InvalidStoredName("x"))
  let assert 500 = upload.error_status(upload.StorageError("x"))
}

pub fn extension_test() {
  let assert Some("png") = upload.extension("photo.png")
  let assert Some("jpg") = upload.extension("my.photo.jpg")
  let assert None = upload.extension("noext")
}

pub fn format_size_test() {
  let assert "500 B" = upload.format_size(500)
  let assert "1 KB" = upload.format_size(1024)
  let assert "5 MB" = upload.format_size(5_242_880)
}

// --- Helpers ---

fn body_of(resp: response.Response(server.ResponseBody)) -> BitArray {
  let assert server.Bytes(tree) = resp.body
  bytes_tree.to_bit_array(tree)
}

@external(erlang, "beacon_upload_test_ffi", "fresh_dir")
fn fresh_dir() -> String

@external(erlang, "beacon_upload_test_ffi", "remove_dir")
fn remove_dir(dir: String) -> Nil

@external(erlang, "beacon_upload_test_ffi", "read_file")
fn read_file(path: String) -> Result(BitArray, Nil)

@external(erlang, "beacon_upload_test_ffi", "write_file")
fn write_file(path: String, data: BitArray) -> Nil

@external(erlang, "beacon_upload_test_ffi", "make_symlink")
fn make_symlink(target: String, link: String) -> Nil

@external(erlang, "beacon_upload_test_ffi", "list_dir")
fn list_dir(dir: String) -> List(String)

@external(erlang, "beacon_upload_ffi", "write_new_file")
fn write_new_file(path: String, data: BitArray) -> Result(Nil, String)
