import AppKit
import ClaudeWatcherCore
import Foundation

/// Demo mode (`CW_DEMO=1` or `--demo`): fake sessions covering every status, panel pinned
/// visible. For screenshots and UI work without real Claude Code sessions.
enum DemoMode {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CW_DEMO"] == "1"
            || CommandLine.arguments.contains("--demo")
    }

    /// `CW_APPEARANCE=dark|light` forces the app appearance (for screenshots of both themes).
    static var forcedAppearance: NSAppearance? {
        switch ProcessInfo.processInfo.environment["CW_APPEARANCE"] {
        case "dark": NSAppearance(named: .darkAqua)
        case "light": NSAppearance(named: .aqua)
        default: nil
        }
    }

    /// Canned focus outcomes so every banner can be seen without real terminals: Terminal.app
    /// rows fail with the Automation-permission error, "other" terminals only activate the app.
    static func focusResult(for session: ClaudeSession) async -> FocusResult {
        try? await Task.sleep(for: .milliseconds(250))
        switch session.terminal {
        case .ghostty: return .focused
        case .appleTerminal:
            return .failed(reason: AppleScriptError.notPermitted(app: "Terminal").userMessage(app: "Terminal"))
        case .other(let name):
            return .appActivatedOnly(reason: "Activated \(name); focusing a specific tab isn't supported there.")
        }
    }

    static let sessions: [ClaudeSession] = {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let home = NSHomeDirectory()
        return [
            ClaudeSession(
                id: "demo-1", pid: 41001, cwd: "\(home)/projects/thegoldenmule/claude-watcher",
                title: "Auto-hiding edge panel", branch: "main",
                lastPrompt: "make the sidebar slide in from the left edge like the Dock",
                status: .busy, tty: "/dev/ttys001", terminal: .ghostty,
                startedAt: ago(42), updatedAt: ago(0.2)),
            ClaudeSession(
                id: "demo-2", pid: 41002, cwd: "\(home)/projects/acme/payments-api",
                title: "Fix flaky webhook retry test", branch: "fix/webhook-retry-backoff",
                lastPrompt: "run the test suite again and check the retry jitter",
                status: .waiting, waitingFor: "Permission to run bash: npm test",
                tty: "/dev/ttys002", terminal: .ghostty,
                startedAt: ago(18), updatedAt: ago(1)),
            ClaudeSession(
                id: "demo-3", pid: 41003, cwd: "\(home)/projects/thegoldenmule/blog",
                title: "Draft release notes for v2.4", branch: "release/2.4",
                lastPrompt: "summarize the merged PRs since the last tag",
                status: .busy, tty: "/dev/ttys003", terminal: .appleTerminal,
                startedAt: ago(9), updatedAt: ago(0.1)),
            ClaudeSession(
                id: "demo-4", pid: 41004, cwd: "\(home)/projects/infra/terraform-modules",
                title: "Refactor VPC module outputs", branch: "refactor/vpc-outputs",
                lastPrompt: "rename the subnet outputs to match the new convention",
                status: .idle, tty: "/dev/ttys004", terminal: .ghostty,
                startedAt: ago(95), updatedAt: ago(30)),
            ClaudeSession(
                id: "demo-5", pid: 41005, cwd: "\(home)/scratch",
                title: "scratch", branch: nil, lastPrompt: nil,
                status: .unknown, tty: "/dev/ttys005", terminal: .other("iTerm2"),
                startedAt: ago(130), updatedAt: ago(60)),
        ]
    }()
}
