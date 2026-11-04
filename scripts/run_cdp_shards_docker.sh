#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/refuse_renamed_env.sh"
IMAGE="${BRAZIER_CDP_DOCKER_IMAGE:-brazier-cdp:local}"
TOTAL="${BRAZIER_CDP_TOTAL_SHARDS:-23}"
VIEWPORTS="${BRAZIER_CDP_VIEWPORTS:-desktop}"
LOG_DIR="${BRAZIER_CDP_DOCKER_LOG_DIR:-$ROOT/.tmp/cdp-shards}"
REQUESTED_SHARDS="${BRAZIER_CDP_SHARDS:-}"
SKIP_DOCKER_BUILD="${BRAZIER_CDP_SKIP_DOCKER_BUILD:-0}"
PREBUILD_EXAMPLES="${BRAZIER_CDP_PREBUILD_EXAMPLES:-0}"
SERVER_TIMEOUT="${BRAZIER_CDP_SERVER_TIMEOUT:-90}"

# Prints the host CPU count, or exits non-zero when it cannot be read. There
# is no guessed default: set BRAZIER_CDP_PARALLEL on a host without nproc or
# sysctl hw.ncpu.
cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu
  else
    echo "cannot read the CPU count (no nproc or sysctl); set BRAZIER_CDP_PARALLEL" >&2
    exit 1
  fi
}

default_parallel() {
  cpu="$(cpu_count)"
  case "$cpu" in
    ''|*[!0-9]*)
      echo "CPU count '$cpu' is not an integer; set BRAZIER_CDP_PARALLEL" >&2
      exit 1
      ;;
  esac
  half=$((cpu / 2))
  if [ "$half" -lt 1 ]; then half=1; fi
  if [ "$half" -gt "$SHARD_COUNT" ]; then half="$SHARD_COUNT"; fi
  echo "$half"
}

case "$TOTAL" in
  ''|*[!0-9]*)
    echo "BRAZIER_CDP_TOTAL_SHARDS must be an integer" >&2
    exit 1
    ;;
esac

if [ "$TOTAL" -lt 1 ]; then
  echo "BRAZIER_CDP_TOTAL_SHARDS must be >= 1" >&2
  exit 1
fi

if [ -n "$REQUESTED_SHARDS" ]; then
  SHARD_LIST="$(printf '%s\n' "$REQUESTED_SHARDS" | tr ',' ' ')"
else
  SHARD_LIST="$(seq 1 "$TOTAL")"
fi

SHARD_COUNT=0
for shard in $SHARD_LIST; do
  case "$shard" in
    ''|*[!0-9]*)
      echo "BRAZIER_CDP_SHARDS entries must be integers" >&2
      exit 1
      ;;
  esac

  if [ "$shard" -lt 1 ] || [ "$shard" -gt "$TOTAL" ]; then
    echo "BRAZIER_CDP_SHARDS entry $shard is outside 1..$TOTAL" >&2
    exit 1
  fi

  SHARD_COUNT=$((SHARD_COUNT + 1))
done

if [ "$SHARD_COUNT" -lt 1 ]; then
  echo "at least one shard is required" >&2
  exit 1
fi

# Assign in two steps: a plain assignment from $(...) carries the
# substitution's exit status, so set -e stops here if default_parallel fails.
if [ -n "${BRAZIER_CDP_PARALLEL:-}" ]; then
  PARALLEL="$BRAZIER_CDP_PARALLEL"
else
  PARALLEL="$(default_parallel)"
fi

case "$PARALLEL" in
  ''|*[!0-9]*)
    echo "BRAZIER_CDP_PARALLEL must be an integer" >&2
    exit 1
    ;;
esac

if [ "$PARALLEL" -lt 1 ]; then
  echo "BRAZIER_CDP_PARALLEL must be >= 1" >&2
  exit 1
fi

if [ "$PARALLEL" -gt "$SHARD_COUNT" ]; then
  PARALLEL="$SHARD_COUNT"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for per-container CDP sharding" >&2
  exit 1
fi

case "$SKIP_DOCKER_BUILD" in
  0|1) ;;
  *)
    echo "BRAZIER_CDP_SKIP_DOCKER_BUILD must be 0 or 1" >&2
    exit 1
    ;;
esac

case "$PREBUILD_EXAMPLES" in
  0|1) ;;
  *)
    echo "BRAZIER_CDP_PREBUILD_EXAMPLES must be 0 or 1" >&2
    exit 1
    ;;
esac

case "$SERVER_TIMEOUT" in
  ''|*[!0-9]*)
    echo "BRAZIER_CDP_SERVER_TIMEOUT must be an integer number of seconds" >&2
    exit 1
    ;;
esac

if [ "$SERVER_TIMEOUT" -lt 1 ]; then
  echo "BRAZIER_CDP_SERVER_TIMEOUT must be >= 1" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/shard-*.log "$LOG_DIR"/summary.txt

if [ "$SKIP_DOCKER_BUILD" = "1" ]; then
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Docker image $IMAGE does not exist; unset BRAZIER_CDP_SKIP_DOCKER_BUILD or build it first" >&2
    exit 1
  fi
  echo "Using existing Docker image $IMAGE"
else
  echo "Building $IMAGE from Dockerfile.ci"
  docker build \
    --build-arg BRAZIER_CDP_PREBUILD_EXAMPLES="$PREBUILD_EXAMPLES" \
    -f "$ROOT/Dockerfile.ci" \
    -t "$IMAGE" \
    "$ROOT"
fi

echo "Running $SHARD_COUNT selected CDP shard container(s) of $TOTAL total, parallel=$PARALLEL, viewport(s)=$VIEWPORTS"
start_epoch=$(date +%s)
failures=0
running=0
remaining_shards="$SHARD_LIST"

run_shard() {
  shard="$1"
  log_file="$LOG_DIR/shard-$shard.log"
  name="brazier-cdp-shard-$shard-$$"
  (
    docker run --rm \
      --name "$name" \
      --shm-size=1g \
      -e BRAZIER_CDP_VIEWPORTS="$VIEWPORTS" \
      -e BRAZIER_CDP_SHARD="$shard/$TOTAL" \
      -e BRAZIER_CDP_SERVER_TIMEOUT="$SERVER_TIMEOUT" \
      "$IMAGE" \
      sh scripts/run_all_cdp.sh --shard "$shard/$TOTAL"
  ) >"$log_file" 2>&1 &
  echo "$!:$shard" >>"$LOG_DIR/pids"
}

wait_one() {
  pid="$1"
  shard="$2"
  if wait "$pid"; then
    echo "shard $shard/$TOTAL passed"
  else
    echo "shard $shard/$TOTAL failed; see $LOG_DIR/shard-$shard.log" >&2
    failures=$((failures + 1))
  fi
}

: >"$LOG_DIR/pids"
active_pids=""
active_shards=""

while [ -n "$remaining_shards" ] || [ -n "$active_pids" ]; do
  while [ -n "$remaining_shards" ] && [ "$running" -lt "$PARALLEL" ]; do
    set -- $remaining_shards
    shard="$1"
    shift
    remaining_shards="$*"

    run_shard "$shard"
    active_pids="$active_pids $(tail -n 1 "$LOG_DIR/pids" | cut -d: -f1)"
    active_shards="$active_shards $shard"
    running=$((running + 1))
  done

  set -- $active_pids
  first_pid="$1"
  set -- $active_shards
  first_shard="$1"
  wait_one "$first_pid" "$first_shard"

  active_pids="$(printf '%s\n' $active_pids | sed '1d' | tr '\n' ' ')"
  active_shards="$(printf '%s\n' $active_shards | sed '1d' | tr '\n' ' ')"
  running=$((running - 1))
done

end_epoch=$(date +%s)
elapsed=$((end_epoch - start_epoch))
{
  echo "total_shards=$TOTAL"
  echo "selected_shards=$SHARD_LIST"
  echo "selected_count=$SHARD_COUNT"
  echo "parallel=$PARALLEL"
  echo "viewports=$VIEWPORTS"
  echo "skip_docker_build=$SKIP_DOCKER_BUILD"
  echo "prebuild_examples=$PREBUILD_EXAMPLES"
  echo "server_timeout=$SERVER_TIMEOUT"
  echo "elapsed_seconds=$elapsed"
  echo "failures=$failures"
} >"$LOG_DIR/summary.txt"

echo "Docker shard run elapsed: ${elapsed}s"
echo "Logs: $LOG_DIR"

if [ "$failures" -ne 0 ]; then
  exit 1
fi
