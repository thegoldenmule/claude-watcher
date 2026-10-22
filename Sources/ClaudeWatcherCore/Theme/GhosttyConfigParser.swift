import Foundation

/// One `key = value` line of a Ghostty config or theme file.
public struct GhosttyConfigEntry: Sendable, Equatable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// Ghostty's config syntax: one `key = value` per line; lines whose first non-blank character
/// is `#` are comments (there are no trailing comments); a value wrapped in double quotes is
/// unquoted; an empty value resets the key to its default. Keys may repeat (`palette`,
/// `font-family`, `config-file`): every occurrence is kept, in order.
public enum GhosttyConfigParser {
    public static func parse(_ text: String) -> [GhosttyConfigEntry] {
        var entries: [GhosttyConfigEntry] = []
        text.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            entries.append(GhosttyConfigEntry(key, value))
        }
        return entries
    }
}

/// The value of Ghostty's `theme` key: one theme, or `light:A,dark:B` (either order) to follow
/// the system appearance.
public enum GhosttyThemeSpec: Sendable, Equatable {
    case fixed(String)
    case adaptive(light: String, dark: String)

    /// nil for an empty value (which resets `theme` to "no theme").
    public init?(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        var light: String?, dark: String?
        var plain: String?
        for part in value.split(separator: ",") {
            let item = part.trimmingCharacters(in: .whitespaces)
            if item.hasPrefix("light:") {
                light = item.dropFirst("light:".count).trimmingCharacters(in: .whitespaces)
            } else if item.hasPrefix("dark:") {
                dark = item.dropFirst("dark:".count).trimmingCharacters(in: .whitespaces)
            } else if !item.isEmpty {
                plain = item
            }
        }
        switch (light, dark) {
        case let (l?, d?): self = .adaptive(light: l, dark: d)
        // Only one variant given: Ghostty rejects it; use what's there rather than nothing.
        case let (l?, nil): self = .fixed(l)
        case let (nil, d?): self = .fixed(d)
        case (nil, nil):
            guard let plain else { return nil }
            // Theme names can contain commas only in theory; keep the whole value.
            self = .fixed(value.contains(",") ? value : plain)
        }
    }

    public var followsAppearance: Bool {
        if case .adaptive = self { return true }
        return false
    }

    public func name(prefersDark: Bool) -> String {
        switch self {
        case .fixed(let name): name
        case .adaptive(let light, let dark): prefersDark ? dark : light
        }
    }
}
