/// Tests for gleam.toml / manifest.toml parsing used by the build.
import brazier/build/project_toml.{
  GitRequirement, GitSource, HexRequirement, HexSource, LocalSource,
  LockedPackage, PathRequirement,
}
import gleam/dict
import gleam/list
import gleam/string

const manifest =
  "
packages = [
  { name = \"brazier\", version = \"0.1.0\", build_tools = [\"gleam\"], requirements = [\"gleam_json\", \"gleam_stdlib\"], source = \"local\", path = \"../..\" },
  { name = \"gleam_json\", version = \"3.1.0\", build_tools = [\"gleam\"], requirements = [\"gleam_stdlib\"], otp_app = \"gleam_json\", source = \"hex\", outer_checksum = \"AB\" },
  { name = \"gleam_stdlib\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], otp_app = \"gleam_stdlib\", source = \"hex\", outer_checksum = \"CD\" },
  { name = \"unrelated\", version = \"9.9.9\", build_tools = [\"gleam\"], requirements = [], source = \"hex\", outer_checksum = \"EF\" },
  { name = \"from_git\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"git\", repo = \"https://example.com/x.git\", commit = \"abc\" },
]

[requirements]
brazier = { path = \"../..\" }
"

pub fn parse_project_reads_all_requirement_kinds_test() {
  let text =
    "name = \"my_app\"
version = \"1.0.0\"

[dependencies]
gleam_stdlib = \">= 1.0.0 and < 2.0.0\"
brazier = { path = \"../..\" }
lib = { git = \"https://example.com/lib.git\", ref = \"main\" }
pinned = { version = \"== 1.2.3\" }
"
  let assert Ok(project) = project_toml.parse_project("gleam.toml", text)
  assert project.name == "my_app"
  assert dict.get(project.dependencies, "gleam_stdlib")
    == Ok(HexRequirement(">= 1.0.0 and < 2.0.0"))
  assert dict.get(project.dependencies, "brazier")
    == Ok(PathRequirement("../.."))
  assert dict.get(project.dependencies, "lib")
    == Ok(GitRequirement("https://example.com/lib.git"))
  assert dict.get(project.dependencies, "pinned")
    == Ok(HexRequirement("== 1.2.3"))
}

pub fn parse_project_without_dependencies_is_empty_test() {
  let assert Ok(project) =
    project_toml.parse_project("gleam.toml", "name = \"bare\"\n")
  assert dict.size(project.dependencies) == 0
}

pub fn parse_project_missing_name_names_the_key_test() {
  let assert Error(reason) =
    project_toml.parse_project("app/gleam.toml", "version = \"1.0.0\"\n")
  assert string.contains(reason, "app/gleam.toml")
  assert string.contains(reason, "missing key `name`")
}

pub fn parse_project_wrong_name_type_test() {
  let assert Error(reason) =
    project_toml.parse_project("gleam.toml", "name = 42\n")
  assert string.contains(reason, "key `name` must be String")
}

pub fn parse_project_invalid_toml_reports_file_test() {
  let assert Error(reason) =
    project_toml.parse_project("broken/gleam.toml", "name = \n")
  assert string.contains(reason, "Invalid TOML in broken/gleam.toml")
}

pub fn parse_project_duplicate_key_test() {
  let assert Error(reason) =
    project_toml.parse_project("gleam.toml", "name = \"a\"\nname = \"b\"\n")
  assert string.contains(reason, "defined twice")
}

pub fn parse_project_dependency_table_without_source_test() {
  let text = "name = \"a\"\n[dependencies]\nweird = { ref = \"x\" }\n"
  let assert Error(reason) = project_toml.parse_project("gleam.toml", text)
  assert string.contains(reason, "dependencies.weird")
  assert string.contains(reason, "`version`, `path` or `git`")
}

pub fn parse_project_dependency_wrong_type_test() {
  let text = "name = \"a\"\n[dependencies]\nweird = 3\n"
  let assert Error(reason) = project_toml.parse_project("gleam.toml", text)
  assert string.contains(reason, "dependencies.weird")
  assert string.contains(reason, "version string or a table")
}

pub fn parse_manifest_reads_every_source_kind_test() {
  let assert Ok(packages) =
    project_toml.parse_manifest("manifest.toml", manifest)
  assert dict.get(packages, "gleam_json")
    == Ok(LockedPackage(
      name: "gleam_json",
      version: "3.1.0",
      requirements: ["gleam_stdlib"],
      source: HexSource,
    ))
  let assert Ok(brazier) = dict.get(packages, "brazier")
  assert brazier.source == LocalSource("../..")
  let assert Ok(git) = dict.get(packages, "from_git")
  assert git.source == GitSource("https://example.com/x.git", "abc")
}

pub fn parse_manifest_missing_packages_test() {
  let assert Error(reason) =
    project_toml.parse_manifest("m.toml", "[requirements]\n")
  assert reason == "m.toml: missing `packages`"
}

pub fn parse_manifest_packages_not_array_test() {
  let assert Error(reason) =
    project_toml.parse_manifest("m.toml", "packages = 1\n")
  assert reason == "m.toml: `packages` must be an array"
}

pub fn parse_manifest_entry_missing_version_names_index_test() {
  let text =
    "packages = [
  { name = \"ok\", version = \"1.0.0\", requirements = [], source = \"hex\" },
  { name = \"bad\", requirements = [], source = \"hex\" },
]
"
  let assert Error(reason) = project_toml.parse_manifest("m.toml", text)
  assert string.contains(reason, "m.toml: packages[1]")
  assert string.contains(reason, "missing key `version`")
}

pub fn parse_manifest_unknown_source_test() {
  let text =
    "packages = [
  { name = \"x\", version = \"1.0.0\", requirements = [], source = \"ftp\" },
]
"
  let assert Error(reason) = project_toml.parse_manifest("m.toml", text)
  assert string.contains(reason, "unknown source \"ftp\"")
}

pub fn parse_manifest_non_string_requirement_test() {
  let text =
    "packages = [
  { name = \"x\", version = \"1.0.0\", requirements = [1], source = \"hex\" },
]
"
  let assert Error(reason) = project_toml.parse_manifest("m.toml", text)
  assert string.contains(reason, "requirements must be strings")
}

pub fn locked_closure_is_transitive_and_sorted_test() {
  let assert Ok(packages) =
    project_toml.parse_manifest("manifest.toml", manifest)
  let assert Ok(closure) = project_toml.locked_closure(packages, ["brazier"])
  assert list.map(closure, fn(p) { p.name })
    == ["brazier", "gleam_json", "gleam_stdlib"]
}

pub fn locked_closure_missing_package_is_error_test() {
  let assert Ok(packages) =
    project_toml.parse_manifest("manifest.toml", manifest)
  let assert Error(reason) =
    project_toml.locked_closure(packages, ["gleam_json", "not_locked"])
  assert string.contains(reason, "`not_locked`")
  assert string.contains(reason, "not locked in manifest.toml")
}

pub fn pinned_dependency_line_hex_is_exact_test() {
  let package =
    LockedPackage(
      name: "gleam_json",
      version: "3.1.0",
      requirements: [],
      source: HexSource,
    )
  assert project_toml.pinned_dependency_line(package, fn(p) { p })
    == Ok("gleam_json = \"== 3.1.0\"")
}

pub fn pinned_dependency_line_local_uses_resolved_path_test() {
  let package =
    LockedPackage(
      name: "brazier",
      version: "0.1.0",
      requirements: [],
      source: LocalSource("../.."),
    )
  assert project_toml.pinned_dependency_line(package, fn(p) { "/abs/" <> p })
    == Ok("brazier = { path = \"/abs/../..\" }")
}

pub fn pinned_dependency_line_git_is_rejected_test() {
  let package =
    LockedPackage(
      name: "lib",
      version: "1.0.0",
      requirements: [],
      source: GitSource("https://example.com/lib.git", "abc"),
    )
  let assert Error(reason) =
    project_toml.pinned_dependency_line(package, fn(p) { p })
  assert string.contains(reason, "comes from git")
}

pub fn toml_string_escapes_quotes_and_control_characters_test() {
  assert project_toml.toml_string("a\"b\\c\nd\te") == "\"a\\\"b\\\\c\\nd\\te\""
}

pub fn toml_string_round_trips_through_parser_test() {
  let value = "path with \"quotes\" and \\ backslash"
  let text = "name = " <> project_toml.toml_string(value) <> "\n"
  let assert Ok(project) = project_toml.parse_project("gleam.toml", text)
  assert project.name == value
}

pub fn brazier_root_for_framework_repo_is_project_dir_test() {
  assert project_toml.brazier_root(".") == Ok(".")
}

pub fn brazier_root_for_path_dependency_example_test() {
  assert project_toml.brazier_root("examples/counter")
    == Ok("examples/counter/../..")
}

pub fn brazier_root_missing_gleam_toml_test() {
  let assert Error(reason) = project_toml.brazier_root("does/not/exist")
  assert string.contains(reason, "Cannot read does/not/exist/gleam.toml")
}
