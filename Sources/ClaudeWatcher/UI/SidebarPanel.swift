import AppKit
import SwiftUI

/// Borderless, non-activating floating panel that hosts the sidebar. It never becomes key or
/// main, so clicking it doesn't steal focus from the frontmost app, and it rides along on
/// every Space, including over fullscreen apps.
final class SidebarPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar  // above .floating utility panels, below menus
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true  // derived from the rounded pane's alpha; see invalidateShadow()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that handles the first click even though its window is never key, so a single
/// click on a row selects it.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
