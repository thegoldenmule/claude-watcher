APP := build/ClaudeWatcher.app

.PHONY: build app run test clean

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
