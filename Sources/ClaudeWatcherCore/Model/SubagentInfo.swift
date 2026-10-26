import Foundation

/// A running subagent of a session (Agent/Task tool), read from the session's `subagents/` dir.
/// Fields are coarse (whole seconds, short labels) so the store doesn't republish on every poll.
public struct SubagentInfo: Identifiable, Equatable, Hashable, Sendable {
    public var id: String            // agentId: the file stem after "agent-"
    public var parentID: String?     // meta `parentAgentId` (nested agents)
    public var agentType: String     // "Explore", "Plan", "general-purpose", "fork", …
    public var label: String         // description ?? name ?? agentType
    public var activity: String?     // latest action, e.g. "Read SessionDiscovery.swift", "thinking"
    public var isBackground: Bool    // meta `requestShape == "background"`
    public var startedAt: Date
    public var lastActivityAt: Date
    public var depth: Int            // 0 = a root of the displayed tree

    public init(
        id: String,
        parentID: String? = nil,
        agentType: String,
        label: String,
        activity: String? = nil,
        isBackground: Bool = true,
        startedAt: Date,
        lastActivityAt: Date,
        depth: Int = 0
    ) {
        self.id = id
        self.parentID = parentID
        self.agentType = agentType
        self.label = label
        self.activity = activity
        self.isBackground = isBackground
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.depth = depth
    }
}

/// One line of a drawn subagent tree: `prefix` goes before the agent's line, `continuation`
/// before any extra lines of the same agent (e.g. its activity).
public struct SubagentTreeLine: Equatable, Sendable {
    public var agent: SubagentInfo
    public var prefix: String
    public var continuation: String
}

public enum SubagentTree {
    /// Box-drawing prefixes for agents already in pre-order with `depth` set: "├ " / "└ " for
    /// the agent's own position among its siblings, "│ " / "  " for each ancestor level.
    public static func lines(_ agents: [SubagentInfo]) -> [SubagentTreeLine] {
        agents.indices.map { i in
            let depth = agents[i].depth
            // Is there a later sibling at `level` before the subtree at that level ends?
            func hasLaterSibling(at level: Int) -> Bool {
                for later in agents[(i + 1)...] {
                    if later.depth < level { return false }
                    if later.depth == level { return true }
                }
                return false
            }
            var prefix = ""
            for level in 0..<depth {
                prefix += hasLaterSibling(at: level) ? "│ " : "  "
            }
            let last = !hasLaterSibling(at: depth)
            return SubagentTreeLine(
                agent: agents[i],
                prefix: prefix + (last ? "└ " : "├ "),
                continuation: prefix + (last ? "  " : "│ ")
            )
        }
    }
}

public enum ElapsedFormat {
    /// "45s", "2m", "1h05m".
    public static func short(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return String(format: "%dh%02dm", s / 3600, (s % 3600) / 60)
    }
}
