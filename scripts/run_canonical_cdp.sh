#!/usr/bin/env sh
# Run the canonical browser conformance matrix: scripts/run_all_cdp.sh with
# --canonical. Usage and environment are the same as run_all_cdp.sh.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
exec sh "$ROOT/scripts/run_all_cdp.sh" --canonical "$@"
