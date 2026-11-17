import AppKit
import CoreServices

/// Reads the titles of Ghostty's terminals, keyed by tty. Codex's TUI puts its state in the
/// terminal title (`[ ! ] Action Required | <thread> | <project>` while blocked on the user,
/// a spinner while working, else `<thread> | <project>`), which is the only external view of
/// "waiting for a question/approval" for a Codex session without the hook, and the thread name
/// in it tells two Codex TUIs in the same directory apart.
public protocol TerminalTitleReading: Sendable {
    /// tty path ("/dev/ttys005") → title, for every Ghostty terminal; nil when unavailable
    /// (Ghostty not running, older than 1.4 (no `tty` property), Automation not granted).
    func ghosttyTitlesByTTY() async -> [String: String]?
}

public struct GhosttyTitleReader: TerminalTitleReading {
    let scripting: GhosttyScripting

    public init(scripting: GhosttyScripting = GhosttyScripting()) {
        self.scripting = scripting
    }

    /// `tty US name RS …` for every terminal (two bulk Apple events). Errors on Ghostty 1.3.1,
    /// which has no `tty` property.
    public static let titlesScript = """
        with timeout of 3 seconds
          tell application id "\(AppActivation.ghosttyBundleID)"
            set {ttys, nms} to {tty, name} of every terminal
          end tell
        end timeout
        if (count of ttys) is not (count of nms) then error "terminal list changed while reading" number -1700
        set US to character id 31
        set RS to character id 30
        set out to ""
        repeat with i from 1 to count of ttys
          set n to ""
          try
            set n to (item i of nms) as text
          end try
          set out to out & ((item i of ttys) as text) & US & n & RS
        end repeat
        return out
        """

    public static func parse(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for record in output.split(separator: GhosttyMatcher.recordSeparator) {
            let fields = record.split(separator: GhosttyMatcher.fieldSeparator, maxSplits: 1, omittingEmptySubsequences: false)
            guard let tty = fields.first.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
                  tty.hasPrefix("/dev/") else { continue }
            result[tty] = fields.count > 1 ? String(fields[1]) : ""
        }
        return result
    }

    public func ghosttyTitlesByTTY() async -> [String: String]? {
        guard AppActivation.runningApp(bundleID: AppActivation.ghosttyBundleID) != nil,
              await AutomationPermission.shared.isGranted(bundleID: AppActivation.ghosttyBundleID)
        else { return nil }
        switch await scripting.runner.run(Self.titlesScript, app: GhosttyScripting.app, timeout: .seconds(5)) {
        case .success(let output): return Self.parse(output)
        case .failure: return nil
        }
    }
}

/// Whether this app may already send Apple events to an app, without ever prompting:
/// `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded` false. Background reads (like
/// Ghostty titles) only run once the user granted Automation via a click-to-focus. Results are
/// cached for a while; the check runs off the main thread.
public actor AutomationPermission {
    public static let shared = AutomationPermission()

    private var cache: [String: (granted: Bool, at: Date)] = [:]
    static let ttl: TimeInterval = 30

    public func isGranted(bundleID: String) async -> Bool {
        if let entry = cache[bundleID], Date().timeIntervalSince(entry.at) < Self.ttl { return entry.granted }
        let granted = await Task.detached(priority: .utility) {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            guard let desc = target.aeDesc else { return false }
            let status = AEDeterminePermissionToAutomateTarget(
                desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
            return status == noErr
        }.value
        cache[bundleID] = (granted, Date())
        return granted
    }
}
