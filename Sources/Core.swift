// Pure logic: color math, LED layout, effects, frame packing.
// No AppKit and no I/O, so tests/run.sh can exercise it directly.

import Foundation

let N_LEDS = LAYOUT.reduce(0) { $0 + $1.1 }
let HDR_LEN = 6

// Frame header (reverse-engineered from the vendor app, confirmed live):
//   "Ada" + 0x00 + LED count as 16-bit big-endian. No checksum, and the count is N (not N-1) —
//   that is the difference from standard Adalight. Required on EVERY frame: without it the
//   controller only shows the first frame after the port opens.
func frameHeader(ledCount n: Int) -> [UInt8] {
    [0x41, 0x64, 0x61, 0x00, UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
}

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

// =====================================================================
// MARK: - LED map
// =====================================================================

/// An LED's position on the screen edge, normalised: (0,0) = top-left, (1,1) = bottom-right.
struct LedPt: Equatable { let x: Double; let y: Double }

private let cornerXY: [(Double, Double)] = [(0, 0), (1, 0), (1, 1), (0, 1)]   // TL, TR, BR, BL

/// A side's two corners, in the direction used when nothing better can be derived.
private func sideCorners(_ side: String) -> (Int, Int) {
    switch side.lowercased() {
    case "left":   return (0, 3)   // top → bottom
    case "bottom": return (3, 2)   // left → right
    case "right":  return (2, 1)   // bottom → top
    case "top":    return (1, 0)   // right → left
    default: fatalError("LAYOUT: unknown side \"\(side)\" — use left, bottom, right or top")
    }
}

/// Positions of every LED in data order. A strip starts at the corner where the previous strip
/// ended; the first strip (or one that doesn't touch its predecessor) is oriented to end at the
/// corner it shares with the next strip.
func genLedMap(_ layout: [(String, Int)] = LAYOUT) -> [LedPt] {
    var map = [LedPt]()
    var prevEnd: Int? = nil
    for (i, (side, count)) in layout.enumerated() {
        let (a, b) = sideCorners(side)
        var start = a, end = b
        if let p = prevEnd, p == a || p == b {
            start = p; end = (p == a) ? b : a
        } else if i + 1 < layout.count {
            let (na, nb) = sideCorners(layout[i + 1].0)
            let shared = [a, b].filter { $0 == na || $0 == nb }
            if shared.count == 1 { end = shared[0]; start = (end == a) ? b : a }
        }
        let (sx, sy) = cornerXY[start], (ex, ey) = cornerXY[end]
        for k in 0..<max(0, count) {
            let f = count > 1 ? Double(k) / Double(count - 1) : 0
            map.append(LedPt(x: sx + (ex - sx) * f, y: sy + (ey - sy) * f))
        }
        prevEnd = end
    }
    return map
}

/// Width ÷ height of the LED ring, so the preview spaces dots evenly on both axes.
func layoutAspect(_ layout: [(String, Int)] = LAYOUT) -> Double {
    func longest(_ sides: [String]) -> Int { layout.filter { sides.contains($0.0.lowercased()) }.map { $0.1 }.max() ?? 0 }
    let h = longest(["top", "bottom"]), v = longest(["left", "right"])
    return (h > 1 && v > 1) ? Double(h - 1) / Double(v - 1) : 16.0 / 9.0
}

// =====================================================================
// MARK: - Frames
// =====================================================================

/// Gamma 2.2 + brightness, as a lookup table from a 0–255 channel value to the byte sent.
func gammaLUT(brightness b: Double, gamma: Double = 2.2) -> [UInt8] {
    (0..<256).map { UInt8(max(0.0, min(255.0, pow(Double($0) / 255.0, gamma) * 255.0 * b))) }
}

/// One frame of an effect as RGB triples (before gamma/brightness). `phase` and `breathe` are
/// accumulated by the caller, so changing speed never makes the animation jump.
func renderEffect(_ fx: Int, phase: Double, breathe: Double, count n: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: n * 3)
    for i in 0..<n {
        var (r, g, b) = (0.0, 0.0, 0.0)
        switch fx {
        case 1:  // color cycle — whole strip one hue
            (r, g, b) = hsv(frac(phase), 1, 1)
        case 2:  // breathe
            let bri = (sin(breathe) + 1) / 2 * 0.85 + 0.15
            (r, g, b) = hsv(frac(phase * 0.3), 1, bri)
        case 3:  // comet chasing around the perimeter
            let pos = frac(phase) * Double(n)
            var d = abs(Double(i) - pos); if d > Double(n) / 2 { d = Double(n) - d }
            let inten = max(0.0, 1.0 - d / 9.0)
            let (cr, cg, cb) = hsv(frac(phase), 1, 1)
            (r, g, b) = (cr * inten, cg * inten, cb * inten)
        case 4:  // wave — two rainbow cycles scrolling
            (r, g, b) = hsv(frac(Double(i) / Double(n) * 2 + phase), 1, 1)
        default: // rainbow flowing around the perimeter
            (r, g, b) = hsv(frac(Double(i) / Double(n) + phase), 1, 1)
        }
        out[i*3]   = UInt8(max(0.0, min(255.0, r)))
        out[i*3+1] = UInt8(max(0.0, min(255.0, g)))
        out[i*3+2] = UInt8(max(0.0, min(255.0, b)))
    }
    return out
}

/// Header + every LED's color run through the LUT, in the controller's byte order.
func packFrame(rgb: [UInt8], lut: [UInt8], grb: Bool) -> [UInt8] {
    let n = rgb.count / 3
    var out = frameHeader(ledCount: n)
    out.reserveCapacity(HDR_LEN + n * 3)
    for i in 0..<n {
        let r = lut[Int(rgb[i*3])], g = lut[Int(rgb[i*3+1])], b = lut[Int(rgb[i*3+2])]
        if grb { out.append(g); out.append(r) } else { out.append(r); out.append(g) }
        out.append(b)
    }
    return out
}
