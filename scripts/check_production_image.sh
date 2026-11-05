#!/usr/bin/env bash
# Build the production image (Dockerfile) for one example and check that it
# runs: the container must report healthy (its HEALTHCHECK renders /) and
# answer /health with {"status":"ok"}. CI runs it on the counter example.
#
# Usage: scripts/check_production_image.sh [EXAMPLE APP_MODULE]
#
# When HEXPM_READ_API_KEY is set, the build gets it as the BuildKit secret
# hexpm_read_api_key. The container gets a fresh SECRET_KEY, since the app
# refuses to start without one.
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "$#" -eq 0 ]; then
  example=counter
  app_module=counter
elif [ "$#" -eq 2 ]; then
  example=$1
  app_module=$2
else
  echo "usage: scripts/check_production_image.sh [EXAMPLE APP_MODULE]" >&2
  exit 2
fi

# The first health check runs after the HEALTHCHECK interval (30s).
health_timeout_seconds=120
image="brazier-image-check-$example"
container="brazier-image-check-$example-$$"

step() {
  echo "image-check: $*"
}

fail() {
  echo "image-check: FAILED: $*" >&2
  echo "image-check: container logs:" >&2
  docker logs "$container" >&2 || echo "image-check: the container's logs could not be read" >&2
  exit 1
}

for tool in docker openssl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "image-check: FAILED: $tool is required but not on PATH" >&2
    exit 1
  fi
done

secret_args=()
if [ -n "${HEXPM_READ_API_KEY:-}" ]; then
  secret_args=(--secret id=hexpm_read_api_key,env=HEXPM_READ_API_KEY)
  step "building $image (Hex requests authenticated)"
else
  step "building $image (no HEXPM_READ_API_KEY: Hex requests unauthenticated)"
fi
# The ${a[@]+...} form: bash 3.2 (macOS) treats an empty array as unset.
docker build ${secret_args[@]+"${secret_args[@]}"} \
  --build-arg "EXAMPLE=$example" --build-arg "APP_MODULE=$app_module" \
  -t "$image" .

cleanup() {
  if docker inspect "$container" >/dev/null 2>&1; then
    docker rm -f "$container" >/dev/null ||
      echo "image-check: FAILED to remove the container $container" >&2
  fi
}
trap cleanup EXIT

step "starting $container"
docker run -d --name "$container" -e SECRET_KEY="$(openssl rand -base64 48)" "$image" >/dev/null

deadline=$((SECONDS + health_timeout_seconds))
while :; do
  running=$(docker inspect -f '{{.State.Running}}' "$container")
  if [ "$running" != true ]; then
    fail "the container stopped (exit code $(docker inspect -f '{{.State.ExitCode}}' "$container"))"
  fi
  health=$(docker inspect -f '{{.State.Health.Status}}' "$container")
  case "$health" in
    healthy) break ;;
    unhealthy) fail "the container's health check failed" ;;
    starting) ;;
    *) fail "unexpected health status '$health'" ;;
  esac
  if [ "$SECONDS" -ge "$deadline" ]; then
    fail "the container was not healthy within ${health_timeout_seconds}s"
  fi
  sleep 2
done
step "the container is healthy"

otp=$(docker exec "$container" erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')
health_body=$(docker exec "$container" wget -qO- http://127.0.0.1:8080/health) ||
  fail "GET /health failed"
if [ "$health_body" != '{"status":"ok"}' ]; then
  fail "GET /health answered '$health_body', not {\"status\":\"ok\"}"
fi
step "$image runs on OTP $otp and answers /health with $health_body"
