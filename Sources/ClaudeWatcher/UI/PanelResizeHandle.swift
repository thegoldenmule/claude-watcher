import AppKit
import SwiftUI

/// Invisible strip on the panel's right edge that resizes it by dragging (double-click resets).
/// AppKit rather than a SwiftUI gesture/pointer style: the panel is never key and doesn't
/// activate the app, so this view takes the first click itself and sets the cursor from its own
/// tracking area. Positions are reported in screen coordinates (`NSEvent.mouseLocation`), which
/// stay stable while the window resizes under the pointer.
struct PanelResizeHandle: NSViewRepresentable {
    let onBegan: (CGFloat) -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onReset = onReset
    }

    final class HandleView: NSView {
        var onBegan: (CGFloat) -> Void = { _ in }
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: () -> Void = {}
        var onReset: () -> Void = {}

        private var isDragging = false
        private var trackingArea: NSTrackingArea?

        private static var resizeCursor: NSCursor { .frameResize(position: .right, directions: .all) }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
                owner: self)
            addTrackingArea(area)
            trackingArea = area
        }

        override func cursorUpdate(with event: NSEvent) { Self.resizeCursor.set() }
        override func mouseEntered(with event: NSEvent) { Self.resizeCursor.set() }
        override func mouseMoved(with event: NSEvent) { Self.resizeCursor.set() }

        override func mouseExited(with event: NSEvent) {
            if !isDragging { NSCursor.arrow.set() }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                isDragging = false
                onReset()
                return
            }
            isDragging = true
            onBegan(NSEvent.mouseLocation.x)
        }

        override func mouseDragged(with event: NSEvent) {
            guard isDragging else { return }
            Self.resizeCursor.set()
            onChanged(NSEvent.mouseLocation.x)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Removed mid-drag (panel torn down): finish the resize so the width still persists.
            if window == nil, isDragging {
                isDragging = false
                onEnded()
            }
        }

        override func mouseUp(with event: NSEvent) {
            guard isDragging else { return }
            isDragging = false
            onEnded()
            // The handle moved with the edge; restore the arrow if the pointer ended up off it.
            let local = convert(event.locationInWindow, from: nil)
            if !bounds.contains(local) { NSCursor.arrow.set() }
        }
    }
}
