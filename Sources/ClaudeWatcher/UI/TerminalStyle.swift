import AppKit
import ClaudeWatcherCore
import SwiftUI

/// SwiftUI-ready colors, fonts and metrics derived from a `GhosttyTheme`, so the sidebar reads
/// like a Ghostty pane: one monospaced font at one size, the theme's background and foreground,
/// and status colors taken from the ANSI palette.
/// `@unchecked Sendable`: every stored property is immutable (NSFont is immutable and thread-safe).
struct TerminalStyle: @unchecked Sendable {
    let theme: GhosttyTheme

    let nsFont: NSFont
    let nsBoldFont: NSFont
    /// Width of one cell (monospaced advance) and the line height, in points.
    let cellWidth: CGFloat
    let lineHeight: CGFloat
    /// Family actually used (for logs); differs from the config when the font isn't available.
    let fontDescription: String

    init(theme: GhosttyTheme) {
        self.theme = theme
        // A pane in a 300 pt sidebar wants slightly less than the terminal's size.
        let size = CGFloat(min(max(theme.fontSize - 1, 10), 16))
        let (regular, description) = Self.resolveFont(families: theme.fontFamilies, size: size,
                                                       thicken: theme.fontThicken)
        nsFont = regular
        nsBoldFont = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        fontDescription = description
        cellWidth = ceil(("M" as NSString).size(withAttributes: [.font: regular]).width * 100) / 100
        lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: regular))
    }

    static let `default` = TerminalStyle(theme: .ghosttyDefault)

    // MARK: Fonts

    var font: Font { Font(nsFont) }
    var boldFont: Font { Font(nsBoldFont) }

    /// The configured `font-family` list, then Ghostty's built-in JetBrains Mono (only usable
    /// when also installed system-wide: Ghostty embeds its copy in the binary), then SF Mono.
    private static func resolveFont(families: [String], size: CGFloat, thicken: Bool) -> (NSFont, String) {
        for family in families + ["JetBrains Mono"] {
            if let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: thicken ? 6 : 5, size: size)
                ?? NSFont(name: family, size: size) {
                return (font, family)
            }
        }
        return (NSFont.monospacedSystemFont(ofSize: size, weight: thicken ? .medium : .regular), "SF Mono")
    }

    // MARK: Metrics

    /// Ghostty's `window-padding-*` is usually tiny (2 pt); a sidebar needs at least a cell.
    var paddingX: CGFloat { max(CGFloat(theme.paddingX.0), cellWidth) }
    var paddingY: CGFloat { max(CGFloat(theme.paddingY.0), lineHeight * 0.5) }
    /// Columns of text the panel is laid out for.
    static let columns: CGFloat = 38
    var panelWidth: CGFloat { min(max(Self.columns * cellWidth + 2 * paddingX + 2, 260), 420) }
    /// Status glyph column: one glyph plus a space.
    var gutterWidth: CGFloat { cellWidth * 2 }
    static let cornerRadius: CGFloat = 12

    // MARK: Colors

    var background: Color { Color(theme.background) }
    var foreground: Color { Color(theme.foreground) }
    /// SGR 2 "faint" text: the foreground at Ghostty's `faint-opacity`, kept legible.
    var faint: Color { foreground.opacity(max(theme.faintOpacity, 0.55)) }
    func ansi(_ index: Int) -> Color { Color(theme.ansi(index)) }

    /// `index` unless its bright twin (`index + 8`) contrasts better with the background:
    /// light themes often have a pale yellow, dark ones a murky blue.
    private func legible(_ index: Int) -> Color {
        let bg = theme.background
        let normal = theme.ansi(index), bright = theme.ansi(index + 8)
        return Color(normal.contrast(with: bg) >= 3 || normal.contrast(with: bg) >= bright.contrast(with: bg)
            ? normal : bright)
    }

    var red: Color { legible(1) }
    var green: Color { legible(2) }
    var yellow: Color { legible(3) }
    var blue: Color { legible(4) }
    var magenta: Color { legible(5) }
    var cyan: Color { legible(6) }

    var busy: Color { blue }
    var waiting: Color { yellow }
    /// Stopped (idle at the prompt): as loud as waiting but its own color, since busy is blue
    /// and the context meter takes green/yellow/red.
    var idle: Color { magenta }
    var failure: Color { red }
    var success: Color { green }

    var cursor: Color { Color(theme.effectiveCursorColor) }
    /// Hover highlight: the theme's selection color, or (when Ghostty would just invert the
    /// cell) a light wash of the foreground.
    var selection: Color {
        theme.selectionBackground.map(Color.init) ?? foreground.opacity(0.12)
    }
    /// Text on the selection highlight: `selection-foreground`, only when the theme also sets
    /// `selection-background` (otherwise the highlight is a wash and palette colors stay).
    var selectionText: Color? {
        guard theme.selectionBackground != nil else { return nil }
        return theme.selectionForeground.map(Color.init)
    }
    /// Ghostty's split divider.
    var divider: Color { Color(theme.effectiveSplitDividerColor) }
    /// Outer hairline, like the window edge macOS draws around a Ghostty window.
    var border: Color { theme.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.16) }

    var colorScheme: ColorScheme { theme.isDark ? .dark : .light }
    var nsAppearance: NSAppearance? { NSAppearance(named: theme.isDark ? .darkAqua : .aqua) }
}

extension Color {
    init(_ rgb: GhosttyColor) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

private struct TerminalStyleKey: EnvironmentKey {
    static let defaultValue = TerminalStyle.default
}

extension EnvironmentValues {
    var terminalStyle: TerminalStyle {
        get { self[TerminalStyleKey.self] }
        set { self[TerminalStyleKey.self] = newValue }
    }
}
