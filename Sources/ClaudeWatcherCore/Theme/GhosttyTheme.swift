import Foundation

/// The parts of a resolved Ghostty configuration that decide how a terminal pane looks.
/// Defaults are Ghostty 1.3's own (`ghostty +show-config --default`), so an empty or missing
/// config yields exactly what a stock Ghostty window shows.
public struct GhosttyTheme: Sendable, Equatable {
    public enum Blur: Sendable, Equatable {
        case off
        /// `background-blur = true` (20) or an explicit radius.
        case radius(Int)
        /// `background-blur = macos-glass-regular` / `macos-glass-clear`.
        case glass(clear: Bool)
    }

    public var background: RGBColor
    public var foreground: RGBColor
    /// The 16 ANSI colors (0-7 normal, 8-15 bright).
    public var palette: [RGBColor]
    public var cursorColor: RGBColor?
    public var selectionBackground: RGBColor?
    public var selectionForeground: RGBColor?
    /// `font-family` values in order (fallbacks follow the first). Empty means Ghostty's
    /// built-in JetBrains Mono.
    public var fontFamilies: [String]
    public var fontSize: Double
    public var fontThicken: Bool
    public var backgroundOpacity: Double
    public var backgroundBlur: Blur
    /// `window-padding-x`: left, right.
    public var paddingX: (Double, Double)
    /// `window-padding-y`: top, bottom.
    public var paddingY: (Double, Double)
    public var unfocusedSplitOpacity: Double
    public var unfocusedSplitFill: RGBColor?
    public var splitDividerColor: RGBColor?
    /// Opacity of SGR 2 ("faint") text.
    public var faintOpacity: Double
    /// Theme name that was applied, if any (for logs).
    public var themeName: String?

    public static let defaultPalette: [RGBColor] = [
        0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
        0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
    ].map(RGBColor.init)

    /// Stock Ghostty 1.3.
    public static let ghosttyDefault = GhosttyTheme(
        background: RGBColor(0x282c34),
        foreground: RGBColor(0xffffff),
        palette: defaultPalette,
        cursorColor: nil,
        selectionBackground: nil,
        selectionForeground: nil,
        fontFamilies: [],
        fontSize: 13,
        fontThicken: false,
        backgroundOpacity: 1,
        backgroundBlur: .off,
        paddingX: (2, 2),
        paddingY: (2, 2),
        unfocusedSplitOpacity: 0.7,
        unfocusedSplitFill: nil,
        splitDividerColor: nil,
        faintOpacity: 0.5,
        themeName: nil)

    public static func == (a: GhosttyTheme, b: GhosttyTheme) -> Bool {
        a.background == b.background && a.foreground == b.foreground && a.palette == b.palette
            && a.cursorColor == b.cursorColor && a.selectionBackground == b.selectionBackground
            && a.selectionForeground == b.selectionForeground && a.fontFamilies == b.fontFamilies
            && a.fontSize == b.fontSize && a.fontThicken == b.fontThicken
            && a.backgroundOpacity == b.backgroundOpacity && a.backgroundBlur == b.backgroundBlur
            && a.paddingX == b.paddingX && a.paddingY == b.paddingY
            && a.unfocusedSplitOpacity == b.unfocusedSplitOpacity
            && a.unfocusedSplitFill == b.unfocusedSplitFill
            && a.splitDividerColor == b.splitDividerColor && a.faintOpacity == b.faintOpacity
            && a.themeName == b.themeName
    }

    // MARK: - Derived colors

    /// ANSI color `index` (0...15); out-of-range indices fall back to the foreground.
    public func ansi(_ index: Int) -> RGBColor {
        palette.indices.contains(index) ? palette[index] : foreground
    }

    public var isDark: Bool { !background.isLight }

    /// Ghostty inverts the cell when no selection colors are set.
    public var effectiveSelectionBackground: RGBColor { selectionBackground ?? foreground }
    public var effectiveSelectionForeground: RGBColor { selectionForeground ?? background }
    /// Ghostty's block cursor defaults to the foreground color.
    public var effectiveCursorColor: RGBColor { cursorColor ?? foreground }

    /// Ghostty macOS's split divider: the configured color, else the background darkened by 8%
    /// (light backgrounds) or 40% (dark ones).
    public var effectiveSplitDividerColor: RGBColor {
        splitDividerColor ?? background.darkened(by: background.isLight ? 0.08 : 0.4)
    }

    // MARK: - Applying config

    /// Applies one config/theme entry. Unknown keys and unparseable values are ignored (Ghostty
    /// reports them as diagnostics and keeps going); an empty value resets the key.
    public mutating func apply(_ entry: GhosttyConfigEntry) {
        let value = entry.value
        let d = Self.ghosttyDefault
        switch entry.key {
        case "background":
            background = value.isEmpty ? d.background : (RGBColor(ghostty: value) ?? background)
        case "foreground":
            foreground = value.isEmpty ? d.foreground : (RGBColor(ghostty: value) ?? foreground)
        case "palette":
            applyPalette(value)
        case "cursor-color":
            cursorColor = RGBColor(ghostty: value)
        case "selection-background":
            selectionBackground = RGBColor(ghostty: value)
        case "selection-foreground":
            selectionForeground = RGBColor(ghostty: value)
        case "font-family":
            if value.isEmpty { fontFamilies = [] } else { fontFamilies.append(value) }
        case "font-size":
            if value.isEmpty { fontSize = d.fontSize } else if let v = Double(value), v > 0 { fontSize = v }
        case "font-thicken":
            fontThicken = Self.bool(value) ?? d.fontThicken
        case "background-opacity":
            if value.isEmpty {
                backgroundOpacity = d.backgroundOpacity
            } else if let v = Double(value) {
                backgroundOpacity = min(max(v, 0), 1)
            }
        case "background-blur":
            backgroundBlur = Self.blur(value) ?? backgroundBlur
        case "window-padding-x":
            paddingX = value.isEmpty ? d.paddingX : (Self.pair(value) ?? paddingX)
        case "window-padding-y":
            paddingY = value.isEmpty ? d.paddingY : (Self.pair(value) ?? paddingY)
        case "unfocused-split-opacity":
            if value.isEmpty {
                unfocusedSplitOpacity = d.unfocusedSplitOpacity
            } else if let v = Double(value) {
                unfocusedSplitOpacity = min(max(v, 0.15), 1)  // Ghostty's clamp
            }
        case "unfocused-split-fill":
            unfocusedSplitFill = RGBColor(ghostty: value)
        case "split-divider-color":
            splitDividerColor = RGBColor(ghostty: value)
        case "faint-opacity":
            if value.isEmpty {
                faintOpacity = d.faintOpacity
            } else if let v = Double(value) {
                faintOpacity = min(max(v, 0), 1)
            }
        default:
            break
        }
    }

    public mutating func apply(_ entries: [GhosttyConfigEntry]) {
        for entry in entries { apply(entry) }
    }

    /// `palette = N=COLOR`; only the 16 ANSI slots are kept.
    private mutating func applyPalette(_ value: String) {
        guard let eq = value.firstIndex(of: "=") else { return }
        let indexText = value[..<eq].trimmingCharacters(in: .whitespaces)
        let index: Int? = indexText.lowercased().hasPrefix("0x")
            ? Int(indexText.dropFirst(2), radix: 16) : Int(indexText)
        guard let index, palette.indices.contains(index),
              let color = RGBColor(ghostty: String(value[value.index(after: eq)...]))
        else { return }
        palette[index] = color
    }

    private static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private static func blur(_ value: String) -> Blur? {
        switch value.lowercased() {
        case "", "false": return .off
        case "true": return .radius(20)
        case "macos-glass-regular": return .glass(clear: false)
        case "macos-glass-clear": return .glass(clear: true)
        default:
            guard let v = Int(value) else { return nil }
            return v > 0 ? .radius(v) : .off
        }
    }

    /// `"4"` -> (4, 4); `"4,8"` -> (4, 8).
    private static func pair(_ value: String) -> (Double, Double)? {
        let parts = value.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        switch parts.count {
        case 1: if let a = parts[0] { return (a, a) }
        case 2: if let a = parts[0], let b = parts[1] { return (a, b) }
        default: break
        }
        return nil
    }
}
