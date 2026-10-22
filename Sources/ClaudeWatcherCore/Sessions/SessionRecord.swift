import Foundation

/// One `~/.claude/sessions/<pid>.json` registry entry, as written by the Claude Code CLI.
/// Only the fields we use are decoded; unknown fields are ignored.
public struct SessionRecord: Decodable, Sendable, Equatable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    /// Epoch milliseconds.
    public var startedAt: Double?
    /// `ctime`-style process start, in UTC, e.g. "Thu Oct 22 14:58:56 2026".
    public var procStart: String?
    public var version: String?
    /// interactive | background | sdk | worker
    public var kind: String?
    public var entrypoint: String?
    public var name: String?
    /// derived | auto | user | collision
    public var nameSource: String?
    /// busy | idle | waiting
    public var status: String?
    public var waitingFor: String?
    /// Epoch milliseconds.
    public var updatedAt: Double?
    /// Epoch milliseconds.
    public var statusUpdatedAt: Double?

    public init(
        pid: Int32, sessionId: String, cwd: String, startedAt: Double? = nil,
        procStart: String? = nil, version: String? = nil, kind: String? = "interactive",
        entrypoint: String? = nil, name: String? = nil, nameSource: String? = nil,
        status: String? = nil, waitingFor: String? = nil, updatedAt: Double? = nil,
        statusUpdatedAt: Double? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.procStart = procStart
        self.version = version
        self.kind = kind
        self.entrypoint = entrypoint
        self.name = name
        self.nameSource = nameSource
        self.status = status
        self.waitingFor = waitingFor
        self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt
    }

    /// Parses a registry file. Returns nil for malformed/partial JSON or missing required fields.
    public static func parse(_ data: Data) -> SessionRecord? {
        guard !data.isEmpty else { return nil }
        guard let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
              record.pid > 0, !record.sessionId.isEmpty
        else { return nil }
        return record
    }

    /// Only interactive sessions are shown. Records without a `kind` (older CLI versions)
    /// are treated as interactive.
    public var isInteractive: Bool {
        guard let kind else { return true }
        return kind == "interactive"
    }

    public var sessionStatus: SessionStatus {
        switch status {
        case "busy": .busy
        case "idle": .idle
        case "waiting": .waiting
        default: .unknown
        }
    }

    public var startedAtDate: Date? { startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    public var updatedAtDate: Date? {
        let ms = [updatedAt, statusUpdatedAt].compactMap { $0 }.max()
        return ms.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    public var procStartDate: Date? { procStart.flatMap(Self.parseProcStart) }

    /// Parses `"Thu Oct 22 14:58:56 2026"` (UTC; day may be space-padded) into a Date.
    public static func parseProcStart(_ string: String) -> Date? {
        let parts = string.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 5 else { return nil }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let monthIndex = months.firstIndex(of: parts[1].lowercased()),
              let day = Int(parts[2]), let year = Int(parts[4])
        else { return nil }
        let hms = parts[3].split(separator: ":")
        guard hms.count == 3, let h = Int(hms[0]), let m = Int(hms[1]), let s = Int(hms[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(
            year: year, month: monthIndex + 1, day: day, hour: h, minute: m, second: s)
        return calendar.date(from: components)
    }
}

/// Pure title-precedence rules.
public enum SessionTitle {
    /// `name` if the user set it; else the last custom title; else the last AI title;
    /// else `name`; else the cwd's last path component.
    public static func resolve(
        name: String?, nameSource: String?, customTitle: String?, aiTitle: String?, cwd: String
    ) -> String {
        if nameSource == "user", let name = nonEmpty(name) { return name }
        if let customTitle = nonEmpty(customTitle) { return customTitle }
        if let aiTitle = nonEmpty(aiTitle) { return aiTitle }
        if let name = nonEmpty(name) { return name }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? "Claude" : base
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
