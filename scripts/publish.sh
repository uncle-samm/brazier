#!/usr/bin/env bash
# Publish the package to Hex, after the release gate passes.
#
# Usage: scripts/publish.sh [--dry-run]
#
# Refuses, before publishing anything, when:
#   - the working tree has uncommitted or untracked changes;
#   - gleam.toml has no single `name` or `version = "X.Y.Z"` line;
#   - CHANGELOG.md has no `## [X.Y.Z]` heading for that version;
#   - a clean `gleam build --warnings-as-errors` fails;
#   - `gleam format --check src test` fails;
#   - `gleam run -m brazier/lint` reports a violation;
#   - `gleam test` fails;
#   - `scripts/check_docs.sh` fails;
#   - `gleam export hex-tarball` cannot build the package;
#   - (real publish only) neither HEXPM_API_KEY nor .hex_api_key holds a key.
#
# --dry-run runs every check and builds the tarball, then stops. It never
# contacts Hex. `gleam publish` has no dry-run flag of its own, so the dry run
# ends at `gleam export hex-tarball`, which builds the package `gleam publish`
# would upload.
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=release_lib.sh
. scripts/release_lib.sh

usage() {
  echo "usage: scripts/publish.sh [--dry-run]" >&2
  exit 2
}

dry_run=0
case "$#" in
  0) ;;
  1)
    if [ "$1" = "--dry-run" ]; then dry_run=1; else usage; fi
    ;;
  *) usage ;;
esac

release_require_tools git gleam python3

release_require_clean_tree
head=$(git rev-parse HEAD)
release_step "tree is clean at $head"

name=$(release_name)
version=$(release_version)
release_require_changelog_heading "$version"
release_step "gleam.toml ($name $version) matches a CHANGELOG.md heading"

# Remove the package's own build output first, so the compiler re-checks
# every module and cannot hide a warning in the cache.
release_step "clean build with warnings as errors"
rm -rf "build/dev/erlang/$name"
gleam build --warnings-as-errors

release_step "format check"
gleam format --check src test

release_step "lint"
gleam run -m brazier/lint

release_step "tests"
gleam test

release_step "docs check"
scripts/check_docs.sh

# A Hex tarball carries only src/, priv/ and the metadata files, and Gleam
# does not follow symlinks into it. The build tool of an app that gets
# Brazier from Hex reads the client runtime from priv/brazier_client_src
# (project_toml.client_runtime_dir), so copy brazier_client/src there for
# the tarball and for `gleam publish`, and remove the copy on exit.
# priv/brazier_client_src/ is gitignored, so the clean-tree checks pass.
runtime_copy=priv/brazier_client_src
if [ -e "$runtime_copy" ]; then
  release_refuse "$runtime_copy already exists; remove it, it is staged by this script"
fi
trap 'rm -rf "$ROOT/$runtime_copy"' EXIT
release_step "stage brazier_client/src as $runtime_copy"
mkdir -p "$runtime_copy"
cp -R brazier_client/src/. "$runtime_copy/"
if [ ! -f "$runtime_copy/brazier_client_ffi.mjs" ]; then
  release_refuse "$runtime_copy/brazier_client_ffi.mjs is missing after the copy"
fi

release_step "build the Hex tarball"
gleam export hex-tarball
release_require_tarball_file "build/$name-$version.tar" "$runtime_copy/brazier_client_ffi.mjs"

# The gate must not have changed the tree (a test or tool writing a tracked
# file would mean the tarball is not the commit).
release_require_clean_tree

if [ "$dry_run" = "1" ]; then
  release_step "dry run: every check passed for $name $version at $head; nothing was published"
  exit 0
fi

if [ -z "${HEXPM_API_KEY:-}" ]; then
  if [ ! -f .hex_api_key ]; then
    release_refuse "set HEXPM_API_KEY or create .hex_api_key (it is gitignored)"
  fi
  HEXPM_API_KEY=$(tr -d '[:space:]' <.hex_api_key)
  if [ -z "$HEXPM_API_KEY" ]; then
    release_refuse ".hex_api_key is empty"
  fi
  export HEXPM_API_KEY
fi

release_step "publishing $name $version to Hex; answer Gleam's prompts to confirm"
gleam publish
release_step "published $name $version from $head"
