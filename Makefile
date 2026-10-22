APP := build/ClaudeWatcher.app

.PHONY: build app run test clean release icon

build:
	swift build

app:
	./scripts/build-app.sh

run: app
	-pkill -x ClaudeWatcher
	open $(APP)

test:
	swift test

# Regenerates Resources/AppIcon.icns (and the README's docs/icon.png) from
# scripts/make-icon.swift. Both are committed, so builds don't need this.
icon:
	@set -e; tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; \
	swift scripts/make-icon.swift "$$tmp"; \
	iconutil -c icns "$$tmp/AppIcon.iconset" -o Resources/AppIcon.icns; \
	mkdir -p docs; cp "$$tmp/AppIcon.iconset/icon_128x128@2x.png" docs/icon.png; \
	echo "wrote Resources/AppIcon.icns, docs/icon.png"

clean:
	swift package clean
	rm -rf build .build

# Notarized universal app (zip) -> GitHub release. See "Releasing" in README.md.
#   make release VERSION=1.2.3 [DRY_RUN=1 [NOTARIZE=1]] [TEAM_ID=...]
release:
	@VERSION="$(VERSION)" DRY_RUN="$(DRY_RUN)" NOTARIZE="$(NOTARIZE)" TEAM_ID="$(TEAM_ID)" scripts/release.sh
