.PHONY: build test test-client test-flake bench bench-check bench-baseline browser-canonical browser-canonical-desktop browser-canonical-mobile browser-all browser-all-desktop browser-all-mobile browser-all-shard browser-all-docker-shards browser-timeline push tag publish publish-dry-run release

build:
	gleam build

test:
	gleam test

# The client JS checks that need no Gleam-generated input. They also run
# inside gleam test (patch_test, runtime_versioning_test), with the vector
# checks; this target is the fast loop and fails if node is missing.
test-client:
	node brazier_client/test/ffi_harness.mjs
	node brazier_client/test/patch_safety.mjs
	node brazier_client/test/apply_equivalence.mjs
	node brazier_client/test/stream_vectors.mjs

# gleam test FLAKE_RUNS times (default 5) under FLAKE_BUSY busy loops
# (default 8); fails if any run fails.
test-flake:
	sh scripts/flake_gate.sh

# Benchmarks (docs/PERFORMANCE.md). Never part of gleam test.
# bench: one run, printed and written to build/bench/latest.json.
bench:
	gleam run -m brazier_bench

# bench-check: BRAZIER_BENCH_RUNS runs (default 3) against
# bench/baselines.json; exits non-zero on a regression beyond a metric's
# tolerance, a missing or new metric, or a different machine.
bench-check:
	gleam run -m brazier_bench_check

# bench-baseline: BRAZIER_BENCH_RUNS runs (default 5) on an idle machine,
# written to bench/baselines.json.
bench-baseline:
	gleam run -m brazier_bench_baseline

browser-canonical:
	sh scripts/run_canonical_cdp.sh

browser-canonical-desktop:
	BRAZIER_CDP_VIEWPORTS=desktop sh scripts/run_canonical_cdp.sh

browser-canonical-mobile:
	BRAZIER_CDP_VIEWPORTS=mobile sh scripts/run_canonical_cdp.sh

browser-all:
	sh scripts/run_all_cdp.sh

browser-all-desktop:
	BRAZIER_CDP_VIEWPORTS=desktop sh scripts/run_all_cdp.sh

browser-all-mobile:
	BRAZIER_CDP_VIEWPORTS=mobile sh scripts/run_all_cdp.sh

browser-all-shard:
	sh scripts/run_all_cdp.sh --shard "$${BRAZIER_CDP_SHARD:?set BRAZIER_CDP_SHARD=INDEX/TOTAL}"

browser-all-docker-shards:
	sh scripts/run_cdp_shards_docker.sh

# The stream example's browser slice (docs/CONFORMANCE.md#timeline-contract).
browser-timeline:
	sh scripts/run_all_cdp.sh timeline

push:
	bash scripts/push.sh

tag:
	bash scripts/tag.sh

publish:
	bash scripts/publish.sh

publish-dry-run:
	bash scripts/publish.sh --dry-run

# The dry run gates the release before anything is pushed or tagged.
release: publish-dry-run push tag publish
