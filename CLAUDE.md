# ClaudeWatcher

Auto-hiding left-edge bar (like the Dock) listing running Claude Code CLI sessions
(title, git branch, status), styled as a Ghostty pane themed from the user's Ghostty config.
Clicking a session focuses its terminal (Ghostty or Terminal.app), even across Spaces.
Menu-bar-only accessory app (LSUIElement), unsandboxed. MIT licensed.
macOS 26, Swift 6 language mode, SwiftPM (no Xcode project).

## Layout
- `Sources/ClaudeWatcherCore/Model/`: shared types (`ClaudeSession`, `SessionStatus`,
  `TerminalKind`, `FocusResult`).
- `Sources/ClaudeWatcherCore/Sessions/`: `SessionStore` (`@MainActor @Observable`) over
  `SessionDiscovery` (actor): registry + transcripts + liveness, joined with hook state.
- `Sources/ClaudeWatcherCore/Hook/`: `HookState`/`HookStateStore`/`HookStateCache` (reads the
  hook's output, `<sid>.json` + `<sid>.ghostty` sidecar), `HookInstaller` (edits
  `settings.json` under `$CLAUDE_CONFIG_DIR` else `~/.claude`, order-preserving, updates our
  entries in place, retries on a concurrent-write conflict; uninstall leaves a no-op stub script).
- `Sources/ClaudeWatcherCore/Focus/`: `RoutingFocuser` -> `GhosttyFocuser` (resolver chain) /
  `AppleTerminalFocuser` / activate-hosting-app fallback. `AppleScriptRunner` runs scripts.
  `OSC7Probe` (`GhosttyOSC7Probe.swift`) + `OSC7ProbeLock` (cross-process lock shared with the hook).
- `Sources/ClaudeWatcherCore/Theme/`: `GhosttyColor`, `GhosttyConfigParser` (+ `GhosttyThemeSpec`,
  incl. `light:A,dark:B`), `GhosttyTheme`, `GhosttyThemeLoader` (Ghostty's config search paths,
  `config-file` includes, user then bundled themes; config colors override the theme's).
- `Sources/ClaudeWatcherCore/Edge/`: `EdgeRevealPolicy`, pure auto-hide logic.
- `Sources/ClaudeWatcher/App/`: `AppDelegate` (owns the store, the single `RoutingFocuser`,
  `EdgeController`, `MenuModel`), `ClaudeWatcherApp` (menu bar extra), `DemoMode`.
- `Sources/ClaudeWatcher/UI/`: `EdgeController` (panel show/hide, focus + result banner, owns
  `ThemeStore`), `SidebarView`, `SidebarPanel`, `TerminalStyle` (SwiftUI colors/font/metrics from a
  `GhosttyTheme`, injected via `\.terminalStyle`), `ThemeStore` (reloads when a watched config/theme
  file changes, stat-polled every 2 s, and on system appearance flips for light:/dark: themes).
- `hooks/claude-watcher-hook.sh`: the Claude Code hook; bundled into Contents/Resources.
- `Tests/ClaudeWatcherCoreTests/`: Swift Testing (`import Testing`). Keep logic in Core so it is testable.
- `Resources/Info.plist`, `scripts/build-app.sh`, `Makefile`: build tooling.

## Commands
- `make build` (`swift build`), `make test` (`swift test`)
- `make app`: release build, assembles and signs `build/ClaudeWatcher.app`
- `make run`: kills any running instance, builds the app, opens it
- `make clean`
- Demo data, panel pinned: `open build/ClaudeWatcher.app --args --demo` (or `CW_DEMO=1`;
  `CW_APPEARANCE=dark|light`). Demo Terminal rows fail with the permission banner, "other" rows
  show the info banner. Screenshot helpers (demo only): `CW_DEMO_NOTICE=error|info`,
  `CW_DEMO_HOVER=<id>`, `CW_DEMO_PENDING=<id>`, `CW_DEMO_EMPTY=1`.
- Theme overrides: `CW_GHOSTTY_CONFIG=<path>` (read only that config),
  `CW_GHOSTTY_THEME=<name or light:A,dark:B>` (preview a theme, ignoring config colors).
- Live discovery dump: `CW_LIVE=1 swift test --filter liveDiscovery`.
- Logs: `/usr/bin/log stream --predicate 'subsystem == "com.thegoldenmule.ClaudeWatcher"'`
  (in zsh, bare `log` is a builtin). Focus lines show the resolver and the hook id.
- Signing: `$CODESIGN_IDENTITY`, else first "Apple Development" identity, else ad-hoc
  (ad-hoc resets TCC Accessibility/Automation grants on every rebuild). No hardened runtime.

## Conventions
- Commit with one-line messages only (no body/trailers). Don't push.
- If several agents work at once: give each its own SwiftPM scratch dir
  (`swift build --scratch-path .build-<name>`; `scripts/build-app.sh` honours `SCRATCH_PATH`)
  and stage only your own paths (never `git add -A`).

## Platform facts / gotchas
- `~/.claude/sessions/<pid>.json` is Claude Code's live session registry (one file per CLI
  process). It is rewritten **in place** on every status change (same inode for the whole
  session, directory mtime unchanged), so a directory vnode source never sees status flips:
  `SessionStore` keeps one vnode source per live registry file, plus directory sources and a
  2 s poll as safety net.
- Discovery honors `$CLAUDE_CONFIG_DIR`. A registry pid is live only if it runs Claude Code:
  `ProcessRules.isClaudeExecutable` accepts a binary named `claude`, the native installer's
  `…/claude/versions/<ver>`, Homebrew's `Caskroom/claude-code/`, or `node` running the npm
  package (argv read via `KERN_PROCARGS2`, only for `node`). Mirrors the hook's `find_claude`.
- Hook state dir `~/Library/Application Support/ClaudeWatcher/hook-state/` (layout documented at
  the top of `hooks/claude-watcher-hook.sh`; keep both sides in sync):
  - `<sid>.json`: replaced wholesale (temp + rename) by every event, no lock, no Ghostty id.
    Discovery joins it by session id, else newest-by-pid; pid, tty and "written after process
    start" must all agree.
  - `<sid>.ghostty`: sidecar with the Ghostty terminal id, written only by the detached probe
    (and SessionStart inheriting a `/clear` predecessor's id); wins over any id in the JSON.
    Only exists for sessions that started after the hook was installed.
  - `<sid>.ended`: SessionEnd tombstone (renamed `<sid>.json`) so late async hooks can't
    resurrect the session; GC'd after ~1 h. The old per-session `.lock-<sid>` is gone.
  - `.probe-<ttyname>.lock/owner` (`<pid> <token>`): per-tty probe lock shared by the hook and
    Swift `OSC7ProbeLock` (same protocol both sides): mkdir to acquire, ~1 s bounded wait then
    skip, stale after 10 s (break by renaming aside), release only if `owner` holds our token.
- `NSAppleScript` must run on the main thread: off-main, Ghostty's replies to element
  queries (`every terminal`) never arrive and the script hangs past its `with timeout`.
  `AppleScriptRunner` hops to the MainActor; every generated script carries
  `with timeout of 3 seconds`. The first run per target app blocks on the TCC Automation prompt.
- Ghostty 1.3.1 has no `tty` terminal property. The OSC 7 probe identifies a terminal by
  writing an OSC 7 with a nonce cwd to the session's tty and asking Ghostty which terminal's
  `working directory` matches, then restoring the real cwd. The hook runs it once at
  SessionStart; `GhosttyFocuser` runs it on demand (cached per pid) when no hook id exists.
  Swift polls for the nonce with short delay-free scripts (exact last-path-component match);
  tty writes are non-blocking, bounded and retried, and the cwd is always restored.
- Ghostty AppleScript `focus <terminal>` switches Spaces to the target window (verified).
- Terminal.app: `activate` first, then `set index of w to 1` and `set frontmost of w to true`.
  Raising before `activate` never switches Spaces.
- Automation denial surfaces as `FocusResult.failed` whose reason contains
  `AppleScriptError.notPermittedMarker`; the panel banner then offers
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`.
- Don't name a Core type `RGBColor`: it clashes with QuickDraw's `RGBColor` in AppKit targets
  (hence `GhosttyColor`).
