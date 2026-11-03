.PHONY: build test browser-canonical browser-canonical-desktop browser-canonical-mobile browser-all browser-all-desktop browser-all-mobile browser-all-shard browser-all-docker-shards push tag publish publish-dry-run release

build:
	gleam build

test:
	gleam test

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
	bash scripts/push.sh

tag:
	bash scripts/tag.sh

publish:
	bash scripts/publish.sh

publish-dry-run:
	bash scripts/publish.sh --dry-run

# The dry run gates the release before anything is pushed or tagged.
release: publish-dry-run push tag publish
