.PHONY: app run snapshot clean

app:
	./scripts/build-app.sh

run: app
	open "build/CRT Player.app"

snapshot:
	swift build -c release --product crt-snapshot

clean:
	rm -rf .build build
