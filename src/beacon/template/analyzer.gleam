/// Template analyzer — uses Glance to walk view function ASTs and classify
/// elements as static (no model dependency) or dynamic (depends on model).
///
/// Reference: LiveView HEEx compile-time template splitting,
/// Architecture doc section 9 (Build-Time Template Analysis).
import glance
import gleam/list
import gleam/option.{None, Some}

/// Classification of an expression in a view function.
pub type Classification {
  /// The expression doesn't depend on any model fields.
  Static
  /// The expression depends on one or more model fields.
  Dynamic(dependencies: List(String))
}

/// Analyze a Gleam source string containing a view function.
/// Returns the list of model field dependencies found in the view function.
pub fn analyze_view_source(
  source: String,
  model_param_name: String,
) -> Result(List(String), String) {
  case glance.module(source) {
    Ok(module) -> {
      case find_view_function(module) {
        Ok(func) -> {
          let deps = extract_model_dependencies(func, model_param_name)
          Ok(deps)
        }
        Error(reason) -> Error(reason)
      }
    }
    Error(_parse_err) -> Error("Failed to parse source")
  }
}

/// Find the public `view` function in a module.
fn find_view_function(
  module: glance.Module,
) -> Result(glance.Function, String) {
  let view_fns =
    list.filter(module.functions, fn(def) {
      def.definition.publicity == glance.Public && def.definition.name == "view"
    })
  case view_fns {
    [def, ..] -> Ok(def.definition)
    [] -> Error("No public 'view' function found")
  }
}

/// Extract all model field dependencies from a function body.
/// Looks for patterns like `model.field_name` in the AST.
pub fn extract_model_dependencies(
  func: glance.Function,
  model_param: String,
) -> List(String) {
  let deps =
    list.flat_map(func.body, fn(statement) {
      extract_deps_from_statement(statement, model_param)
    })
  list.unique(deps)
}

/// Extract dependencies from a statement.
fn extract_deps_from_statement(
  statement: glance.Statement,
  model_param: String,
) -> List(String) {
  case statement {
    glance.Expression(expr) -> extract_deps_from_expression(expr, model_param)
    glance.Assignment(value: expr, ..) ->
      extract_deps_from_expression(expr, model_param)
    _ -> []
  }
}

/// Extract dependencies from an expression.
/// Recursively walks the AST looking for `model.field` patterns.
fn extract_deps_from_expression(
  expr: glance.Expression,
  model_param: String,
) -> List(String) {
  case expr {
    // model.field_name — FieldAccess on a Variable
    glance.FieldAccess(
      container: glance.Variable(name: var_name, ..),
      label: field_name,
      ..,
    ) -> {
      case var_name == model_param {
        True -> [field_name]
        False -> []
      }
    }

    // Nested field access: something.field where something might reference model
    glance.FieldAccess(container: inner, ..) ->
      extract_deps_from_expression(inner, model_param)

    // Variable reference to model itself (passed to a function)
    glance.Variable(name: var_name, ..) -> {
      case var_name == model_param {
        True -> ["*"]
        False -> []
      }
    }

    // Function call — check function and all arguments
    glance.Call(function: func_expr, arguments: args, ..) -> {
      let func_deps = extract_deps_from_expression(func_expr, model_param)
      let arg_deps =
        list.flat_map(args, fn(arg) {
          case arg {
            glance.LabelledField(item: value, ..) ->
              extract_deps_from_expression(value, model_param)
            glance.ShorthandField(..) -> []
            glance.UnlabelledField(item: value) ->
              extract_deps_from_expression(value, model_param)
          }
        })
      list.append(func_deps, arg_deps)
    }

    // Binary operator (e.g., string concatenation <>)
    glance.BinaryOperator(left: left, right: right, ..) ->
      list.append(
        extract_deps_from_expression(left, model_param),
        extract_deps_from_expression(right, model_param),
      )

    // List literal
    glance.List(elements: elements, rest: rest, ..) -> {
      let elem_deps =
        list.flat_map(elements, fn(e) {
          extract_deps_from_expression(e, model_param)
        })
      let rest_deps = case rest {
        None -> []
        Some(rest_expr) -> extract_deps_from_expression(rest_expr, model_param)
      }
      list.append(elem_deps, rest_deps)
    }

    // Tuple
    glance.Tuple(elements: elements, ..) ->
      list.flat_map(elements, fn(e) {
        extract_deps_from_expression(e, model_param)
      })

    // Block (sequence of statements)
    glance.Block(statements: statements, ..) ->
      list.flat_map(statements, fn(s) {
        extract_deps_from_statement(s, model_param)
      })

    // Case expression
    glance.Case(subjects: subjects, clauses: clauses, ..) -> {
      let subject_deps =
        list.flat_map(subjects, fn(s) {
          extract_deps_from_expression(s, model_param)
        })
      let clause_deps =
        list.flat_map(clauses, fn(clause) {
          extract_deps_from_expression(clause.body, model_param)
        })
      list.append(subject_deps, clause_deps)
    }

    // Negate
    glance.NegateInt(value: inner, ..) ->
      extract_deps_from_expression(inner, model_param)
    glance.NegateBool(value: inner, ..) ->
      extract_deps_from_expression(inner, model_param)

    // String, Int, Float literals — no dependencies
    glance.String(..) | glance.Int(..) | glance.Float(..) -> []

    // Fn (anonymous function) — walk body
    glance.Fn(body: body, ..) ->
      list.flat_map(body, fn(s) { extract_deps_from_statement(s, model_param) })

    // Anything else — conservatively return empty
    _ -> []
  }
}

/// Check if a classification is static.
pub fn is_static(classification: Classification) -> Bool {
  case classification {
    Static -> True
    Dynamic(_) -> False
  }
}

/// Check if a classification is dynamic.
pub fn is_dynamic(classification: Classification) -> Bool {
  case classification {
    Static -> False
    Dynamic(_) -> True
  }
}
