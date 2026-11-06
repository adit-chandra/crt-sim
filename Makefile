.PHONY: app run demo install snapshot clean

APP := build/CRT Sim.app
INSTALL_DIR ?= /Applications

app:
	@./scripts/build-app.sh

run: app
	open "$(APP)"

demo: app
	open "$(APP)" --args --demo

install: app
	@./scripts/build-app.sh --install --install-dir "$(INSTALL_DIR)"

snapshot:
	swift build -c release --product crt-snapshot

clean:
	rm -rf .build build

# The existing commands above continue to target macOS.
.PHONY: macos ios ios-open ios-test
macos: app

ios:
	@python3 scripts/build-ios.py build

ios-open:
	open Apps/iOS/CRTPlayer.xcodeproj

ios-test:
	@python3 scripts/build-ios.py test
