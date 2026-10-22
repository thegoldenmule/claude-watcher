// make-icon.swift: renders the ClaudeWatcher app icon ("Prompt": a shell chevron followed by
// three status dots) with CoreGraphics. `make icon` runs it and packs Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift <outdir>
//   (or: swiftc -O scripts/make-icon.swift -o make-icon && ./make-icon <outdir>)
//
// Writes <outdir>/AppIcon.iconset/ (all 10 sizes, each rendered from vectors at its own pixel
// size, with simplified art at 16/32/64 px) and <outdir>/AppIcon-1024.png. Pack the iconset with
//   iconutil -c icns <outdir>/AppIcon.iconset -o AppIcon.icns
//
// Geometry follows the macOS (Big Sur .. Tahoe) icon grid: a 1024x1024 canvas, an 824x824 body
// centered (100 px margins), continuous ("squircle") corners with radius 185.4, and a soft drop
// shadow inside the margin. Art is authored in 1024-unit, y-down coordinates.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Color

struct RGBA {
    var r, g, b, a: CGFloat
    init(_ hex: UInt32, _ a: CGFloat = 1) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
        self.a = a
    }
    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) { self.r = r; self.g = g; self.b = b; self.a = a }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    func alpha(_ v: CGFloat) -> RGBA { RGBA(r: r, g: g, b: b, a: v) }
    func mix(_ o: RGBA, _ t: CGFloat) -> RGBA {
        RGBA(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t, a: a + (o.a - a) * t)
    }
    func lighter(_ t: CGFloat) -> RGBA { mix(RGBA(0xFFFFFF, a), t) }
    func darker(_ t: CGFloat) -> RGBA { mix(RGBA(0x000000, a), t) }
}

// One Dark-ish status colors, matching the Ghostty theme the sidebar is usually shown in.
enum P {
    static let blue = RGBA(0x61AFEF)    // working
    static let yellow = RGBA(0xE5C07B)  // waiting
    static let idle = RGBA(0x7F8794)    // idle
}

// MARK: - Geometry

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185.4

/// Rounded rect with Apple-style continuous corners (y-down coordinates).
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 1.52866483
    let rad = min(radius, min(r.width, r.height) / 2 / k)
    func tl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * rad, y: r.minY + y * rad) }
    func tr(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.maxX - x * rad, y: r.minY + y * rad) }
    func br(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.maxX - x * rad, y: r.maxY - y * rad) }
    func bl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * rad, y: r.maxY - y * rad) }
    let a: CGFloat = 1.08849323, b: CGFloat = 0.86840689, c: CGFloat = 0.63149399, d: CGFloat = 0.07491100
    let e: CGFloat = 0.37282392, f: CGFloat = 0.16905899
    p.move(to: tl(k, 0))
    p.addLine(to: tr(k, 0))
    p.addCurve(to: tr(c, d), control1: tr(a, 0), control2: tr(b, 0))
    p.addCurve(to: tr(d, c), control1: tr(e, f), control2: tr(f, e))
    p.addCurve(to: tr(0, k), control1: tr(0, b), control2: tr(0, a))
    p.addLine(to: br(0, k))
    p.addCurve(to: br(d, c), control1: br(0, a), control2: br(0, b))
    p.addCurve(to: br(c, d), control1: br(f, e), control2: br(e, f))
    p.addCurve(to: br(k, 0), control1: br(b, 0), control2: br(a, 0))
    p.addLine(to: bl(k, 0))
    p.addCurve(to: bl(c, d), control1: bl(a, 0), control2: bl(b, 0))
    p.addCurve(to: bl(d, c), control1: bl(e, f), control2: bl(f, e))
    p.addCurve(to: bl(0, k), control1: bl(0, b), control2: bl(0, a))
    p.addLine(to: tl(0, k))
    p.addCurve(to: tl(d, c), control1: tl(0, a), control2: tl(0, b))
    p.addCurve(to: tl(c, d), control1: tl(f, e), control2: tl(e, f))
    p.addCurve(to: tl(k, 0), control1: tl(b, 0), control2: tl(a, 0))
    p.closeSubpath()
    return p
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}

func chevronPath(_ tip: CGPoint, halfHeight h: CGFloat, width w: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: tip.x - w, y: tip.y - h))
    p.addLine(to: tip)
    p.addLine(to: CGPoint(x: tip.x - w, y: tip.y + h))
    return p
}

// MARK: - Rendering context

/// Detail tier chosen from the output pixel size; small sizes get hand-simplified art.
enum Tier: Int, Comparable {
    case tiny = 0, small, medium, full
    static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    init(px: Int) {
        switch px {
        case ...20: self = .tiny
        case ...40: self = .small
        case ...80: self = .medium
        default: self = .full
        }
    }
}

struct R {
    let ctx: CGContext
    let px: Int
    let tier: Tier
    var s: CGFloat { CGFloat(px) / canvas }       // device pixels per unit
    var unit: CGFloat { canvas / CGFloat(px) }    // units per device pixel

    func fill(_ path: CGPath, _ color: RGBA) {
        ctx.addPath(path); ctx.setFillColor(color.cg); ctx.fillPath()
    }
    func stroke(_ path: CGPath, _ color: RGBA, width: CGFloat, cap: CGLineCap = .round, join: CGLineJoin = .round) {
        ctx.addPath(path); ctx.setStrokeColor(color.cg); ctx.setLineWidth(width)
        ctx.setLineCap(cap); ctx.setLineJoin(join); ctx.strokePath()
    }
    func gradient(_ stops: [(RGBA, CGFloat)]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                   colors: stops.map { $0.0.cg } as CFArray, locations: stops.map { $0.1 })!
    }
    /// Fills `path` with a linear gradient from p0 to p1.
    func linear(_ path: CGPath, _ stops: [(RGBA, CGFloat)], _ p0: CGPoint, _ p1: CGPoint) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(gradient(stops), start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    func radial(_ path: CGPath, _ stops: [(RGBA, CGFloat)], c0: CGPoint, r0: CGFloat, c1: CGPoint, r1: CGFloat) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawRadialGradient(gradient(stops), startCenter: c0, startRadius: r0, endCenter: c1, endRadius: r1,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    /// Strokes `path` (centered) with a vertical gradient between y0 and y1.
    func gradientStroke(_ path: CGPath, width: CGFloat, _ stops: [(RGBA, CGFloat)], y0: CGFloat, y1: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path); ctx.setLineWidth(width); ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(gradient(stops), start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    /// Shadow in unit coordinates (CoreGraphics shadows live in device space, y-up).
    func shadow(dy: CGFloat, blur: CGFloat, _ color: RGBA) {
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * s), blur: blur * s, color: color.cg)
    }
    func with(_ body: () -> Void) { ctx.saveGState(); body(); ctx.restoreGState() }
}

// MARK: - Pieces

/// The squircle tile: drop shadow, base gradient, top-left key light, and an optional glow.
func drawTile(_ r: R, top: RGBA, bottom: RGBA, glow: RGBA? = nil) {
    let shape = squircle(body, radius: bodyRadius)
    // Drop shadow (macOS template: ~12 px down, ~28 px blur, inside the 100 px margin).
    r.with {
        if r.tier >= .medium {
            r.shadow(dy: 12, blur: 28, RGBA(0x000000, 0.38))
        } else {
            r.shadow(dy: r.unit * 0.5, blur: r.unit * 1.0, RGBA(0x000000, 0.30))
        }
        r.fill(shape, bottom)
    }
    r.linear(shape, [(top, 0), (bottom, 1)], CGPoint(x: 0, y: body.minY), CGPoint(x: 0, y: body.maxY))
    // Soft key light from the top-left.
    r.radial(shape, [(RGBA(0xFFFFFF, 0.07), 0), (RGBA(0xFFFFFF, 0), 1)],
             c0: CGPoint(x: 330, y: 160), r0: 0, c1: CGPoint(x: 330, y: 160), r1: 640)
    if let glow {
        r.radial(shape, [(glow, 0), (glow.alpha(0), 1)],
                 c0: CGPoint(x: 512, y: 560), r0: 0, c1: CGPoint(x: 512, y: 560), r1: 520)
    }
}

/// Inner rim: bright along the top edge, fading down; a faint dark outline outside it keeps the
/// tile's edge readable on dark backgrounds.
func drawRim(_ r: R) {
    let shape = squircle(body, radius: bodyRadius)
    let w = max(5, r.unit * 1.0)
    r.with {
        r.ctx.addPath(shape); r.ctx.clip()
        r.gradientStroke(shape, width: w * 2, [(RGBA(0xFFFFFF, 0.30), 0), (RGBA(0xFFFFFF, 0.08), 0.35),
                                               (RGBA(0xFFFFFF, 0.04), 0.8), (RGBA(0xFFFFFF, 0.10), 1)],
                         y0: body.minY, y1: body.maxY)
    }
    if r.tier >= .medium {
        r.stroke(shape, RGBA(0x000000, 0.35), width: 2)
    }
}

/// A status dot with a lit gradient, specular highlight and optional colored glow.
func drawDot(_ r: R, _ c: CGPoint, _ rad: CGFloat, _ color: RGBA, glow: Bool) {
    let path = circle(c, rad)
    if r.tier <= .small {
        r.fill(path, color.lighter(0.08))
        return
    }
    if glow {
        r.with {
            r.shadow(dy: 0, blur: rad * 1.6, color.alpha(0.75))
            r.fill(path, color)
        }
    }
    r.radial(path, [(color.lighter(0.30), 0), (color.lighter(0.06), 0.6), (color.darker(0.10), 1)],
             c0: CGPoint(x: c.x - rad * 0.25, y: c.y - rad * 0.35), r0: 0, c1: c, r1: rad * 1.05)
    if r.tier == .full {
        // Glass edge: a thin light rim along the top of the dot.
        r.gradientStroke(circle(c, rad - 1.5), width: 3, [(RGBA(0xFFFFFF, 0.45), 0), (RGBA(0xFFFFFF, 0), 0.55)],
                         y0: c.y - rad, y1: c.y + rad)
    }
}

// MARK: - Icon

func drawIcon(_ r: R) {
    drawTile(r, top: RGBA(0x2A303B), bottom: RGBA(0x14171D), glow: r.tier >= .medium ? P.blue.alpha(0.16) : nil)

    // Layout per tier: chevron tip/size/stroke and the dot row. The small tiers are hand-tuned
    // so strokes and dots land on whole device pixels.
    struct L { var tip: CGPoint; var h: CGFloat; var w: CGFloat; var stroke: CGFloat; var dotX: [CGFloat]; var dotY: CGFloat; var dotR: CGFloat }
    let l: L
    switch r.tier {
    case .tiny:   // 1 px = 64 units
        l = L(tip: CGPoint(x: 416, y: 512), h: 192, w: 160, stroke: 128, dotX: [576, 736], dotY: 672, dotR: 72)
    case .small:  // 1 px = 32 units
        l = L(tip: CGPoint(x: 432, y: 496), h: 192, w: 168, stroke: 104, dotX: [576, 704, 832], dotY: 656, dotR: 44)
    case .medium:
        l = L(tip: CGPoint(x: 456, y: 496), h: 184, w: 176, stroke: 96, dotX: [572, 680, 788], dotY: 640, dotR: 42)
    case .full:
        l = L(tip: CGPoint(x: 450, y: 492), h: 170, w: 166, stroke: 84, dotX: [570, 680, 790], dotY: 640, dotR: 42)
    }

    let chev = chevronPath(l.tip, halfHeight: l.h, width: l.w)
    // Chevron: a stroked path filled with a cool silver gradient, with a soft drop shadow.
    r.with {
        // Normalized so the round join doesn't leave an inner seam.
        let outline = chev.copy(strokingWithWidth: l.stroke, lineCap: .round, lineJoin: .round, miterLimit: 10).normalized()
        if r.tier >= .medium {
            r.with {
                r.shadow(dy: 14, blur: 30, RGBA(0x000000, 0.55))
                r.fill(outline, RGBA(0xC9D2DE))
            }
            r.linear(outline, [(RGBA(0xFFFFFF), 0), (RGBA(0xDCE3EC), 0.5), (RGBA(0xA9B4C4), 1)],
                     CGPoint(x: 0, y: l.tip.y - l.h - l.stroke / 2), CGPoint(x: 0, y: l.tip.y + l.h + l.stroke / 2))
            if r.tier == .full {
                // Inner edge: bright where the light hits the top, darker toward the bottom.
                r.with {
                    r.ctx.addPath(outline); r.ctx.clip()
                    r.gradientStroke(outline, width: 6, [(RGBA(0xFFFFFF, 0.9), 0), (RGBA(0x7D899B, 0.5), 1)],
                                     y0: l.tip.y - l.h - l.stroke / 2, y1: l.tip.y + l.h + l.stroke / 2)
                }
            }
        } else {
            r.fill(outline, RGBA(0xE6EBF2))
        }
    }

    // Status dots on the baseline, like a cursor that is "thinking": working, waiting, idle.
    // 16 px has room for only two.
    let colors: [RGBA] = r.tier == .tiny ? [P.blue, P.yellow] : [P.blue, P.yellow, P.idle]
    for (i, x) in l.dotX.enumerated() {
        drawDot(r, CGPoint(x: x, y: l.dotY), l.dotR, colors[i], glow: i < 2)
    }
    drawRim(r)
}

// MARK: - Output

func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let s = CGFloat(px) / canvas
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)
    drawIcon(R(ctx: ctx, px: px, tier: Tier(px: px)))
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest), "failed to write \(url.path)")
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-icon <outdir>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[1], isDirectory: true)
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

writePNG(render(px: 1024), out.appendingPathComponent("AppIcon-1024.png"))
for pt in [16, 32, 128, 256, 512] {
    writePNG(render(px: pt), iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    writePNG(render(px: pt * 2), iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
print("wrote \(iconset.path)")
