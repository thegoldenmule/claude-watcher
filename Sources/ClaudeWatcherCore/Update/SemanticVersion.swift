import Foundation

/// A semantic version (`MAJOR.MINOR.PATCH[-pre][+build]`), as in release tags (`v0.3.1`) and
/// `CFBundleShortVersionString`. Parsing accepts a leading `v`/`V` and missing minor/patch
/// components (`1.2` is `1.2.0`); build metadata is kept but ignored by comparison.
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible, Codable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Dot-separated pre-release identifiers (`rc.1` -> `["rc", "1"]`); empty for a release.
    public var prerelease: [String]
    public var build: String?

    public init(major: Int, minor: Int = 0, patch: Int = 0, prerelease: [String] = [], build: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    /// nil unless `string` is a version: 1-3 numeric components, then optional `-pre`/`+build`.
    public init?(_ string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        var build: String?
        if let plus = s.firstIndex(of: "+") {
            build = String(s[s.index(after: plus)...])
            s = s[..<plus]
            guard let b = build, !b.isEmpty else { return nil }
        }
        var prerelease: [String] = []
        if let dash = s.firstIndex(of: "-") {
            prerelease = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            s = s[..<dash]
            guard !prerelease.isEmpty, prerelease.allSatisfy({ id in
                !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }) else { return nil }
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prerelease, build: build)
    }

    /// Coded as its string form (`"0.3.1"`).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let version = SemanticVersion(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a version: \(string)")
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        var s = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { s += "-" + prerelease.joined(separator: ".") }
        if let build { s += "+" + build }
        return s
    }

    /// Semver precedence: build metadata doesn't count.
    public static func == (a: Self, b: Self) -> Bool {
        (a.major, a.minor, a.patch) == (b.major, b.minor, b.patch) && a.prerelease == b.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prerelease)
    }

    /// Semver precedence: a pre-release sorts before its release; identifiers compare
    /// numerically if both are numeric, numeric before alphanumeric, else ASCII; a shorter
    /// identifier list sorts first when it's a prefix of the other.
    public static func < (a: Self, b: Self) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (nx?, ny?): return nx < ny
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}
