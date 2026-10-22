import Foundation
import Testing
@testable import ClaudeWatcherCore

/// In-memory file system for the loader.
private func files(_ map: [String: String]) -> @Sendable (String) -> String? {
    { map[$0] }
}

private let mocha = """
    palette = 0=#45475a
    palette = 1=#f38ba8
    palette = 3=#f9e2af
    palette = 8=#585b70
    background = #1e1e2e
    foreground = #cdd6f4
    cursor-color = #f5e0dc
    selection-background = #585b70
    selection-foreground = #cdd6f4
    """

private let latte = """
    palette = 3=#df8e1d
    background = #eff1f5
    foreground = #4c4f69
    """

@Suite struct GhosttyColorTests {
    @Test func parsesHexForms() {
        #expect(GhosttyColor(ghostty: "#282c34") == GhosttyColor(0x282c34))
        #expect(GhosttyColor(ghostty: "282C34") == GhosttyColor(0x282c34))
        #expect(GhosttyColor(ghostty: "#fff") == GhosttyColor(0xffffff))
        #expect(GhosttyColor(ghostty: " #000000 ") == GhosttyColor(0x000000))
        #expect(GhosttyColor(ghostty: "Red") == GhosttyColor(0xff0000))
    }

    @Test func rejectsGarbageAndKeywords() {
        #expect(GhosttyColor(ghostty: "") == nil)
        #expect(GhosttyColor(ghostty: "#12345") == nil)
        #expect(GhosttyColor(ghostty: "#gg0000") == nil)
        #expect(GhosttyColor(ghostty: "cell-foreground") == nil)
    }

    @Test func hexRoundTripAndLightness() {
        #expect(GhosttyColor(0x1e1e2e).hexString == "#1e1e2e")
        #expect(GhosttyColor(0xeff1f5).isLight)
        #expect(!GhosttyColor(0x282c34).isLight)
        #expect(GhosttyColor(0x000000).contrast(with: GhosttyColor(0xffffff)) > 20.9)
    }

    @Test func darkenScalesChannels() {
        #expect(GhosttyColor(0x804020).darkened(by: 0.5) == GhosttyColor(red: 0x40 / 255.0, green: 0x20 / 255.0, blue: 0x10 / 255.0))
    }
}

@Suite struct GhosttyConfigParserTests {
    @Test func parsesKeysCommentsQuotesAndRepeats() {
        let entries = GhosttyConfigParser.parse("""
            # a comment
              # indented comment
            font-family = "Berkeley Mono"
            font-family = Symbols Nerd Font
            palette=1=#ff0000
            palette = 2 = #00ff00

            background-opacity = 0.9
            not a key value line
            = orphan value
            font-size =
            """)
        #expect(entries == [
            GhosttyConfigEntry("font-family", "Berkeley Mono"),
            GhosttyConfigEntry("font-family", "Symbols Nerd Font"),
            GhosttyConfigEntry("palette", "1=#ff0000"),
            GhosttyConfigEntry("palette", "2 = #00ff00"),
            GhosttyConfigEntry("background-opacity", "0.9"),
            GhosttyConfigEntry("font-size", ""),
        ])
    }

    @Test func hashInsideValueIsNotAComment() {
        #expect(GhosttyConfigParser.parse("background = #101010") == [GhosttyConfigEntry("background", "#101010")])
    }

    @Test func themeSpecs() {
        #expect(GhosttyThemeSpec("Catppuccin Mocha") == .fixed("Catppuccin Mocha"))
        #expect(GhosttyThemeSpec("light:Catppuccin Latte,dark:Catppuccin Mocha")
            == .adaptive(light: "Catppuccin Latte", dark: "Catppuccin Mocha"))
        #expect(GhosttyThemeSpec("dark: B , light: A") == .adaptive(light: "A", dark: "B"))
        #expect(GhosttyThemeSpec("") == nil)
        let adaptive = GhosttyThemeSpec("light:A,dark:B")!
        #expect(adaptive.followsAppearance)
        #expect(adaptive.name(prefersDark: true) == "B")
        #expect(adaptive.name(prefersDark: false) == "A")
        #expect(!GhosttyThemeSpec("A")!.followsAppearance)
    }
}

@Suite struct GhosttyThemeApplyTests {
    @Test func defaultsMatchStockGhostty() {
        let t = GhosttyTheme.ghosttyDefault
        #expect(t.background == GhosttyColor(0x282c34))
        #expect(t.foreground == GhosttyColor(0xffffff))
        #expect(t.palette.count == 16)
        #expect(t.ansi(3) == GhosttyColor(0xf0c674))
        #expect(t.ansi(8) == GhosttyColor(0x666666))
        #expect(t.fontSize == 13)
        #expect(t.backgroundOpacity == 1)
        #expect(t.backgroundBlur == .off)
        #expect(t.isDark)
        // Unset selection inverts the cell.
        #expect(t.effectiveSelectionBackground == t.foreground)
        #expect(t.effectiveSelectionForeground == t.background)
        #expect(t.effectiveCursorColor == t.foreground)
    }

    @Test func appliesKeys() {
        var t = GhosttyTheme.ghosttyDefault
        t.apply(GhosttyConfigParser.parse("""
            palette = 4=#0000ff
            palette = 0x0c=#0000aa
            palette = 200=#ffffff
            palette = 99
            font-family = JetBrains Mono
            font-family = Menlo
            font-size = 15.5
            font-thicken = true
            background-opacity = 1.4
            background-blur = true
            window-padding-x = 4,8
            window-padding-y = 6
            unfocused-split-opacity = 0.01
            split-divider-color = #333333
            selection-background = cell-foreground
            faint-opacity = 0.6
            """))
        #expect(t.ansi(4) == GhosttyColor(0x0000ff))
        #expect(t.ansi(12) == GhosttyColor(0x0000aa))
        #expect(t.palette.count == 16)
        #expect(t.fontFamilies == ["JetBrains Mono", "Menlo"])
        #expect(t.fontSize == 15.5)
        #expect(t.fontThicken)
        #expect(t.backgroundOpacity == 1)
        #expect(t.backgroundBlur == .radius(20))
        #expect(t.paddingX == (4, 8))
        #expect(t.paddingY == (6, 6))
        #expect(t.unfocusedSplitOpacity == 0.15)
        #expect(t.effectiveSplitDividerColor == GhosttyColor(0x333333))
        #expect(t.selectionBackground == nil)
        #expect(t.faintOpacity == 0.6)
    }

    @Test func emptyValuesReset() {
        var t = GhosttyTheme.ghosttyDefault
        t.apply(GhosttyConfigParser.parse("""
            font-family = A
            font-size = 20
            background = #000000
            background-blur = 30
            font-family =
            font-size =
            background =
            """))
        #expect(t.fontFamilies.isEmpty)
        #expect(t.fontSize == 13)
        #expect(t.background == GhosttyColor(0x282c34))
        #expect(t.backgroundBlur == .radius(30))
    }

    @Test func blurVariants() {
        var t = GhosttyTheme.ghosttyDefault
        t.apply(GhosttyConfigEntry("background-blur", "macos-glass-clear"))
        #expect(t.backgroundBlur == .glass(clear: true))
        t.apply(GhosttyConfigEntry("background-blur", "0"))
        #expect(t.backgroundBlur == .off)
        t.apply(GhosttyConfigEntry("background-blur", "nonsense"))
        #expect(t.backgroundBlur == .off)
    }

    @Test func splitDividerDefaultDarkensBackground() {
        var t = GhosttyTheme.ghosttyDefault
        #expect(t.effectiveSplitDividerColor == GhosttyColor(0x282c34).darkened(by: 0.4))
        t.apply(GhosttyConfigEntry("background", "#eff1f5"))
        #expect(t.effectiveSplitDividerColor == GhosttyColor(0xeff1f5).darkened(by: 0.08))
    }
}

@Suite struct GhosttyThemeLoaderTests {
    private func loader(_ map: [String: String], override: String? = nil) -> GhosttyThemeLoader {
        GhosttyThemeLoader(
            configPaths: ["/cfg/xdg/config", "/cfg/app/config.ghostty"],
            themeDirectories: ["/cfg/xdg/themes", "/res/themes"],
            themeOverride: override.flatMap(GhosttyThemeSpec.init),
            home: "/home",
            readFile: files(map))
    }

    @Test func noConfigGivesStockLook() {
        let load = loader([:]).load(prefersDark: true)
        #expect(load.theme == .ghosttyDefault)
        #expect(!load.followsAppearance)
        #expect(load.watchedPaths == ["/cfg/xdg/config", "/cfg/app/config.ghostty"])
    }

    @Test func themeThenConfigOverrides() {
        let load = loader([
            "/cfg/app/config.ghostty": """
                background = #000000
                theme = Catppuccin Mocha
                palette = 1=#ff0000
                font-size = 14
                """,
            "/res/themes/Catppuccin Mocha": mocha,
        ]).load(prefersDark: false)
        let t = load.theme
        #expect(t.themeName == "Catppuccin Mocha")
        // Config keys win over the theme regardless of their position in the file.
        #expect(t.background == GhosttyColor(0x000000))
        #expect(t.ansi(1) == GhosttyColor(0xff0000))
        #expect(t.foreground == GhosttyColor(0xcdd6f4))
        #expect(t.ansi(3) == GhosttyColor(0xf9e2af))
        #expect(t.selectionBackground == GhosttyColor(0x585b70))
        #expect(t.fontSize == 14)
        #expect(load.watchedPaths.contains("/res/themes/Catppuccin Mocha"))
    }

    @Test func adaptiveThemeFollowsAppearance() {
        let map = [
            "/cfg/xdg/config": "theme = light:Catppuccin Latte,dark:Catppuccin Mocha",
            "/res/themes/Catppuccin Mocha": mocha,
            "/res/themes/Catppuccin Latte": latte,
        ]
        let dark = loader(map).load(prefersDark: true)
        let light = loader(map).load(prefersDark: false)
        #expect(dark.followsAppearance && light.followsAppearance)
        #expect(dark.theme.background == GhosttyColor(0x1e1e2e))
        #expect(light.theme.background == GhosttyColor(0xeff1f5))
        #expect(light.theme.ansi(3) == GhosttyColor(0xdf8e1d))
        #expect(!light.theme.isDark)
    }

    @Test func userThemeDirectoryWinsAndAbsolutePathsWork() {
        let map = [
            "/cfg/xdg/config": "theme = Mine",
            "/cfg/xdg/themes/Mine": "background = #111111",
            "/res/themes/Mine": "background = #222222",
        ]
        #expect(loader(map).load(prefersDark: true).theme.background == GhosttyColor(0x111111))
        let abs = ["/cfg/xdg/config": "theme = ~/t/x", "/home/t/x": "background = #333333"]
        #expect(loader(abs).load(prefersDark: true).theme.background == GhosttyColor(0x333333))
    }

    @Test func missingThemeKeepsDefaults() {
        let t = loader(["/cfg/xdg/config": "theme = Nope"]).load(prefersDark: true).theme
        #expect(t.background == GhosttyTheme.ghosttyDefault.background)
        #expect(t.themeName == nil)
    }

    @Test func laterConfigFileOverridesEarlier() {
        let t = loader([
            "/cfg/xdg/config": "font-size = 11\ntheme = A",
            "/cfg/app/config.ghostty": "font-size = 16\ntheme =",
            "/res/themes/A": "background = #444444",
        ]).load(prefersDark: true).theme
        #expect(t.fontSize == 16)
        #expect(t.themeName == nil, "an empty theme value clears the earlier one")
    }

    @Test func includesLoadBreadthFirstAfterAllTopLevelFiles() {
        let config = loader([
            "/cfg/xdg/config": """
                config-file = sub/colors
                config-file = ?missing.conf
                config-file = ~/abs.conf
                background = #010101
                font-size = 10
                """,
            "/cfg/app/config.ghostty": "background = #0a0a0a\nconfig-file = app-inc",
            "/cfg/xdg/sub/colors": "background = #020202\nconfig-file = nested",
            "/home/abs.conf": "font-size = 18",
            "/cfg/app/app-inc": "background = #030303",
            "/cfg/xdg/sub/nested": "background = #040404",
        ]).loadConfig()
        // Ghostty: every top-level file, then their includes in order, then nested includes
        // (relative to the including file) appended to the end of the queue.
        #expect(config.files == [
            "/cfg/xdg/config", "/cfg/app/config.ghostty",
            "/cfg/xdg/sub/colors", "/cfg/xdg/missing.conf", "/home/abs.conf", "/cfg/app/app-inc",
            "/cfg/xdg/sub/nested",
        ])
        #expect(config.entries.filter { $0.key == "background" }.map(\.value) == [
            "#010101", "#0a0a0a", "#020202", "#030303", "#040404",
        ])
        var t = GhosttyTheme.ghosttyDefault
        t.apply(config.entries)
        // The XDG file's include beats the later App Support file.
        #expect(t.background == GhosttyColor(0x040404))
        #expect(t.fontSize == 18)
    }

    @Test func includeCyclesAreCut() {
        let config = loader([
            "/cfg/xdg/config": "font-size = 1\nconfig-file = b\nconfig-file = config",
            "/cfg/xdg/b": "font-size = 2\nconfig-file = config\nconfig-file = b",
        ]).loadConfig()
        // As in Ghostty, each include path loads once; a top-level file isn't in that set, so
        // including it re-applies it once, and its own includes are then cut.
        #expect(config.entries.map(\.value) == ["1", "2", "1"])
        #expect(config.files == ["/cfg/xdg/config", "/cfg/app/config.ghostty", "/cfg/xdg/b"])
    }

    @Test func emptyConfigFileClearsPendingIncludes() {
        let config = loader([
            "/cfg/xdg/config": "config-file = x\nconfig-file = ?\"\"",
            "/cfg/app/config.ghostty": "config-file =\nconfig-file = \"?y\"",
            "/cfg/xdg/x": "font-size = 1",
            "/cfg/app/y": "font-size = 2",
        ]).loadConfig()
        #expect(config.entries.map(\.value) == ["2"])
        #expect(config.files == ["/cfg/xdg/config", "/cfg/app/config.ghostty", "/cfg/app/y"])
    }

    @Test func watchesEveryThemeCandidateEvenIfMissing() {
        let load = loader([
            "/cfg/xdg/config": "theme = light:L,dark:D",
            "/res/themes/D": "background = #111111",
        ]).load(prefersDark: false)
        #expect(load.watchedPaths == [
            "/cfg/xdg/config", "/cfg/app/config.ghostty",
            "/cfg/xdg/themes/L", "/res/themes/L", "/cfg/xdg/themes/D", "/res/themes/D",
        ])
        #expect(load.theme.themeName == nil, "L isn't installed yet")
    }

    @Test func themeAppearingOrShadowingIsPickedUpOnReload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-theme-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: "\(root)/user", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: "\(root)/res", withIntermediateDirectories: true)
        try "theme = Mine".write(toFile: "\(root)/config", atomically: true, encoding: .utf8)
        let loader = GhosttyThemeLoader(
            configPaths: ["\(root)/config"], themeDirectories: ["\(root)/user", "\(root)/res"])
        let mtime = { (path: String) in
            (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }

        // Not installed: both candidates are watched while missing.
        let first = loader.load(prefersDark: true)
        #expect(first.theme.themeName == nil)
        #expect(first.watchedPaths.allSatisfy { $0 == "\(root)/config" || mtime($0) == nil })

        // Installed into the bundled directory: a watched path appears.
        try "background = #222222".write(toFile: "\(root)/res/Mine", atomically: true, encoding: .utf8)
        #expect(first.watchedPaths.contains { $0 != "\(root)/config" && mtime($0) != nil })
        let second = loader.load(prefersDark: true)
        #expect(second.theme.background == GhosttyColor(0x222222))

        // A user theme now shadows it: its (previously missing) path was already watched.
        #expect(second.watchedPaths.contains("\(root)/user/Mine"))
        try "background = #111111".write(toFile: "\(root)/user/Mine", atomically: true, encoding: .utf8)
        #expect(mtime("\(root)/user/Mine") != nil)
        #expect(loader.load(prefersDark: true).theme.background == GhosttyColor(0x111111))
    }

    @Test func themeOverrideIgnoresConfigColors() {
        let load = loader([
            "/cfg/xdg/config": "theme = Catppuccin Mocha\nbackground = #000000\nfont-size = 15",
            "/res/themes/Catppuccin Latte": latte,
        ], override: "Catppuccin Latte").load(prefersDark: true)
        #expect(load.theme.background == GhosttyColor(0xeff1f5))
        #expect(load.theme.fontSize == 15, "non-color keys still apply")
    }

    @Test func standardPathsAndOverrides() {
        let std = GhosttyThemeLoader.standard(environment: [:], home: "/Users/u")
        #expect(std.configPaths == [
            "/Users/u/.config/ghostty/config", "/Users/u/.config/ghostty/config.ghostty",
            "/Users/u/Library/Application Support/com.mitchellh.ghostty/config",
            "/Users/u/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ])
        #expect(std.themeDirectories.last == "/Applications/Ghostty.app/Contents/Resources/ghostty/themes")
        #expect(std.themeOverride == nil)

        let custom = GhosttyThemeLoader.standard(
            environment: [
                "XDG_CONFIG_HOME": "/x", "CW_GHOSTTY_CONFIG": "~/my.conf",
                "CW_GHOSTTY_THEME": "Dracula", "GHOSTTY_RESOURCES_DIR": "/r",
            ],
            home: "/Users/u")
        #expect(custom.configPaths == ["/Users/u/my.conf"])
        #expect(custom.themeDirectories.first == "/x/ghostty/themes")
        #expect(custom.themeDirectories.last == "/r/themes")
        #expect(custom.themeOverride == .fixed("Dracula"))
    }
}
