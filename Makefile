# chromeos-linux without Nix: fetch, build, and (optionally) verify.
#
#   make            # chrome + sommelier + bridges
#   make fetch      # download the pinned ChromiumOS Chrome snapshot
#   make verify     # ldd/readelf sanity checks on everything we built
#
# System integration (D-Bus policy, directories, lsb-release) is a separate,
# explicit root step: sudo ./scripts/setup-system.sh

SHELL := /bin/bash
.DEFAULT_GOAL := all

.PHONY: all fetch chrome sommelier bridges vendor clean distclean verify test

all: chrome sommelier bridges

fetch:
	./chromeos-bin/fetch.sh

chrome: fetch
	./scripts/build-chrome.sh

sommelier:
	./scripts/build-sommelier.sh

bridges:
	./scripts/build-bridges.sh

# Pre-download Go modules into .cache/go-mod for offline rebuilds, then build
# from vendor/.
vendor:
	VENDOR=1 ./scripts/build-bridges.sh

verify:
	./scripts/verify.sh

# Needs a running system bus plus the D-Bus policy (setup-system.sh).
test:
	./scripts/smoke-test.sh

clean:
	rm -rf dist .cache/sommelier/build .cache/go-mod

distclean: clean
	rm -rf .cache chromeos-bin/chrome chromeos-bin/.stage
