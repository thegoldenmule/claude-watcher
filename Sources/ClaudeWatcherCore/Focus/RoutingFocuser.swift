import AppKit

/// The focuser the app should use: dispatches on `session.terminal`.
/// - `.ghostty` → `GhosttyFocuser`
/// - `.appleTerminal` → `AppleTerminalFocuser`
/// - `.other` → activates the nearest regular app above `session.pid` in the process tree
///   (`.appActivatedOnly`), or `.failed` if none is found.
public struct RoutingFocuser: SessionFocuser {
    public var ghostty: any SessionFocuser
    public var appleTerminal: any SessionFocuser

    public init(
        ghostty: any SessionFocuser = GhosttyFocuser(),
        appleTerminal: any SessionFocuser = AppleTerminalFocuser()
    ) {
        self.ghostty = ghostty
        self.appleTerminal = appleTerminal
    }

    public func focus(_ session: ClaudeSession) async -> FocusResult {
        switch session.terminal {
        case .ghostty:
            return await ghostty.focus(session)
        case .appleTerminal:
            return await appleTerminal.focus(session)
        case .other(let name):
            guard let app = AppActivation.hostingApp(forPID: session.pid) else {
                return .failed(reason: "Don't know how to focus \(name), and no hosting app was found.")
            }
            let label = app.localizedName ?? name
            guard await AppActivation.activate(app) else {
                return .failed(reason: "Couldn't activate \(label).")
            }
            return .appActivatedOnly(reason: "Activated \(label); focusing a specific tab isn't supported there.")
        }
    }
}
