# HTML Elements Reference

A view is built from four modules, following Lustre's layout:

<!-- docs-check: fragment an import list; each module is used by the samples below -->
```gleam
import brazier/attribute
import brazier/element.{type Element}
import brazier/event
import brazier/html
```

SVG elements are in `brazier/svg` (see [SVG.md](SVG.md)).

## Elements (`brazier/html`)

Elements take `(attributes: List(Attribute(msg)), children: List(Element(msg)))`.

**Sections:** `div`, `span`, `p`, `h1`-`h6`, `nav`, `header`, `footer`, `main`, `section`, `article`, `aside`, `address`, `hgroup`, `search`

**Forms:** `button`, `a`, `form`, `label`, `textarea`, `select`, `option`, `optgroup`, `fieldset`, `legend`, `datalist`, `output`, `progress`, `meter`

**Lists:** `ul`, `ol`, `li`, `dl`, `dt`, `dd`, `menu`

**Tables:** `table`, `caption`, `colgroup`, `thead`, `tbody`, `tfoot`, `tr`, `td`, `th`

**Inline text:** `strong`, `em`, `b`, `i`, `u`, `s`, `small`, `mark`, `sub`, `sup`, `abbr`, `cite`, `q`, `dfn`, `kbd`, `samp`, `var`, `time`, `data`, `bdi`, `bdo`, `ruby`, `rt`, `rp`, `del`, `ins`

**Blocks:** `pre`, `code`, `blockquote`, `figure`, `figcaption`, `details`, `summary`, `dialog`

**Embedded:** `canvas`, `video`, `audio`, `picture`, `iframe`, `object`, `map`, `noscript`, `template`, `slot`

**Void elements** take only attributes: `input`, `br`, `hr`, `img`, `source`, `track`, `wbr`, `col`, `area`, `embed`

**Text:** `html.text("content")`, escaped when rendered.

## Element Helpers (`brazier/element`)

| Function | Description |
|----------|-------------|
| `element.element(tag, attributes, children)` | Any tag. A tag with characters outside `a-z A-Z 0-9 - _ : .` crashes. |
| `element.text(content)` | Escaped text |
| `element.none()` | Renders nothing; use it for conditional content |
| `element.keyed(key, child)` | Gives `child` an identity (`data-brazier-key`) so the browser keeps or replaces its DOM node by key instead of by position. A reorder moves keyed nodes, which keep focus and state; a key rendered with another tag is a new node. Keys must be unique among siblings: a repeated key is logged as an error. |
| `element.map(element, f)` | Changes the message type, for child modules |
| `element.unsafe_raw_html(html)` | Inserts HTML without escaping or the URL policy |
| `element.to_string(element)` | Renders to an HTML string |

<!-- docs-check: wrap
import brazier/element.{type Element}
import brazier/html

pub type Item {
  Item(id: String, title: String)
}

pub type Model {
  Model(show_details: Bool, details: String, items: List(Item), email: String)
}

pub type Msg {
  Search(String)
  PointerMoved(x: Float, y: Float)
  SetEmail(String)
  Submitted(List(#(String, String)))
}

pub fn details(model: Model) -> Element(Msg) {
  {{block}}
}
-->
```gleam
case model.show_details {
  True -> html.p([], [html.text(model.details)])
  False -> element.none()
}
```

Key list items whose order can change, so focus and input state stay with
the right item:

<!-- docs-check: wrap
import brazier/element.{type Element}
import brazier/html
import gleam/list

pub type Item {
  Item(id: String, title: String)
}

pub type Model {
  Model(show_details: Bool, details: String, items: List(Item), email: String)
}

pub type Msg {
  Search(String)
  PointerMoved(x: Float, y: Float)
  SetEmail(String)
  Submitted(List(#(String, String)))
}

pub fn item_list(model: Model) -> Element(Msg) {
  {{block}}
}
-->
```gleam
html.ul([], list.map(model.items, fn(item) {
  element.keyed(item.id, html.li([], [html.text(item.title)]))
}))
```

**`element.unsafe_raw_html(html)`** never escapes. Pass it only HTML you
produced or sanitized yourself, such as rendered markdown output, never text
a user controls. Its counterpart for an `<iframe>` document is
`attribute.unsafe_srcdoc(html)`.

## Attributes (`brazier/attribute`)

| Function | HTML |
|----------|------|
| `attribute.class("x")` | `class="x"` |
| `attribute.classes([#("active", True), #("hidden", False)])` | `class="active"` |
| `attribute.id("x")` | `id="x"` |
| `attribute.name("field")` | `name="field"` |
| `attribute.type_("text")` | `type="text"` |
| `attribute.value("x")` | `value="x"` |
| `attribute.placeholder("x")` | `placeholder="x"` |
| `attribute.title("x")`, `alt`, `role`, `target`, `rel`, `method`, `for` | the attribute of the same name |
| `attribute.min("0")`, `max`, `step` | the attribute of the same name |
| `attribute.rows(3)`, `cols`, `tabindex` | integer attributes |
| `attribute.data("testid", "x")` | `data-testid="x"` |
| `attribute.aria("label", "x")` | `aria-label="x"` |
| `attribute.style("color", "red")` | `style="color:red"` (several are joined) |
| `attribute.styles([#("color", "red"), #("margin", "0")])` | `style="color:red;margin:0"` |
| `attribute.disabled(True)`, `checked`, `selected`, `readonly`, `required`, `autofocus` | boolean attributes: present when `True`, absent when `False` |
| `attribute.draggable(True)` | `draggable="true"` (`"false"` for `False`) |
| `attribute.boolean("hidden", True)` | any boolean attribute |
| `attribute.attribute("k", "v")` | `k="v"` |
| `attribute.unsafe_srcdoc(html)` | `srcdoc="..."`: the iframe's whole document, not checked |
| `attribute.none()` | nothing |

`attribute.attribute(name, value)` crashes on:

- an inline event name such as `onclick`: use `brazier/event` for handlers;
- `srcdoc`: use `attribute.unsafe_srcdoc`, which says what it does;
- `attributeName` with a value containing `href`, which would let an SVG
  animation rewrite a link after the URL policy checked it (see
  [SVG.md](SVG.md#animation));
- a name with characters outside `a-z A-Z 0-9 - _ : .`.

Names match case-insensitively, so `SrcDoc` and `ONCLICK` crash too.

**`attribute.unsafe_srcdoc(html)`** gives an `<iframe>` a whole document.
The value is attribute-escaped, as every value is, and the browser decodes it
back to `html`, so its markup runs as a page. Unless the iframe has a
`sandbox` attribute without `allow-scripts` and `allow-same-origin`
together, its scripts run with your page's origin. Never pass it text a user
controls.

### URL attributes

`attribute.href`, `src`, `action`, `formaction`, `poster` and `cite` (and the
same names through `attribute.attribute`, plus `xlink:href`) go through the
URL policy. Relative URLs, `http:`, `https:`, `mailto:` and `tel:` are
allowed, and `src` also accepts `data:image/png`, `gif`, `jpeg` and `webp`.
Any other value, such as `javascript:alert(1)`, drops the attribute and logs
a warning. The scheme is read as a browser reads it, one code point at a
time. See [SECURITY.md](SECURITY.md#url-policy).

### Client hooks

| Function | LiveView | Description |
|----------|----------|-------------|
| `attribute.ignore_updates()` | `phx-update="ignore"` | The browser does not touch the element's children after the first render |
| `attribute.hook("Chart")` | `phx-hook` | Attaches a JavaScript hook registered with `Brazier.hooks` |
| `attribute.watch(["data-points"])` | | Attribute changes that call the hook's `updated` callback |

## Events (`brazier/event`)

| Function | Event | Message |
|----------|-------|---------|
| `event.on_click(msg)` | click | `msg` |
| `event.on_double_click(msg)` | dblclick | `msg` |
| `event.on_mouse_down(msg)`, `on_mouse_up`, `on_mouse_enter`, `on_mouse_leave`, `on_mouse_over`, `on_mouse_out` | mouse events | `msg` |
| `event.on_input(fn(String) -> msg)` | input | `event.target.value` |
| `event.on_change(fn(String) -> msg)` | change | `event.target.value` |
| `event.on_check(fn(Bool) -> msg)` | change | `event.target.checked` |
| `event.on_submit(fn(List(#(String, String))) -> msg)` | submit | The form's string fields; the browser's submission is prevented |
| `event.on_keydown(fn(String) -> msg)`, `on_keyup`, `on_keypress` | key events | `event.key` |
| `event.on_focus(msg)`, `on_blur` | focus, blur | `msg` |
| `event.on_drag_start(msg)`, `on_drag_end` | dragstart, dragend | `msg` |
| `event.on_drag_over(msg)` | dragover | `msg`; the default is prevented so the element accepts drops |
| `event.on_drop(msg)` | drop | `msg`; the default is prevented |

### Custom events

`event.on(name, decoder)` listens for any DOM event and decodes the event
object with a `gleam/dynamic/decode` decoder, as Lustre does. The decoder runs
in the browser; a decode failure is logged with `console.warn` and the event
is dropped.

<!-- docs-check: wrap
import brazier/attribute
import brazier/event
import gleam/dynamic/decode

pub type Item {
  Item(id: String, title: String)
}

pub type Model {
  Model(show_details: Bool, details: String, items: List(Item), email: String)
}

pub type Msg {
  Search(String)
  PointerMoved(x: Float, y: Float)
  SetEmail(String)
  Submitted(List(#(String, String)))
}

pub fn on_pointer_move(_model: Model) -> attribute.Attribute(Msg) {
  {{block}}
}
-->
```gleam
event.on("pointermove", {
  use #(x, y) <- decode.then(event.mouse_position())
  decode.success(PointerMoved(x:, y:))
})
```

Payload decoders: `event.value()`, `event.checked()`, `event.key()`,
`event.mouse_position()` (`#(offsetX, offsetY)`) and `event.form_data()`.

### Modifiers

| Function | Description |
|----------|-------------|
| `event.prevent_default(handler)` | Calls `preventDefault()` |
| `event.stop_propagation(handler)` | Calls `stopPropagation()` |
| `event.debounce(handler, ms)` | Dispatches the latest event once it has stopped firing for `ms` |
| `event.throttle(handler, ms)` | Dispatches at most one event every `ms` |

<!-- docs-check: wrap
import brazier/element.{type Element}
import brazier/event
import brazier/html

pub type Item {
  Item(id: String, title: String)
}

pub type Model {
  Model(show_details: Bool, details: String, items: List(Item), email: String)
}

pub type Msg {
  Search(String)
  PointerMoved(x: Float, y: Float)
  SetEmail(String)
  Submitted(List(#(String, String)))
}

pub fn search_box(_model: Model) -> Element(Msg) {
  {{block}}
}
-->
```gleam
html.input([event.on_input(Search) |> event.debounce(300)])
```

Every message constructor that client code can build is accepted from the
browser; any other message is refused by the server. See
[SECURITY.md](SECURITY.md#events-from-the-browser).

## Example: Login Form

<!-- docs-check: wrap
import brazier/attribute
import brazier/element.{type Element}
import brazier/event
import brazier/html

pub type Item {
  Item(id: String, title: String)
}

pub type Model {
  Model(show_details: Bool, details: String, items: List(Item), email: String)
}

pub type Msg {
  Search(String)
  PointerMoved(x: Float, y: Float)
  SetEmail(String)
  Submitted(List(#(String, String)))
}

{{block}}
-->
```gleam
pub fn view(model: Model) -> Element(Msg) {
  html.form([event.on_submit(Submitted)], [
    html.label([attribute.for("email")], [html.text("Email")]),
    html.input([
      attribute.id("email"),
      attribute.name("email"),
      attribute.type_("email"),
      attribute.value(model.email),
      event.on_input(SetEmail),
    ]),
    html.label([attribute.for("password")], [html.text("Password")]),
    html.input([
      attribute.id("password"),
      attribute.name("password"),
      attribute.type_("password"),
    ]),
    html.button([attribute.type_("submit")], [html.text("Log in")]),
  ])
}
```

`Submitted` receives `[#("email", ...), #("password", ...)]` from the form at
the moment it is submitted.
