import AppKit

/// Focuses the Terminal.app tab whose `tty` equals `session.tty`. Never launches Terminal.
///
/// The script selects the tab, raises its window (`index 1`), un-minimises it and sends
/// `activate`. Returns `.focused`, `.appActivatedOnly` (no tty / no matching tab: Terminal is
/// just raised) or `.failed` (not running, permission, timeout).
public struct AppleTerminalFocuser: SessionFocuser {
    public let runner: any AppleScriptExecuting
    static let app = "Terminal"

    public init(runner: any AppleScriptExecuting = AppleScriptRunner.shared) {
        self.runner = runner
    }

    /// Normalises "ttys001" / "/dev/ttys001" to "/dev/ttys001" (Terminal reports the latter).
    public static func normalizeTTY(_ tty: String) -> String {
        let t = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("/dev/") { return t }
        return "/dev/" + t
    }

    /// Returns the matched window's id (its CGWindowID) as text, or "notfound".
    public static func focusScript(tty: String) -> String {
        """
        with timeout of 3 seconds
          tell application id "\(AppActivation.appleTerminalBundleID)"
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is \(AppleScriptSource.quoted(normalizeTTY(tty))) then
                  if miniaturized of w then set miniaturized of w to false
                  set selected tab of w to t
                  set index of w to 1
                  activate
                  return (id of w) as text
                end if
              end repeat
            end repeat
          end tell
        end timeout
        return "notfound"
        """
    }

    public func focus(_ session: ClaudeSession) async -> FocusResult {
        guard let app = AppActivation.runningApp(bundleID: AppActivation.appleTerminalBundleID) else {
            return .failed(reason: "Terminal isn't running.")
        }
        guard let tty = session.tty, !tty.isEmpty else {
            await AppActivation.activate(app)
            return .appActivatedOnly(reason: "Session has no known tty.")
        }
        await AppActivation.yieldActivation(to: app)
        switch await runner.run(Self.focusScript(tty: tty), app: Self.app, timeout: .seconds(5)) {
        case .success("notfound"):
            await AppActivation.activate(app)
            return .appActivatedOnly(reason: "No Terminal tab on \(Self.normalizeTTY(tty)).")
        case .success:
            return .focused
        case .failure(let e):
            return .failed(reason: e.userMessage(app: Self.app))
        }
    }
}
