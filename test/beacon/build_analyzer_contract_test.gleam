/// Tests for the analyzer's full Msg variant list, update side-effect
/// detection and AST-driven client source extraction.
import beacon/build/analyzer
import gleam/list
import gleam/string

fn names(variants: List(analyzer.MsgVariant)) -> List(String) {
  list.map(variants, fn(v) { v.name })
}

pub fn msg_type_variants_include_variants_outside_the_allowlist_test() {
  let source =
    "
pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
  Internal(Int)
}

pub type ClientMsg {
  Increment
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + 1)
    Internal(_) -> model
  }
}
"
  let assert Ok(analysis) = analyzer.analyze(source)
  assert names(analysis.msg_type_variants) == ["Increment", "Internal"]
  assert names(analyzer.client_event_variants(analysis)) == ["Increment"]
  let assert [_, internal] = analysis.msg_type_variants
  assert !internal.affects_model
}

pub fn imported_msg_keeps_every_variant_when_allowlisted_test() {
  let child =
    "
pub type Msg {
  Opened
  Closed
  Secret
}
"
  let source =
    "
import child

pub type Model {
  Model(count: Int)
}

pub type ClientMsg {
  Opened
}
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(source, [#("child", "child", child)])
  assert analysis.msg_module == "child"
  assert names(analysis.msg_variants) == ["Opened"]
  assert names(analysis.msg_type_variants) == ["Opened", "Closed", "Secret"]
}

pub fn nested_msg_info_lists_all_variants_test() {
  let child =
    "
pub type Msg {
  Opened
  Hidden
}

pub type ClientMsg {
  Opened
}
"
  let source =
    "
import child

pub type Model {
  Model(count: Int)
}

pub type Msg {
  ChildMsg(child.Msg)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    ChildMsg(_) -> model
  }
}
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(source, [#("child", "child", child)])
  let assert [info] = analysis.external_msg_types
  assert names(info.variants) == ["Opened"]
  assert names(info.all_variants) == ["Opened", "Hidden"]
}

fn purity_error(source: String) -> String {
  let assert Error(reason) = analyzer.validate_client_update_purity(source)
  reason
}

pub fn side_effect_inside_use_is_detected_test() {
  let reason =
    purity_error(
      "
import beacon/store

pub fn update(model, msg) {
  use x <- store.with(model)
  x
}
",
    )
  assert string.contains(reason, "store.with from beacon/store")
}

pub fn side_effect_inside_record_update_and_guard_is_detected_test() {
  let reason =
    purity_error(
      "
import beacon/store as s

pub fn update(model, msg) {
  case msg {
    _ if s.flag() -> Model(..model, count: s.read(model))
    _ -> model
  }
}
",
    )
  assert string.contains(reason, "s.flag from beacon/store")
  assert string.contains(reason, "s.read from beacon/store")
}

pub fn side_effect_through_capture_and_pipe_is_detected_test() {
  let reason =
    purity_error(
      "
import beacon/pubsub

pub fn update(model, msg) {
  let f = pubsub.publish(_, msg)
  model |> pubsub.broadcast
}
",
    )
  assert string.contains(reason, "pubsub.publish from beacon/pubsub")
  assert string.contains(reason, "pubsub.broadcast from beacon/pubsub")
}

pub fn unqualified_side_effect_import_is_detected_test() {
  let reason =
    purity_error(
      "
import beacon/store.{put as save}

pub fn update(model, msg) {
  save(model)
}
",
    )
  assert string.contains(reason, "save (imported beacon/store.put)")
}

pub fn discarded_side_effect_import_alias_is_not_a_qualifier_test() {
  // `store` here is a local record, not the discarded import.
  let source =
    "
import beacon/store as _unused

pub fn update(model, msg) {
  let store = model.store
  store.count
}
"
  assert analyzer.validate_client_update_purity(source) == Ok(Nil)
}

pub fn extraction_keeps_only_referenced_imports_test() {
  let source =
    "
import beacon as b
import beacon/html.{div}
import gleam/int
import gleam/list as l
import gleam/option.{type Option}

pub type Model {
  Model(count: Int, note: Option(String))
}

pub fn view(model: Model) -> b.Node(Nil) {
  div([], [b.text(int.to_string(model.count))])
}
"
  let assert Ok(client) = analyzer.extract_client_source(source)
  assert string.contains(client, "import beacon as b")
  assert string.contains(client, "import beacon/html.{div}")
  assert string.contains(client, "import gleam/int")
  assert string.contains(client, "import gleam/option.{type Option}")
  assert !string.contains(client, "gleam/list")
}

pub fn extraction_keeps_private_helpers_reached_from_public_code_test() {
  let source =
    "
const label = \"Count: \"

const unused = \"x\"

pub fn view(model: Int) -> String {
  render(model)
}

fn render(n: Int) -> String {
  prefix() <> string.inspect(n)
}

fn prefix() -> String {
  label
}

fn dead() -> String {
  unused
}
"
  let assert Ok(client) = analyzer.extract_client_source(source)
  assert string.contains(client, "fn render(")
  assert string.contains(client, "fn prefix(")
  assert string.contains(client, "const label")
  assert !string.contains(client, "fn dead(")
  assert !string.contains(client, "const unused")
}

pub fn extraction_ignores_names_in_comments_test() {
  let source =
    "
import gleam/list

pub fn view(model: Int) -> Int {
  // list.map is mentioned only in this comment
  model
}
"
  let assert Ok(client) = analyzer.extract_client_source(source)
  assert !string.contains(client, "import gleam/list")
}
