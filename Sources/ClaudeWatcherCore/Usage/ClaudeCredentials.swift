import CryptoKit
import Foundation
import Security

/// The subset of Claude Code's OAuth credentials the usage source needs.
///
/// Only the access token and its expiry are ever decoded; the refresh token, MCP secrets and
/// everything else in the Keychain item are never retained. We never refresh the token
/// ourselves: that would rotate Claude Code's refresh token and silently log Claude Code out.
struct ClaudeCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    let accessToken: String
    /// nil when Claude Code didn't record an expiry.
    let expiresAt: Date?

    /// Treat the token as expired slightly early so a request doesn't race the expiry.
    static let expirySkew: TimeInterval = 60

    func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(Self.expirySkew)
    }

    /// SHA-256 of the token, so a rejected token can be recognized without keeping it.
    var tokenHash: SHA256.Digest { SHA256.hash(data: Data(accessToken.utf8)) }

    // Never let the token leak through string interpolation / logging.
    var description: String {
        "ClaudeCredentials(accessToken: <redacted>, expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"))"
    }
    var debugDescription: String { description }
    // Nor through `dump` / `Mirror`: no child carries the token.
    var customMirror: Mirror { Mirror(self, children: ["expiresAt": expiresAt as Any]) }
}

/// Every failure of the Claude usage source (credentials and API).
enum ClaudeUsageError: Error, Sendable, Equatable {
    case notLoggedIn
    case keychainUnavailable
    /// The Keychain item / credentials file isn't the expected JSON.
    case unreadableCredentials
    case tokenExpired
    /// 401 / 403.
    case unauthorized(Int)
    /// 429, with the server's `retry-after` in seconds if it sent one.
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(String)
    case decoding

    /// Short, user-facing message (rate limiting is formatted by the source, which knows the backoff).
    var userMessage: String {
        switch self {
        case .notLoggedIn: "Not logged in to Claude Code"
        case .keychainUnavailable: "Couldn't read Claude Code credentials"
        case .unreadableCredentials: "Couldn't parse Claude Code credentials"
        case .tokenExpired, .unauthorized: "Token expired: open Claude Code to refresh"
        case .rateLimited: "Rate limited"
        case .http(let code): "Server error (\(code))"
        case .network: "Network error"
        case .decoding: "Unexpected response from server"
        }
    }
}

/// Reads Claude Code's OAuth credentials: login Keychain items and
/// `<claude home>/.credentials.json` (what Claude Code writes when it can't use the Keychain).
enum ClaudeCredentialStore {
    static let baseService = "Claude Code-credentials"

    /// One Keychain lookup's outcome.
    enum KeychainRead: Sendable, Equatable {
        case found(Data)
        case notFound
        case failed
    }

    /// Reads one generic-password item's value by service name. Injected in tests.
    typealias ReadKeychain = @Sendable (_ service: String) async -> KeychainRead
    /// Reads a file; nil if it doesn't exist (or can't be read). Injected in tests.
    typealias ReadFile = @Sendable (_ url: URL) async -> Data?

    /// Claude Code (2.1.330, `m8()`) suffixes the service name whenever `CLAUDE_CONFIG_DIR` is
    /// set (even to `~/.claude`): `-` + the first 8 hex digits of SHA-256 of the variable's raw
    /// value, NFC-normalized. We only see the resolved (tilde-expanded, standardized) path, so
    /// the hash matches unless the raw value had `~`, a trailing slash, `..` or the like.
    static func suffixedService(configDir: String) -> String {
        let normalized = configDir.precomposedStringWithCanonicalMapping
        let hex = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(baseService)-\(hex.prefix(8))"
    }

    /// One place Claude Code may keep its credentials.
    enum Location: Sendable, Equatable {
        case keychain(service: String)
        case file(URL)
    }

    /// Where to look, as tiers of locations that belong together. The first tier holds what
    /// belongs to `claudeHome`: for the default home the plain item (Claude Code run without
    /// `CLAUDE_CONFIG_DIR`), the suffixed ones (an explicit `CLAUDE_CONFIG_DIR=~/.claude`) and the
    /// file; for any other home the suffixed items and the file. For a non-default home the plain
    /// item is a second tier: it belongs to the default config dir, possibly another account, so
    /// it's only used when the home has nothing at all.
    static func locationTiers(claudeHome: URL, defaultHome: URL) -> [[Location]] {
        let path = claudeHome.standardizedFileURL.path
        var suffixed = [Location.keychain(service: suffixedService(configDir: path))]
        if !path.hasSuffix("/") { suffixed.append(.keychain(service: suffixedService(configDir: path + "/"))) }
        let file = Location.file(claudeHome.appendingPathComponent(".credentials.json"))
        let plain = Location.keychain(service: baseService)
        if path == defaultHome.standardizedFileURL.path {
            return [[plain] + suffixed + [file]]
        }
        return [suffixed + [file], [plain]]
    }

    /// `~/.claude`, the home Claude Code uses without `CLAUDE_CONFIG_DIR`.
    static var defaultHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Reads every location of the first tier that has anything (see `locationTiers`) and
    /// returns its best credentials: a usable (not expired) token with the latest `expiresAt`;
    /// a usable token without an expiry ranks below any with a known one; ties go to the
    /// earlier location. Claude Code may have used several items over time (e.g. the plain one
    /// before `CLAUDE_CONFIG_DIR` was set) and refreshes only the one it uses now, so the first
    /// one found can be long expired.
    ///
    /// - Throws: in that tier, with no usable token: `.keychainUnavailable` if a `security` read
    ///   failed (locked keychain, timeout, ...: the failed item may hold the fresh token; never
    ///   falls through to the next tier); else the expired token is returned (the caller reports
    ///   it); else `.unreadableCredentials` if something isn't the expected JSON; else
    ///   `.notLoggedIn` (items without a Claude.ai OAuth token). `.notLoggedIn` if no tier has
    ///   anything.
    static func load(
        claudeHome: URL, defaultHome: URL = defaultHome, now: Date,
        readKeychain: ReadKeychain, readFile: ReadFile
    ) async throws -> ClaudeCredentials {
        for tier in locationTiers(claudeHome: claudeHome, defaultHome: defaultHome) {
            var decoded: [ClaudeCredentials] = []
            var readFailed = false
            var decodeErrors: [ClaudeUsageError] = []
            for location in tier {
                let data: Data?
                switch location {
                case .keychain(let service):
                    switch await readKeychain(service) {
                    case .found(let value): data = value
                    case .notFound: data = nil
                    case .failed: readFailed = true; data = nil
                    }
                case .file(let url):
                    data = await readFile(url)
                }
                guard let data else { continue }
                do {
                    decoded.append(try decode(data))
                } catch let error as ClaudeUsageError {
                    decodeErrors.append(error)
                }
            }
            let best = best(of: decoded, now: now)
            if let best, !best.isExpired(now: now) { return best }
            if readFailed { throw ClaudeUsageError.keychainUnavailable }
            if let best { return best }
            if decodeErrors.contains(.unreadableCredentials) { throw ClaudeUsageError.unreadableCredentials }
            if !decodeErrors.isEmpty { throw ClaudeUsageError.notLoggedIn }
        }
        throw ClaudeUsageError.notLoggedIn
    }

    /// The highest-ranked credentials (see `load`); the earliest on a tie.
    static func best(of candidates: [ClaudeCredentials], now: Date) -> ClaudeCredentials? {
        func rank(_ credentials: ClaudeCredentials) -> (Int, Date) {
            if credentials.isExpired(now: now) { return (0, credentials.expiresAt ?? .distantPast) }
            guard let expiresAt = credentials.expiresAt else { return (1, .distantPast) }
            return (2, expiresAt)
        }
        var best: ClaudeCredentials?
        for candidate in candidates where best.map({ rank(candidate) > rank($0) }) ?? true {
            best = candidate
        }
        return best
    }

    /// Live: resolves the Claude home (off-main, see `SessionDiscovery.resolvedClaudeHome`),
    /// then reads the Keychain via `/usr/bin/security` and the file on a private queue.
    static func loadLive(now: Date) async throws -> ClaudeCredentials {
        try await load(claudeHome: await SessionDiscovery.resolvedClaudeHome(), now: now,
                       readKeychain: SecurityTool.read, readFile: readFileOffPool)
    }

    private struct Payload: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?   // milliseconds since epoch
        }
        let claudeAiOauth: OAuth?
    }

    /// Parses the item's value (`security -w` output, or the credentials file).
    static func decode(_ output: Data) throws -> ClaudeCredentials {
        var data = output
        while let last = data.last, last == UInt8(ascii: "\n") || last == UInt8(ascii: "\r") {
            data.removeLast()
        }
        guard !data.isEmpty else { throw ClaudeUsageError.notLoggedIn }
        // `security -w` prints the value as hex if it has any non-printable byte or newline
        // (e.g. a non-ASCII MCP server name in the JSON).
        if data.first != UInt8(ascii: "{"), let decoded = hexDecoded(data) {
            data = decoded
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ClaudeUsageError.unreadableCredentials
        }
        guard let oauth = payload.claudeAiOauth, let token = oauth.accessToken, !token.isEmpty else {
            throw ClaudeUsageError.notLoggedIn
        }
        let expiry = oauth.expiresAt.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        return ClaudeCredentials(accessToken: token, expiresAt: expiry)
    }

    /// nil unless `hex` is a non-empty, even-length run of hex digits.
    static func hexDecoded(_ hex: Data) -> Data? {
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var result = Data(capacity: hex.count / 2)
        var high: UInt8?
        for char in hex {
            let nibble: UInt8
            switch char {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = char - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = char - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibble = char - UInt8(ascii: "A") + 10
            default: return nil
            }
            if let h = high {
                result.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return result
    }

    private static let fileQueue = DispatchQueue(label: "com.thegoldenmule.ClaudeWatcher.ClaudeCredentials.file",
                                                 qos: .utility)

    static let readFileOffPool: ReadFile = { url in
        await withCheckedContinuation { continuation in
            fileQueue.async { continuation.resume(returning: try? Data(contentsOf: url)) }
        }
    }
}

/// Runs `/usr/bin/security find-generic-password -a <account> -s <service> -w`, like Claude Code's
/// own reader. `security` created Claude Code's item, so it's in the item's ACL and no Keychain
/// prompt is shown, unless the keychain is locked: then `security` may raise the unlock dialog
/// on every attempt, so a locked default keychain fails the read without spawning it. The
/// process is run and waited for on a private queue (never on the cooperative pool), sent
/// SIGTERM after `timeout` and SIGKILL `killGrace` later.
enum SecurityTool {
    /// `security`'s exit status when the item doesn't exist (errSecItemNotFound).
    static let itemNotFoundExitCode: Int32 = 44
    static let timeout: TimeInterval = 15
    static let killGrace: TimeInterval = 2

    /// True if the default keychain is known to be locked. Injected in tests.
    typealias IsKeychainLocked = @Sendable () -> Bool
    /// Runs `security` for one service (blocking). Injected in tests.
    typealias Spawn = @Sendable (_ service: String) -> ClaudeCredentialStore.KeychainRead

    private static let queue = DispatchQueue(label: "com.thegoldenmule.ClaudeWatcher.SecurityTool",
                                             qos: .utility)

    static let read: ClaudeCredentialStore.ReadKeychain = makeRead(
        isKeychainLocked: defaultKeychainIsLocked, spawn: { readBlocking(service: $0) })

    /// A reader that checks the lock state, then spawns, both on the private queue.
    static func makeRead(isKeychainLocked: @escaping IsKeychainLocked,
                         spawn: @escaping Spawn) -> ClaudeCredentialStore.ReadKeychain {
        { service in
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: isKeychainLocked() ? .failed : spawn(service)) }
            }
        }
    }

    /// Claude Code's account name: `$USER` (else the login name) if it matches
    /// `^[a-zA-Z0-9._-]+$`, else `claude-code-user` (Claude Code 2.1.330). We use the login name.
    static func account(userName: String) -> String {
        userName.wholeMatch(of: /[a-zA-Z0-9._-]+/) != nil ? userName : "claude-code-user"
    }

    /// `kSecUnlockStateStatus` unset on the default keychain. Unknown (no default keychain, an
    /// error) counts as unlocked, so `security` decides as before. The APIs are deprecated but
    /// have no replacement for asking without unlocking.
    static let defaultKeychainIsLocked: IsKeychainLocked = {
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return false }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return false }
        return status & SecKeychainStatus(kSecUnlockStateStatus) == 0
    }

    private static func readBlocking(service: String) -> ClaudeCredentialStore.KeychainRead {
        let arguments = ["find-generic-password", "-a", account(userName: NSUserName()), "-s", service, "-w"]
        guard let output = run(URL(fileURLWithPath: "/usr/bin/security"), arguments: arguments,
                               timeout: timeout, killGrace: killGrace),
              let status = output.exitStatus else { return .failed }
        switch status {
        case 0: return .found(output.stdout)
        case itemNotFoundExitCode: return .notFound
        default: return .failed
        }
    }

    struct Output: Sendable {
        let stdout: Data
        /// nil if the process didn't exit normally (killed by a signal).
        let exitStatus: Int32?
    }

    /// Runs `executable` to completion (blocking; call off the cooperative pool), stdout
    /// captured, stdin/stderr null. nil if it couldn't be started.
    static func run(_ executable: URL, arguments: [String],
                    timeout: TimeInterval, killGrace: TimeInterval) -> Output? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let reader = stdout.fileHandleForReading
        defer { try? reader.close() }

        do {
            try process.run()
        } catch {
            return nil
        }
        // Killing the process closes its end of the pipe, which unblocks the read below. A
        // process that ignores SIGTERM gets SIGKILL after the grace period.
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGrace) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        // Drain the pipe before waiting so a large item can't deadlock on a full pipe buffer.
        let data = reader.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return Output(stdout: data,
                      exitStatus: process.terminationReason == .exit ? process.terminationStatus : nil)
    }
}
