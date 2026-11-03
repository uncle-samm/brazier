#!/usr/bin/env bash
# Tag HEAD of main as v<gleam.toml version> and push the tag.
#
# Usage: scripts/tag.sh
#
# Refuses off main, with a dirty tree, without a CHANGELOG.md heading for the
# version, or when the tag already exists locally or on origin.
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=release_lib.sh
. scripts/release_lib.sh

if [ "$#" -ne 0 ]; then
  echo "usage: scripts/tag.sh" >&2
  exit 2
fi

release_require_tools git
release_require_main
release_require_clean_tree

version=$(release_version)
release_require_changelog_heading "$version"
tag="v$version"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  release_refuse "tag $tag already exists locally"
fi
# ls-remote exits non-zero when origin cannot be reached, which set -e
# reports; an empty answer means the tag is not there.
remote_tag=$(git ls-remote --tags origin "refs/tags/$tag")
if [ -n "$remote_tag" ]; then
  release_refuse "tag $tag already exists on origin"
fi

release_step "creating tag $tag at $(git rev-parse HEAD)"
git tag "$tag"
release_step "pushing tag $tag"
git push origin "$tag"
release_step "tagged and pushed $tag"
