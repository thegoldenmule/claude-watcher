import Foundation

extension GhosttyTheme {
    /// Background blended toward an accent palette color, staying in the background's luminance class (dark stays dark).
    ///
    /// Used as an OSC 11 pane tint. Claude Code queries OSC 11 and picks its light/dark theme by
    /// the background's luminance, so the tint must never flip that class: the blend strength is
    /// reduced until the (8-bit rounded) result sits on the same side of 0.5 as the background,
    /// both by WCAG relative luminance and by perceived brightness (`isLight`).
    public func highlightTint(strength: Double = 0.25) -> GhosttyColor {
        let accent = highlightAccent
        let maxT = min(max(strength, 0), 1)
        let bgDark = background.luminance < 0.5
        let bgLight = background.isLight
        // Relative luminance along a linear sRGB blend is convex, so "stays light" isn't an
        // interval of t; scan down from the requested strength instead of bisecting.
        let steps = 50
        for i in stride(from: steps, through: 1, by: -1) {
            let t = maxT * Double(i) / Double(steps)
            let mixed = background.mixed(with: accent, amount: t)
            let candidate = GhosttyColor(ghostty: mixed.hexString) ?? mixed
            if (candidate.luminance < 0.5) == bgDark, candidate.isLight == bgLight { return candidate }
        }
        return GhosttyColor(ghostty: background.hexString) ?? background
    }

    /// Palette blue (4), else the first of bright blue, cyan, magenta, foreground that stands out
    /// from the background.
    var highlightAccent: GhosttyColor {
        for index in [4, 12, 6, 5] where ansi(index).contrast(with: background) >= 1.5 {
            return ansi(index)
        }
        return foreground
    }
}
