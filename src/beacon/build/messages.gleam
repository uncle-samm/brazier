/// The Msg types that cross the wire, as the server codec and the client
/// entry module see them.
///
/// The browser sends the primary Msg type. A variant of it may carry the Msg
/// of an imported module (`ChildMsg(child.Msg)`); that nested Msg is sent as
/// a JSON string holding its own `{"tag": ..}` object. Only nested Msg types
/// reachable from variants the browser may send get generated code, so the
/// generated modules have no unused functions.
import beacon/build/analyzer.{type Analysis, type MsgVariant}
import beacon/build/field_type.{type FieldType}
import gleam/int
import gleam/list
import gleam/set.{type Set}

pub type MsgType {
  MsgType(
    /// Canonical alias of the module that defines the Msg type; "" for the
    /// app module.
    module: String,
    /// The type name, "Msg" unless the analyzer found another.
    type_name: String,
    /// Variants the browser may send.
    allowed: List(MsgVariant),
    /// Every variant, allowed or not.
    all: List(MsgVariant),
  )
}

pub fn primary(analysis: Analysis) -> MsgType {
  MsgType(
    module: analysis.msg_module,
    type_name: analysis.msg_type_name,
    allowed: analyzer.client_event_variants(analysis),
    all: analysis.msg_type_variants,
  )
}

/// The module whose Msg a field carries, when the field is a nested Msg.
pub fn nested_module(
  analysis: Analysis,
  type_: FieldType,
) -> Result(String, Nil) {
  case type_ {
    field_type.NamedType(module:, name: "Msg") ->
      case
        list.any(analysis.external_msg_types, fn(info) { info.module == module })
      {
        True -> Ok(module)
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// The nested Msg types reachable from the variants the browser may send,
/// in the order they are first reached.
pub fn reachable_nested(analysis: Analysis) -> List(MsgType) {
  let nested =
    list.map(analysis.external_msg_types, fn(info) {
      MsgType(
        module: info.module,
        type_name: "Msg",
        allowed: info.variants,
        all: info.all_variants,
      )
    })
  let start = nested_modules_of(analysis, primary(analysis).allowed)
  walk(analysis, nested, start, set.new(), [])
  |> list.reverse
}

fn walk(
  analysis: Analysis,
  nested: List(MsgType),
  pending: List(String),
  seen: Set(String),
  acc: List(MsgType),
) -> List(MsgType) {
  case pending {
    [] -> acc
    [module, ..rest] ->
      case
        set.contains(seen, module),
        list.find(nested, fn(m) { m.module == module })
      {
        True, _ | False, Error(Nil) -> walk(analysis, nested, rest, seen, acc)
        False, Ok(msg_type) ->
          walk(
            analysis,
            nested,
            list.append(rest, nested_modules_of(analysis, msg_type.allowed)),
            set.insert(seen, module),
            [msg_type, ..acc],
          )
      }
  }
}

fn nested_modules_of(
  analysis: Analysis,
  variants: List(MsgVariant),
) -> List(String) {
  list.flat_map(variants, fn(variant) {
    list.filter_map(variant.fields, fn(f) {
      nested_module(analysis, f.field_type)
    })
  })
}

/// True when `variant` is one the browser may send.
pub fn is_allowed(msg_type: MsgType, variant: MsgVariant) -> Bool {
  list.any(msg_type.allowed, fn(allowed) { allowed.name == variant.name })
}

/// The wire key of a variant's argument at `index`.
pub fn arg_key(index: Int) -> String {
  "arg" <> int.to_string(index)
}
