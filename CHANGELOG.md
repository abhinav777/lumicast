# Changelog

Each `## vX.Y.Z` section becomes that version's release notes when its tag is pushed.

## v1.0.1

A fix release. If v1.0.0 would not open for you, this is why.

### Fixed
- **The app now launches on macOS 13 and later, on Apple silicon and Intel.** The v1.0.0 download
  was built for Apple silicon only and required macOS 26, despite claiming macOS 13.
- **The power button returns to the mode you were using**, including after a relaunch. Quitting
  no longer saves the mode as "off", so the lights resume as you left them.
- **The strip goes dark when you're away** — when the display sleeps, and on quit, logout,
  shutdown or `kill` — and comes back afterwards.
- **Mirror recovers** after sleep or a display change, and shows black rather than a frozen frame
  when no capture is running. Brightness, color order and smoothing no longer wait for the screen
  to change.
- **Screen capture only runs while Mirror is selected**, and nothing touches screen capture at
  launch, so Solid and Effects never raise a permission prompt.
- **Effects no longer jump** when you drag the speed slider.
- **Right-click on the menu-bar icon** opens a Quit menu.

### Changed
- **Port detection goes by USB vendor ID** (WCH, the maker of the CH340) and never writes to
  another vendor's serial adapter. To force a device:
  `defaults write com.abhinav.lumicast port /dev/cu.yourdevice`.
- **Wiring is one list.** The LED count, preview and screen mapping all follow from `LAYOUT` in
  `Sources/Config.swift`, and strip directions follow the data path, so reversed and 3-sided
  strips work.
- A hardware-free test suite checks every byte sent to the controller (`tests/run.sh`).

## v1.0.0

First public release: Solid, Effects and Mirror modes for the SkyDimo SK0L27.
