#!/usr/bin/env bash
# Check the docs mechanically:
#   1. every relative link and backticked `.md` path resolves (and its #anchor);
#   2. every ```gleam sample compiles against the current Brazier API, with
#      zero warnings, in a scratch project at build/docs_check.
#
# Usage: scripts/check_docs.sh [links | samples [DOC...] | all]   (default: all)
#   samples DOC...  compiles only the samples of the named docs (for iterating;
#                   the gate runs `all`).
#
# The marker convention for samples is described in scripts/docs_check.py
# and in CLAUDE.md ("Docs that compile"). Exits non-zero on any failure.
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

mode="${1:-all}"
if [ "$#" -gt 0 ]; then shift; fi
case "$mode" in
  samples) ;;
  links | all)
    if [ "$#" -ne 0 ]; then
      echo "usage: scripts/check_docs.sh [links | samples [DOC...] | all]" >&2
      exit 2
    fi
    ;;
  *)
    echo "usage: scripts/check_docs.sh [links | samples [DOC...] | all]" >&2
    exit 2
    ;;
esac

for tool in python3 gleam; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "docs-check: $tool is required but not on PATH" >&2
    exit 1
  fi
done

if [ "$mode" = "links" ] || [ "$mode" = "all" ]; then
  python3 -I scripts/docs_check.py links
fi

if [ "$mode" = "samples" ] || [ "$mode" = "all" ]; then
  python3 -I scripts/docs_check.py samples "$@"
  log="build/docs_check/build.log"
  echo "docs-check: compiling samples (gleam build --warnings-as-errors)"
  if ! (cd build/docs_check && gleam build --warnings-as-errors) >"$log" 2>&1; then
    cat "$log" >&2
    echo >&2
    echo "docs-check: FAILED: a sample does not compile cleanly. Generated module -> doc line:" >&2
    cat build/docs_check/index.tsv >&2
    exit 1
  fi
  # --warnings-as-errors covers the sample package; also refuse any warning
  # text in case a future Gleam reports some without failing.
  if grep -q '^warning' "$log"; then
    cat "$log" >&2
    echo "docs-check: FAILED: the sample build printed warnings" >&2
    exit 1
  fi
  echo "docs-check: $(wc -l <build/docs_check/index.tsv | tr -d ' ') sample module(s) compile with zero warnings"
fi

echo "docs-check: OK"
