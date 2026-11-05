/// Tests for gleam.toml / manifest.toml parsing used by the build.
import brazier/build/project_toml.{
  GitRequirement, GitSource, HexRequirement, HexSource, LocalSource,
  LockedPackage, PathRequirement,
}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
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
      build_tools: ["gleam"],
      requirements: ["gleam_stdlib"],
      otp_app: Some("gleam_json"),
      source: HexSource("AB"),
    ))
  let assert Ok(brazier) = dict.get(packages, "brazier")
  assert brazier.source == LocalSource("../..")
  assert brazier.otp_app == None
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
  { name = \"ok\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"hex\", outer_checksum = \"AB\" },
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
  { name = \"x\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"ftp\" },
]
"
  let assert Error(reason) = project_toml.parse_manifest("m.toml", text)
  assert string.contains(reason, "unknown source \"ftp\"")
}

pub fn parse_manifest_non_string_requirement_test() {
  let text =
    "packages = [
  { name = \"x\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [1], source = \"hex\" },
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

fn hex_package(name: String, version: String) -> project_toml.LockedPackage {
  LockedPackage(
    name:,
    version:,
    build_tools: ["gleam"],
    requirements: [],
    otp_app: Some(name),
    source: HexSource("CHECKSUM"),
  )
}

pub fn pinned_dependency_line_hex_is_exact_test() {
  assert project_toml.pinned_dependency_line(hex_package("gleam_json", "3.1.0"))
    == Ok("gleam_json = \"== 3.1.0\"")
}

pub fn pinned_dependency_line_local_uses_the_path_as_given_test() {
  let package =
    LockedPackage(
      ..hex_package("brazier", "0.1.0"),
      source: LocalSource("../../.."),
    )
  assert project_toml.pinned_dependency_line(package)
    == Ok("brazier = { path = \"../../..\" }")
}

pub fn pinned_dependency_line_git_is_rejected_test() {
  let package =
    LockedPackage(
      ..hex_package("lib", "1.0.0"),
      source: GitSource("https://example.com/lib.git", "abc"),
    )
  let assert Error(reason) = project_toml.pinned_dependency_line(package)
  assert string.contains(reason, "comes from git")
}

/// A Hex entry without `outer_checksum` cannot be locked: Gleam would refuse
/// the client manifest, and nothing could check the tarball.
pub fn parse_manifest_hex_without_checksum_is_error_test() {
  let text =
    "packages = [
  { name = \"x\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"hex\" },
]
"
  let assert Error(reason) =
    project_toml.parse_manifest("app/manifest.toml", text)
  assert string.contains(reason, "app/manifest.toml: packages[0]")
  assert string.contains(reason, "missing key `outer_checksum`")
  assert string.contains(reason, "gleam deps download")
}

pub fn parse_manifest_missing_build_tools_is_error_test() {
  let text =
    "packages = [
  { name = \"x\", version = \"1.0.0\", requirements = [], source = \"hex\", outer_checksum = \"AB\" },
]
"
  let assert Error(reason) = project_toml.parse_manifest("m.toml", text)
  assert string.contains(reason, "missing key `build_tools`")
}

/// A requirement with no entry of its own is a broken lock, reported as one
/// and naming the package that requires it.
pub fn locked_closure_requirement_without_entry_is_inconsistent_test() {
  let text =
    "packages = [
  { name = \"a\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [\"gone\"], source = \"hex\", outer_checksum = \"AB\" },
]
"
  let assert Ok(packages) = project_toml.parse_manifest("m.toml", text)
  let assert Error(reason) = project_toml.locked_closure(packages, ["a"])
  assert string.contains(reason, "manifest.toml is inconsistent")
  assert string.contains(reason, "`a` requires `gone`")
}

/// The client manifest locks exactly the app's entries: the same versions,
/// checksums, build tools, requirements and OTP app names, and its
/// `[requirements]` state the same pins as the client's `gleam.toml`.
pub fn client_manifest_pins_the_app_entries_test() {
  let assert Ok(app) = project_toml.parse_manifest("manifest.toml", manifest)
  let assert Ok(closure) = project_toml.locked_closure(app, ["gleam_json"])
  let assert Ok(text) =
    project_toml.client_manifest("app/manifest.toml", closure)
  let assert Ok(client) = project_toml.parse_manifest("client.toml", text)
  assert sorted(dict.to_list(client))
    == list.map(closure, fn(p) { #(p.name, p) })
  assert string.contains(
    text,
    "Generated by the Brazier build from app/manifest.toml",
  )
  assert string.ends_with(
    text,
    "[requirements]
gleam_json = { version = \"== 3.1.0\" }
gleam_stdlib = { version = \"== 1.0.0\" }
",
  )
  assert string.contains(
    text,
    "  { name = \"gleam_json\", version = \"3.1.0\", build_tools = [\"gleam\"], requirements = [\"gleam_stdlib\"], otp_app = \"gleam_json\", source = \"hex\", outer_checksum = \"AB\" },\n",
  )
}

/// A local package keeps its entry with the path the caller gives, in the
/// entry and in `[requirements]`, and has no `otp_app`, as Gleam writes it.
pub fn client_manifest_local_package_test() {
  let local =
    LockedPackage(
      name: "lib",
      version: "0.2.0",
      build_tools: ["gleam"],
      requirements: [],
      otp_app: None,
      source: LocalSource("../../lib"),
    )
  let assert Ok(text) = project_toml.client_manifest("m.toml", [local])
  assert string.contains(
    text,
    "  { name = \"lib\", version = \"0.2.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../../lib\" },\n",
  )
  assert string.contains(text, "lib = { path = \"../../lib\" }\n")
  let assert Ok(client) = project_toml.parse_manifest("client.toml", text)
  assert dict.get(client, "lib") == Ok(local)
}

pub fn client_manifest_git_package_is_rejected_test() {
  let package =
    LockedPackage(
      ..hex_package("lib", "1.0.0"),
      source: GitSource("https://example.com/lib.git", "abc"),
    )
  let assert Error(reason) = project_toml.client_manifest("m.toml", [package])
  assert string.contains(reason, "comes from git")
}

pub fn parse_downloaded_reads_versions_test() {
  let text =
    "[packages]\ngleam_json = \"3.1.0\"\ngleam_stdlib = \"1.0.5\"\n\n[git]\n"
  let assert Ok(downloaded) =
    project_toml.parse_downloaded("build/packages/packages.toml", text)
  assert sorted(dict.to_list(downloaded))
    == [#("gleam_json", "3.1.0"), #("gleam_stdlib", "1.0.5")]
}

pub fn parse_downloaded_without_packages_table_is_error_test() {
  let assert Error(reason) = project_toml.parse_downloaded("p.toml", "[git]\n")
  assert reason == "p.toml: missing key `packages`"
}

pub fn parse_downloaded_non_string_version_is_error_test() {
  let assert Error(reason) =
    project_toml.parse_downloaded("p.toml", "[packages]\nx = 1\n")
  assert reason == "p.toml: packages.x must be a version string"
}

fn sorted(entries: List(#(String, a))) -> List(#(String, a)) {
  list.sort(entries, fn(a, b) { string.compare(a.0, b.0) })
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
