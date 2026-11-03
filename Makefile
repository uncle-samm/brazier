.PHONY: build test test-client test-flake bench bench-check bench-baseline browser-canonical browser-canonical-desktop browser-canonical-mobile browser-all browser-all-desktop browser-all-mobile browser-all-shard browser-all-docker-shards push tag publish release

build:
	gleam build

test:
	gleam test

# The client JS checks that need no Gleam-generated input. They also run
# inside gleam test (patch_test, runtime_versioning_test), with the vector
# checks; this target is the fast loop and fails if node is missing.
test-client:
	node beacon_client/test/ffi_harness.mjs
	node beacon_client/test/patch_safety.mjs

# gleam test FLAKE_RUNS times (default 5) under FLAKE_BUSY busy loops
# (default 8); fails if any run fails.
test-flake:
	sh scripts/flake_gate.sh

# Benchmarks (docs/PERFORMANCE.md). Never part of gleam test.
# bench: one run, printed and written to build/bench/latest.json.
bench:
	gleam run -m beacon_bench

# bench-check: BEACON_BENCH_RUNS runs (default 3) against
# bench/baselines.json; exits non-zero on a regression beyond a metric's
# tolerance, a missing or new metric, or a different machine.
bench-check:
	gleam run -m beacon_bench_check

# bench-baseline: BEACON_BENCH_RUNS runs (default 5) on an idle machine,
# written to bench/baselines.json.
bench-baseline:
	gleam run -m beacon_bench_baseline

browser-canonical:
	sh scripts/run_canonical_cdp.sh

browser-canonical-desktop:
	BEACON_CDP_VIEWPORTS=desktop sh scripts/run_canonical_cdp.sh

browser-canonical-mobile:
	BEACON_CDP_VIEWPORTS=mobile sh scripts/run_canonical_cdp.sh

browser-all:
	sh scripts/run_all_cdp.sh

browser-all-desktop:
	BEACON_CDP_VIEWPORTS=desktop sh scripts/run_all_cdp.sh

browser-all-mobile:
	BEACON_CDP_VIEWPORTS=mobile sh scripts/run_all_cdp.sh

browser-all-shard:
	sh scripts/run_all_cdp.sh --shard "$${BEACON_CDP_SHARD:?set BEACON_CDP_SHARD=INDEX/TOTAL}"

browser-all-docker-shards:
	sh scripts/run_cdp_shards_docker.sh

push:
	sh scripts/push.sh

tag:
	sh scripts/tag.sh

publish:
	/usr/bin/expect scripts/publish.sh

release: push tag publish
