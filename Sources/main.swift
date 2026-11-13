// Lumicast — native macOS menu-bar driver for a USB-serial LED backlight behind a monitor
// (built for the SkyDimo SK0L27: 27", 4-sided, 96 LEDs, CH340 controller).
// No network, no telemetry, no ads — it only reads the screen and writes colors to the strip.
//
//   Config.swift  — what you edit for your hardware (LED layout, frame rate, USB vendor)
//   Core.swift    — pure logic: color math, LED map, effects, frame packing
//   Engine.swift  — settings, serial port, the output clock
//   App.swift     — menu-bar agent, screen capture, sleep/wake handling
//   Panel.swift   — the SwiftUI control panel

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
