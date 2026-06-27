// Lumicast — native macOS menu-bar ambient-light driver for the SkyDimo SK0L27
// (27" 4-sided, 96-LED CH340 controller). Replaces the vendor app entirely.
// No network, no telemetry, no ads — it only reads the screen and writes colors to the strip.
//
// Protocol (reverse-engineered + confirmed live):
//   CH340 serial @ 115200 8N1, bare stream of 96 x 3 bytes, byte order GRB.
//
// Output is driven by a STEADY 30fps timer (not the capture callback) so the strip always
// stays lit — the controller blanks itself if it stops receiving data for ~1s.

import AppKit
import SwiftUI
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import ServiceManagement
import Darwin

let N_LEDS = 96
let GRID_W = 31
let GRID_H = 17
// Raw-mode controllers latch a frame on the idle gap after it. At 30fps the gap is too short
// (~8ms) and frames never latch; ledprobe works because it leaves ~33ms. 15fps + tcdrain gives
// a ~40ms idle gap per frame — matching ledprobe's proven pacing.
let FPS = 15
let DEFAULT_PORT = "/dev/cu.usbserial-130"

// Vendor frame header (reverse-engineered from SKController::onLayoutChanged):
//   "Ada" + 0x00 + LED count as 16-bit big-endian.  Required on EVERY frame so the
//   controller re-syncs and latches — without it only the first frame after open shows.
let HDR: [UInt8] = [0x41, 0x64, 0x61, 0x00, UInt8((N_LEDS >> 8) & 0xFF), UInt8(N_LEDS & 0xFF)]
let HDR_LEN = 6
let FRAME_LEN = HDR_LEN + N_LEDS * 3

let SOLID_PRESETS: [(String, Int, Int, Int)] = [
    ("Warm", 255, 150, 80), ("White", 255, 255, 255), ("Red", 255, 0, 0),
    ("Green", 0, 255, 0), ("Blue", 0, 0, 255), ("Cyan", 0, 255, 255),
]
let EFFECTS = ["Rainbow", "Color cycle", "Breathe", "Comet", "Wave"]

func frac(_ x: Double) -> Double { let r = x.truncatingRemainder(dividingBy: 1.0); return r < 0 ? r + 1 : r }
func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
    let f = h * 6.0 - Double(Int(h * 6.0))
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    let r: Double, g: Double, b: Double
    switch (Int(h * 6.0) % 6 + 6) % 6 {
    case 0: (r, g, b) = (v, t, p)
    case 1: (r, g, b) = (q, v, p)
    case 2: (r, g, b) = (p, v, t)
    case 3: (r, g, b) = (p, q, v)
    case 4: (r, g, b) = (t, p, v)
    default: (r, g, b) = (v, p, q)
    }
    return (r * 255, g * 255, b * 255)
}

func findSerialPort() -> String {
    let fm = FileManager.default
    if fm.fileExists(atPath: DEFAULT_PORT) { return DEFAULT_PORT }
    if let items = try? fm.contentsOfDirectory(atPath: "/dev") {
        for prefix in ["cu.usbserial", "cu.wchusbserial", "cu.SLAB_USBtoUART"] {
            if let m = items.first(where: { $0.hasPrefix(prefix) }) { return "/dev/" + m }
        }
    }
    return DEFAULT_PORT
}

// =====================================================================
// MARK: - Settings (thread-safe, persisted)
// =====================================================================
final class Settings {
    static let shared = Settings()
    private let lock = NSLock()
    private let d = UserDefaults.standard

    private var _mode: String          // "off" | "solid" | "mirror"
    private var _brightness: Double
    private var _grb: Bool
    private var _displayIndex: Int
    private var _r: Int; private var _g: Int; private var _b: Int
    private var _fxIndex: Int; private var _fxSpeed: Double

    private init() {
        d.register(defaults: ["mode": "off", "brightness": 0.7, "grb": false, "displayIndex": 0,
                              "solidR": 255, "solidG": 150, "solidB": 80, "fxIndex": 0, "fxSpeed": 0.5])
        _mode = d.string(forKey: "mode") ?? "off"
        _brightness = d.double(forKey: "brightness")
        _grb = d.bool(forKey: "grb")
        _displayIndex = d.integer(forKey: "displayIndex")
        _r = d.integer(forKey: "solidR"); _g = d.integer(forKey: "solidG"); _b = d.integer(forKey: "solidB")
        _fxIndex = d.integer(forKey: "fxIndex"); _fxSpeed = d.double(forKey: "fxSpeed")
    }

    var mode: String { get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; d.set(newValue, forKey: "mode"); lock.unlock() } }
    var brightness: Double { get { lock.lock(); defer { lock.unlock() }; return _brightness }
        set { lock.lock(); _brightness = newValue; d.set(newValue, forKey: "brightness"); lock.unlock() } }
    var grb: Bool { get { lock.lock(); defer { lock.unlock() }; return _grb }
        set { lock.lock(); _grb = newValue; d.set(newValue, forKey: "grb"); lock.unlock() } }
    var displayIndex: Int { get { lock.lock(); defer { lock.unlock() }; return _displayIndex }
        set { lock.lock(); _displayIndex = newValue; d.set(newValue, forKey: "displayIndex"); lock.unlock() } }
    var solidColor: (Int, Int, Int) {
        get { lock.lock(); defer { lock.unlock() }; return (_r, _g, _b) }
        set { lock.lock(); _r = newValue.0; _g = newValue.1; _b = newValue.2
              d.set(_r, forKey: "solidR"); d.set(_g, forKey: "solidG"); d.set(_b, forKey: "solidB"); lock.unlock() }
    }
    var fxIndex: Int { get { lock.lock(); defer { lock.unlock() }; return _fxIndex }
        set { lock.lock(); _fxIndex = newValue; d.set(newValue, forKey: "fxIndex"); lock.unlock() } }
    var fxSpeed: Double { get { lock.lock(); defer { lock.unlock() }; return _fxSpeed }
        set { lock.lock(); _fxSpeed = newValue; d.set(newValue, forKey: "fxSpeed"); lock.unlock() } }
}

// =====================================================================
// MARK: - Serial port (POSIX termios)
// =====================================================================
final class Serial {
    private(set) var fd: Int32 = -1
    private(set) var path: String
    init(_ path: String) { self.path = path }

    @discardableResult
    func openPort() -> Bool {
        path = findSerialPort()
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd < 0 { return false }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetispeed(&t, speed_t(B115200))
        cfsetospeed(&t, speed_t(B115200))
        let CRTSCTS: tcflag_t = 0x0003_0000
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~CRTSCTS
        t.c_cflag &= ~tcflag_t(PARENB)
        t.c_cflag &= ~tcflag_t(CSTOPB)
        t.c_cflag = (t.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS8)
        tcsetattr(fd, TCSANOW, &t)
        _ = fcntl(fd, F_SETFL, 0)
        return true
    }

    var isOpen: Bool { fd >= 0 }

    func writeFrame(_ bytes: [UInt8]) {
        guard fd >= 0 else { return }
        var ok = true
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { ok = false; return }
            var off = 0
            let total = bytes.count
            while off < total {
                let n = Darwin.write(fd, base + off, total - off)
                if n <= 0 { closePort(); ok = false; return }
                off += n
            }
        }
        // Wait for the frame to fully transmit before the next one — without this the kernel
        // serial buffer backs up and the blocking write() eventually stalls. (This is the
        // difference between the working ledprobe and the previously-stalling app.)
        if ok && fd >= 0 { tcdrain(fd) }
    }

    func closePort() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
}

// =====================================================================
// MARK: - LED map
// =====================================================================
struct LedPt { let x: Double; let y: Double }

// Physical LED layout in DATA order — EDIT THIS to match how your strips are wired.
// Each entry is (side, LED count). Default: strip 1 = Left, 2 = Bottom, 3 = Right, 4 = Top —
// one continuous loop (directions are derived so consecutive strips meet at a shared corner).
let LAYOUT: [(String, Int)] = [("left", 17), ("bottom", 31), ("right", 17), ("top", 31)]

func genLedMap() -> [LedPt] {
    let W = Double(GRID_W - 1), H = Double(GRID_H - 1)   // x: 0..left→right, y: 0..top→bottom
    var m = [LedPt]()
    for (side, count) in LAYOUT {
        for k in 0..<count {
            let f = count > 1 ? Double(k) / Double(count - 1) : 0
            switch side {
            case "left":   m.append(LedPt(x: 0,         y: f * H))         // top → bottom
            case "bottom": m.append(LedPt(x: f * W,     y: H))            // left → right
            case "right":  m.append(LedPt(x: W,         y: (1 - f) * H))  // bottom → top
            default:       m.append(LedPt(x: (1 - f) * W, y: 0))          // top: right → left
            }
        }
    }
    return m
}

// =====================================================================
// MARK: - Engine: steady 30fps output, three modes, live preview
// =====================================================================
final class Engine: NSObject, SCStreamOutput, SCStreamDelegate {
    let serial: Serial
    let leds: [LedPt]
    let queue = DispatchQueue(label: "lumicast.capture")
    private var timer: DispatchSourceTimer?
    private var ticks = 0

    private var mirrorFrame = [UInt8](repeating: 0, count: FRAME_LEN)  // [header][GRB]
    private var output = [UInt8](repeating: 0, count: FRAME_LEN)
    private var smooth = [Double](repeating: 0, count: N_LEDS * 3)
    private var lut = [UInt8](repeating: 0, count: 256)
    private var lutBrightness = -1.0
    private let gamma = 2.2
    private let smoothing = 0.5

    private let previewLock = NSLock()
    private var previewRGB = [UInt8](repeating: 0, count: N_LEDS * 3)

    init(serial: Serial, leds: [LedPt]) {
        self.serial = serial; self.leds = leds
        for i in 0..<HDR_LEN { output[i] = HDR[i]; mirrorFrame[i] = HDR[i] }   // prefill header once
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(1000 / FPS), leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }

    func snapshotPreview() -> [UInt8] { previewLock.lock(); defer { previewLock.unlock() }; return previewRGB }
    private func setPreview(_ rgb: [UInt8]) { previewLock.lock(); previewRGB = rgb; previewLock.unlock() }

    private func ensureLUT(_ b: Double) {
        if b == lutBrightness { return }
        for i in 0..<256 { lut[i] = UInt8(max(0.0, min(255.0, pow(Double(i)/255.0, gamma) * 255.0 * b))) }
        lutBrightness = b
    }

    private func solidFrame(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: N_LEDS * 3)
        var i = 0; while i < N_LEDS { a[i*3] = r; a[i*3+1] = g; a[i*3+2] = b; i += 1 }
        return a
    }

    private func tick() {
        ticks &+= 1
        if !serial.isOpen { if ticks % FPS == 0 { _ = serial.openPort() } }
        switch Settings.shared.mode {
        case "solid":
            let b = Settings.shared.brightness; ensureLUT(b)
            let grb = Settings.shared.grb
            let (r0, g0, b0) = Settings.shared.solidColor
            let r = min(255, max(0, r0)), g = min(255, max(0, g0)), bl = min(255, max(0, b0))
            let R = lut[r], G = lut[g], B = lut[bl]
            var i = 0
            while i < N_LEDS {
                let o = HDR_LEN + i*3
                if grb { output[o] = G; output[o+1] = R; output[o+2] = B }
                else   { output[o] = R; output[o+1] = G; output[o+2] = B }
                i += 1
            }
            setPreview(solidFrame(UInt8(r), UInt8(g), UInt8(bl)))
        case "mirror":
            output = mirrorFrame
        case "fx":
            let b = Settings.shared.brightness; ensureLUT(b)
            let grb = Settings.shared.grb
            let fx = Settings.shared.fxIndex
            let sp = max(0.1, Settings.shared.fxSpeed)
            let phase = Double(ticks) * 0.012 * sp
            var prev = [UInt8](repeating: 0, count: N_LEDS * 3)
            var i = 0
            while i < N_LEDS {
                var rr = 0.0, gg = 0.0, bb = 0.0
                switch fx {
                case 1:  // color cycle — whole strip one hue
                    (rr, gg, bb) = hsv(frac(phase), 1, 1)
                case 2:  // breathe
                    let bri = (sin(Double(ticks) * 0.05 * sp) + 1) / 2 * 0.85 + 0.15
                    (rr, gg, bb) = hsv(frac(phase * 0.3), 1, bri)
                case 3:  // comet chasing around the perimeter
                    let pos = frac(phase) * Double(N_LEDS)
                    var d = abs(Double(i) - pos); if d > Double(N_LEDS) / 2 { d = Double(N_LEDS) - d }
                    let inten = max(0.0, 1.0 - d / 9.0)
                    let (cr, cg, cb) = hsv(frac(phase), 1, 1)
                    (rr, gg, bb) = (cr * inten, cg * inten, cb * inten)
                case 4:  // wave — two rainbow cycles scrolling
                    (rr, gg, bb) = hsv(frac(Double(i) / Double(N_LEDS) * 2 + phase), 1, 1)
                default: // rainbow flowing around the perimeter
                    (rr, gg, bb) = hsv(frac(Double(i) / Double(N_LEDS) + phase), 1, 1)
                }
                let pr = UInt8(max(0.0, min(255.0, rr))), pg = UInt8(max(0.0, min(255.0, gg))), pb = UInt8(max(0.0, min(255.0, bb)))
                prev[i*3] = pr; prev[i*3+1] = pg; prev[i*3+2] = pb
                let R = lut[Int(pr)], G = lut[Int(pg)], B = lut[Int(pb)]
                let o = HDR_LEN + i*3
                if grb { output[o] = G; output[o+1] = R; output[o+2] = B }
                else   { output[o] = R; output[o+1] = G; output[o+2] = B }
                i += 1
            }
            setPreview(prev)
        default:
            for i in HDR_LEN..<output.count { output[i] = 0 }   // keep header, blank the RGB
            setPreview(solidFrame(0, 0, 0))
        }
        serial.writeFrame(output)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, Settings.shared.mode == "mirror",
              CMSampleBufferIsValid(sampleBuffer),
              let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let b = Settings.shared.brightness; ensureLUT(b)
        let grb = Settings.shared.grb
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        let bpr = CVPixelBufferGetBytesPerRow(px)
        guard w > 0, h > 0, let baseRaw = CVPixelBufferGetBaseAddress(px) else { return }
        let base = baseRaw.assumingMemoryBound(to: UInt8.self)
        var preview = [UInt8](repeating: 0, count: N_LEDS * 3)
        let rad = 3
        for (i, p) in leds.enumerated() {
            let u = GRID_W > 1 ? p.x / Double(GRID_W - 1) : 0
            let v = GRID_H > 1 ? p.y / Double(GRID_H - 1) : 0
            let cx = Int(u * Double(w - 1)), cy = Int(v * Double(h - 1))
            let xs = max(0, cx - rad), xe = min(w - 1, cx + rad)
            let ys = max(0, cy - rad), ye = min(h - 1, cy + rad)
            var rs = 0, gs = 0, bs = 0, cnt = 0
            var yy = ys
            while yy <= ye {
                let row = base + yy * bpr
                var xx = xs
                while xx <= xe { let o = xx * 4; bs += Int(row[o]); gs += Int(row[o+1]); rs += Int(row[o+2]); cnt += 1; xx += 1 }
                yy += 1
            }
            if cnt == 0 { cnt = 1 }
            let s = smoothing
            smooth[i*3]   = smooth[i*3]   * (1-s) + (Double(rs)/Double(cnt)) * s
            smooth[i*3+1] = smooth[i*3+1] * (1-s) + (Double(gs)/Double(cnt)) * s
            smooth[i*3+2] = smooth[i*3+2] * (1-s) + (Double(bs)/Double(cnt)) * s
            let pr = UInt8(max(0.0, min(255.0, smooth[i*3])))
            let pg = UInt8(max(0.0, min(255.0, smooth[i*3+1])))
            let pb = UInt8(max(0.0, min(255.0, smooth[i*3+2])))
            preview[i*3] = pr; preview[i*3+1] = pg; preview[i*3+2] = pb
            let R = lut[Int(pr)], G = lut[Int(pg)], B = lut[Int(pb)]
            let o = HDR_LEN + i*3
            if grb { mirrorFrame[o] = G; mirrorFrame[o+1] = R; mirrorFrame[o+2] = B }
            else   { mirrorFrame[o] = R; mirrorFrame[o+1] = G; mirrorFrame[o+2] = B }
        }
        setPreview(preview)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Lumicast: stream stopped: \(error.localizedDescription)")
    }

    func sendBlackSync() {
        queue.sync { for i in HDR_LEN..<self.output.count { self.output[i] = 0 }; self.serial.writeFrame(self.output) }
    }
}

// =====================================================================
// MARK: - Live preview view (drawn inside a menu item)
// =====================================================================
final class PreviewView: NSView {
    weak var engine: Engine?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.10, alpha: 1).setFill(); bounds.fill()
        let frame = bounds.insetBy(dx: 14, dy: 12)
        NSColor(white: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: 8, dy: 8), xRadius: 6, yRadius: 6).fill()
        guard let eng = engine else { return }
        let leds = eng.leds
        let rgb = eng.snapshotPreview()
        guard rgb.count >= leds.count * 3 else { return }
        let dot: CGFloat = 7
        for (i, p) in leds.enumerated() {
            let u = GRID_W > 1 ? p.x / Double(GRID_W - 1) : 0
            let v = GRID_H > 1 ? p.y / Double(GRID_H - 1) : 0
            let cx = frame.minX + CGFloat(u) * frame.width
            let cy = frame.minY + CGFloat(v) * frame.height
            NSColor(srgbRed: CGFloat(rgb[i*3])/255.0, green: CGFloat(rgb[i*3+1])/255.0,
                    blue: CGFloat(rgb[i*3+2])/255.0, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: cx - dot/2, y: cy - dot/2, width: dot, height: dot),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

// =====================================================================
// MARK: - App (reliable NSMenu — actions fire natively in a menu-bar agent)
// =====================================================================
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var serial: Serial!
    var engine: Engine!
    var stream: SCStream?
    var displays: [SCDisplay] = []
    let menu = NSMenu()
    var previewView: PreviewView!
    var previewTimer: Timer?
    let model = PanelModel()
    var panel: PanelWindow?
    private var monitor: Any?
    var panelScreen: NSScreen?
    var panelTopY: CGFloat = 0
    var panelCenterX: CGFloat = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        serial = Serial(DEFAULT_PORT)
        _ = serial.openPort()
        engine = Engine(serial: serial, leds: genLedMap())   // user's physical layout, not the vendor map
        engine.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: "Lumicast")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        model.app = self

        Task { await self.discoverDisplays() }
        if CGPreflightScreenCaptureAccess() && Settings.shared.mode == "mirror" {
            Task { await self.ensureCaptureAsync() }
        }
    }

    // ---- panel (SwiftUI control panel in a key window) ----
    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let mm = NSMenu()
            mm.addItem(NSMenuItem(title: "Quit Lumicast", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem.menu = mm; statusItem.button?.performClick(nil); statusItem.menu = nil
            return
        }
        if let p = panel, p.isVisible { closePanel() } else { showPanel() }
    }

    func showPanel() {
        let hc = NSHostingController(rootView: ControlPanel(m: model))
        hc.sizingOptions = [.preferredContentSize]   // window auto-sizes to each mode's content

        let p = panel ?? PanelWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.delegate = self
        p.contentViewController = hc
        p.contentView?.wantsLayer = true
        p.contentView?.layer?.cornerRadius = 12
        p.contentView?.layer?.masksToBounds = true
        panel = p

        model.start()

        // Anchor the TOP edge just below the menu bar, centered under the cursor. As the content
        // resizes per mode, windowDidResize re-anchors so the top stays put.
        let mouse = NSEvent.mouseLocation
        panelScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
        if let s = panelScreen {
            panelTopY = s.visibleFrame.maxY - 4
            panelCenterX = mouse.x
        }
        repositionPanel()

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
        repositionPanel()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    func repositionPanel() {
        guard let p = panel, let s = panelScreen else { return }
        let vis = s.visibleFrame
        var ox = panelCenterX - p.frame.width / 2
        ox = max(vis.minX + 8, min(ox, vis.maxX - p.frame.width - 8))
        p.setFrameOrigin(NSPoint(x: ox, y: panelTopY - p.frame.height))
    }

    func windowDidResize(_ notification: Notification) { repositionPanel() }

    func closePanel() {
        model.stop()
        if let mon = monitor { NSEvent.removeMonitor(mon); monitor = nil }
        panel?.orderOut(nil)
    }

    // ---- menu lifecycle (legacy, unused now) ----
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }
    func menuWillOpen(_ menu: NSMenu) {
        let t = Timer(timeInterval: 1.0/20.0, repeats: true) { [weak self] _ in self?.previewView.needsDisplay = true }
        RunLoop.main.add(t, forMode: .common); previewTimer = t
    }
    func menuDidClose(_ menu: NSMenu) { previewTimer?.invalidate(); previewTimer = nil }

    func rebuildMenu() {
        let mode = Settings.shared.mode
        let (r, g, b) = Settings.shared.solidColor
        let grb = Settings.shared.grb
        menu.removeAllItems()

        let pItem = NSMenuItem(); pItem.view = previewView; menu.addItem(pItem)

        let stateText = engine.serial.isOpen
            ? "\(mode) · RGB(\(r),\(g),\(b)) · \(grb ? "GRB" : "RGB") · \(Int(Settings.shared.brightness*100))%"
            : "⚠︎ controller not found — is it plugged in?"
        let state = NSMenuItem(title: stateText, action: nil, keyEquivalent: ""); state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())

        for (label, val) in [("Off", "off"), ("Solid color", "solid"), ("Mirror screen", "mirror")] {
            let it = NSMenuItem(title: label, action: #selector(setMode(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = val; it.state = (mode == val) ? .on : .off
            menu.addItem(it)
        }
        if mode == "mirror" && !CGPreflightScreenCaptureAccess() {
            let en = NSMenuItem(title: "    Enable Screen Recording…", action: #selector(enableScreen), keyEquivalent: "")
            en.target = self; menu.addItem(en)
        }
        menu.addItem(.separator())

        let fxItem = NSMenuItem(title: "Effects", action: nil, keyEquivalent: "")
        let fxSub = NSMenu()
        for (i, name) in EFFECTS.enumerated() {
            let it = NSMenuItem(title: name, action: #selector(setEffect(_:)), keyEquivalent: "")
            it.target = self; it.tag = i
            it.state = (mode == "fx" && Settings.shared.fxIndex == i) ? .on : .off
            fxSub.addItem(it)
        }
        fxItem.submenu = fxSub; menu.addItem(fxItem)

        let spItem = NSMenuItem(title: "Effect speed", action: nil, keyEquivalent: "")
        let spSub = NSMenu()
        for (name, val) in [("Slow", 0.25), ("Medium", 0.5), ("Fast", 1.0)] {
            let it = NSMenuItem(title: name, action: #selector(setSpeed(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = val
            it.state = (abs(Settings.shared.fxSpeed - val) < 0.01) ? .on : .off
            spSub.addItem(it)
        }
        spItem.submenu = spSub; menu.addItem(spItem)

        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorSub = NSMenu()
        for (i, p) in SOLID_PRESETS.enumerated() {
            let it = NSMenuItem(title: p.0, action: #selector(setColorPreset(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; it.state = (r == p.1 && g == p.2 && b == p.3) ? .on : .off
            colorSub.addItem(it)
        }
        colorItem.submenu = colorSub; menu.addItem(colorItem)

        let brItem = NSMenuItem(title: "Brightness", action: nil, keyEquivalent: "")
        let brSub = NSMenu()
        for pct in [20, 40, 60, 80, 100] {
            let it = NSMenuItem(title: "\(pct)%", action: #selector(setBrightness(_:)), keyEquivalent: "")
            it.target = self; it.tag = pct
            it.state = (Int((Settings.shared.brightness*100).rounded()) == pct) ? .on : .off
            brSub.addItem(it)
        }
        brItem.submenu = brSub; menu.addItem(brItem)

        let ordItem = NSMenuItem(title: "Color order", action: nil, keyEquivalent: "")
        let ordSub = NSMenu()
        for o in ["GRB", "RGB"] {
            let it = NSMenuItem(title: o, action: #selector(setOrder(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = o; it.state = ((o == "GRB") == grb) ? .on : .off
            ordSub.addItem(it)
        }
        ordItem.submenu = ordSub; menu.addItem(ordItem)

        if displays.count > 1 {
            let dItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
            let dSub = NSMenu()
            for (i, d) in displays.enumerated() {
                let it = NSMenuItem(title: "Display \(i+1) — \(d.width)×\(d.height)", action: #selector(setDisplay(_:)), keyEquivalent: "")
                it.target = self; it.tag = i; it.state = (i == Settings.shared.displayIndex) ? .on : .off
                dSub.addItem(it)
            }
            dItem.submenu = dSub; menu.addItem(dItem)
        }
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Quit Lumicast", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
    }

    // ---- actions ----
    @objc func setMode(_ s: NSMenuItem) {
        let m = (s.representedObject as? String) ?? "off"
        Settings.shared.mode = m
        if m == "mirror" { ensureCapture() }
    }
    @objc func setColorPreset(_ s: NSMenuItem) {
        let p = SOLID_PRESETS[s.tag]
        Settings.shared.solidColor = (p.1, p.2, p.3); Settings.shared.mode = "solid"
    }
    @objc func setEffect(_ s: NSMenuItem) { Settings.shared.fxIndex = s.tag; Settings.shared.mode = "fx" }
    @objc func setSpeed(_ s: NSMenuItem) { Settings.shared.fxSpeed = (s.representedObject as? Double) ?? 0.5 }
    @objc func setBrightness(_ s: NSMenuItem) { Settings.shared.brightness = Double(s.tag)/100.0 }
    @objc func setOrder(_ s: NSMenuItem) { Settings.shared.grb = ((s.representedObject as? String) == "GRB") }
    @objc func enableScreen() { requestScreenAccess() }
    @objc func setDisplay(_ s: NSMenuItem) { selectDisplay(s.tag) }
    @objc func toggleLogin() {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
             else { try SMAppService.mainApp.register() } } catch { NSLog("login: \(error)") }
    }
    @objc func quitApp() { Settings.shared.mode = "off"; engine.sendBlackSync(); serial.closePort(); NSApp.terminate(nil) }

    // ---- capture ----
    func discoverDisplays() async {
        if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) {
            self.displays = content.displays
        }
    }
    func ensureCapture() { Task { await self.ensureCaptureAsync() } }
    func ensureCaptureAsync() async {
        guard CGPreflightScreenCaptureAccess() else { return }
        do {
            if displays.isEmpty {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                self.displays = content.displays
            }
            guard !displays.isEmpty else { return }
            var idx = Settings.shared.displayIndex
            if idx < 0 || idx >= displays.count { idx = 0; Settings.shared.displayIndex = 0 }
            try await startStream(on: displays[idx])
        } catch { NSLog("Lumicast: capture not started: \(error.localizedDescription)") }
    }
    func startStream(on display: SCDisplay) async throws {
        if let s = stream { try? await s.stopCapture(); stream = nil }
        let cfg = SCStreamConfiguration()
        cfg.width = 192
        cfg.height = max(64, Int(192.0 * Double(display.height) / Double(max(1, display.width))))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(FPS))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 4
        cfg.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: engine)
        try s.addStreamOutput(engine, type: .screen, sampleHandlerQueue: engine.queue)
        try await s.startCapture()
        stream = s
    }
    func selectDisplay(_ i: Int) {
        guard i >= 0, i < displays.count else { return }
        Settings.shared.displayIndex = i
        Task { try? await startStream(on: displays[i]) }
    }
    func requestScreenAccess() {
        let granted = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        if granted { ensureCapture() }
        else {
            let a = NSAlert()
            a.messageText = "Enable Screen Recording"
            a.informativeText = "Turn on “Lumicast” under Screen Recording, then quit and reopen this app — Mirror mode starts after a relaunch."
            a.runModal()
        }
    }
}

// ---- entry point ----
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
