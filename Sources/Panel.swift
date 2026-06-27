// SwiftUI control panel hosted in a key NSPanel (replaces the plain NSMenu).
// The engine/Settings are untouched — this is purely the UI shell.

import AppKit
import SwiftUI
import ServiceManagement
import CoreGraphics

// A borderless panel that CAN become key, so SwiftUI controls receive clicks.
final class PanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// Bridges Settings + engine to SwiftUI.
final class PanelModel: ObservableObject {
    @Published var mode: String = "off"
    @Published var brightness: Double = 0.7
    @Published var grb: Bool = false
    @Published var fxIndex: Int = 0
    @Published var fxSpeed: Double = 0.5
    @Published var r: Double = 0
    @Published var g: Double = 0
    @Published var b: Double = 0
    @Published var displayNames: [String] = []
    @Published var displayIndex: Int = 0
    @Published var captureGranted: Bool = false
    @Published var portOpen: Bool = false
    @Published var loginEnabled: Bool = false
    @Published var preview: [UInt8] = []
    var leds: [LedPt] = []
    private var lastMode = "solid"
    weak var app: AppDelegate?
    private var timer: Timer?

    func start() {
        mode = Settings.shared.mode
        brightness = Settings.shared.brightness
        grb = Settings.shared.grb
        fxIndex = Settings.shared.fxIndex
        fxSpeed = Settings.shared.fxSpeed
        let (rr, gg, bb) = Settings.shared.solidColor
        r = Double(rr); g = Double(gg); b = Double(bb)
        displayIndex = Settings.shared.displayIndex
        captureGranted = CGPreflightScreenCaptureAccess()
        loginEnabled = (SMAppService.mainApp.status == .enabled)
        if let a = app {
            leds = a.engine.leds
            displayNames = a.displays.enumerated().map { "Display \($0.offset + 1) — \($0.element.width)×\($0.element.height)" }
        }
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self, let a = self.app else { return }
            self.preview = a.engine.snapshotPreview()
            self.portOpen = a.serial.isOpen
        }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    func stop() { timer?.invalidate(); timer = nil }

    func setMode(_ m: String) {
        if m != "off" { lastMode = m }
        mode = m; Settings.shared.mode = m
        if m == "mirror" { app?.ensureCapture(); captureGranted = CGPreflightScreenCaptureAccess() }
    }
    func togglePower() { mode == "off" ? setMode(lastMode) : setMode("off") }
    func setEffect(_ i: Int) { fxIndex = i; mode = "fx"; Settings.shared.fxIndex = i; Settings.shared.mode = "fx" }
    func setSpeed(_ s: Double) { fxSpeed = s; Settings.shared.fxSpeed = s }
    func setPreset(_ p: (String, Int, Int, Int)) {
        r = Double(p.1); g = Double(p.2); b = Double(p.3); commit()
        mode = "solid"; Settings.shared.mode = "solid"
    }
    func commit() { Settings.shared.solidColor = (Int(r), Int(g), Int(b)) }
    func setBrightness(_ v: Double) { brightness = v; Settings.shared.brightness = v }
    func setOrder(_ on: Bool) { grb = on; Settings.shared.grb = on }
    func pickDisplay(_ i: Int) { displayIndex = i; app?.selectDisplay(i) }
    func enableScreen() { app?.requestScreenAccess() }
    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("login: \(error)") }
        loginEnabled = (SMAppService.mainApp.status == .enabled)
    }
    func quit() { app?.quitApp() }
}

struct ControlPanel: View {
    @ObservedObject var m: PanelModel
    @State private var showAdvanced = false
    private let tabs: [(String, String)] = [("Solid", "solid"), ("Effects", "fx"), ("Mirror", "mirror")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            LedPreviewView(leds: m.leds, colors: m.preview).frame(height: 134)
            modeTabs
            if m.mode != "off" {
                context
                slider("Brightness", m.brightness, 0.05...1.0, "\(Int(m.brightness * 100))%") { m.setBrightness($0) }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.fill").foregroundStyle(.tint).font(.system(size: 15))
            Text("Lumicast").font(.system(size: 13, weight: .medium))
            Spacer()
            Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            Button { m.togglePower() } label: {
                Image(systemName: m.mode == "off" ? "power" : "power")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(m.mode == "off" ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(m.mode == "off" ? "Turn on" : "Turn off")
        }
    }
    private var status: String {
        if !m.portOpen { return "no controller" }
        switch m.mode {
        case "solid": return "Solid · \(Int(m.r)),\(Int(m.g)),\(Int(m.b))"
        case "fx": return EFFECTS[min(m.fxIndex, EFFECTS.count - 1)]
        case "mirror": return m.captureGranted ? "Mirroring" : "needs permission"
        default: return "Off"
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.1) { t in
                Button { m.setMode(t.1) } label: {
                    Text(t.0).font(.system(size: 12, weight: m.mode == t.1 ? .medium : .regular))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(m.mode == t.1 ? Color.accentColor.opacity(0.18) : Color.clear)
                .foregroundStyle(m.mode == t.1 ? Color.accentColor : Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var context: some View {
        switch m.mode {
        case "fx":
            VStack(spacing: 10) {
                tileGrid(EFFECTS.indices.map { (EFFECTS[$0], $0) }, selected: { m.mode == "fx" && m.fxIndex == $0 }) { m.setEffect($0) }
                slider("Speed", m.fxSpeed, 0.1...1.0, m.fxSpeed < 0.35 ? "Slow" : (m.fxSpeed < 0.7 ? "Medium" : "Fast")) { m.setSpeed($0) }
            }
        case "solid":
            VStack(spacing: 10) {
                tileGrid(SOLID_PRESETS.indices.map { (SOLID_PRESETS[$0].0, $0) }, selected: { _ in false }) { m.setPreset(SOLID_PRESETS[$0]) }
                channel("R", $m.r); channel("G", $m.g); channel("B", $m.b)
            }
        case "mirror":
            VStack(alignment: .leading, spacing: 8) {
                if !m.captureGranted {
                    Text("Mirror needs Screen Recording.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Enable screen recording…") { m.enableScreen() }.font(.system(size: 12))
                } else if m.displayNames.count > 1 {
                    ForEach(Array(m.displayNames.enumerated()), id: \.offset) { i, name in
                        Button { m.pickDisplay(i) } label: {
                            HStack {
                                Text(name).font(.system(size: 11))
                                Spacer()
                                if i == m.displayIndex { Image(systemName: "checkmark").font(.system(size: 10)) }
                            }.frame(maxWidth: .infinity).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                } else {
                    Text("Mirroring your screen.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }

    private func tileGrid(_ items: [(String, Int)], selected: @escaping (Int) -> Bool, action: @escaping (Int) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(items, id: \.1) { name, idx in
                Button { action(idx) } label: {
                    Text(name).font(.system(size: 11)).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(selected(idx) ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                .foregroundStyle(selected(idx) ? Color.accentColor : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func channel(_ name: String, _ v: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 12)
            Slider(value: Binding(get: { v.wrappedValue }, set: { v.wrappedValue = $0; m.commit() }), in: 0...255)
            Text("\(Int(v.wrappedValue))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
        }
    }

    private func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ readout: String, _ onChange: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(readout).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Toggle(isOn: Binding(get: { m.loginEnabled }, set: { _ in m.toggleLogin() })) {
                Text("Launch at login").font(.system(size: 12)).foregroundStyle(.secondary)
            }.toggleStyle(.switch).controlSize(.mini)
            DisclosureGroup(isExpanded: $showAdvanced) {
                HStack {
                    Text("Color order").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(get: { m.grb }, set: { m.setOrder($0) })) {
                        Text("GRB").tag(true); Text("RGB").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 108)
                }.padding(.top, 6)
            } label: {
                Text("Advanced").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Quit Lumicast") { m.quit() }.font(.system(size: 12))
            }
        }
    }
}

struct LedPreviewView: View {
    let leds: [LedPt]
    let colors: [UInt8]
    var body: some View {
        Canvas { ctx, size in
            let full = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: full, cornerRadius: 10), with: .color(Color(white: 0.07)))
            // Size the LED ring to the grid's aspect (30:16) and center it, so horizontal and
            // vertical dot spacing match (uniform border) regardless of the preview's proportions.
            let avail = full.insetBy(dx: 16, dy: 14)
            let aspect = CGFloat(GRID_W - 1) / CGFloat(GRID_H - 1)
            var fw = avail.width, fh = avail.width / aspect
            if fh > avail.height { fh = avail.height; fw = avail.height * aspect }
            let frame = CGRect(x: avail.midX - fw / 2, y: avail.midY - fh / 2, width: fw, height: fh)
            ctx.fill(Path(roundedRect: frame.insetBy(dx: 9, dy: 9), cornerRadius: 6), with: .color(Color(white: 0.14)))
            guard !leds.isEmpty, colors.count >= leds.count * 3 else { return }
            for (i, p) in leds.enumerated() {
                let u = GRID_W > 1 ? p.x / Double(GRID_W - 1) : 0
                let v = GRID_H > 1 ? p.y / Double(GRID_H - 1) : 0
                let cx = frame.minX + CGFloat(u) * frame.width
                let cy = frame.minY + CGFloat(v) * frame.height
                let col = Color(red: Double(colors[i*3]) / 255, green: Double(colors[i*3+1]) / 255, blue: Double(colors[i*3+2]) / 255)
                ctx.fill(Path(roundedRect: CGRect(x: cx - 2, y: cy - 2, width: 4, height: 4), cornerRadius: 1), with: .color(col))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
