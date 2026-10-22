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

    /// Reads every config file and its `config-file` includes. Ghostty loads an include after
    /// the rest of the file that names it; `?path` marks an optional include, and relative
    /// paths are relative to the including file's directory.
    public func loadConfig() -> GhosttyConfig {
        var entries: [GhosttyConfigEntry] = []
        var files: [String] = []
        var visited: Set<String> = []

        func load(_ path: String) {
            let standardized = (path as NSString).standardizingPath
            guard visited.insert(standardized).inserted else { return }  // include cycles
            files.append(standardized)
            guard let text = readFile(standardized) else { return }
            var includes: [String] = []
            for entry in GhosttyConfigParser.parse(text) {
                if entry.key == "config-file" {
                    var target = entry.value
                    if target.hasPrefix("?") { target.removeFirst() }
                    guard !target.isEmpty else { continue }
                    let dir = (standardized as NSString).deletingLastPathComponent
                    includes.append(Self.expand(target, home: home, relativeTo: dir))
                } else {
                    entries.append(entry)
                }
            }
            includes.forEach(load)
        }

        configPaths.forEach(load)
        return GhosttyConfig(entries: entries, files: files)
    }

    /// Path of the theme file for `name`: absolute paths as-is, else the first match in
    /// `themeDirectories`.
    public func themePath(named name: String) -> String? {
        let expanded = Self.expand(name, home: home, relativeTo: nil)
        if expanded.hasPrefix("/") { return expanded }
        for dir in themeDirectories {
            let path = "\(dir)/\(name)"
            if readFile(path) != nil { return path }
        }
        return nil
    }

    public func load(prefersDark: Bool) -> GhosttyThemeLoad {
        let config = loadConfig()
        var watched = config.files
        let theme = config.resolve(prefersDark: prefersDark, themeOverride: themeOverride) { name in
            guard let path = themePath(named: name), let text = readFile(path) else { return nil }
            watched.append(path)
            return GhosttyConfigParser.parse(text)
        }
        let spec = themeOverride ?? config.themeSpec
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
