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
