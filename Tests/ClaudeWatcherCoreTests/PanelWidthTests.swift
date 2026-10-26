import CoreGraphics
import Testing
@testable import ClaudeWatcherCore

@Suite struct PanelWidthClampTests {
    @Test func inRangePassesThrough() {
        #expect(PanelWidth.clamped(320, visibleWidth: 1512) == 320)
    }

    @Test func belowMinimumGivesMinimum() {
        #expect(PanelWidth.clamped(120, visibleWidth: 1512) == PanelWidth.minimum)
    }

    @Test func aboveScreenFractionGivesHalfTheScreen() {
        #expect(PanelWidth.clamped(1000, visibleWidth: 1512) == 756)
    }

    @Test func tinyScreenNeverInvertsTheRange() {
        // 300 * 0.5 = 150 < minimum: the upper bound is lifted to the minimum.
        #expect(PanelWidth.clamped(250, visibleWidth: 300) == PanelWidth.minimum)
        #expect(PanelWidth.clamped(100, visibleWidth: 300) == PanelWidth.minimum)
    }

    @Test func nonFiniteRequests() {
        #expect(PanelWidth.clamped(.nan, visibleWidth: 1512) == PanelWidth.minimum)
        #expect(PanelWidth.clamped(.infinity, visibleWidth: 1512) == 756)
        #expect(PanelWidth.clamped(-.infinity, visibleWidth: 1512) == PanelWidth.minimum)
    }
}

@Suite struct PanelWidthResolveTests {
    @Test func noStoredWidthUsesThemeDefaultClamped() {
        #expect(PanelWidth.resolved(stored: nil, themeDefault: 300, visibleWidth: 1512) == 300)
        #expect(PanelWidth.resolved(stored: nil, themeDefault: 420, visibleWidth: 600) == 300)
    }

    @Test func storedWidthBeatsThemeDefault() {
        #expect(PanelWidth.resolved(stored: 500, themeDefault: 300, visibleWidth: 1512) == 500)
    }

    @Test(arguments: [CGFloat(0), -40, .nan, .infinity])
    func unusableStoredWidthFallsBackToThemeDefault(_ stored: CGFloat) {
        #expect(PanelWidth.resolved(stored: stored, themeDefault: 300, visibleWidth: 1512) == 300)
    }

    @Test func storedWidthAboveBoundIsClamped() {
        #expect(PanelWidth.resolved(stored: 900, themeDefault: 300, visibleWidth: 1512) == 756)
    }
}
