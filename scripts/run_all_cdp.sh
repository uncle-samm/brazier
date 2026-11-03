#!/usr/bin/env sh
# Run the browser (CDP) conformance harness, test_all_cdp.py, against a
# temporary headless Chrome, once per viewport in BEACON_CDP_VIEWPORTS.
#
# Usage: scripts/run_all_cdp.sh [test_all_cdp.py ARGS...]
#   scripts/run_canonical_cdp.sh is this script with --canonical.
#
# Environment: PYTHON_BIN, CDP_PORT (9223), CHROME_BIN, CHROME_PROFILE_DIR,
# CHROME_EXTRA_ARGS, BEACON_CDP_VIEWPORTS ("desktop mobile").
#
# POSIX sh on purpose: the Makefile and the Dockerfile.ci container run it
# with `sh`.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PYTHON_BIN="${PYTHON_BIN:-$ROOT/.venv/bin/python}"
CDP_PORT="${CDP_PORT:-9223}"
PROFILE_DIR="${CHROME_PROFILE_DIR:-$ROOT/.tmp/chrome-cdp-profile}"
CHROME_LOG="$ROOT/.tmp/cdp-chrome-$CDP_PORT.log"
VIEWPORTS="${BEACON_CDP_VIEWPORTS:-desktop mobile}"

if [ ! -x "$PYTHON_BIN" ]; then
  echo "missing executable Python environment: $PYTHON_BIN" >&2
  echo "create it with: uv venv .venv && .venv/bin/pip install -r requirements-dev.txt" >&2
  exit 1
fi

if [ -n "${CHROME_BIN:-}" ]; then
  CHROME="$CHROME_BIN"
elif [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
elif command -v google-chrome >/dev/null 2>&1; then
  CHROME="$(command -v google-chrome)"
elif command -v chromium >/dev/null 2>&1; then
  CHROME="$(command -v chromium)"
elif command -v chromium-browser >/dev/null 2>&1; then
  CHROME="$(command -v chromium-browser)"
else
  echo "missing Chrome/Chromium. Set CHROME_BIN to a headless-capable browser." >&2
  exit 1
fi

mkdir -p "$PROFILE_DIR" "$ROOT/.tmp"

# CHROME_EXTRA_ARGS is split on whitespace on purpose (one flag per word).
# shellcheck disable=SC2086
"$CHROME" \
  --headless=new \
  --remote-debugging-port="$CDP_PORT" \
  --user-data-dir="$PROFILE_DIR" \
  --disable-gpu \
  ${CHROME_EXTRA_ARGS:-} \
  --no-first-run \
  --no-default-browser-check \
  about:blank >"$CHROME_LOG" 2>&1 &
CHROME_PID=$!

# Stop Chrome on exit. It may already have exited (it crashed, or the readiness
# loop below saw it die); that is reported there, so only signal a live one.
# `wait` then returns Chrome's status from our SIGTERM (143), which is the
# expected outcome of the kill, not a failure to report.
cleanup() {
  if kill -0 "$CHROME_PID" 2>/dev/null; then
    kill "$CHROME_PID"
    wait "$CHROME_PID" 2>/dev/null || :
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

chrome_failed() {
  echo "$1" >&2
  echo "--- last 40 lines of $CHROME_LOG ---" >&2
  tail -40 "$CHROME_LOG" >&2
  exit 1
}

# Poll the CDP endpoint. A refused connection is the expected answer until
# Chrome is listening, so each probe's own error is not reported; the loop
# fails loudly if Chrome exits or never answers.
ready=0
for _ in $(seq 1 60); do
  if ! kill -0 "$CHROME_PID" 2>/dev/null; then
    chrome_failed "Chrome exited before exposing CDP on port $CDP_PORT"
  fi
  if "$PYTHON_BIN" -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$CDP_PORT/json', timeout=0.5).read()" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.25
done

if [ "$ready" != "1" ]; then
  chrome_failed "Chrome did not expose CDP on port $CDP_PORT within 15s"
fi

cd "$ROOT"
for VIEWPORT in $VIEWPORTS; do
  echo "== Beacon browser conformance: viewport=$VIEWPORT args=[$*] =="
  PYTHONUNBUFFERED=1 "$PYTHON_BIN" test_all_cdp.py --viewport "$VIEWPORT" "$@"
done
