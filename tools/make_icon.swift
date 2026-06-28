// Generates Lumicast's app icon: a dark monitor with a glowing rainbow LED ring
// behind it — the bias-light effect the app produces. Renders a 1024×1024 PNG master;
// build.sh turns it into AppIcon.icns. Run: swiftc -O tools/make_icon.swift -o /tmp/makeicon -framework AppKit
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_master.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// --- rounded-square body (macOS squircle-ish), dark gradient fill ---
let bodyInset: CGFloat = 96
let body = NSBezierPath(roundedRect: NSRect(x: bodyInset, y: bodyInset, width: S - 2*bodyInset, height: S - 2*bodyInset),
                        xRadius: 188, yRadius: 188)
NSGradient(colors: [NSColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1),
                    NSColor(srgbRed: 0.10, green: 0.11, blue: 0.15, alpha: 1)])!
    .draw(in: body, angle: -90)

// --- inner monitor screen ---
let screen = NSRect(x: 272, y: 372, width: 480, height: 300)
let screenPath = NSBezierPath(roundedRect: screen, xRadius: 26, yRadius: 26)
NSGradient(colors: [NSColor(srgbRed: 0.06, green: 0.07, blue: 0.10, alpha: 1),
                    NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1)])!
    .draw(in: screenPath, angle: 90)
NSColor(srgbRed: 0.20, green: 0.23, blue: 0.30, alpha: 1).setStroke()
screenPath.lineWidth = 3
screenPath.stroke()

// --- glowing LED ring around the screen, full rainbow once around ---
let ring = screen.insetBy(dx: -28, dy: -28)
func edgePoints(_ r: NSRect, count: Int) -> [CGPoint] {
    let w = r.width, h = r.height, per = 2*(w+h)
    var pts = [CGPoint]()
    for i in 0..<count {
        var d = per * CGFloat(i) / CGFloat(count)   // clockwise from top-left
        if d < w { pts.append(CGPoint(x: r.minX + d, y: r.maxY)); continue }; d -= w
        if d < h { pts.append(CGPoint(x: r.maxX, y: r.maxY - d)); continue }; d -= h
        if d < w { pts.append(CGPoint(x: r.maxX - d, y: r.minY)); continue }; d -= w
        pts.append(CGPoint(x: r.minX, y: r.minY + d))
    }
    return pts
}

let dots = edgePoints(ring, count: 56)
for (i, p) in dots.enumerated() {
    let hue = CGFloat(i) / CGFloat(dots.count)
    let color = NSColor(calibratedHue: hue, saturation: 0.95, brightness: 1.0, alpha: 1)
    // bloom: draw the dot a few times with a colored shadow so the light spreads
    for _ in 0..<2 {
        ctx.setShadow(offset: .zero, blur: 36, color: color.withAlphaComponent(0.9).cgColor)
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 15, y: p.y - 15, width: 30, height: 30)).fill()
    }
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // crisp core + white hotspot
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)).fill()
    NSColor(white: 1, alpha: 0.85).setFill()
    NSBezierPath(ovalIn: NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
