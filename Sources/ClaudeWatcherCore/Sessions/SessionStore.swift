import Foundation
import Observation

/// Owns the live list of Claude Code sessions. Stub: discovery agent fills this in.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var sessions: [ClaudeSession] = []

    public init() {}

    public func start() {}

    public func stop() {}
}
