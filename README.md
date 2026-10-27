# CRT Player

A minimal macOS video player, styled after QuickTime Player, that shows every
frame through a simulated cathode-ray tube.

- Edge-to-edge video in a transparent title bar. The title bar and a floating Liquid Glass
  control bar fade out while the video plays.
- Multi-pass Metal CRT shader: composite-style signal bandwidth and chroma
  bleed, Gaussian scanline beam that widens with brightness, aperture-grille /
  shadow-mask / slot-mask phosphors, curved faceplate with rounded corners,
  halation and bezel glow, phosphor persistence, misconvergence, hum bar and
  grain. If there's no picture yet, it shows analog snow.
- Presets: Studio Monitor, Living Room TV, Arcade Cabinet, Green Terminal,
  Amber Terminal. Each parameter can also be adjusted from the TV button in the control bar.

Requires macOS 26 and Xcode 26 or later.

## Build

```sh
make run          # builds "build/CRT Player.app" and opens it
make app          # just build the app bundle
swift run CRTPlayer   # run unbundled during development
```

Open videos with ⌘O, by dropping them on the window or Dock icon, or with
Finder's Open With menu. Any format AVFoundation plays will work.

## Shortcuts

| Key | Action |
| --- | --- |
| Space | Play / pause |
| ← / → | Skip 10 seconds |
| ↑ / ↓ | Volume |
| ⌘E | Toggle the CRT effect |
| ⌘[ / ⌘] | Previous / next preset |
| ⌘I | CRT settings |
| ⌥⌘L | Loop |
| Double-click, ⌃⌘F | Full screen |

## Layout

- `Sources/CRTCore`: the renderer (`CRTRenderer`), Metal shaders, settings and presets.
- `Sources/CRTPlayer`: the AppKit/SwiftUI app (document, window, controls).
- `Sources/crt-snapshot`: renders one frame through the shader to a PNG, which is
  useful for tuning:
  `swift run crt-snapshot movie.mp4 out.png --time 5 --preset arcade`
- `scripts/make-icon.swift`: regenerates `Resources/AppIcon.icns`.
