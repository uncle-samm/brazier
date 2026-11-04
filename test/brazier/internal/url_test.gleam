import brazier/internal/url
import gleam/list

fn blocked(name: String, value: String) -> Bool {
  case url.check(name, value) {
    Ok(_) -> False
    Error(_) -> True
  }
}

fn kept(name: String, value: String) -> Bool {
  url.check(name, value) == Ok(value)
}

pub fn url_attributes_test() {
  let assert True =
    list.all(
      ["href", "src", "action", "formaction", "poster", "cite", "xlink:href"],
      url.is_url_attribute,
    )
  let assert True = url.is_url_attribute("HREF")
  let assert True = url.is_url_attribute("XLink:Href")
  let assert False = url.is_url_attribute("class")
  let assert False = url.is_url_attribute("data-href")
  let assert False = url.is_url_attribute("hrefx")
}

pub fn non_url_attribute_is_never_checked_test() {
  let assert True = kept("title", "javascript:alert(1)")
  let assert True = kept("data-url", "javascript:alert(1)")
}

pub fn javascript_blocked_test() {
  let assert Error(url.DisallowedScheme("javascript")) =
    url.check("href", "javascript:alert(1)")
}

pub fn mixed_case_scheme_blocked_test() {
  let assert Error(url.DisallowedScheme("javascript")) =
    url.check("href", "JaVaScRiPt:alert(1)")
}

pub fn leading_whitespace_and_controls_blocked_test() {
  let assert True = blocked("href", "   javascript:alert(1)")
  let assert True = blocked("href", "\u{0000}javascript:alert(1)")
  let assert True = blocked("href", "\u{001F}\u{0001} javascript:alert(1)")
  let assert True = blocked("href", "\n\r\tjavascript:alert(1)")
  let assert True = blocked("href", "\u{007F}javascript:alert(1)")
}

pub fn embedded_tab_and_newlines_blocked_test() {
  let assert Error(url.DisallowedScheme("javascript")) =
    url.check("href", "java\tscript:alert(1)")
  let assert True = blocked("href", "java\nscript:alert(1)")
  let assert True = blocked("href", "java\rscript:alert(1)")
  let assert True = blocked("href", "java\r\nscript:alert(1)")
  let assert True = blocked("href", "j\ta\nv\ra\r\nscript:alert(1)")
  let assert True = blocked("href", "javascript\t:alert(1)")
}

pub fn trailing_whitespace_does_not_hide_scheme_test() {
  let assert True = blocked("href", "javascript:alert(1)   \u{0000}")
}

pub fn vbscript_blocked_test() {
  let assert Error(url.DisallowedScheme("vbscript")) =
    url.check("href", "VBScript:msgbox(1)")
}

pub fn unknown_schemes_blocked_test() {
  let assert True = blocked("href", "file:///etc/passwd")
  let assert True = blocked("href", "blob:https://example.com/id")
  let assert True = blocked("src", "filesystem:https://example.com/x")
  let assert True = blocked("href", "about:blank")
}

pub fn data_text_html_blocked_test() {
  let assert Error(url.DisallowedData("href")) =
    url.check("href", "data:text/html,<script>alert(1)</script>")
  let assert Error(url.DisallowedData("src")) =
    url.check("src", "data:text/html;base64,PHNjcmlwdD4=")
}

pub fn data_svg_blocked_everywhere_test() {
  let assert True = blocked("src", "data:image/svg+xml,<svg onload=alert(1)>")
  let assert True = blocked("src", "data:image/svg+xml;base64,PHN2Zz4=")
  let assert True = blocked("href", "data:image/svg+xml,<svg>")
}

pub fn data_image_allowed_in_src_only_test() {
  let assert True = kept("src", "data:image/png;base64,iVBORw0KGgo=")
  let assert True = kept("src", "data:image/gif;base64,R0lGOD==")
  let assert True = kept("src", "data:image/jpeg,abc")
  let assert True = kept("src", "DATA:IMAGE/WEBP;base64,UklGR")
  let assert True = kept("SRC", "data:image/png;base64,iVBORw0KGgo=")
  let assert Error(url.DisallowedData("href")) =
    url.check("href", "data:image/png;base64,iVBORw0KGgo=")
  let assert True = blocked("poster", "data:image/png;base64,iVBORw0KGgo=")
  let assert True = blocked("action", "data:image/png;base64,iVBORw0KGgo=")
}

pub fn data_image_lookalikes_blocked_test() {
  let assert True = blocked("src", "data:image/pngx;base64,AAAA")
  let assert True = blocked("src", "data:image/png")
  let assert True = blocked("src", "data:image/;base64,AAAA")
  let assert True = blocked("src", "data:,hello")
  let assert True = blocked("src", "data:text/plain;image/png,AAAA")
}

pub fn allowed_schemes_kept_test() {
  let assert True = kept("href", "http://example.com/")
  let assert True = kept("href", "https://example.com/a?b=c#d")
  let assert True = kept("href", "HTTPS://EXAMPLE.COM")
  let assert True = kept("href", "mailto:someone@example.com")
  let assert True = kept("href", "tel:+15555550100")
  let assert True = kept("src", "https://cdn.example.com/i.png")
  let assert True = kept("action", "/submit")
  let assert True = kept("formaction", "https://example.com/post")
  let assert True = kept("cite", "https://example.com/source")
  let assert True = kept("xlink:href", "#icon")
}

pub fn relative_urls_kept_test() {
  let assert True = kept("href", "")
  let assert True = kept("href", "/")
  let assert True = kept("href", "/path/to/page")
  let assert True = kept("href", "page.html")
  let assert True = kept("href", "../up")
  let assert True = kept("href", "?q=1")
  let assert True = kept("href", "#section")
  let assert True = kept("href", "//example.com/protocol-relative")
  // A colon after the first `/`, `?` or `#` is not a scheme separator.
  let assert True = kept("href", "/search?q=javascript:alert(1)")
  let assert True = kept("href", "#javascript:alert(1)")
  let assert True = kept("href", "./javascript:alert(1)")
}

pub fn value_is_returned_unchanged_test() {
  let assert Ok("  HTTPS://Example.com/Path  ") =
    url.check("href", "  HTTPS://Example.com/Path  ")
}

pub fn describe_and_truncate_test() {
  let assert "scheme `javascript:` is not allowed" =
    url.describe(url.DisallowedScheme("javascript"))
  let assert "data: URLs are not allowed in `href`" =
    url.describe(url.DisallowedData("href"))
  let long = "javascript:" <> string_repeat("a", 200)
  let truncated = url.truncate_for_log(long)
  let assert True = truncated != long
  let assert "short" = url.truncate_for_log("short")
}

fn string_repeat(s: String, times: Int) -> String {
  list.repeat(s, times) |> list.fold("", fn(acc, x) { acc <> x })
}
