// Renders an animated GIF of the Rainbow effect flowing around the LED ring — the same
// hue math the app uses (hue = frac(i/N + phase)). Loops seamlessly. For the README.
// Run: swiftc -O tools/make_demo_gif.swift -o /tmp/makegif -framework AppKit && /tmp/makegif demo.gif
import AppKit
import ImageIO
import UniformTypeIdentifiers

let W = 600, H = 380
let frames = 40
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "demo.gif"

func frac(_ x: Double) -> Double { let r = x.truncatingRemainder(dividingBy: 1); return r < 0 ? r + 1 : r }

// LED ring positions around a centered monitor rect
let screen = NSRect(x: 150, y: 120, width: 300, height: 175)
let ring = screen.insetBy(dx: -20, dy: -20)
let count = 64
func dots(_ r: NSRect) -> [CGPoint] {
    let per = 2 * (r.width + r.height)
    return (0..<count).map { i -> CGPoint in
        var d = per * CGFloat(i) / CGFloat(count)
        if d < r.width { return CGPoint(x: r.minX + d, y: r.maxY) }; d -= r.width
        if d < r.height { return CGPoint(x: r.maxX, y: r.maxY - d) }; d -= r.height
        if d < r.width { return CGPoint(x: r.maxX - d, y: r.minY) }; d -= r.width
        return CGPoint(x: r.minX, y: r.minY + d)
    }
}
let pts = dots(ring)

func renderFrame(_ phase: Double) -> CGImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    NSColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H)).fill()
    let sp = NSBezierPath(roundedRect: screen, xRadius: 18, yRadius: 18)
    NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1).setFill(); sp.fill()
    NSColor(srgbRed: 0.18, green: 0.21, blue: 0.27, alpha: 1).setStroke(); sp.lineWidth = 2; sp.stroke()

    for (i, p) in pts.enumerated() {
        let hue = frac(Double(i) / Double(count) + phase)
        let c = NSColor(calibratedHue: CGFloat(hue), saturation: 0.95, brightness: 1, alpha: 1)
        ctx.setShadow(offset: .zero, blur: 24, color: c.withAlphaComponent(0.9).cgColor)
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)).fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)).fill()
        NSColor(white: 1, alpha: 0.8).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

let url = URL(fileURLWithPath: out)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for f in 0..<frames {
    let img = renderFrame(Double(f) / Double(frames))   // phase 0..1 → seamless loop
    CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
}
CGImageDestinationFinalize(dest)
print("wrote \(out)")
