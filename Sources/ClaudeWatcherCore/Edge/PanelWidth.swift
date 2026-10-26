import CoreGraphics

/// Bounds for the sidebar's user-chosen width (dragging its right edge while pinned).
public enum PanelWidth {
    /// Narrowest the panel may get.
    public static let minimum: CGFloat = 200
    /// Widest the panel may get, as a fraction of the screen's visible width.
    public static let maxScreenFraction: CGFloat = 0.5

    /// `requested` limited to `minimum...max(minimum, visibleWidth * maxScreenFraction)` (the
    /// range never inverts on a tiny screen). NaN gives `minimum`, +infinity the upper bound.
    public static func clamped(_ requested: CGFloat, visibleWidth: CGFloat) -> CGFloat {
        let fraction = visibleWidth * maxScreenFraction
        let upper = fraction.isFinite ? max(minimum, fraction) : minimum
        guard !requested.isNaN else { return minimum }
        return min(max(requested, minimum), upper)
    }

    /// The width to lay the panel out at: the stored width if it's usable (finite and positive),
    /// else `themeDefault`; always clamped to the screen.
    public static func resolved(stored: CGFloat?, themeDefault: CGFloat, visibleWidth: CGFloat) -> CGFloat {
        let requested = stored.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? themeDefault
        return clamped(requested, visibleWidth: visibleWidth)
    }
}
