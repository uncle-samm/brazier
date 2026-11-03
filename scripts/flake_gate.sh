#!/bin/sh
# Flake gate: run `gleam test` RUNS times while BUSY busy loops compete for
# the CPU, and fail if any run fails. A test that only passes on an idle
# machine is waiting on timing, not on an event, and this finds it.
#
# Usage: sh scripts/flake_gate.sh
#   FLAKE_RUNS=5   number of gleam test runs (default 5)
#   FLAKE_BUSY=8   number of `yes > /dev/null` busy loops (default 8)
#   FLAKE_LOG_DIR  where each run's output goes (default build/flake_gate)
#
# Each run's full output is kept in $FLAKE_LOG_DIR/run_N.log. The busy
# loops are killed by pid on exit, including on failure or Ctrl-C.
set -u

runs="${FLAKE_RUNS:-5}"
busy="${FLAKE_BUSY:-8}"
log_dir="${FLAKE_LOG_DIR:-build/flake_gate}"

case "$runs" in ''|*[!0-9]*|0) echo "flake_gate: FLAKE_RUNS must be a positive integer, got '$runs'" >&2; exit 2 ;; esac
case "$busy" in ''|*[!0-9]*) echo "flake_gate: FLAKE_BUSY must be a non-negative integer, got '$busy'" >&2; exit 2 ;; esac

mkdir -p "$log_dir" || exit 2

busy_pids=""
stop_busy() {
  if [ -n "$busy_pids" ]; then
    # shellcheck disable=SC2086
    kill $busy_pids 2>/dev/null
    busy_pids=""
  fi
}
trap stop_busy EXIT
trap 'stop_busy; exit 130' INT TERM

i=0
while [ "$i" -lt "$busy" ]; do
  yes > /dev/null &
  busy_pids="$busy_pids $!"
  i=$((i + 1))
done
echo "flake_gate: $runs runs of gleam test under $busy busy loops; logs in $log_dir"

failed=0
run=1
while [ "$run" -le "$runs" ]; do
  log="$log_dir/run_$run.log"
  start=$(date +%s)
  gleam test > "$log" 2>&1
  code=$?
  seconds=$(( $(date +%s) - start ))
  # gleeunit's last line, e.g. "1405 passed, no failures", minus colour codes.
  summary=$(tail -c 4000 "$log" | tr -d '\033' | sed 's/\[[0-9;]*m//g' | grep -oE '[0-9]+ passed, [a-z0-9 ]+' | tail -1)
  if [ "$code" -eq 0 ]; then
    echo "flake_gate: run $run/$runs passed in ${seconds}s: $summary"
  else
    failed=$((failed + 1))
    echo "flake_gate: run $run/$runs FAILED (exit $code) in ${seconds}s: $summary" >&2
    # gleeunit's failure blocks: the assertion site, test name, code, value.
    tr -d '\033' < "$log" | sed 's/\[[0-9;]*m//g' \
      | grep -nE '^(let assert|panic|todo) |^ *(test|code|value|info): |eaddrinuse' \
      | head -40 >&2
  fi
  run=$((run + 1))
done

stop_busy
if [ "$failed" -ne 0 ]; then
  echo "flake_gate: $failed of $runs runs failed" >&2
  exit 1
fi
echo "flake_gate: all $runs runs passed"
