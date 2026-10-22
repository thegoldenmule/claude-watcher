import Foundation

/// A Ghostty configuration with `config-file` includes expanded, in effective order.
public struct GhosttyConfig: Sendable, Equatable {
    public var entries: [GhosttyConfigEntry]
    /// Every config path read or probed (missing ones included), for change detection.
    public var files: [String]

    public init(entries: [GhosttyConfigEntry], files: [String] = []) {
        self.entries = entries
        self.files = files
    }

    /// The last `theme` entry wins; an empty one clears it.
    public var themeSpec: GhosttyThemeSpec? {
        entries.last(where: { $0.key == "theme" }).flatMap { GhosttyThemeSpec($0.value) }
    }

    /// Ghostty applies the theme first and the config on top, so explicit config keys
    /// (`background`, `palette = 1=...`) override the theme's.
    public func resolve(
        prefersDark: Bool,
        themeOverride: GhosttyThemeSpec? = nil,
        loadTheme: (String) -> [GhosttyConfigEntry]?
    ) -> GhosttyTheme {
        var theme = GhosttyTheme.ghosttyDefault
        let spec = themeOverride ?? themeSpec
        if let spec {
            let name = spec.name(prefersDark: prefersDark)
            if let themeEntries = loadTheme(name) {
                theme.apply(themeEntries)
                theme.themeName = name
            }
        }
        // An override previews a theme as-is: config colors would otherwise mask it.
        theme.apply(themeOverride == nil ? entries : entries.filter { !Self.colorKeys.contains($0.key) })
        return theme
    }

    private static let colorKeys: Set<String> = [
        "background", "foreground", "palette", "cursor-color",
        "selection-background", "selection-foreground",
    ]
}

/// Result of loading the user's Ghostty look from disk.
public struct GhosttyThemeLoad: Sendable, Equatable {
    public var theme: GhosttyTheme
    /// True for `theme = light:X,dark:Y`: the look depends on the system appearance.
    public var followsAppearance: Bool
    /// Config and theme files involved (some may not exist); watch these for changes.
    public var watchedPaths: [String]
}

/// Finds and reads the Ghostty config and themes. File access goes through `readFile` so tests
/// can feed fixture strings.
public struct GhosttyThemeLoader: Sendable {
    /// Config files in load order (later ones override earlier ones).
    public var configPaths: [String]
    /// Directories searched, in order, for a theme given by name.
    public var themeDirectories: [String]
    /// Forces a theme (`CW_GHOSTTY_THEME`), ignoring the config's own `theme` and colors.
    public var themeOverride: GhosttyThemeSpec?
    public var home: String
    public var readFile: @Sendable (String) -> String?

    public init(
        configPaths: [String],
        themeDirectories: [String],
        themeOverride: GhosttyThemeSpec? = nil,
        home: String = NSHomeDirectory(),
        readFile: @escaping @Sendable (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) {
        self.configPaths = configPaths
        self.themeDirectories = themeDirectories
        self.themeOverride = themeOverride
        self.home = home
        self.readFile = readFile
    }

    public static let defaultResourcesDirectory = "/Applications/Ghostty.app/Contents/Resources/ghostty"

    /// Ghostty's macOS search paths: `$XDG_CONFIG_HOME/ghostty/` (default `~/.config/ghostty/`)
    /// then `~/Library/Application Support/com.mitchellh.ghostty/`, each `config.ghostty` and
    /// the legacy `config`. Themes: the user's `themes/` directories, then the app bundle's.
    ///
    /// Overrides: `CW_GHOSTTY_CONFIG=<path>` reads only that config file;
    /// `CW_GHOSTTY_THEME=<name or light:A,dark:B>` previews a theme.
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        resourcesDirectory: String? = nil
    ) -> GhosttyThemeLoader {
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.config"
        let xdgDir = "\(xdg)/ghostty"
        let appSupportDir = "\(home)/Library/Application Support/com.mitchellh.ghostty"
        let resources = environment["GHOSTTY_RESOURCES_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? resourcesDirectory ?? defaultResourcesDirectory

        let configPaths: [String]
        if let override = environment["CW_GHOSTTY_CONFIG"], !override.isEmpty {
            configPaths = [expand(override, home: home, relativeTo: FileManager.default.currentDirectoryPath)]
        } else {
            configPaths = [
                "\(xdgDir)/config", "\(xdgDir)/config.ghostty",
                "\(appSupportDir)/config", "\(appSupportDir)/config.ghostty",
            ]
        }
        return GhosttyThemeLoader(
            configPaths: configPaths,
            themeDirectories: ["\(xdgDir)/themes", "\(appSupportDir)/themes", "\(resources)/themes"],
            themeOverride: environment["CW_GHOSTTY_THEME"].flatMap(GhosttyThemeSpec.init),
            home: home)
    }

    /// Reads every config file and its `config-file` includes, as Ghostty does
    /// (`Config.loadRecursiveFiles`): all top-level files first, each appending its includes to
    /// one list; then that list is loaded in order, every included file appending its own
    /// includes to the end (breadth-first). So an include overrides every top-level file, not
    /// just the one naming it. `?path` marks an optional include; relative paths resolve
    /// against the including file's directory; an empty `config-file =` clears the list; each
    /// include path loads at most once (cycles), though a top-level file may be re-included.
    public func loadConfig() -> GhosttyConfig {
        var entries: [GhosttyConfigEntry] = []
        var files: [String] = []
        var includes: [String] = []

        func read(_ path: String) {
            if !files.contains(path) { files.append(path) }
            guard let text = readFile(path) else { return }
            let dir = (path as NSString).deletingLastPathComponent
            for entry in GhosttyConfigParser.parse(text) {
                guard entry.key == "config-file" else {
                    entries.append(entry)
                    continue
                }
                guard let target = Self.includeTarget(entry.value) else {
                    includes.removeAll()
                    continue
                }
                guard !target.isEmpty else { continue }
                includes.append(Self.standardize(Self.expand(target, home: home, relativeTo: dir)))
            }
        }

        configPaths.forEach { read(Self.standardize($0)) }
        var loaded: Set<String> = []
        var next = 0
        while next < includes.count {
            let path = includes[next]
            next += 1
            guard loaded.insert(path).inserted else { continue }  // include cycles
            read(path)
        }
        return GhosttyConfig(entries: entries, files: files)
    }

    /// A `config-file` value's path: nil for an empty value (which clears the include list),
    /// "" for one that is empty only after dropping `?` and quotes (ignored).
    static func includeTarget(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        var target = Substring(value)
        if target.hasPrefix("?") { target = target.dropFirst() }
        if target.count >= 2, target.hasPrefix("\""), target.hasSuffix("\"") {
            target = target.dropFirst().dropLast()
        }
        return String(target)
    }

    private static func standardize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    /// Every path the theme `name` could be read from, in lookup order: an absolute path as-is,
    /// else that name in each of `themeDirectories`.
    public func themeCandidates(named name: String) -> [String] {
        let expanded = Self.expand(name, home: home, relativeTo: nil)
        if expanded.hasPrefix("/") { return [expanded] }
        return themeDirectories.map { "\($0)/\(name)" }
    }

    /// Path of the theme file for `name`: absolute paths as-is, else the first match in
    /// `themeDirectories`.
    public func themePath(named name: String) -> String? {
        findTheme(named: name)?.path
    }

    /// The first readable candidate for `name`, with its contents (read once).
    private func findTheme(named name: String) -> (path: String, text: String)? {
        for path in themeCandidates(named: name) {
            if let text = readFile(path) { return (path, text) }
        }
        return nil
    }

    public func load(prefersDark: Bool) -> GhosttyThemeLoad {
        let config = loadConfig()
        let theme = config.resolve(prefersDark: prefersDark, themeOverride: themeOverride) { name in
            findTheme(named: name).map { GhosttyConfigParser.parse($0.text) }
        }
        let spec = themeOverride ?? config.themeSpec
        // Watch every candidate for every name the spec can select (both variants of
        // light:/dark:), found or not: installing the theme, or a user theme shadowing a
        // bundled one, must trigger a reload. A missing path costs one failed stat per poll.
        var watched = config.files
        let names: [String] = switch spec {
        case .fixed(let name): [name]
        case .adaptive(let light, let dark): [light, dark]
        case nil: []
        }
        for path in names.flatMap(themeCandidates(named:)) where !watched.contains(path) {
            watched.append(path)
        }
        return GhosttyThemeLoad(
            theme: theme, followsAppearance: spec?.followsAppearance ?? false, watchedPaths: watched)
    }

    static func expand(_ path: String, home: String, relativeTo dir: String?) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        if path.hasPrefix("/") || dir == nil { return path }
        return "\(dir!)/\(path)"
    }
}
