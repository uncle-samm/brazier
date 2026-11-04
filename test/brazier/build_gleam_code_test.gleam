/// Tests for the structured Gleam source builder used by brazier/build.
import brazier/build/gleam_code.{
  Arg, BinOp, Call, Case, Clause, Concat, Ctor, ExprStmt, Function, Import, Let,
  Module, PCtor, PDiscard, PString, PVar, Param, Pipe, Ref, Str, TNamed, Use,
  Var,
}
import gleam/option.{None, Some}
import gleam/string

fn string_type() {
  TNamed(None, "String", [])
}

fn simple_module(body) {
  Module(
    docs: ["generated"],
    imports: [
      Import("gleam/json", Some("brazier_json")),
      Import("gleam/list", None),
    ],
    definitions: [
      Function(
        name: "go",
        public: True,
        docs: [],
        params: [Param("value", string_type())],
        return: string_type(),
        body: body,
      ),
    ],
  )
}

pub fn renders_and_prunes_unused_imports_test() {
  let assert Ok(source) =
    gleam_code.render(
      simple_module([
        ExprStmt(
          Call(Ref(Some("brazier_json"), "to_string"), [Arg(Var("value"))]),
        ),
      ]),
    )
  assert string.contains(source, "/// generated")
  assert string.contains(source, "import gleam/json as brazier_json")
  assert !string.contains(source, "import gleam/list")
  assert string.contains(source, "pub fn go(value: String) -> String {")
  assert string.contains(source, "brazier_json.to_string(value)")
}

pub fn reference_without_import_is_an_error_test() {
  let assert Error(reason) =
    gleam_code.render(
      simple_module([ExprStmt(Call(Ref(Some("missing"), "f"), []))]),
    )
  assert string.contains(reason, "not imported: missing")
}

pub fn duplicate_import_names_are_an_error_test() {
  let module =
    Module(
      docs: [],
      imports: [Import("a/types", None), Import("b/types", None)],
      definitions: [],
    )
  let assert Error(reason) = gleam_code.render(module)
  assert string.contains(reason, "both named `types`")
}

pub fn duplicate_functions_are_an_error_test() {
  let def =
    Function(
      name: "f",
      public: False,
      docs: [],
      params: [],
      return: string_type(),
      body: [ExprStmt(Str("x"))],
    )
  let assert Error(reason) =
    gleam_code.render(Module(docs: [], imports: [], definitions: [def, def]))
  assert string.contains(reason, "`f` is defined twice")
}

pub fn invalid_identifiers_are_rejected_test() {
  let assert Error(reason) =
    gleam_code.render(simple_module([Let(PVar("type"), Str("x"))]))
  assert string.contains(reason, "`type` is not a valid name")
  let assert Error(reason) =
    gleam_code.render(simple_module([ExprStmt(Ctor(None, "lower"))]))
  assert string.contains(reason, "`lower` is not a valid constructor")
  let assert Error(reason) =
    gleam_code.render(simple_module([ExprStmt(Var("Bad-name"))]))
  assert string.contains(reason, "`Bad-name`")
  let assert Error(reason) =
    gleam_code.render(simple_module([ExprStmt(Var("_hidden"))]))
  assert string.contains(reason, "used as a value")
}

pub fn invalid_import_path_is_rejected_test() {
  let module =
    Module(docs: [], imports: [Import("app/../x", None)], definitions: [])
  let assert Error(reason) = gleam_code.render(module)
  assert string.contains(reason, "not a valid module path")
}

pub fn string_literals_escape_user_values_test() {
  assert gleam_code.string_literal("a\"b\\c\nd\te\r\u{0001}")
    == "\"a\\\"b\\\\c\\nd\\te\\r\\u{1}\""
  assert gleam_code.string_literal("héllo ✓") == "\"héllo ✓\""
  let assert Ok(source) =
    gleam_code.render(simple_module([ExprStmt(Str("\"} panic {\""))]))
  assert string.contains(source, "\"\\\"} panic {\\\"\"")
}

pub fn case_clause_arity_is_checked_test() {
  let assert Error(reason) =
    gleam_code.render(
      simple_module([
        ExprStmt(
          Case([Var("value")], [Clause([PDiscard(""), PDiscard("")], Str("x"))]),
        ),
      ]),
    )
  assert string.contains(reason, "different number of patterns")
}

pub fn compound_operands_are_wrapped_test() {
  let assert Ok(source) =
    gleam_code.render(
      simple_module([
        ExprStmt(BinOp(
          Concat,
          Pipe(Var("value"), Ref(None, "go")),
          Case([Var("value")], [
            Clause([PString("a")], Str("b")),
            Clause([PDiscard("")], Var("value")),
          ]),
        )),
      ]),
    )
  assert string.contains(source, "{\nvalue\n|> go\n} <> {\ncase value {")
  assert string.contains(source, "\"a\" -> \"b\"")
}

pub fn constructor_patterns_render_spread_test() {
  let assert Ok(source) =
    gleam_code.render(
      Module(
        docs: [],
        imports: [Import("app", Some("brazier_app"))],
        definitions: [
          Function(
            name: "tag",
            public: True,
            docs: [],
            params: [Param("msg", TNamed(Some("brazier_app"), "Msg", []))],
            return: string_type(),
            body: [
              Use(["x"], Ref(None, "tag")),
              ExprStmt(
                Case([Var("msg")], [
                  Clause(
                    [PCtor(Some("brazier_app"), "Clicked", [], True)],
                    Str("Clicked"),
                  ),
                  Clause(
                    [PCtor(Some("brazier_app"), "Set", [PVar("v")], True)],
                    Str("Set"),
                  ),
                  Clause(
                    [PCtor(Some("brazier_app"), "Reset", [], False)],
                    Var("x"),
                  ),
                ]),
              ),
            ],
          ),
        ],
      ),
    )
  assert string.contains(source, "import app as brazier_app")
  assert string.contains(source, "brazier_app.Clicked(..) -> \"Clicked\"")
  assert string.contains(source, "brazier_app.Set(v, ..) -> \"Set\"")
  assert string.contains(source, "brazier_app.Reset -> x")
  assert string.contains(source, "use x <- tag")
}
