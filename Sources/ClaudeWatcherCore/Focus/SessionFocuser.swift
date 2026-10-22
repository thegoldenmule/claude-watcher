/// Brings the terminal hosting a session to the front. Stub: focus agent implements it.
public protocol SessionFocuser: Sendable {
    func focus(_ session: ClaudeSession) async -> FocusResult
}
