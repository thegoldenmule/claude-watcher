import Foundation

/// The running app's version, from its Info.plist. `swift run`/`swift test` have no app
/// Info.plist, so both fields can be nil there.
public struct AppVersionInfo: Sendable, Equatable {
    /// `CFBundleShortVersionString`, e.g. `0.3.1`.
    public var shortVersion: String?
    /// `CFBundleVersion`, e.g. `114`.
    public var build: String?

    public init(shortVersion: String?, build: String?) {
        self.shortVersion = shortVersion?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        self.build = build?.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    public init(infoDictionary: [String: Any]?) {
        self.init(shortVersion: infoDictionary?["CFBundleShortVersionString"] as? String,
                  build: infoDictionary?["CFBundleVersion"] as? String)
    }

    public static var main: AppVersionInfo { AppVersionInfo(infoDictionary: Bundle.main.infoDictionary) }

    /// nil if the short version isn't a semantic version (then no update is ever claimed).
    public var version: SemanticVersion? { shortVersion.flatMap(SemanticVersion.init) }

    /// "ClaudeWatcher 0.3.1 (114)"; "ClaudeWatcher (development build)" without a version.
    public var displayString: String {
        guard let shortVersion else { return "ClaudeWatcher (development build)" }
        guard let build, build != shortVersion else { return "ClaudeWatcher \(shortVersion)" }
        return "ClaudeWatcher \(shortVersion) (\(build))"
    }
}

/// A published GitHub release, reduced to what the menu needs.
public struct ReleaseInfo: Sendable, Equatable, Codable {
    /// The tag as published, e.g. `v0.3.1`.
    public var tag: String
    public var version: SemanticVersion
    /// The release page (notes + downloads).
    public var pageURL: URL
    /// The `ClaudeWatcher-X.Y.Z.dmg` asset, if the release has one.
    public var dmgURL: URL?
    public var publishedAt: Date?

    public init(tag: String, version: SemanticVersion, pageURL: URL, dmgURL: URL? = nil, publishedAt: Date? = nil) {
        self.tag = tag
        self.version = version
        self.pageURL = pageURL
        self.dmgURL = dmgURL
        self.publishedAt = publishedAt
    }

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case malformed
        /// The release is a draft or pre-release (`releases/latest` never returns one).
        case notARelease
        case unrecognizedTag(String)

        public var description: String {
            switch self {
            case .malformed: "unexpected response from GitHub"
            case .notARelease: "latest release is a draft or pre-release"
            case .unrecognizedTag(let tag): "unrecognized release tag \(tag)"
            }
        }
    }

    /// Decodes GitHub's `GET /repos/{owner}/{repo}/releases/latest` JSON.
    public static func decodeGitHubRelease(_ data: Data) throws(DecodeError) -> ReleaseInfo {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL?
        }
        struct Release: Decodable {
            var tag_name: String
            var html_url: URL
            var draft: Bool?
            var prerelease: Bool?
            var published_at: String?
            var assets: [Asset]?
        }
        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw .malformed
        }
        if release.draft == true || release.prerelease == true { throw .notARelease }
        guard let version = SemanticVersion(release.tag_name) else { throw .unrecognizedTag(release.tag_name) }
        if version.isPrerelease { throw .notARelease }
        let assets = release.assets ?? []
        let dmg = assets.first { $0.name == "ClaudeWatcher-\(version).dmg" }
            ?? assets.first { $0.name.hasSuffix(".dmg") }
        return ReleaseInfo(
            tag: release.tag_name, version: version, pageURL: release.html_url,
            dmgURL: dmg?.browser_download_url,
            publishedAt: release.published_at.flatMap { try? Date.ISO8601FormatStyle().parse($0) })
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
