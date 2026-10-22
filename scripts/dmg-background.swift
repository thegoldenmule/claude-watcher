#!/usr/bin/env swift
// Renders the ClaudeWatcher DMG window background at 1x and 2x.
//
//   swift scripts/dmg-background.swift <out-dir>
//
// Writes <out-dir>/background.png (660x400 pt) and <out-dir>/background@2x.png (1320x800 px);
// dmgbuild merges them into one HiDPI TIFF. The geometry must match scripts/dmg-settings.py
// (window size and icon centers).
//
// Finder draws the icon labels itself, black in light mode and white in dark mode, and a
// .DS_Store can't change that. So the strip the labels sit on is a mid-tone slate
// (relative luminance ~0.18), which gives both black and white text about 4.5:1 contrast;
// the rest of the window stays dark.
import AppKit
import CoreGraphics
import CoreText
import Foundation

let width: CGFloat = 660
let height: CGFloat = 400
// Icon centers in Finder coordinates (origin top-left), matching dmg-settings.py.
let appCenter = CGPoint(x: 170, y: 170)
let appsCenter = CGPoint(x: 490, y: 170)
let iconSize: CGFloat = 128
let caption = "Drag ClaudeWatcher to Applications"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(scale: CGFloat, to url: URL) throws {
    let pw = Int(width * scale), ph = Int(height * scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "bg", code: 1) }
    // Work in points with a top-left origin, like Finder.
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)

    // Window: dark, slightly cool vertical gradient.
    let base = CGGradient(colorsSpace: space,
                          colors: [color(0x1C1E25), color(0x111216)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: height), options: [])

    // Faint dot grid over the whole window.
    func dots(alpha: CGFloat, in rect: CGRect) {
        ctx.setFillColor(color(0xFFFFFF, alpha))
        let step: CGFloat = 20
        var y = step / 2
        while y < height {
            var x = step / 2
            while x < width {
                if rect.contains(CGPoint(x: x, y: y)) {
                    ctx.fillEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                }
                x += step
            }
            y += step
        }
    }
    dots(alpha: 0.04, in: CGRect(x: 0, y: 0, width: width, height: height))

    // The card the icons sit on: a terminal-window-like panel whose fill lightens toward
    // the label row (see the header comment).
    let card = CGRect(x: 36, y: 44, width: width - 72, height: 262)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 16, cornerHeight: 16, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 28, color: color(0x000000, 0.55))
    ctx.addPath(cardPath)
    ctx.setFillColor(color(0x2A2D35))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    let labelY = appCenter.y + iconSize / 2 + 18   // label baseline area
    let fill = CGGradient(colorsSpace: space,
                          colors: [color(0x30343D), color(0x464B56), color(0x5C6271),
                                   color(0x5F6573)] as CFArray,
                          locations: [0, (appCenter.y - card.minY) / card.height,
                                      (labelY - 18 - card.minY) / card.height, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: card.minY),
                           end: CGPoint(x: 0, y: card.maxY), options: [])
    // Title bar with three muted "traffic light" dots.
    ctx.setFillColor(color(0x000000, 0.18))
    ctx.fill(CGRect(x: card.minX, y: card.minY, width: card.width, height: 28))
    for (i, c) in [0xE0675F, 0xE5B355, 0x6BC167].enumerated() {
        ctx.setFillColor(color(UInt32(c), 0.55))
        ctx.fillEllipse(in: CGRect(x: card.minX + 14 + CGFloat(i) * 18, y: card.minY + 9,
                                   width: 10, height: 10))
    }
    ctx.restoreGState()
    ctx.addPath(cardPath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(1)
    ctx.strokePath()

    // Arrow from the app to Applications, at icon-center height.
    let gap = iconSize / 2 + 22
    let x0 = appCenter.x + gap, x1 = appsCenter.x - gap, ay = appCenter.y
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(3)
    ctx.setStrokeColor(color(0xFFFFFF, 0.55))
    ctx.setLineDash(phase: 0, lengths: [0.01, 9])   // a row of round dots
    ctx.move(to: CGPoint(x: x0, y: ay))
    ctx.addLine(to: CGPoint(x: x1 - 10, y: ay))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.setLineWidth(3.5)
    ctx.setStrokeColor(color(0xFFFFFF, 0.8))
    ctx.move(to: CGPoint(x: x1 - 12, y: ay - 12))
    ctx.addLine(to: CGPoint(x: x1, y: ay))
    ctx.addLine(to: CGPoint(x: x1 - 12, y: ay + 12))
    ctx.strokePath()

    // Caption below the card, monospaced, with a prompt glyph.
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let text = NSMutableAttributedString(string: "\u{203A} ", attributes: [
        .font: font, .foregroundColor: NSColor(srgbRed: 0.85, green: 0.62, blue: 0.42, alpha: 0.95),
    ])
    text.append(NSAttributedString(string: caption, attributes: [
        .font: font, .foregroundColor: NSColor(white: 1, alpha: 0.6),
    ]))
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // undo the flip for glyphs
    ctx.textPosition = CGPoint(x: (width - bounds.width) / 2 - bounds.minX, y: 352)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { throw NSError(domain: "bg", code: 2) }
    let dpi = 72 * scale
    CGImageDestinationAddImage(dest, image, [
        kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "bg", code: 3) }
}

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : ".", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try render(scale: 1, to: out.appendingPathComponent("background.png"))
try render(scale: 2, to: out.appendingPathComponent("background@2x.png"))
print("wrote \(out.path)/background.png and background@2x.png")
