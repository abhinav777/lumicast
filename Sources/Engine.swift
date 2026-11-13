// Settings, the serial port, and the output engine (a steady frame clock → the controller).

import Foundation
import Darwin
import IOKit
import IOKit.serial
import ScreenCaptureKit
import CoreMedia
import CoreVideo

// =====================================================================
// MARK: - Settings (thread-safe, persisted)
// =====================================================================
final class Settings {
    static let shared = Settings()
    private let lock = NSLock()
    private let d: UserDefaults

    private var _mode: String          // "off" | "solid" | "fx" | "mirror"
    private var _lastMode: String      // the mode the power button returns to
    private var _brightness: Double
    private var _grb: Bool
    private var _displayIndex: Int
    private var _r: Int; private var _g: Int; private var _b: Int
    private var _fxIndex: Int; private var _fxSpeed: Double

    init(defaults: UserDefaults = .standard) {
        d = defaults
        d.register(defaults: ["mode": "off", "lastMode": "solid", "brightness": 0.7, "grb": false,
                              "displayIndex": 0, "solidR": 255, "solidG": 150, "solidB": 80,
                              "fxIndex": 0, "fxSpeed": 0.5, "port": ""])
        let on = ["solid", "fx", "mirror"]
        let m = d.string(forKey: "mode") ?? "off"
        _mode = (m == "off" || on.contains(m)) ? m : "off"
        let lm = d.string(forKey: "lastMode") ?? "solid"
        _lastMode = on.contains(lm) ? lm : "solid"
        if on.contains(_mode) { _lastMode = _mode }
        _brightness = d.double(forKey: "brightness")
        _grb = d.bool(forKey: "grb")
        _displayIndex = d.integer(forKey: "displayIndex")
        _r = d.integer(forKey: "solidR"); _g = d.integer(forKey: "solidG"); _b = d.integer(forKey: "solidB")
        _fxIndex = d.integer(forKey: "fxIndex"); _fxSpeed = d.double(forKey: "fxSpeed")
    }

    var mode: String { get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; d.set(newValue, forKey: "mode"); lock.unlock() } }
    var lastMode: String { get { lock.lock(); defer { lock.unlock() }; return _lastMode }
        set { lock.lock(); _lastMode = newValue; d.set(newValue, forKey: "lastMode"); lock.unlock() } }
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

    /// Optional fixed device path (see Config.swift); empty means auto-detect.
    var portOverride: String { d.string(forKey: "port") ?? "" }
}

// =====================================================================
// MARK: - Serial port (POSIX termios)
// =====================================================================

/// Every callout device (/dev/cu.*) with the USB vendor ID of the adapter behind it, if any.
func listSerialPorts() -> [(path: String, vendor: Int?)] {
    var ports = [(path: String, vendor: Int?)]()
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iter) == KERN_SUCCESS else { return ports }
    defer { IOObjectRelease(iter) }
    let search = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
    while true {
        let svc = IOIteratorNext(iter)
        if svc == 0 { break }
        defer { IOObjectRelease(svc) }
        guard let path = IORegistryEntryCreateCFProperty(svc, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { continue }
        let vendor = (IORegistryEntrySearchCFProperty(svc, kIOServicePlane, "idVendor" as CFString, kCFAllocatorDefault, search) as? NSNumber)?.intValue
        ports.append((path, vendor))
    }
    return ports
}

/// The controller's port: the override if set, else an adapter from an accepted USB vendor.
/// Only when a port's vendor can't be read at all do we fall back to matching the driver's
/// device name — an adapter that identifies as some other vendor is never picked.
func chooseSerialPort(_ ports: [(path: String, vendor: Int?)], override: String) -> String? {
    if !override.isEmpty { return override }
    if let p = ports.first(where: { $0.vendor.map(USB_VENDOR_IDS.contains) ?? false }) { return p.path }
    let names = ["cu.usbserial", "cu.wchusbserial"]
    return ports.first(where: { p in
        p.vendor == nil && names.contains { (p.path as NSString).lastPathComponent.hasPrefix($0) }
    })?.path
}

final class Serial {
    private(set) var fd: Int32 = -1
    private(set) var path = ""

    @discardableResult
    func openPort() -> Bool {
        guard let p = chooseSerialPort(listSerialPorts(), override: Settings.shared.portOverride) else { return false }
        path = p
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
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { closePort(); ok = false; return }   // unplugged — tick() reopens
                off += n
            }
        }
        // Wait for the frame to fully transmit before the next one — without this the kernel
        // serial buffer backs up and the blocking write() eventually stalls.
        if ok && fd >= 0 { tcdrain(fd) }
    }

    func closePort() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
}

// =====================================================================
// MARK: - Engine: steady frame clock, four modes, live preview
// =====================================================================
// Output is driven by a timer (not the capture callback) so every mode shares one pacing and
// the strip keeps receiving frames. Everything below runs on `queue` unless noted; the serial
// port is only ever touched there.
final class Engine: NSObject, SCStreamOutput, SCStreamDelegate {
    let leds: [LedPt]
    let queue = DispatchQueue(label: "lumicast.engine")
    /// Called (on an arbitrary queue) when the system ends a capture stream.
    var onCaptureStopped: ((SCStream, Error) -> Void)?

    private let serial = Serial()
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var phase = 0.0, breathe = 0.0     // accumulated effect clocks
    private var suspended = false              // displays asleep / quitting → strip dark
    private var captureLive = false            // a capture stream is feeding mirrorTarget
    private var mirrorTarget = [Double](repeating: 0, count: N_LEDS * 3)
    private var mirrorSmooth = [Double](repeating: 0, count: N_LEDS * 3)
    private let smoothing = 0.5
    private var lut = [UInt8](repeating: 0, count: 256)
    private var lutBrightness = -1.0

    private let lock = NSLock()                // guards the two fields the UI reads
    private var _preview = [UInt8](repeating: 0, count: N_LEDS * 3)
    private var _portOpen = false

    init(leds: [LedPt]) {
        precondition(leds.count == N_LEDS, "LED map and LAYOUT disagree")
        self.leds = leds
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(1000 / FPS), leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }

    /// What the strip is showing right now, for the panel. Safe from any thread.
    func snapshot() -> (preview: [UInt8], portOpen: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (_preview, _portOpen)
    }

    /// Darken the strip (displays asleep, session switched out) without touching the saved mode.
    /// `wait` blocks briefly until the black frame is on the wire — for use right before sleep.
    func setSuspended(_ on: Bool, wait: Bool = false) {
        let work = { self.suspended = on; if on { self.writeBlack() } }
        if wait { runBounded(work) } else { queue.async(execute: work) }
    }

    /// Tells the engine whether a capture stream is running; without one, Mirror shows black
    /// rather than a frozen frame.
    func setCaptureLive(_ on: Bool) {
        queue.async {
            self.captureLive = on
            if !on {
                self.mirrorTarget = [Double](repeating: 0, count: N_LEDS * 3)
                self.mirrorSmooth = self.mirrorTarget
            }
        }
    }

    /// Stop the clock, blank the strip and release the port. Called once, at termination.
    func shutdown() {
        runBounded {
            self.timer?.cancel(); self.timer = nil
            self.writeBlack()
            self.serial.closePort()
        }
    }

    // Run on the engine queue and wait, but never hang the caller on a stuck serial port.
    private func runBounded(_ work: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        queue.async { work(); done.signal() }
        _ = done.wait(timeout: .now() + 1.0)
    }

    private func writeBlack() {
        serial.writeFrame(packFrame(rgb: [UInt8](repeating: 0, count: N_LEDS * 3), lut: lut, grb: false))
    }

    private func tick() {
        ticks &+= 1
        if !serial.isOpen && ticks % FPS == 1 { serial.openPort() }   // retry about once a second

        let s = Settings.shared
        let brightness = s.brightness
        if brightness != lutBrightness { lut = gammaLUT(brightness: brightness); lutBrightness = brightness }

        var rgb = [UInt8](repeating: 0, count: N_LEDS * 3)
        switch suspended ? "off" : s.mode {
        case "solid":
            let (r, g, b) = s.solidColor
            let c = (UInt8(clamping: r), UInt8(clamping: g), UInt8(clamping: b))
            for i in 0..<N_LEDS { rgb[i*3] = c.0; rgb[i*3+1] = c.1; rgb[i*3+2] = c.2 }
        case "fx":
            let speed = max(0.1, s.fxSpeed)
            phase += 0.012 * speed; breathe += 0.05 * speed
            rgb = renderEffect(s.fxIndex, phase: phase, breathe: breathe, count: N_LEDS)
        case "mirror" where captureLive:
            // Ease toward the latest captured colors every tick, so a single captured frame
            // (static screen) still converges, and brightness/order changes apply at once.
            for j in 0..<rgb.count {
                mirrorSmooth[j] += (mirrorTarget[j] - mirrorSmooth[j]) * smoothing
                rgb[j] = UInt8(max(0.0, min(255.0, mirrorSmooth[j])))
            }
        default:
            break   // off, or Mirror with no capture running: black
        }

        serial.writeFrame(packFrame(rgb: rgb, lut: lut, grb: s.grb))
        lock.lock(); _preview = rgb; _portOpen = serial.isOpen; lock.unlock()
    }

    // Capture callback (delivered on `queue`).
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }   // idle frames carry no image
        ingest(px)
    }

    /// Average a small patch of a captured BGRA frame under each LED. Must run on `queue`.
    func ingest(_ px: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        let bpr = CVPixelBufferGetBytesPerRow(px)
        guard w > 0, h > 0, let baseRaw = CVPixelBufferGetBaseAddress(px) else { return }
        let base = baseRaw.assumingMemoryBound(to: UInt8.self)
        let rad = 3
        for (i, p) in leds.enumerated() {
            let cx = Int(p.x * Double(w - 1)), cy = Int(p.y * Double(h - 1))
            let xs = max(0, cx - rad), xe = min(w - 1, cx + rad)
            let ys = max(0, cy - rad), ye = min(h - 1, cy + rad)
            var rs = 0, gs = 0, bs = 0, cnt = 0
            var yy = ys
            while yy <= ye {
                let row = base + yy * bpr
                var xx = xs
                while xx <= xe { let o = xx * 4; bs += Int(row[o]); gs += Int(row[o+1]); rs += Int(row[o+2]); cnt += 1; xx += 1 }   // BGRA
                yy += 1
            }
            if cnt == 0 { cnt = 1 }
            mirrorTarget[i*3]   = Double(rs) / Double(cnt)
            mirrorTarget[i*3+1] = Double(gs) / Double(cnt)
            mirrorTarget[i*3+2] = Double(bs) / Double(cnt)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Lumicast: capture stopped: \(error.localizedDescription)")
        onCaptureStopped?(stream, error)
    }
}
