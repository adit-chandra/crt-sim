<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/icon-dark.png">
    <img src="docs/icon.png" width="128" height="128" alt="CRT Player app icon">
  </picture>
</p>

<h1 align="center">CRT Player</h1>

<p align="center">
  A minimal macOS video player, styled after QuickTime Player, that shows every
  frame through a simulated cathode-ray tube.
</p>

- Edge-to-edge video in a transparent title bar. The title bar and a floating Liquid Glass
  control bar fade out while the video plays.
- Multi-pass Metal CRT shader: a choice of video signal (RGB, S-Video,
  composite with dot crawl and rainbowing, or RF with ghosting and snow),
  Gaussian scanline beam that widens with brightness, aperture-grille /
  shadow-mask / slot-mask phosphors, curved faceplate with rounded corners,
  halation and bezel glow, phosphor persistence, misconvergence, hum bar and
  grain. If there's no picture yet, it shows analog snow.
- HDR output: on displays with extended dynamic range, lit phosphors can go
  brighter than SDR white, so the mask and scanlines don't dim the picture.
- Glass Pane (⌥⌘G): the window turns into a Liquid Glass pane and the picture
  becomes light on it, so the desktop shows through the dark parts of the video,
  the scanline gaps, and the corners outside the tube.
- Picture-tube transitions: windows power on and off like a CRT, and switching
  presets cuts through a burst of static.
- Presets: Classic (the default), Studio Monitor, Living Room TV, Arcade Cabinet,
  Green Terminal, and Amber Terminal. Every parameter can also be adjusted from
  the TV button in the control bar.

Requires macOS 26 and Xcode 26 or later.

## Build

```sh
make run          # builds "build/CRT Player.app" and opens it
make demo         # same, but opens a bundled test pattern (the app's --demo flag)
make app          # just build the app bundle
make install      # builds the app and copies it to /Applications
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
| ⌥⌘G | Glass Pane |
| ⌥⌘L | Loop |
| Double-click, ⌃⌘F | Full screen |

## Layout

- `Sources/CRTCore`: the renderer (`CRTRenderer`), Metal shaders, settings and presets.
- `Sources/CRTPlayer`: the AppKit/SwiftUI app (document, window, controls).
- `Sources/crt-snapshot`: renders one frame through the shader to a PNG, which is
  useful for tuning:
  `swift run crt-snapshot movie.mp4 out.png --time 5 --preset arcade`. It can also
  override the signal (`--signal composite`) or freeze a transition mid-way
  (`--transition off --at 0.3`), or preview Glass Pane over a blurred backdrop
  (`--glass wallpaper.png`).
- `Resources/AppIcon.icon`: the app icon, an Icon Composer document. Open it in
  Icon Composer to edit it; `make app` compiles it with `actool`. The README's
  `docs/icon.png` and `docs/icon-dark.png` are exported from it with Icon
  Composer's `ictool` (`--rendition Default` / `Dark`, 128×128 @2x).
