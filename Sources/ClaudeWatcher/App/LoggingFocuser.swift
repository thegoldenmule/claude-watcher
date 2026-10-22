import ClaudeWatcherCore
import os

/// Placeholder focuser that only logs. Replaced by the real focuser at integration.
struct LoggingFocuser: SessionFocuser {
    private static let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Focus")

    func focus(_ session: ClaudeSession) async -> FocusResult {
        Self.logger.info("focus requested: \(session.title, privacy: .public) pid=\(session.pid) tty=\(session.tty ?? "-", privacy: .public)")
        return .failed(reason: "no focuser wired yet")
    }
}
