.PHONY: app run promote snapshot clean

APP := build/CRT Player.app

app:
	./scripts/build-app.sh

run: app
	open "$(APP)"

promote: app
	rm -rf "/Applications/CRT Player.app"
	ditto "$(APP)" "/Applications/CRT Player.app"
	@echo "Installed /Applications/CRT Player.app"

snapshot:
	swift build -c release --product crt-snapshot

clean:
	rm -rf .build build
