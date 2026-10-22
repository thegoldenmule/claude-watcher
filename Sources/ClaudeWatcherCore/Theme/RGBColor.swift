import Foundation

/// An sRGB color with components in 0...1, as Ghostty's config describes colors
/// (`window-colorspace` defaults to sRGB).
public struct RGBColor: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// `0xRRGGBB`.
    public init(_ hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    /// Parses a Ghostty color value: `#rrggbb`, `rrggbb`, `#rgb`, `rgb` or a basic X11 name.
    /// Returns nil for anything else (including Ghostty's `cell-foreground`/`cell-background`
    /// keywords, which have no fixed color).
    public init?(ghostty raw: String) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let named = Self.names[value.lowercased().replacingOccurrences(of: " ", with: "")] {
            self = named
            return
        }
        var hex = Substring(value)
        if hex.hasPrefix("#") { hex = hex.dropFirst() }
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        switch hex.count {
        case 6:
            guard let v = UInt32(hex, radix: 16) else { return nil }
            self.init(v)
        case 3:
            let expanded = hex.map { "\($0)\($0)" }.joined()
            guard let v = UInt32(expanded, radix: 16) else { return nil }
            self.init(v)
        default:
            return nil
        }
    }

    public var hexString: String {
        func byte(_ c: Double) -> String { String(format: "%02x", Int((c * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue)
    }

    public var description: String { hexString }

    /// WCAG relative luminance (0 = black, 1 = white).
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    /// Matches Ghostty's macOS `NSColor.isLightColor` closely enough: perceived brightness > 0.5.
    public var isLight: Bool { (0.299 * red + 0.587 * green + 0.114 * blue) > 0.5 }

    /// HSB brightness scaled by `1 - amount` (Ghostty's `NSColor.darken(by:)`). Scaling HSB
    /// brightness with hue and saturation fixed is the same as scaling every channel.
    public func darkened(by amount: Double) -> RGBColor {
        let f = 1 - min(max(amount, 0), 1)
        return RGBColor(red: red * f, green: green * f, blue: blue * f)
    }

    /// Linear blend: `amount` 0 returns self, 1 returns `other`.
    public func mixed(with other: RGBColor, amount: Double) -> RGBColor {
        let t = min(max(amount, 0), 1)
        return RGBColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t)
    }

    /// WCAG contrast ratio against `other` (1...21).
    public func contrast(with other: RGBColor) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static let names: [String: RGBColor] = [
        "black": RGBColor(0x000000), "white": RGBColor(0xFFFFFF),
        "red": RGBColor(0xFF0000), "green": RGBColor(0x00FF00), "blue": RGBColor(0x0000FF),
        "yellow": RGBColor(0xFFFF00), "cyan": RGBColor(0x00FFFF), "magenta": RGBColor(0xFF00FF),
        "gray": RGBColor(0xBEBEBE), "grey": RGBColor(0xBEBEBE),
        "darkgray": RGBColor(0xA9A9A9), "darkgrey": RGBColor(0xA9A9A9),
        "lightgray": RGBColor(0xD3D3D3), "lightgrey": RGBColor(0xD3D3D3),
        "orange": RGBColor(0xFFA500), "purple": RGBColor(0xA020F0),
    ]
}
