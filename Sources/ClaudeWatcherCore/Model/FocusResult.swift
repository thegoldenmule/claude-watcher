public enum FocusResult: Sendable, Equatable {
    case focused
    case appActivatedOnly(reason: String)
    case failed(reason: String)
}

extension FocusResult {
    /// The user-facing reason, or nil for `.focused`.
    public var reason: String? {
        switch self {
        case .focused: nil
        case .appActivatedOnly(let reason), .failed(let reason): reason
        }
    }

    /// True when focusing failed because macOS Automation (Apple Events) permission for the
    /// terminal is denied; the UI offers to open System Settings → Privacy → Automation.
    public var needsAutomationPermission: Bool {
        guard case .failed(let reason) = self else { return false }
        return reason.contains(AppleScriptError.notPermittedMarker)
    }

    /// System Settings deep link to Privacy & Security → Automation.
    public static let automationSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
}
