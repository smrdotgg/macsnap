.PHONY: build test app install snapshots check clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

install:
	scripts/install.sh

# Renders the real views offscreen with synthesized input into build/ui-snapshots.
snapshots: build
	MACSNAP_UI_SNAPSHOT=$(CURDIR)/.build/ui-snapshots $$(swift build --show-bin-path)/MacSnap
	@echo "open .build/ui-snapshots"

check: test snapshots

clean:
	rm -rf .build dist
