import AppKit

/// Focuses the Terminal.app tab whose `tty` equals `session.tty`. Never launches Terminal.
///
/// The script un-minimises the window, selects the tab, activates Terminal, then raises the
/// window (`index 1`, `frontmost true`), which also switches to its Space. Returns `.focused`,
/// `.appActivatedOnly` (no tty / no matching tab: Terminal is just raised) or `.failed`
/// (not running, permission, timeout).
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
    /// The window is re-resolved by id before changing it: `repeat with w in windows` yields
    /// index-based references, and `set index of w to 1` would make later uses of `w` point at
    /// a different window.
    ///
    /// Space switching: `activate` must come *before* raising, and `set frontmost … to true`
    /// is what switches to the window's Space (verified, macOS 26, "switch to a Space with open
    /// windows" off). `set index … to 1` alone is a no-op for the window already at index 1,
    /// and raising before `activate` never switches Spaces.
    public static func focusScript(tty: String) -> String {
        """
        with timeout of 3 seconds
          tell application id "\(AppActivation.appleTerminalBundleID)"
            repeat with w in windows
              set tabTTYs to tty of tabs of w
              repeat with i from 1 to count of tabTTYs
                if item i of tabTTYs is \(AppleScriptSource.quoted(normalizeTTY(tty))) then
                  set wid to id of w
                  set tw to window id wid
                  if miniaturized of tw then set miniaturized of tw to false
                  set selected tab of tw to tab i of tw
                  activate
                  set index of tw to 1
                  set frontmost of tw to true
                  return wid as text
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
