import Foundation

/// Installs / uninstalls the ClaudeWatcher hook in Codex CLI's user hooks file,
/// `$CODEX_HOME/hooks.json` (same `hooks` → event → matcher groups → handlers schema as
/// Claude Code's settings; edited with `HookInstaller`'s order-preserving machinery and the
/// `.codex` profile). Codex only allows the top-level keys `description` and `hooks` there; we
/// only ever add `hooks`.
///
/// Trust: Codex runs a user hook only once it is trusted, recorded by Codex itself in
/// `$CODEX_HOME/config.toml` as `[hooks.state."<hooks.json path>:<event>:<group>:<handler>"]
/// trusted_hash = "sha256:…"` (the user approves it in Codex's startup "Review hooks" prompt).
/// We never write that; `status` only reports whether each of our handlers has a
/// `trusted_hash` entry (presence, not hash equality: the hash is over Codex's internal serde
/// form, too brittle to recompute).
public enum CodexHookInstaller {
    public struct Status: Sendable, Equatable {
        public var install: HookInstaller.InstallStatus
        /// Installed, but Codex hasn't recorded trust for every one of our handlers (or one is
        /// disabled), so it won't run them until the user approves them in Codex.
        public var needsTrust: Bool

        public init(install: HookInstaller.InstallStatus, needsTrust: Bool) {
            self.install = install
            self.needsTrust = needsTrust
        }
    }

    public static let profile = HookInstaller.Profile.codex

    public static func hooksURL(codexHome: URL) -> URL {
        codexHome.appendingPathComponent("hooks.json")
    }

    public static func configURL(codexHome: URL) -> URL {
        codexHome.appendingPathComponent("config.toml")
    }

    /// Whether Codex looks installed for this user: its home directory exists.
    public static func isCodexPresent(codexHome: URL = CodexPaths.defaultHome) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: codexHome.path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func status(
        hookScriptSource: URL? = nil,
        codexHome: URL = CodexPaths.defaultHome,
        installDirectory: URL = HookInstaller.defaultInstallDirectory
    ) -> Status {
        let hooksURL = hooksURL(codexHome: codexHome)
        let install = HookInstaller.status(
            hookScriptSource: hookScriptSource, settingsURL: hooksURL,
            installDirectory: installDirectory, profile: profile)
        guard install == .installed else { return Status(install: install, needsTrust: false) }
        guard let data = try? Data(contentsOf: hooksURL), let root = try? OrderedJSON.parse(data) else {
            return Status(install: install, needsTrust: false)
        }
        let toml = (try? String(contentsOf: configURL(codexHome: codexHome), encoding: .utf8)) ?? ""
        let states = CodexHookTrust.states(configTOML: toml)
        let keySources = Set([hooksURL.path, hooksURL.resolvingSymlinksInPath().path,
                              ProcessRules.realpath(hooksURL.path)].compactMap { $0 })
        let trusted = ourHandlerKeys(root: root).allSatisfy { suffix in
            keySources.contains { source in
                guard let state = states["\(source):\(suffix)"] else { return false }
                return state.trustedHash != nil && state.enabled != false
            }
        }
        return Status(install: install, needsTrust: !trusted)
    }

    /// Idempotent; see `HookInstaller.install`. Creates `hooks.json` if missing.
    @discardableResult
    public static func install(
        hookScriptSource: URL,
        codexHome: URL = CodexPaths.defaultHome,
        installDirectory: URL = HookInstaller.defaultInstallDirectory
    ) throws -> URL? {
        try HookInstaller.install(
            hookScriptSource: hookScriptSource, settingsURL: hooksURL(codexHome: codexHome),
            installDirectory: installDirectory, profile: profile)
    }

    /// Removes only our handlers and leaves the no-op stub at the script path (running Codex
    /// daemons snapshot their hooks and keep invoking it).
    @discardableResult
    public static func uninstall(
        codexHome: URL = CodexPaths.defaultHome,
        installDirectory: URL = HookInstaller.defaultInstallDirectory
    ) throws -> URL? {
        try HookInstaller.uninstall(
            settingsURL: hooksURL(codexHome: codexHome), installDirectory: installDirectory, profile: profile)
    }

    /// `<event label>:<group index>:<handler index>` of each handler of ours, as Codex numbers
    /// them (all groups of the event, all handlers of the group, foreign ones included).
    static func ourHandlerKeys(root: OrderedJSON) -> [String] {
        guard case let .object(eventPairs)? = root["hooks"] else { return [] }
        var keys: [String] = []
        for (event, value) in eventPairs {
            for (gi, group) in (value.arrayValue ?? []).enumerated() {
                for (hi, handler) in (group["hooks"]?.arrayValue ?? []).enumerated()
                where HookInstaller.isOurs(handler, profile: profile) {
                    keys.append("\(eventKeyLabel(event)):\(gi):\(hi)")
                }
            }
        }
        return keys
    }

    /// Codex's `hook_event_key_label`: "PermissionRequest" -> "permission_request".
    static func eventKeyLabel(_ event: String) -> String {
        var out = ""
        for (i, ch) in event.enumerated() {
            if ch.isUppercase {
                if i > 0 { out += "_" }
                out += ch.lowercased()
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

/// Minimal, read-only scan of `config.toml` for `hooks.state.<key>.{trusted_hash, enabled}`.
/// Understands standard table headers (`[hooks.state."k"]`), dotted keys under `[hooks]` /
/// `[hooks.state]` / the root, and a one-line inline table (`"k" = { trusted_hash = "…" }`).
/// Keys may be bare, basic ("…", with escapes) or literal ('…') strings.
enum CodexHookTrust {
    struct State: Equatable {
        var trustedHash: String?
        var enabled: Bool?
    }

    static func states(configTOML: String) -> [String: State] {
        var result: [String: State] = [:]
        var table: [String] = []
        for rawLine in configTOML.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[[") {
                table = ["\u{0}array"]  // array of tables: nothing of ours lives there
                continue
            }
            if line.hasPrefix("[") {
                var scanner = Substring(line.dropFirst())
                if let path = parseKeyPath(&scanner), scanner.first == "]" {
                    table = path
                } else {
                    table = ["\u{0}invalid"]
                }
                continue
            }
            var scanner = Substring(line)
            guard let keyPath = parseKeyPath(&scanner), scanner.first == "=" else { continue }
            scanner = scanner.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
            let full = table + keyPath
            if full.count == 4, full[0] == "hooks", full[1] == "state" {
                apply(field: full[3], value: &scanner, to: &result[full[2], default: State()])
            } else if full.count == 3, full[0] == "hooks", full[1] == "state", scanner.first == "{" {
                scanner = scanner.dropFirst()
                var state = result[full[2], default: State()]
                while true {
                    skipSpaces(&scanner)
                    guard let field = parseKeyPath(&scanner), field.count == 1, scanner.first == "=" else { break }
                    scanner = scanner.dropFirst()
                    skipSpaces(&scanner)
                    apply(field: field[0], value: &scanner, to: &state)
                    skipSpaces(&scanner)
                    guard scanner.first == "," else { break }
                    scanner = scanner.dropFirst()
                }
                result[full[2]] = state
            }
        }
        return result
    }

    private static func apply(field: String, value: inout Substring, to state: inout State) {
        switch field {
        case "trusted_hash":
            if let s = parseString(&value) { state.trustedHash = s }
        case "enabled":
            if value.hasPrefix("true") { state.enabled = true; value = value.dropFirst(4) }
            else if value.hasPrefix("false") { state.enabled = false; value = value.dropFirst(5) }
        default:
            // Skip an unknown value up to the next top-level comma (inline tables).
            if let s = parseString(&value) { _ = s } else {
                value = value.drop(while: { $0 != "," && $0 != "}" })
            }
        }
    }

    private static func skipSpaces(_ s: inout Substring) {
        s = s.drop(while: { $0 == " " || $0 == "\t" })
    }

    /// Parses `a."b c".'d'` up to (not including) the next `=` / `]` and the spaces before it.
    static func parseKeyPath(_ s: inout Substring) -> [String]? {
        var parts: [String] = []
        while true {
            skipSpaces(&s)
            guard let first = s.first else { return nil }
            if first == "\"" || first == "'" {
                guard let str = parseString(&s) else { return nil }
                parts.append(str)
            } else {
                let bare = s.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
                guard !bare.isEmpty else { return nil }
                parts.append(String(bare))
                s = s.dropFirst(bare.count)
            }
            skipSpaces(&s)
            if s.first == "." { s = s.dropFirst(); continue }
            return parts
        }
    }

    /// A basic ("…", escapes `\" \\ \n \t \r \b \f \uXXXX \UXXXXXXXX`) or literal ('…') string.
    static func parseString(_ s: inout Substring) -> String? {
        guard let quote = s.first, quote == "\"" || quote == "'" else { return nil }
        var rest = s.dropFirst()
        var out = ""
        while let ch = rest.first {
            rest = rest.dropFirst()
            if ch == quote {
                s = rest
                return out
            }
            if quote == "\"", ch == "\\" {
                guard let esc = rest.first else { return nil }
                rest = rest.dropFirst()
                switch esc {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{8}")
                case "f": out.append("\u{c}")
                case "u", "U":
                    let n = esc == "u" ? 4 : 8
                    let hex = rest.prefix(n)
                    guard hex.count == n, let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) else { return nil }
                    out.unicodeScalars.append(u)
                    rest = rest.dropFirst(n)
                default: return nil
                }
            } else {
                out.append(ch)
            }
        }
        return nil
    }
}
