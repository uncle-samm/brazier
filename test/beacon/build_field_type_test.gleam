/// Tests for type resolution and codec type validation in the build analyzer.
import beacon/build/analyzer
import beacon/build/field_type.{
  BoolType, DictType, FloatType, IntType, ListType, NamedType, OptionType,
  StringType, TupleType,
}
import gleam/dict
import gleam/list
import gleam/string

fn field_type_of(fields: List(analyzer.TypeField), name: String) {
  let assert Ok(field) = list.find(fields, fn(f) { f.name == name })
  field.field_type
}

fn codec_error(source: String) -> String {
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert Error(reason) = analyzer.validate_codec_types(analysis)
  reason
}

pub fn resolves_dict_tuple_and_option_fields_test() {
  let source =
    "
import gleam/dict.{type Dict}
import gleam/option.{type Option}

pub type Model {
  Model(
    scores: Dict(String, Int),
    by_id: Dict(Int, List(Float)),
    point: #(Int, String, Bool),
    note: Option(String),
  )
}
"
  let assert Ok(analysis) = analyzer.analyze(source)
  assert field_type_of(analysis.model_fields, "scores")
    == DictType(StringType, IntType)
  assert field_type_of(analysis.model_fields, "by_id")
    == DictType(IntType, ListType(FloatType))
  assert field_type_of(analysis.model_fields, "point")
    == TupleType([IntType, StringType, BoolType])
  assert field_type_of(analysis.model_fields, "note") == OptionType(StringType)
  assert analyzer.validate_codec_types(analysis) == Ok(Nil)
}

pub fn resolves_qualified_option_and_dict_test() {
  let source =
    "
import gleam/dict
import gleam/option as opt

pub type Model {
  Model(tags: dict.Dict(String, String), name: opt.Option(Int))
}
"
  let assert Ok(analysis) = analyzer.analyze(source)
  assert field_type_of(analysis.model_fields, "tags")
    == DictType(StringType, StringType)
  assert field_type_of(analysis.model_fields, "name") == OptionType(IntType)
}

pub fn resolves_aliased_and_unqualified_imports_test() {
  let shapes =
    "
pub type Point {
  Point(x: Int, y: Int)
}

pub type Colour {
  Red
  Green
}
"
  let source =
    "
import app/shapes as s
import app/shapes.{type Colour as Hue}

pub type Model {
  Model(origin: s.Point, colour: Hue, path: List(s.Point))
}
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(source, [#("s", "app/shapes", shapes)])
  assert field_type_of(analysis.model_fields, "origin")
    == NamedType("s", "Point")
  assert field_type_of(analysis.model_fields, "colour")
    == NamedType("s", "Colour")
  assert field_type_of(analysis.model_fields, "path")
    == ListType(NamedType("s", "Point"))
  assert analyzer.validate_codec_types(analysis) == Ok(Nil)
  let assert [origin, path] = analysis.substates
  assert origin.field_name == "origin"
    && origin.module == "s"
    && !origin.is_list
  assert path.field_name == "path" && path.is_list
}

pub fn expands_type_aliases_test() {
  let source =
    "
pub type Card {
  Card(title: String)
}

pub type Cards =
  List(Card)

pub type Model {
  Model(cards: Cards)
}
"
  let assert Ok(analysis) = analyzer.analyze(source)
  assert field_type_of(analysis.model_fields, "cards")
    == ListType(NamedType("", "Card"))
  let assert [substate] = analysis.substates
  assert substate.type_name == "Card" && substate.is_list
}

pub fn unsupported_dict_key_names_field_and_type_test() {
  let reason =
    codec_error(
      "
import gleam/dict.{type Dict}

pub type Model {
  Model(weights: Dict(Float, Int))
}
",
    )
  assert string.contains(reason, "Model.weights")
  assert string.contains(reason, "Dict keys must be String or Int")
  assert string.contains(reason, "Dict(Float, Int)")
}

pub fn unsupported_function_field_test() {
  let reason =
    codec_error("pub type Model {\n  Model(callback: fn() -> Int)\n}\n")
  assert string.contains(reason, "Model.callback")
  assert string.contains(reason, "functions cannot be sent over the wire")
}

pub fn unsupported_result_field_test() {
  let reason =
    codec_error("pub type Model {\n  Model(outcome: Result(Int, String))\n}\n")
  assert string.contains(reason, "Model.outcome")
  assert string.contains(reason, "`Result` is not supported")
}

pub fn unsupported_unknown_external_type_names_module_test() {
  let reason =
    codec_error(
      "
import gleam/erlang/process

pub type Model {
  Model(owner: process.Pid)
}
",
    )
  assert string.contains(reason, "Model.owner")
  assert string.contains(reason, "`Pid` comes from `gleam/erlang/process`")
}

pub fn unsupported_nested_type_reports_path_test() {
  let reason =
    codec_error(
      "
pub type Shape {
  Circle(radius: Float)
  Square(side: Float)
}

pub type Drawing {
  Drawing(shapes: List(Shape))
}

pub type Model {
  Model(drawing: Drawing)
}
",
    )
  assert string.contains(reason, "Model.drawing → Drawing.shapes")
  assert string.contains(reason, "several variants that carry fields")
}

pub fn unsupported_recursive_type_test() {
  let reason =
    codec_error(
      "
pub type Tree {
  Tree(children: List(Tree))
}

pub type Model {
  Model(tree: Tree)
}
",
    )
  assert string.contains(reason, "recursive type `Tree`")
}

pub fn unsupported_generic_and_unlabelled_types_test() {
  let reason =
    codec_error(
      "
pub type Box(a) {
  Box(value: a)
}

pub type Pair {
  Pair(Int, Int)
}

pub type Model {
  Model(boxed: Box(Int), pair: Pair)
}
",
    )
  assert string.contains(reason, "Model.boxed")
  assert string.contains(reason, "generic type `Box`")
  assert string.contains(reason, "Model.pair")
  assert string.contains(reason, "record `Pair` has unlabelled fields")
}

pub fn unsupported_large_tuple_test() {
  let reason =
    codec_error(
      "pub type Model {\n  Model(t: #(Int, Int, Int, Int, Int, Int, Int, Int, Int))\n}\n",
    )
  assert string.contains(reason, "tuples of more than 8 elements")
}

pub fn enum_variants_that_collide_case_insensitively_test() {
  let reason =
    codec_error(
      "
pub type Mode {
  Ab
  AB
}

pub type Model {
  Model(mode: Mode)
}
",
    )
  assert string.contains(reason, "Model.mode")
  assert string.contains(reason, "differ only by case")
}

pub fn msg_argument_types_are_validated_test() {
  let source =
    "
pub type Model {
  Model(count: Int)
}

pub type Msg {
  Clicked(fn() -> Nil)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Clicked(_) -> model
  }
}
"
  let reason = codec_error(source)
  assert string.contains(reason, "Msg.Clicked.arg0")
}

pub fn client_msg_allowlist_limits_validated_variants_test() {
  let source =
    "
pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
  Internal(fn() -> Nil)
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
  assert analyzer.validate_codec_types(analysis) == Ok(Nil)
}

pub fn computed_field_without_annotation_is_an_error_test() {
  let source =
    "
pub type Model {
  Model(count: Int)
}

pub fn doubled(model: Model) {
  model.count * 2
}
"
  let reason = codec_error(source)
  assert string.contains(reason, "computed field `doubled`")
  assert string.contains(reason, "no return annotation")
}

pub fn computed_field_resolves_return_type_test() {
  let source =
    "
pub type Model {
  Model(count: Int)
}

pub fn labels(model: Model) -> List(String) {
  []
}
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert [computed] = analysis.computed_fields
  assert computed.field_type == ListType(StringType)
  assert computed.return_type == "List"
}

pub fn parse_error_reports_location_test() {
  let assert Error(reason) =
    analyzer.analyze("pub type Model {\n  Model(count: )\n}\n")
  assert string.contains(reason, "app module:2:")
}

pub fn external_parse_error_names_module_path_test() {
  let source = "import app/broken\n\npub type Model {\n  Model(count: Int)\n}\n"
  let assert Error(reason) =
    analyzer.analyze_multi(source, [#("broken", "app/broken", "pub fn (")])
  assert string.contains(reason, "app/broken.gleam:1:")
}

pub fn colliding_import_aliases_are_an_error_test() {
  let source = "pub type Model {\n  Model(count: Int)\n}\n"
  let assert Error(reason) =
    analyzer.analyze_multi(source, [
      #("types", "app/types", "pub type A {\n  A(x: Int)\n}\n"),
      #("types", "lib/types", "pub type B {\n  B(y: Int)\n}\n"),
    ])
  assert string.contains(reason, "`app/types` and `lib/types`")
}

pub fn external_msg_uses_its_own_variants_not_the_app_allowlist_test() {
  let child =
    "
pub type Msg {
  Opened
  Closed
}
"
  let source =
    "
import child

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
  ChildMsg(child.Msg)
}

pub type ClientMsg {
  Increment
  ChildMsg(child.Msg)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + 1)
    ChildMsg(_) -> model
  }
}
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(source, [#("child", "child", child)])
  let assert [info] = analysis.external_msg_types
  assert info.module == "child"
  assert list.map(info.variants, fn(v) { v.name }) == ["Opened", "Closed"]
  assert analyzer.validate_codec_types(analysis) == Ok(Nil)
}

pub fn external_server_fields_are_qualified_test() {
  let server_state =
    "
pub type Session {
  Session(token: String)
}

pub type Server {
  Server(session: Session)
}
"
  let source =
    "
import server_state

pub type Model {
  Model(count: Int)
}
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(source, [
      #("server_state", "server_state", server_state),
    ])
  assert analysis.server_module == "server_state"
  let assert [session] = analysis.server_fields
  assert session.module == "server_state"
  assert session.field_type == NamedType("server_state", "Session")
}

pub fn type_defs_cover_every_analyzed_module_test() {
  let shapes = "pub type Point {\n  Point(x: Int)\n}\n"
  let source =
    "import shapes\n\npub type Model {\n  Model(p: shapes.Point)\n}\n"
  let assert Ok(analysis) =
    analyzer.analyze_multi(source, [#("shapes", "shapes", shapes)])
  assert dict.has_key(analysis.type_defs, #("", "Model"))
  assert dict.get(analysis.type_defs, #("shapes", "Point"))
    == Ok(field_type.RecordDef("Point", [#("x", IntType)]))
}
