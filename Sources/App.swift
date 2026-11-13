// The menu-bar agent: status item, the control panel window, screen capture for Mirror mode,
// and reacting to sleep / wake / quit.

import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreMedia

enum MirrorState { case needsPermission, starting, live, stopped }

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    let engine = Engine(leds: genLedMap())
    let model = PanelModel()
    var panel: PanelWindow?
    private var clickMonitor: Any?
    private var panelScreen: NSScreen?
    private var panelTopY: CGFloat = 0
    private var panelCenterX: CGFloat = 0

    private(set) var displays: [SCDisplay] = []
    private var hasScreenAccess = false
    private var stream: SCStream?
    private var streamDisplayID: CGDirectDisplayID = 0
    private var captureBusy = false, captureDirty = false
    private var captureFailures = 0, retryToken = 0
    private var captureStoppedByUser = false
    private var pauseReasons = Set<String>()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        engine.onCaptureStopped = { [weak self] stream, error in
            DispatchQueue.main.async { self?.captureDidStop(stream, error) }
        }
        engine.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: "Lumicast")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])   // right-click → Quit menu
        model.app = self

        observeSystemEvents()
        syncCapture()   // resumes Mirror if that was the saved mode; touches no capture API otherwise
    }

    func applicationWillTerminate(_ note: Notification) { engine.shutdown() }

    @objc func quitApp() { NSApp.terminate(nil) }

    // ---- sleep / wake / logout ----
    // The controller keeps showing its last frame, so the strip is blanked explicitly whenever
    // nobody is looking at the screen, and on every way the app can exit.
    private func observeSystemEvents() {
        let ws = NSWorkspace.shared.notificationCenter
        let pauses: [(Notification.Name, String, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, "display", true),
            (NSWorkspace.screensDidWakeNotification, "display", false),
            (NSWorkspace.willSleepNotification, "sleep", true),
            (NSWorkspace.didWakeNotification, "sleep", false),
            (NSWorkspace.sessionDidResignActiveNotification, "session", true),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session", false),
        ]
        for (name, reason, on) in pauses {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setPaused(reason, on) }
        }
        // A display was added or removed: re-resolve which one Mirror is following.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.syncCapture() }
        // `kill`, logout and shutdown should blank the strip too, not just the Quit button.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    private func setPaused(_ reason: String, _ on: Bool) {
        if on { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        // Before system sleep, wait for the black frame to actually reach the controller.
        engine.setSuspended(!pauseReasons.isEmpty, wait: on && reason == "sleep")
        syncCapture()
    }

    // ---- panel (SwiftUI control panel in a key window) ----
    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            let menu = NSMenu()
            let quit = NSMenuItem(title: "Quit Lumicast", action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
            return
        }
        if let p = panel, p.isVisible { closePanel() } else { showPanel() }
    }

    func showPanel() {
        // Someone is clearly at the screen: drop any pause a missed wake notification left behind.
        if !pauseReasons.isEmpty { pauseReasons.removeAll(); engine.setSuspended(false); syncCapture() }
        hasScreenAccess = CGPreflightScreenCaptureAccess()

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
        if let old = clickMonitor { NSEvent.removeMonitor(old) }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
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
        if let mon = clickMonitor { NSEvent.removeMonitor(mon); clickMonitor = nil }
        panel?.orderOut(nil)
    }

    // ---- screen capture (Mirror mode only) ----
    // One rule decides everything: a stream should exist exactly while the mode is Mirror, the
    // displays are awake and we have permission. Every event that could change that calls
    // syncCapture(), which starts, stops or re-targets the stream to match. Nothing here runs —
    // and no capture API is touched — unless Mirror is the selected mode.

    var mirrorState: MirrorState {
        if !hasScreenAccess { return .needsPermission }
        if captureStoppedByUser { return .stopped }
        return stream != nil ? .live : .starting
    }

    /// The panel changed the mode (or asked for Mirror again after a stop).
    func modeChanged() { captureStoppedByUser = false; captureFailures = 0; syncCapture() }

    func selectDisplay(_ i: Int) {
        guard i >= 0, i < displays.count else { return }
        Settings.shared.displayIndex = i
        syncCapture()
    }

    func syncCapture() { Task { @MainActor in await self.reconcileCapture() } }

    @MainActor private func reconcileCapture() async {
        if captureBusy { captureDirty = true; return }   // a pass is mid-await; have it go around again
        captureBusy = true
        defer { captureBusy = false }
        repeat {
            captureDirty = false
            guard Settings.shared.mode == "mirror", pauseReasons.isEmpty, !captureStoppedByUser else {
                await stopStream(); continue
            }
            hasScreenAccess = CGPreflightScreenCaptureAccess()
            guard hasScreenAccess else { await stopStream(); continue }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                displays = content.displays
                guard !displays.isEmpty else { throw CocoaError(.featureUnsupported) }
                var idx = Settings.shared.displayIndex
                if idx < 0 || idx >= displays.count { idx = 0; Settings.shared.displayIndex = 0 }
                let target = displays[idx]
                if stream != nil && streamDisplayID == target.displayID { continue }   // already right
                await stopStream()
                try await startStream(on: target)
                captureFailures = 0
            } catch {
                NSLog("Lumicast: capture not started: \(error.localizedDescription)")
                await stopStream()
                scheduleRetry()
            }
        } while captureDirty
    }

    @MainActor private func startStream(on display: SCDisplay) async throws {
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
        streamDisplayID = display.displayID
        engine.setCaptureLive(true)
    }

    @MainActor private func stopStream() async {
        guard let s = stream else { return }
        stream = nil
        engine.setCaptureLive(false)
        try? await s.stopCapture()
    }

    // The system ended our stream (display unplugged, sleep, or the user chose "Stop Sharing").
    private func captureDidStop(_ stopped: SCStream, _ error: Error) {
        guard stopped === stream else { return }   // a stream we already replaced
        stream = nil
        engine.setCaptureLive(false)
        if (error as? SCStreamError)?.code == .userStopped {
            captureStoppedByUser = true            // respect it; the panel offers "Resume"
        } else {
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        captureFailures += 1
        retryToken += 1
        let token = retryToken
        let delay = min(30.0, pow(2.0, Double(captureFailures)))   // 2, 4, 8 … 30 s
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, token == self.retryToken else { return }
            self.syncCapture()
        }
    }

    func requestScreenAccess() {
        let granted = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        if granted { syncCapture() }
        else {
            let a = NSAlert()
            a.messageText = "Enable Screen Recording"
            a.informativeText = "Turn on “Lumicast” under Screen Recording, then quit and reopen this app — Mirror mode starts after a relaunch."
            a.runModal()
        }
    }
}
