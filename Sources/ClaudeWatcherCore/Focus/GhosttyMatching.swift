import Foundation

/// One Ghostty terminal surface as reported by its AppleScript dictionary.
public struct GhosttyTerminalInfo: Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var workingDirectory: String

    public init(id: String, name: String, workingDirectory: String) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
    }
}

/// Outcome of resolving a session to a Ghostty terminal.
public enum GhosttyResolution: Sendable, Equatable {
    /// Exactly one terminal is the session's.
    case unique(terminalID: String)
    /// Several plausible terminals, best first. `reason` is human readable.
    case ambiguous(candidates: [String], reason: String)
    case notFound
}

/// Pure title/cwd matching and list parsing. No Apple events here, so it's unit-testable.
public enum GhosttyMatcher {
    /// Field / record separators used by the listing script (ASCII US / RS). They can't occur
    /// in titles Ghostty reports or in paths in practice.
    public static let fieldSeparator: Character = "\u{1F}"
    public static let recordSeparator: Character = "\u{1E}"

    /// Strips the status glyph Claude Code prepends to its terminal title ("✳ Foo", "◐ Foo",
    /// "✶ Foo"…): a leading run of non-letter/non-digit/non-space characters that is followed by
    /// whitespace. Titles that merely start with punctuation ("[WIP] x", "(x)") are left alone
    /// unless the punctuation run is followed by a space. Surrounding whitespace is trimmed.
    public static func stripTitleGlyph(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, isGlyph(trimmed[idx]) {
            idx = trimmed.index(after: idx)
        }
        guard idx > trimmed.startIndex, idx < trimmed.endIndex, trimmed[idx].isWhitespace else {
            return trimmed
        }
        return trimmed[idx...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isGlyph(_ c: Character) -> Bool {
        !(c.isLetter || c.isNumber || c.isWhitespace)
    }

    /// Lexical path normalisation for comparing cwds: trailing slashes removed, `/private/tmp`
    /// and `/private/var` folded to `/tmp` and `/var`, `~` expanded.
    public static func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return p }
        if p.hasPrefix("file://"), let url = URL(string: p) { p = url.path }
        p = (p as NSString).expandingTildeInPath
        p = (p as NSString).standardizingPath
        for prefix in ["/private/tmp", "/private/var"] where p == prefix || p.hasPrefix(prefix + "/") {
            p = String(p.dropFirst("/private".count))
        }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Parses the listing script output: records separated by RS, fields (id, name, wd) by US.
    /// Malformed records (fewer than 2 fields or empty id) are skipped.
    public static func parseListing(_ output: String) -> [GhosttyTerminalInfo] {
        output.split(separator: recordSeparator, omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: fieldSeparator, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 2 else { return nil }
            let id = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            var wd = fields.count >= 3 ? fields[2] : ""
            if wd == "missing value" { wd = "" }
            return GhosttyTerminalInfo(id: id, name: fields[1], workingDirectory: wd)
        }
    }

    /// Picks the session's terminal from `terminals`.
    ///
    /// Policy (best first):
    /// 1. Title (glyph-stripped) and cwd both match: one hit → `.unique`; several → `.ambiguous`.
    /// 2. Title matches and exactly one terminal has it (cwd differs, e.g. the shell `cd`ed or
    ///    Ghostty lacks OSC 7) → `.unique`; several → `.ambiguous`.
    /// 3. Only cwd matches → `.ambiguous` (one or more), since any shell in that directory matches.
    /// 4. Otherwise `.notFound`.
    ///
    /// New sessions are all titled "✳ Claude Code", so they usually end up `.ambiguous`.
    public static func match(session: ClaudeSession, in terminals: [GhosttyTerminalInfo]) -> GhosttyResolution {
        let wantTitle = stripTitleGlyph(session.title)
        let wantCwd = normalizePath(session.cwd)

        let titleHits = wantTitle.isEmpty ? [] : terminals.filter { stripTitleGlyph($0.name) == wantTitle }
        let cwdHits = wantCwd.isEmpty ? [] : terminals.filter { normalizePath($0.workingDirectory) == wantCwd }
        let both = titleHits.filter { t in cwdHits.contains(where: { $0.id == t.id }) }

        if both.count == 1 { return .unique(terminalID: both[0].id) }
        if both.count > 1 {
            return .ambiguous(candidates: both.map(\.id),
                              reason: "\(both.count) Ghostty terminals are titled \"\(wantTitle)\" in \(session.cwd)")
        }
        if titleHits.count == 1 { return .unique(terminalID: titleHits[0].id) }
        if titleHits.count > 1 {
            return .ambiguous(candidates: titleHits.map(\.id),
                              reason: "\(titleHits.count) Ghostty terminals are titled \"\(wantTitle)\"")
        }
        if !cwdHits.isEmpty {
            return .ambiguous(candidates: cwdHits.map(\.id),
                              reason: "No Ghostty terminal titled \"\(wantTitle)\"; matched by directory only")
        }
        return .notFound
    }
}
