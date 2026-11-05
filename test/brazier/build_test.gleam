/// Build system tests: command line, source collection and external
/// programs.
import brazier/build
import brazier/build/discovery
import brazier/build/program
import brazier/build/sources
import gleam/list
import gleam/string
import simplifile

// === Command line ===

pub fn parse_args_defaults_to_src_test() {
  let assert Ok(build.SourceDir("src")) = build.parse_args([])
}

pub fn parse_args_gleam_file_is_the_app_module_test() {
  let assert Ok(build.AppFile("src/my_app.gleam")) =
    build.parse_args(["src/my_app.gleam"])
}

pub fn parse_args_other_argument_is_a_source_dir_test() {
  let assert Ok(build.SourceDir("app/src")) = build.parse_args(["app/src"])
}

pub fn parse_args_rejects_extra_arguments_test() {
  let assert Error(reason) = build.parse_args(["src", "extra"])
  let assert True = string.contains(reason, "src extra")
  let assert True = string.contains(reason, build.usage)
}

// === Source collection ===

fn fresh_tree(root: String, files: List(#(String, String))) -> Nil {
  let assert Ok(Nil) = case simplifile.delete(root) {
    Ok(Nil) -> Ok(Nil)
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
  list.each(files, fn(file) {
    let path = root <> "/" <> file.0
    let assert Ok(Nil) = simplifile.create_directory_all(parent(path))
    let assert Ok(Nil) = simplifile.write(path, file.1)
  })
}

fn parent(path: String) -> String {
  let assert Ok(#(_, dir)) = string.split_once(string.reverse(path), "/")
  string.reverse(dir)
}

pub fn app_externals_recurses_through_user_modules_test() {
  let src = "build/brazier_test_app_externals/src"
  let app_source =
    "import types/models\npub type Model { Model(status: models.AgentRunStatus) }\n"
  fresh_tree(src, [
    #("app.gleam", app_source),
    #(
      "types/models.gleam",
      "import types/enums\npub type AgentRunStatus { AgentRunStatus(type_: enums.AgentType) }\n",
    ),
    #("types/enums.gleam", "pub type AgentType { Codex Gemini }\n"),
  ])
  let app =
    discovery.AppModule(
      path: src <> "/app.gleam",
      module_path: "app",
      source: app_source,
    )
  let assert Ok(sources) = sources.app_externals(src, app)
  let assert [#("types/models", _), #("types/enums", _)] = sources
}

pub fn app_externals_excludes_the_app_and_unimported_siblings_test() {
  let src = "build/brazier_test_app_externals_siblings/src"
  let app_source = "import helper\nimport gleam/int\npub fn main() { 1 }\n"
  fresh_tree(src, [
    #("app.gleam", app_source),
    // The helper imports the app back; the app is still not an external.
    #("helper.gleam", "import app\npub fn x() { app.main() }\n"),
    #("unrelated.gleam", "pub const secret = \"s\"\n"),
  ])
  let app =
    discovery.AppModule(
      path: src <> "/app.gleam",
      module_path: "app",
      source: app_source,
    )
  let assert Ok([#("helper", _)]) = sources.app_externals(src, app)
}

pub fn app_externals_reports_unparsable_user_module_test() {
  let src = "build/brazier_test_app_externals_broken/src"
  let app_source = "import broken\npub type Model { Model(count: Int) }\n"
  fresh_tree(src, [#("app.gleam", app_source), #("broken.gleam", "pub type {")])
  let app =
    discovery.AppModule(
      path: src <> "/app.gleam",
      module_path: "app",
      source: app_source,
    )
  let assert Error(reason) = sources.app_externals(src, app)
  let assert True = string.contains(reason, "broken.gleam")
}

pub fn framework_closure_follows_brazier_imports_test() {
  let source = "import brazier/html\nimport gleam/int\npub fn x() { 1 }\n"
  let assert Ok(sources) = sources.framework_closure(".", [source])
  let module_paths = list.map(sources, fn(s) { s.0 })
  let assert True = list.contains(module_paths, "brazier/html")
  let assert True = list.contains(module_paths, "brazier/element")
  let assert True = list.contains(module_paths, "brazier/attribute")
  let assert True = list.contains(module_paths, "brazier/internal/render")
  // The shimmed module is generated for the client, never copied, and
  // nothing outside the import graph is pulled in.
  let assert False = list.contains(module_paths, "brazier/log")
  let assert False = list.contains(module_paths, "brazier/runtime")
  let assert False = list.contains(module_paths, "gleam/int")
}

pub fn framework_closure_missing_module_is_an_error_test() {
  let source = "import brazier/no_such_module\n"
  let assert Error(reason) = sources.framework_closure(".", [source])
  let assert True = string.contains(reason, "no_such_module")
}

// === External programs ===

pub fn program_run_passes_unicode_arguments_unchanged_test() {
  let assert Ok(output) =
    program.run(".", "printf", ["%s", "zoë \" </script> 日本"])
  let assert "zoë \" </script> 日本" = output
}

pub fn program_run_nonzero_exit_is_an_error_test() {
  let assert Error(reason) = program.run(".", "sh", ["-c", "echo boom; exit 3"])
  let assert True = string.contains(reason, "boom")
  let assert True = string.contains(reason, "Exit status: 3")
  let assert True = string.contains(reason, "`sh -c")
}

pub fn program_warnings_reads_headlines_and_locations_test() {
  let output =
    "  Compiling app\n"
    <> "warning: Unused value\n"
    <> "    ┌─ /p/src/app.gleam:3:3\n"
    <> "    │\n"
    <> "3 │   f(x)\n"
    <> "\n"
    <> "warning: Deprecated value used\n"
    <> "\n"
    <> "   Compiled in 0.10s\n"
    <> "warning: Unused variable"
  let assert [
    "Unused value at /p/src/app.gleam:3:3",
    "Deprecated value used",
    "Unused variable",
  ] = program.warnings(output)
}

pub fn program_warnings_of_a_clean_build_is_empty_test() {
  let assert [] =
    program.warnings(
      "  Compiling app\n   Compiled in 0.10s\nno warning: here\n",
    )
}

/// The parser against the compiler's real output: a project with an unused
/// private function builds, and its one warning is read with its location.
pub fn program_warnings_reads_a_real_gleam_build_test() {
  let dir = "build/brazier_test_program_warnings"
  let assert Ok(Nil) = simplifile.delete_all([dir])
  let assert Ok(Nil) = simplifile.create_directory_all(dir <> "/src")
  let assert Ok(Nil) =
    simplifile.write(
      dir <> "/gleam.toml",
      "name = \"warned\"\nversion = \"1.0.0\"\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      dir <> "/src/warned.gleam",
      "pub fn main() { 1 }\n\nfn unused() { 2 }\n",
    )
  let assert Ok(output) = program.run(dir, "gleam", ["build"])
  let assert [warning] = program.warnings(output)
  let assert True = string.starts_with(warning, "Unused private function at ")
  let assert True = string.ends_with(warning, "src/warned.gleam:3:1")
  let assert Ok(Nil) = program.gleam_build(dir)
  let assert Ok(Nil) = simplifile.delete(dir)
}

pub fn program_run_missing_executable_is_an_error_test() {
  let assert Error(reason) = program.run(".", "brazier-no-such-program", [])
  let assert True =
    string.contains(reason, "Executable not found: brazier-no-such-program")
}

pub fn program_absolute_path_keeps_unicode_test() {
  let assert Ok(path) = program.absolute_path("build/zoë/日本.gleam")
    as "the test's current directory exists"
  let assert True = string.starts_with(path, "/")
  let assert True = string.ends_with(path, "/build/zoë/日本.gleam")
}

/// A current directory deleted under the VM cannot be read: resolving a
/// path is an `Error` naming the path and the reason. filename:absname/1
/// used to crash the build with a badmatch instead.
pub fn program_absolute_path_without_a_current_directory_is_an_error_test() {
  let assert Error(reason) =
    in_deleted_directory("build/brazier_test_gone_cwd", fn() {
      program.absolute_path("src/app.gleam")
    })
    as "a deleted current directory cannot be read"
  assert string.contains(reason, "Cannot resolve src/app.gleam")
  assert string.contains(reason, "no such file or directory")
}

/// Run `run` with the current directory set to `dir`, which is deleted
/// first, then restore the current directory.
@external(erlang, "brazier_build_test_ffi", "in_deleted_directory")
fn in_deleted_directory(dir: String, run: fn() -> a) -> a

pub fn program_content_hash_is_stable_test() {
  let hash = program.content_hash("bundle")
  let assert 16 = string.length(hash)
  let assert True = hash == program.content_hash("bundle")
  let assert True = hash != program.content_hash("bundle2")
}
