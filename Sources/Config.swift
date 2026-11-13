// Lumicast configuration — the things you edit to match your hardware. Rebuild after changing.

import Foundation

// Physical LED layout in DATA order: the order the strips are chained from the controller.
// Each entry is (side, LED count); sides are "left", "bottom", "right", "top".
// Directions are derived — each strip starts at the corner where the previous one ended — so
// just list the sides in the order the data travels. The LED count, preview and screen
// mapping all follow from this one list.
// Default: Left → Bottom → Right → Top, one continuous loop starting at the top-left corner.
let LAYOUT: [(String, Int)] = [("left", 17), ("bottom", 31), ("right", 17), ("top", 31)]

// Output frame rate. 15 fps with a full drain after every frame is the pacing that latched
// reliably on the SK0L27 during bring-up (30 fps did not).
let FPS = 15

// USB vendor IDs that port auto-detection accepts (0x1A86 = WCH, maker of the CH340).
// A serial adapter from any other vendor is never written to. To force a specific port:
//   defaults write com.abhinav.lumicast port /dev/cu.yourdevice
let USB_VENDOR_IDS: Set<Int> = [0x1A86]

let SOLID_PRESETS: [(String, Int, Int, Int)] = [
    ("Warm", 255, 150, 80), ("White", 255, 255, 255), ("Red", 255, 0, 0),
    ("Green", 0, 255, 0), ("Blue", 0, 0, 255), ("Cyan", 0, 255, 255),
]
let EFFECTS = ["Rainbow", "Color cycle", "Breathe", "Comet", "Wave"]
