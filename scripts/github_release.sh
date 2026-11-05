#!/usr/bin/env bash
# Create the GitHub release for v<gleam.toml version>. Publishing the release
# starts .github/workflows/publish.yml, which publishes that version to Hex.
#
# Usage: scripts/github_release.sh
#
# Refuses off main, with a dirty tree, without a CHANGELOG.md heading for the
# version, when the tag is not on origin at HEAD (run scripts/tag.sh first),
# or when the release already exists.
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=release_lib.sh
. scripts/release_lib.sh

if [ "$#" -ne 0 ]; then
  echo "usage: scripts/github_release.sh" >&2
  exit 2
fi

release_require_tools git gh
release_require_main
release_require_clean_tree

version=$(release_version)
release_require_changelog_heading "$version"
tag="v$version"
head=$(git rev-parse HEAD)

# ls-remote exits non-zero when origin cannot be reached, which set -e
# reports. An annotated tag lists its commit on the ^{} line.
remote_tag=$(git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")
if [ -z "$remote_tag" ]; then
  release_refuse "tag $tag is not on origin; run scripts/tag.sh first"
fi
tag_commit=$(printf '%s\n' "$remote_tag" | awk -v ref="refs/tags/$tag^{}" '$2 == ref { print $1 }')
if [ -z "$tag_commit" ]; then
  tag_commit=$(printf '%s\n' "$remote_tag" | awk '{ print $1; exit }')
fi
if [ "$tag_commit" != "$head" ]; then
  release_refuse "tag $tag on origin is $tag_commit, not HEAD $head"
fi

# `gh release view` fails both for a missing release and for an unreachable
# GitHub, so list the releases and look for the tag instead.
existing=$(gh release list --limit 1000 --json tagName --jq ".[] | select(.tagName == \"$tag\") | .tagName")
if [ -n "$existing" ]; then
  release_refuse "the GitHub release $tag already exists"
fi

repo_url=$(gh repo view --json url --jq .url)
release_step "creating the GitHub release $tag at $head"
gh release create "$tag" \
  --verify-tag \
  --title "$tag" \
  --notes "The changes are listed under $version in [CHANGELOG.md]($repo_url/blob/$tag/CHANGELOG.md). Publishing this release publishes $version to Hex (.github/workflows/publish.yml), after approval of the hex environment."
release_step "created the GitHub release $tag; approve the Publish workflow's hex environment to publish to Hex"
