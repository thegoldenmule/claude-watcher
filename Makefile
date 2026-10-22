APP := build/ClaudeWatcher.app

.PHONY: build app run test clean release

build:
	swift build

app:
	./scripts/build-app.sh

run: app
	-pkill -x ClaudeWatcher
	open $(APP)

test:
	swift test

clean:
	swift package clean
	rm -rf build .build

# Notarized universal app (zip) -> GitHub release. See "Releasing" in README.md.
#   make release VERSION=1.2.3 [DRY_RUN=1 [NOTARIZE=1]] [TEAM_ID=...]
release:
	@VERSION="$(VERSION)" DRY_RUN="$(DRY_RUN)" NOTARIZE="$(NOTARIZE)" TEAM_ID="$(TEAM_ID)" scripts/release.sh
