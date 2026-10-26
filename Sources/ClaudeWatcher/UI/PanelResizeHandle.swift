import AppKit
import os
import SwiftUI

/// Invisible strip on the panel's right edge that resizes it by dragging (double-click resets).
/// AppKit rather than a SwiftUI gesture/pointer style: the panel is never key and doesn't
/// activate the app, so this view takes the first click itself and sets the cursor from its own
/// tracking area (which needs `BackgroundCursor.enable()`: the app stays in the background).
/// Positions are reported in screen coordinates (`NSEvent.mouseLocation`), which stay stable
/// while the window resizes under the pointer. Hover/drag state goes to `onStateChange`, for
/// the visible edge line.
struct PanelResizeHandle: NSViewRepresentable {
    /// False while the panel is hidden: drops a hover/drag the strip slid away from (no exit
    /// event comes), restoring the arrow.
    let isActive: Bool
    let onBegan: (CGFloat) -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onReset: () -> Void
    let onStateChange: (_ hovering: Bool, _ dragging: Bool) -> Void

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
        view.onStateChange = onStateChange
        if !isActive { view.dropState() }
    }

    final class HandleView: NSView {
        var onBegan: (CGFloat) -> Void = { _ in }
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: () -> Void = {}
        var onReset: () -> Void = {}
        var onStateChange: (_ hovering: Bool, _ dragging: Bool) -> Void = { _, _ in }

        private var isHovering = false
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

        /// Reports a hover/drag change (only changes).
        private func setState(hovering: Bool? = nil, dragging: Bool? = nil) {
            let hovering = hovering ?? isHovering, dragging = dragging ?? isDragging
            guard hovering != isHovering || dragging != isDragging else { return }
            isHovering = hovering
            isDragging = dragging
            onStateChange(hovering, dragging)
        }

        /// The strip left the pointer without an exit (panel hidden, view removed): forget the
        /// hover and drag, and restore the arrow, which `SetsCursorInBackground` would otherwise
        /// leave as the resize cursor. Reported asynchronously: this runs inside view updates.
        func dropState() {
            guard isHovering || isDragging else { return }
            if isHovering { NSCursor.arrow.set() }
            isHovering = false
            isDragging = false
            let report = onStateChange
            Task { @MainActor in report(false, false) }
        }

        override func cursorUpdate(with event: NSEvent) { Self.resizeCursor.set() }

        override func mouseEntered(with event: NSEvent) {
            Self.resizeCursor.set()
            setState(hovering: true)
        }

        override func mouseMoved(with event: NSEvent) {
            Self.resizeCursor.set()
            setState(hovering: true)  // e.g. shown under a pointer that never "entered"
        }

        override func mouseExited(with event: NSEvent) {
            if !isDragging { NSCursor.arrow.set() }
            setState(hovering: false)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                setState(dragging: false)
                onReset()
                return
            }
            setState(dragging: true)
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
            guard window == nil else { return }
            let wasDragging = isDragging
            dropState()
            if wasDragging { onEnded() }
        }

        override func mouseUp(with event: NSEvent) {
            guard isDragging else { return }
            // The handle moved with the edge; restore the arrow if the pointer ended up off it.
            let local = convert(event.locationInWindow, from: nil)
            let inside = bounds.contains(local)
            if !inside { NSCursor.arrow.set() }
            setState(hovering: inside, dragging: false)
            onEnded()
        }
    }
}

/// Lets the app set the cursor while it's in the background. The sidebar is a non-activating
/// panel of an accessory app, so the app is never active, and the window server ignores a
/// background app's `NSCursor.set()` unless its connection has the private
/// `SetsCursorInBackground` property. Resolved at run time; skipped if the symbols are missing.
@MainActor
enum BackgroundCursor {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static var attempted = false
    private static let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "BackgroundCursor")

    /// Sets the property once (later calls do nothing).
    static func enable() {
        guard !attempted else { return }
        attempted = true
        // RTLD_DEFAULT, which Swift can't import; CoreGraphics (linked via AppKit) re-exports
        // SkyLight's symbols.
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        func symbol(_ names: String...) -> UnsafeMutableRawPointer? {
            names.lazy.compactMap { dlsym(handle, $0) }.first
        }
        guard let mainSymbol = symbol("CGSMainConnectionID", "_CGSDefaultConnection", "SLSMainConnectionID"),
              let setSymbol = symbol("CGSSetConnectionProperty", "SLSSetConnectionProperty")
        else {
            logger.debug("SetsCursorInBackground: CGS symbols not found; resize cursor only when active")
            return
        }
        let mainConnection = unsafeBitCast(mainSymbol, to: MainConnectionID.self)
        let setProperty = unsafeBitCast(setSymbol, to: SetConnectionProperty.self)
        let connection = mainConnection()
        let error = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if error != 0 { logger.debug("SetsCursorInBackground: CGSSetConnectionProperty failed (\(error))") }
    }
}
