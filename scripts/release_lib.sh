# Shared checks for scripts/push.sh, scripts/tag.sh and scripts/publish.sh.
# Source it from bash running with `set -euo pipefail`, from the repository
# root. Every check either succeeds or exits non-zero with a message.

release_step() {
  echo "release: $*"
}

release_refuse() {
  echo "release: REFUSED: $*" >&2
  exit 1
}

release_require_tools() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      release_refuse "$tool is required but not on PATH"
    fi
  done
}

# What is pushed, tagged or published must be exactly a commit.
release_require_clean_tree() {
  local dirty
  dirty=$(git status --porcelain --untracked-files=normal)
  if [ -n "$dirty" ]; then
    echo "$dirty" >&2
    release_refuse "the working tree is not clean; commit or remove these changes first"
  fi
}

release_require_main() {
  local branch
  branch=$(git branch --show-current)
  if [ "$branch" != "main" ]; then
    release_refuse "not on main (on '${branch:-detached HEAD}'); switch to main first"
  fi
}

# Prints the single top-level `name = "..."` value of gleam.toml.
release_name() {
  local name
  if [ ! -f gleam.toml ]; then release_refuse "gleam.toml is missing"; fi
  # sed exits non-zero only on an I/O error, which set -e turns into a
  # failure; no match prints nothing, which the case below refuses.
  name=$(sed -n -E 's/^name = "([a-z][a-z0-9_]*)"$/\1/p' gleam.toml)
  case "$name" in
    '' | *$'\n'*) release_refuse "gleam.toml must have exactly one top-level name = \"...\" line" ;;
  esac
  printf '%s\n' "$name"
}

# Prints the single top-level `version = "X.Y.Z"` value of gleam.toml.
release_version() {
  local version
  if [ ! -f gleam.toml ]; then release_refuse "gleam.toml is missing"; fi
  version=$(sed -n -E 's/^version = "([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' gleam.toml)
  case "$version" in
    '' | *$'\n'*) release_refuse "gleam.toml must have exactly one top-level version = \"X.Y.Z\" line" ;;
  esac
  printf '%s\n' "$version"
}

# Refuses unless CHANGELOG.md has a `## [VERSION]` heading (optionally
# followed by ` - YYYY-MM-DD`).
release_require_changelog_heading() {
  local version="$1" version_re
  if [ ! -f CHANGELOG.md ]; then release_refuse "CHANGELOG.md is missing"; fi
  version_re=$(printf '%s' "$version" | sed 's/\./\\./g')
  if ! grep -Eq "^## \[$version_re\]( - [0-9]{4}-[0-9]{2}-[0-9]{2})?$" CHANGELOG.md; then
    release_refuse "CHANGELOG.md has no '## [$version]' heading for the gleam.toml version; move the [Unreleased] entries under one first"
  fi
}
