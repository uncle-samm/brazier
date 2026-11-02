/// Names a piece of Gleam source refers to, collected from the glance AST.
///
/// The build uses this to decide which imports, helper functions and
/// constants a slice of user source needs, and which imports a slice of
/// framework source uses, without searching the text for substrings.
///
/// Collection is syntactic and over-approximates: a local variable that is
/// used as a record (`model.count`) is reported as a possible module
/// qualifier `model`. Callers only use these sets to decide what to keep, so
/// an over-approximation keeps an extra import at worst, never drops a
/// needed one.
import glance
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string

pub type Refs {
  Refs(
    /// Names used as module qualifiers: `list` in `list.map` or
    /// `option.Option`.
    qualifiers: Set(String),
    /// Unqualified names: variables, functions, constructors and types.
    names: Set(String),
    /// Qualified references as #(qualifier, name): `#("list", "map")` for
    /// `list.map`, `#("option", "Option")` for `option.Option`.
    qualified: Set(#(String, String)),
  )
}

pub fn empty() -> Refs {
  Refs(qualifiers: set.new(), names: set.new(), qualified: set.new())
}

pub fn merge(a: Refs, b: Refs) -> Refs {
  Refs(
    qualifiers: set.union(a.qualifiers, b.qualifiers),
    names: set.union(a.names, b.names),
    qualified: set.union(a.qualified, b.qualified),
  )
}

fn add_qualifier(refs: Refs, name: String) -> Refs {
  Refs(..refs, qualifiers: set.insert(refs.qualifiers, name))
}

fn add_name(refs: Refs, value: String) -> Refs {
  Refs(..refs, names: set.insert(refs.names, value))
}

fn add_qualified(refs: Refs, qualifier: String, name: String) -> Refs {
  Refs(
    ..add_qualifier(refs, qualifier),
    qualified: set.insert(refs.qualified, #(qualifier, name)),
  )
}

/// A reference to `name`, qualified by `module` when there is one.
fn reference(refs: Refs, module: Option(String), name: String) -> Refs {
  case module {
    Some(module) -> add_qualified(refs, module, name)
    None -> add_name(refs, name)
  }
}

pub fn function(refs: Refs, function: glance.Function) -> Refs {
  let refs =
    list.fold(function.parameters, refs, fn(refs, param) {
      optional_type(refs, param.type_)
    })
  let refs = optional_type(refs, function.return)
  list.fold(function.body, refs, statement)
}

pub fn custom_type(refs: Refs, custom_type: glance.CustomType) -> Refs {
  list.fold(custom_type.variants, refs, fn(refs, variant) {
    list.fold(variant.fields, refs, fn(refs, field) {
      case field {
        glance.LabelledVariantField(item:, ..)
        | glance.UnlabelledVariantField(item:) -> type_(refs, item)
      }
    })
  })
}

pub fn type_alias(refs: Refs, alias: glance.TypeAlias) -> Refs {
  type_(refs, alias.aliased)
}

pub fn constant(refs: Refs, constant: glance.Constant) -> Refs {
  expression(optional_type(refs, constant.annotation), constant.value)
}

fn optional_type(refs: Refs, t: Option(glance.Type)) -> Refs {
  case t {
    Some(t) -> type_(refs, t)
    None -> refs
  }
}

pub fn type_(refs: Refs, t: glance.Type) -> Refs {
  case t {
    glance.NamedType(name: type_name, module:, parameters:, ..) -> {
      list.fold(parameters, reference(refs, module, type_name), type_)
    }
    glance.TupleType(elements:, ..) -> list.fold(elements, refs, type_)
    glance.FunctionType(parameters:, return:, ..) ->
      type_(list.fold(parameters, refs, type_), return)
    glance.VariableType(..) | glance.HoleType(..) -> refs
  }
}

fn statement(refs: Refs, statement: glance.Statement) -> Refs {
  case statement {
    glance.Expression(expr) -> expression(refs, expr)
    glance.Assignment(kind:, pattern: p, annotation:, value:, ..) -> {
      let refs =
        expression(walk_pattern(optional_type(refs, annotation), p), value)
      case kind {
        glance.LetAssert(message: Some(message)) -> expression(refs, message)
        glance.LetAssert(message: None) | glance.Let -> refs
      }
    }
    glance.Use(patterns:, function:, ..) ->
      list.fold(patterns, expression(refs, function), fn(refs, use_pattern) {
        walk_pattern(
          optional_type(refs, use_pattern.annotation),
          use_pattern.pattern,
        )
      })
    glance.Assert(expression: expr, message:, ..) ->
      optional_expression(expression(refs, expr), message)
  }
}

fn optional_expression(refs: Refs, expr: Option(glance.Expression)) -> Refs {
  case expr {
    Some(e) -> expression(refs, e)
    None -> refs
  }
}

fn fields(refs: Refs, fields: List(glance.Field(glance.Expression))) -> Refs {
  list.fold(fields, refs, fn(refs, field) {
    case field {
      glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
        expression(refs, item)
      // `f(label:)` passes the variable `label`.
      glance.ShorthandField(label:, ..) -> add_name(refs, label)
    }
  })
}

pub fn expression(refs: Refs, expr: glance.Expression) -> Refs {
  case expr {
    glance.Int(..) | glance.Float(..) | glance.String(..) -> refs
    glance.Variable(name: variable, ..) -> add_name(refs, variable)
    glance.NegateInt(value:, ..) | glance.NegateBool(value:, ..) ->
      expression(refs, value)
    glance.Block(statements:, ..) -> list.fold(statements, refs, statement)
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      optional_expression(refs, message)
    glance.Tuple(elements:, ..) -> list.fold(elements, refs, expression)
    glance.List(elements:, rest:, ..) ->
      optional_expression(list.fold(elements, refs, expression), rest)
    glance.Fn(arguments:, return_annotation:, body:, ..) -> {
      let refs =
        list.fold(arguments, refs, fn(refs, argument) {
          optional_type(refs, argument.type_)
        })
      list.fold(body, optional_type(refs, return_annotation), statement)
    }
    glance.RecordUpdate(module:, constructor:, record:, fields: updates, ..) -> {
      let refs = reference(refs, module, constructor)
      list.fold(updates, expression(refs, record), fn(refs, update) {
        case update.item {
          Some(item) -> expression(refs, item)
          // `Record(..r, label:)` uses the variable `label`.
          None -> add_name(refs, update.label)
        }
      })
    }
    // `alias.name`: the container is a qualifier when it is a bare name.
    glance.FieldAccess(
      container: glance.Variable(name: container, ..),
      label:,
      ..,
    ) -> add_name(add_qualified(refs, container, label), container)
    glance.FieldAccess(container:, ..) -> expression(refs, container)
    glance.Call(function:, arguments:, ..) ->
      fields(expression(refs, function), arguments)
    glance.TupleIndex(tuple:, ..) -> expression(refs, tuple)
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      fields(
        fields(expression(refs, function), arguments_before),
        arguments_after,
      )
    glance.BitString(segments:, ..) ->
      list.fold(segments, refs, fn(refs, segment) {
        list.fold(segment.1, expression(refs, segment.0), fn(refs, option) {
          case option {
            glance.SizeValueOption(size) -> expression(refs, size)
            _ -> refs
          }
        })
      })
    glance.Case(subjects:, clauses:, ..) ->
      list.fold(clauses, list.fold(subjects, refs, expression), fn(refs, c) {
        let refs =
          list.fold(c.patterns, refs, fn(refs, alternative) {
            list.fold(alternative, refs, walk_pattern)
          })
        expression(optional_expression(refs, c.guard), c.body)
      })
    glance.BinaryOperator(left:, right:, ..) ->
      expression(expression(refs, left), right)
    glance.Echo(expression: inner, message:, ..) ->
      optional_expression(optional_expression(refs, inner), message)
  }
}

fn walk_pattern(refs: Refs, pattern: glance.Pattern) -> Refs {
  case pattern {
    glance.PatternInt(..)
    | glance.PatternFloat(..)
    | glance.PatternString(..)
    | glance.PatternDiscard(..)
    | glance.PatternVariable(..)
    | glance.PatternConcatenate(..) -> refs
    glance.PatternTuple(elements:, ..) ->
      list.fold(elements, refs, walk_pattern)
    glance.PatternList(elements:, tail:, ..) -> {
      let refs = list.fold(elements, refs, walk_pattern)
      case tail {
        Some(tail) -> walk_pattern(refs, tail)
        None -> refs
      }
    }
    glance.PatternAssignment(pattern: inner, ..) -> walk_pattern(refs, inner)
    glance.PatternBitString(segments:, ..) ->
      list.fold(segments, refs, fn(refs, segment) {
        list.fold(segment.1, walk_pattern(refs, segment.0), fn(refs, option) {
          case option {
            glance.SizeValueOption(glance.BitArraySizeVariable(name: n, ..)) ->
              add_name(refs, n)
            _ -> refs
          }
        })
      })
    glance.PatternVariant(module:, constructor:, arguments:, ..) -> {
      list.fold(
        arguments,
        reference(refs, module, constructor),
        fn(refs, argument) {
          case argument {
            glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
              walk_pattern(refs, item)
            glance.ShorthandField(..) -> refs
          }
        },
      )
    }
  }
}

/// The name an import is referenced by when qualified: its alias, or the
/// last segment of its path. A discarded import (`as _name`) cannot be
/// referenced qualified, so it has none.
pub fn import_qualifier(import_: glance.Import) -> Result(String, Nil) {
  case import_.alias {
    Some(glance.Named(alias)) -> Ok(alias)
    Some(glance.Discarded(_)) -> Error(Nil)
    None -> list.last(string.split(import_.module, "/"))
  }
}

/// The local names an import's unqualified values and types are used by.
pub fn import_unqualified_names(import_: glance.Import) -> List(String) {
  list.map(
    list.append(import_.unqualified_types, import_.unqualified_values),
    fn(item) { option.unwrap(item.alias, item.name) },
  )
}

/// True when `refs` uses anything `import_` brings into scope.
pub fn uses_import(refs: Refs, import_: glance.Import) -> Bool {
  let qualified = case import_qualifier(import_) {
    Ok(alias) -> set.contains(refs.qualifiers, alias)
    Error(Nil) -> False
  }
  qualified
  || list.any(import_unqualified_names(import_), set.contains(refs.names, _))
}
