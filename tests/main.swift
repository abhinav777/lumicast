// Lumicast tests — no LED hardware needed. Run with tests/run.sh.
//
// Part 1 checks the pure logic (layout, effects, frame packing, port selection, power memory).
// Part 2 runs the real Engine against a pseudo-terminal standing in for the controller and
// checks the bytes it actually puts on the wire.
//
//   lumicast-tests                 run everything
//   lumicast-tests --snapshot DIR  also render the control panel in each state to PNGs in DIR

import AppKit
import SwiftUI
import CoreVideo

var passed = 0, failures = 0
func check(_ ok: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if ok() { passed += 1 } else { failures += 1; print("  FAIL (line \(line)): \(what)") }
}
func section(_ name: String) { print("• \(name)") }
func near(_ a: LedPt, _ x: Double, _ y: Double) -> Bool { abs(a.x - x) < 1e-9 && abs(a.y - y) < 1e-9 }

// =====================================================================
// Part 1 — pure logic
// =====================================================================
section("frame format")
check(N_LEDS == LAYOUT.reduce(0) { $0 + $1.1 }, "LED count follows LAYOUT")
check(frameHeader(ledCount: 96) == [0x41, 0x64, 0x61, 0x00, 0x00, 0x60], "header for 96 LEDs is Ada 00 00 60")
check(frameHeader(ledCount: 290) == [0x41, 0x64, 0x61, 0x00, 0x01, 0x22], "header count is 16-bit big-endian")
do {
    let lut = gammaLUT(brightness: 1.0)
    let f = packFrame(rgb: [10, 20, 30, 40, 50, 60], lut: lut, grb: false)
    check(f.count == HDR_LEN + 6 && Array(f[0..<6]) == frameHeader(ledCount: 2), "frame = header + 3 bytes per LED")
    check(Array(f[6...]) == [10, 20, 30, 40, 50, 60].map { lut[$0] }, "RGB order")
    let g = packFrame(rgb: [10, 20, 30, 40, 50, 60], lut: lut, grb: true)
    check(Array(g[6...]) == [20, 10, 30, 50, 40, 60].map { lut[$0] }, "GRB order swaps the first two bytes")
    check(lut[0] == 0 && lut[255] == 255, "LUT endpoints at full brightness")
    check(zip(lut, lut.dropFirst()).allSatisfy { $0 <= $1 }, "LUT is monotonic")
    check(gammaLUT(brightness: 0.5)[255] == 127, "brightness scales the LUT")
}

section("LED layout")
do {
    // The shipped default must match the original hand-written mapping exactly.
    let m = genLedMap([("left", 17), ("bottom", 31), ("right", 17), ("top", 31)])
    var legacy = [(Double, Double)]()
    for k in 0..<17 { legacy.append((0, Double(k) / 16)) }
    for k in 0..<31 { legacy.append((Double(k) / 30, 1)) }
    for k in 0..<17 { legacy.append((1, 1 - Double(k) / 16)) }
    for k in 0..<31 { legacy.append((1 - Double(k) / 30, 0)) }
    check(m.count == 96 && zip(m, legacy).allSatisfy { near($0, $1.0, $1.1) }, "default layout unchanged from v1.0.0")
    check(abs(layoutAspect([("left", 17), ("bottom", 31), ("right", 17), ("top", 31)]) - 30.0 / 16.0) < 1e-12, "preview aspect 30:16")

    // Wired the other way round: directions must follow the data path.
    let cw = genLedMap([("top", 4), ("right", 3), ("bottom", 4), ("left", 3)])
    check(near(cw[0], 0, 0) && near(cw[3], 1, 0), "clockwise: top runs left → right")
    check(near(cw[4], 1, 0) && near(cw[6], 1, 1), "clockwise: right runs top → bottom")
    check(near(cw[7], 1, 1) && near(cw[10], 0, 1), "clockwise: bottom runs right → left")
    check(near(cw[11], 0, 1) && near(cw[13], 0, 0), "clockwise: left runs bottom → top")

    // Three-sided kit (no bottom strip).
    let three = genLedMap([("left", 3), ("top", 5), ("right", 3)])
    check(three.count == 11 && near(three[0], 0, 1) && near(three[2], 0, 0), "3-sided: left runs bottom → top")
    check(near(three[3], 0, 0) && near(three[7], 1, 0) && near(three[10], 1, 1), "3-sided: top → right continue the path")
    check(genLedMap([("left", 2), ("right", 2)]).count == 4, "strips that don't touch still map")
}

section("effects")
do {
    let cyc = renderEffect(1, phase: 0.37, breathe: 0, count: 96)
    check(cyc.count == 288 && (0..<96).allSatisfy { Array(cyc[$0*3..<$0*3+3]) == Array(cyc[0..<3]) }, "color cycle: one hue on every LED")
    let comet = renderEffect(3, phase: 0.5, breathe: 0, count: 96)
    let lit = (0..<96).filter { comet[$0*3] > 0 || comet[$0*3+1] > 0 || comet[$0*3+2] > 0 }.count
    check(lit >= 15 && lit <= 18, "comet lights a short tail (\(lit) LEDs)")
    let a = renderEffect(0, phase: 1.0, breathe: 0, count: 96), b = renderEffect(0, phase: 1.012, breathe: 0, count: 96)
    check(zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 19 }, "rainbow moves smoothly from one tick to the next")
    let lap0 = renderEffect(0, phase: 0, breathe: 0, count: 96), lap5 = renderEffect(0, phase: 5, breathe: 0, count: 96)
    check(zip(lap0, lap5).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "rainbow loops seamlessly (to within float rounding)")
}

section("serial port selection")
do {
    let wch = 0x1A86, ftdi = 0x0403
    check(chooseSerialPort([("/dev/cu.usbserial-A", ftdi), ("/dev/cu.usbserial-130", wch)], override: "") == "/dev/cu.usbserial-130",
          "picks the CH340 even when another adapter is listed first")
    check(chooseSerialPort([("/dev/cu.usbserial-A", ftdi), ("/dev/cu.usbmodem1", 0x2341)], override: "") == nil,
          "never picks an adapter from another vendor")
    check(chooseSerialPort([("/dev/cu.Bluetooth-Incoming-Port", nil), ("/dev/cu.wchusbserial10", nil)], override: "") == "/dev/cu.wchusbserial10",
          "falls back to the driver's device name when the vendor is unreadable")
    check(chooseSerialPort([("/dev/cu.Bluetooth-Incoming-Port", nil), ("/dev/cu.debug-console", nil)], override: "") == nil,
          "ignores non-USB system ports")
    check(chooseSerialPort([("/dev/cu.usbserial-130", wch)], override: "/dev/cu.custom") == "/dev/cu.custom", "an explicit override wins")
    _ = listSerialPorts()   // must not crash on whatever this Mac has attached
}

section("settings + power button memory")
do {
    func fresh(_ values: [String: Any]) -> Settings {
        let name = "lumicast-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        values.forEach { d.set($1, forKey: $0) }
        defer { d.removePersistentDomain(forName: name) }
        return Settings(defaults: d)
    }
    check(fresh([:]).mode == "off" && fresh([:]).lastMode == "solid", "first launch: off, power button → Solid")
    check(fresh(["mode": "fx"]).lastMode == "fx", "relaunch while in Effects: power button remembers Effects")
    check(fresh(["mode": "off", "lastMode": "mirror"]).lastMode == "mirror", "relaunch while off: remembers the mode before off")
    check(fresh(["mode": "bogus"]).mode == "off", "an unknown saved mode falls back to off")

    let m = PanelModel()          // no app attached: pure model logic
    m.setMode("fx")
    m.togglePower(); check(m.mode == "off" && Settings.shared.mode == "off", "power off")
    m.togglePower(); check(m.mode == "fx", "power on returns to Effects, not Solid")
    m.setMode("mirror"); m.togglePower(); m.togglePower(); check(m.mode == "mirror", "…and to Mirror")
    m.setMode("off"); m.setPreset(SOLID_PRESETS[2])
    check(m.mode == "solid" && Settings.shared.lastMode == "solid" && Settings.shared.solidColor == (255, 0, 0), "choosing a preset turns Solid on")
    m.setEffect(3); check(m.mode == "fx" && Settings.shared.fxIndex == 3 && Settings.shared.lastMode == "fx", "choosing an effect turns Effects on")
}

// =====================================================================
// Part 2 — the real engine, writing to a pseudo-terminal
// =====================================================================
final class FakeController {
    let master: Int32
    let path: String
    private let lock = NSLock()
    private var bytes = [UInt8]()

    init() {
        var m: Int32 = 0, s: Int32 = 0
        precondition(openpty(&m, &s, nil, nil, nil) == 0, "openpty failed")
        master = m
        path = String(cString: ttyname(s))
        let t = Thread { [self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(master, &buf, buf.count)
                if n <= 0 { break }
                lock.lock(); bytes.append(contentsOf: buf[0..<n]); lock.unlock()
            }
        }
        t.start()
    }
    /// Everything received so far, split into frames; nil if the stream is ever malformed.
    func frames() -> [[UInt8]]? {
        lock.lock(); let all = bytes; lock.unlock()
        let len = HDR_LEN + N_LEDS * 3
        var out = [[UInt8]]()
        var i = 0
        while i + len <= all.count {
            let f = Array(all[i..<i + len])
            if Array(f[0..<HDR_LEN]) != frameHeader(ledCount: N_LEDS) { return nil }
            out.append(Array(f[HDR_LEN...]))
            i += len
        }
        return out
    }
    var count: Int { frames()?.count ?? -1 }
    var last: [UInt8] { frames()?.last ?? [] }
}
func led(_ payload: [UInt8], _ i: Int) -> [UInt8] { payload.count >= (i + 1) * 3 ? Array(payload[i*3..<i*3+3]) : [] }
func wait(_ s: Double) { Thread.sleep(forTimeInterval: s) }
/// Poll until `cond` holds (or give up), so the tests don't depend on a busy machine's timing.
func eventually(timeout: Double = 5.0, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; wait(0.03) }
    return cond()
}
let black = [UInt8](repeating: 0, count: N_LEDS * 3)

section("engine → wire (pseudo-terminal)")
do {
    let dev = FakeController()
    UserDefaults.standard.set(dev.path, forKey: "port")
    let s = Settings.shared
    s.mode = "solid"; s.solidColor = (255, 150, 80); s.brightness = 1.0; s.grb = false

    let engine = Engine(leds: genLedMap())
    engine.start()
    wait(1.0)
    let n1 = dev.count
    check(n1 >= 8 && n1 <= 17, "close to 15 well-formed frames per second, never more (got \(n1))")
    let lut1 = gammaLUT(brightness: 1.0)
    let solid = [lut1[255], lut1[150], lut1[80]]
    check(dev.frames()?.allSatisfy { f in (0..<N_LEDS).allSatisfy { led(f, $0) == solid } } ?? false, "solid: every LED carries the chosen color")
    check(engine.snapshot().portOpen, "engine reports the port as open")
    check(led(engine.snapshot().preview, 0) == [255, 150, 80], "preview shows the un-dimmed color")

    s.grb = true; s.brightness = 0.5
    let lut5 = gammaLUT(brightness: 0.5)
    check(eventually { led(dev.last, 40) == [lut5[150], lut5[255], lut5[80]] }, "color order + brightness changes take effect on the wire")
    s.grb = false; s.brightness = 1.0
    _ = eventually { led(dev.last, 0) == solid }

    // Displays asleep → strip dark, saved mode untouched; wake → back.
    engine.setSuspended(true, wait: true)
    let mark = dev.count
    check(eventually { dev.count >= mark + 4 } && (dev.frames()?[mark...].allSatisfy { $0 == black } ?? false), "suspended: only black frames")
    check(s.mode == "solid", "suspending does not change the saved mode")
    engine.setSuspended(false)
    check(eventually { led(dev.last, 0) == solid }, "resumed: color returns")

    // Effects: dragging the speed slider must not make the animation jump.
    s.mode = "fx"; s.fxIndex = 0; s.fxSpeed = 0.1
    let fxStart = dev.count
    _ = eventually { dev.count >= fxStart + 8 }
    let before = dev.count
    s.fxSpeed = 1.0
    if eventually({ dev.count >= before + 8 }), let fr = dev.frames() {
        let run = Array(fr[(before - 3)...])
        let worst = zip(run, run.dropFirst()).map { a, b in zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0 }.max() ?? 255
        check(worst <= 45, "effects: no jump when speed changes (largest step \(worst)/255)")
        check(Set(run.map { led($0, 0) }).count > 3, "effects: the rainbow is actually moving")
    } else { check(false, "effects: frames kept flowing") }

    // Mirror with no capture stream → black, not a frozen frame.
    s.mode = "mirror"
    check(eventually { dev.last == black && engine.snapshot().preview == black }, "mirror without capture: strip and preview are black")

    // One captured frame of a static screen (left half red, right half blue) must fully converge.
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 192, 108, kCVPixelFormatType_32BGRA, nil, &pb)
    if let px = pb {
        CVPixelBufferLockBaseAddress(px, [])
        let base = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(px)
        for y in 0..<108 { for x in 0..<192 {
            let o = y * bpr + x * 4
            base[o] = x < 96 ? 0 : 255; base[o+1] = 0; base[o+2] = x < 96 ? 255 : 0; base[o+3] = 255   // B G R A
        } }
        CVPixelBufferUnlockBaseAddress(px, [])
        engine.setCaptureLive(true)
        engine.queue.sync { engine.ingest(px) }
        check(eventually { led(dev.last, 8).first ?? 0 >= lut1[250] }, "mirror: left-edge LEDs converge to red from a single frame")
        let f = dev.last
        check(led(f, 8)[2] == 0 && led(f, 56)[2] >= lut1[250] && led(f, 56)[0] == 0, "mirror: right-edge LEDs converge to blue")
        check(led(f, 18)[0] > 0 && led(f, 46)[2] > 0, "mirror: bottom strip runs red → blue, left → right")
        s.brightness = 0.25
        check(eventually { (60...64).contains(Int(led(dev.last, 8).first ?? 0)) }, "mirror: brightness applies without waiting for a new screen frame")
        s.brightness = 1.0
        engine.setCaptureLive(false)
        check(eventually { dev.last == black }, "mirror: capture lost → black again")
    } else { check(false, "could not create a pixel buffer") }

    // Quit: last thing on the wire is black, then silence.
    s.mode = "solid"
    check(eventually { !dev.last.isEmpty && dev.last != black }, "lit before shutdown")
    engine.shutdown()
    let end = dev.count
    check(dev.last == black, "shutdown: final frame is black")
    wait(0.4)
    check(dev.count == end, "shutdown: nothing sent afterwards")
    check(s.mode == "solid", "shutdown leaves the saved mode alone, so lights resume next launch")
    check(dev.frames() != nil, "every frame on the wire was well-formed")
}

// =====================================================================
// Optional — render the panel in each state
// =====================================================================
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    _ = NSApplication.shared
    func shoot(_ name: String, _ setup: (PanelModel) -> Void) {
        let m = PanelModel()
        m.leds = genLedMap(); m.portOpen = true; m.brightness = 0.8; m.fxSpeed = 0.5
        m.preview = renderEffect(0, phase: 0.2, breathe: 0, count: N_LEDS)
        setup(m)
        let host = NSHostingView(rootView: ControlPanel(m: m))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("  wrote \(dir)/\(name).png")
    }
    section("panel snapshots")
    let dark = [UInt8](repeating: 0, count: N_LEDS * 3)
    shoot("off") { $0.mode = "off"; $0.preview = dark }
    shoot("effects") { $0.mode = "fx" }
    shoot("solid") { $0.mode = "solid"; $0.r = 255; $0.g = 150; $0.b = 80; $0.preview = (0..<N_LEDS).flatMap { _ in [UInt8(255), 150, 80] } }
    shoot("mirror-needs-permission") { $0.mode = "mirror"; $0.mirror = .needsPermission; $0.preview = dark }
    shoot("mirror-stopped") { $0.mode = "mirror"; $0.mirror = .stopped; $0.preview = dark }
    shoot("mirror-live") { $0.mode = "mirror"; $0.mirror = .live; $0.displayNames = ["Display 1 — 3024×1964", "Display 2 — 2560×1440"]; $0.displayIndex = 1 }
    shoot("no-controller") { $0.mode = "fx"; $0.portOpen = false }
}

UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
print(failures == 0 ? "\nAll \(passed) checks passed." : "\n\(failures) of \(passed + failures) checks FAILED.")
exit(failures == 0 ? 0 : 1)
