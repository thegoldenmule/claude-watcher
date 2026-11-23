import AppKit
import ClaudeWatcherCore

/// Draws the menu bar item: the app's symbol followed by one compact usage meter per agent
/// (`CC ▰▰▱ 42%`). A MenuBarExtra label only keeps an Image or Text, so it's one NSImage.
///
/// A template image (AppKit tints it for the menu bar) unless a fresh meter is at warning or
/// critical level: then the whole image is drawn in `labelColor` (resolved against the menu
/// bar's appearance when AppKit draws it) with an orange/red fill. A stale meter is dimmed and
/// never coloured. Each meter has the same fixed width (caption and "100%" reserved), so the
/// item doesn't jitter as values change.
enum StatusItemRenderer {
    private static let imageHeight: CGFloat = 18
    private static let symbolPointSize: CGFloat = 13
    private static let symbolGap: CGFloat = 5
    private static let meterGap: CGFloat = 7
    private static let captionGap: CGFloat = 2
    private static let barWidth: CGFloat = 16
    private static let barHeight: CGFloat = 7
    private static let labelGap: CGFloat = 2
    private static let staleAlpha: CGFloat = 0.4

    private static var captionFont: NSFont { NSFont.systemFont(ofSize: 8, weight: .semibold) }
    private static var percentFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium) }
    /// The "%" is set smaller than the digits: it saves ~3 pt per meter and still reads.
    private static var percentSignFont: NSFont { NSFont.systemFont(ofSize: 7.5, weight: .medium) }

    private static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static let captionWidth = AgentKind.allCases.map { textWidth($0.meterCaption, captionFont) }.max() ?? 0
    private static let percentWidth = ceil(percentLabel(100, color: .black).size().width)

    /// "42%" with a small "%", baseline-aligned.
    private static func percentLabel(_ value: Int, color: NSColor) -> NSAttributedString {
        let label = NSMutableAttributedString(
            string: "\(value)", attributes: [.font: percentFont, .foregroundColor: color])
        label.append(NSAttributedString(string: "%", attributes: [.font: percentSignFont, .foregroundColor: color]))
        return label
    }

    /// Width of one meter: caption, bar and the reserved percent label.
    static var meterWidth: CGFloat { captionWidth + captionGap + barWidth + labelGap + percentWidth }

    /// The whole label. `meters` must not be empty (the plain symbol is used then).
    ///
    /// Deliberately not `@MainActor`: the drawing handler would inherit that isolation, and
    /// Swift 6 would trap if AppKit draws the image off the main thread, which NSImage allows.
    /// The handler only touches its captured values and AppKit drawing calls.
    nonisolated static func image(symbol symbolName: String, meters: [UsageMeter]) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        let symbolSize = symbol?.size ?? .zero
        let colored = meters.contains { !$0.isStale && $0.level != .normal }
        // Reserved "100%" width; only a value of 1000% or more would widen a meter.
        let percentWidths = meters.map {
            max(percentWidth, ceil(percentLabel($0.roundedPercent, color: .black).size().width))
        }
        let width = symbolSize.width + symbolGap + meterGap * CGFloat(meters.count - 1)
            + percentWidths.reduce(0) { $0 + meterWidth - percentWidth + $1 }
        let size = NSSize(width: ceil(width), height: imageHeight)

        let image = NSImage(size: size, flipped: false) { _ in
            // Template images only use alpha, so draw in black; coloured ones resolve labelColor
            // against the appearance AppKit sets while drawing the status item.
            let base: NSColor = colored ? .labelColor : .black

            if let symbol {
                let rect = NSRect(x: 0, y: ((imageHeight - symbolSize.height) / 2).rounded(),
                                  width: symbolSize.width, height: symbolSize.height)
                symbol.draw(in: rect)
                if colored {
                    base.set()
                    rect.fill(using: .sourceAtop)
                }
            }

            var x = symbolSize.width
            for (index, meter) in meters.enumerated() {
                x += index == 0 ? symbolGap : meterGap
                drawMeter(meter, at: x, base: base, colored: colored)
                x += meterWidth - percentWidth + percentWidths[index]
            }
            return true
        }
        image.isTemplate = !colored
        image.accessibilityDescription = accessibilityLabel(meters: meters, paused: symbolName == "moon.zzz")
        return image
    }

    /// "ClaudeWatcher. Claude Code weekly usage 67 percent. Codex weekly usage 96 percent, critical"
    static func accessibilityLabel(meters: [UsageMeter], paused: Bool) -> String {
        (["ClaudeWatcher" + (paused ? ", edge reveal paused" : "")] + meters.map(\.accessibilityText))
            .joined(separator: ". ")
    }

    private static func drawMeter(_ meter: UsageMeter, at x: CGFloat, base: NSColor, colored: Bool) {
        let alpha: CGFloat = meter.isStale ? staleAlpha : 1

        // Caption, vertically centred on cap height.
        let captionBaseline = ((imageHeight - captionFont.capHeight) / 2).rounded()
        (meter.agent.meterCaption as NSString).draw(
            at: NSPoint(x: x, y: captionBaseline + captionFont.descender),
            withAttributes: [.font: captionFont, .foregroundColor: base.withAlphaComponent(alpha * 0.85)])

        // Pill: 1 pt outline (inset half a point to land on pixels), fill clipped to the pill.
        let barX = x + captionWidth + captionGap
        let barRect = NSRect(x: barX, y: (imageHeight - barHeight) / 2, width: barWidth, height: barHeight)
        let radius = barHeight / 2
        let outline = NSBezierPath(roundedRect: barRect.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: radius - 0.5, yRadius: radius - 0.5)
        outline.lineWidth = 1
        base.withAlphaComponent(alpha * (colored ? 0.55 : 0.85)).setStroke()
        outline.stroke()

        // Follows the rounded label: "0%" draws no fill, "1%" at least a dot.
        let fraction = meter.fillFraction
        if fraction > 0 {
            let fill: NSColor
            switch (colored && !meter.isStale, meter.level) {
            case (true, .critical): fill = .systemRed
            case (true, .warning): fill = .systemOrange
            default: fill = base.withAlphaComponent(alpha)
            }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).addClip()
            fill.setFill()
            // Never thinner than the pill is tall, so a small value still reads as a dot.
            NSRect(x: barX, y: barRect.minY, width: max(barHeight, barWidth * fraction), height: barHeight).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Percent, left-aligned in its reserved width.
        let baseline = ((imageHeight - percentFont.capHeight) / 2).rounded()
        percentLabel(meter.roundedPercent, color: base.withAlphaComponent(alpha))
            .draw(at: NSPoint(x: barRect.maxX + labelGap, y: baseline + percentFont.descender))
    }
}
