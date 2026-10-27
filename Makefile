.PHONY: app run demo install snapshot clean

APP := build/CRT Player.app

app:
	./scripts/build-app.sh

run: app
	open "$(APP)"

demo: app
	open "$(APP)" --args --demo

install: app
	rm -rf "/Applications/CRT Player.app"
	ditto "$(APP)" "/Applications/CRT Player.app"
	@echo "Installed /Applications/CRT Player.app"

snapshot:
	swift build -c release --product crt-snapshot

clean:
	rm -rf .build build
