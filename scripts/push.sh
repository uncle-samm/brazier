#!/usr/bin/env bash
# Push main to origin. Refuses off main or with a dirty tree.
#
# Usage: scripts/push.sh
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=release_lib.sh
. scripts/release_lib.sh

if [ "$#" -ne 0 ]; then
  echo "usage: scripts/push.sh" >&2
  exit 2
fi

release_require_tools git
release_require_main
release_require_clean_tree

release_step "pushing main to origin"
git push origin main
release_step "pushed main at $(git rev-parse HEAD)"
