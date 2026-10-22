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
  `settings.json` under the resolved Claude home, order-preserving, updates our entries in place,
  retries on a concurrent-write conflict; uninstall leaves a no-op stub script; status counts only
  handlers in match-all groups, `.outdated` if one of ours sits under a restricting matcher).
- `Sources/ClaudeWatcherCore/Focus/`: `RoutingFocuser` -> `GhosttyFocuser` (resolver chain) /
  `AppleTerminalFocuser` / activate-hosting-app fallback. `AppleScriptRunner` runs scripts.
  `OSC7Probe` (`GhosttyOSC7Probe.swift`) + `OSC7ProbeLock` (cross-process lock shared with the hook).
  `TerminalHighlighter` (`.shared`): tints a Ghostty session's split pane on sidebar hover and
  pulses it after a successful focus (see "Pane highlight" below).
- `Sources/ClaudeWatcherCore/Theme/`: `GhosttyColor`, `GhosttyConfigParser` (+ `GhosttyThemeSpec`,
  incl. `light:A,dark:B`), `GhosttyTheme`, `GhosttyThemeLoader` (Ghostty's config search paths;
  `config-file` includes load breadth-first after all top-level files, like Ghostty's
  `loadRecursiveFiles`; user then bundled themes; config colors override the theme's; every
  theme candidate path is watched, even missing ones, so a newly created theme file is seen).
  `GhosttyTheme.highlightTint(strength:)` (`GhosttyTheme+Highlight.swift`): the pane tint color.
- `Sources/ClaudeWatcherCore/Edge/`: `EdgeRevealPolicy`, pure auto-hide logic.
- `Sources/ClaudeWatcher/App/`: `AppDelegate` (owns the store, the single `RoutingFocuser`,
  `EdgeController`, `MenuModel`), `ClaudeWatcherApp` (menu bar extra), `DemoMode`. Nothing may
  resolve `SessionDiscovery.defaultClaudeHome` on main at launch: `AppDelegate.init` prewarms it,
  the store is created once it resolves off-main, and `MenuModel` computes statuses off-main.
- `Sources/ClaudeWatcher/UI/`: `EdgeController` (panel show/hide, focus + result banner, owns
  `ThemeStore`), `SidebarView` (its `TimelineView`s pause while the panel is hidden, via
  `\.panelVisible`: they keep firing after `orderOut`), `SidebarPanel`, `TerminalStyle` (SwiftUI
  colors/font/metrics from a `GhosttyTheme`, injected via `\.terminalStyle`), `ThemeStore` (reloads when a watched config/theme
  file changes, stat-polled every 2 s, and on system appearance flips for light:/dark: themes).
- `hooks/claude-watcher-hook.sh`: the Claude Code hook; bundled into Contents/Resources.
- `Tests/ClaudeWatcherCoreTests/`: Swift Testing (`import Testing`). Keep logic in Core so it is testable.
  Tests run in parallel on the shared cooperative pool and must never block it (`waitUntilExit`,
  `Thread.sleep`, blocking reads/`queue.sync` starve other tests): use `TestSupport.swift`'s
  `runProcess` (async subprocess) and `onDedicatedThread` (blocking work on its own thread), and
  `Task.sleep` for waits.
- `Resources/Info.plist`, `scripts/build-app.sh`, `Makefile`: build tooling. `build-app.sh` also
  takes `HARDENED_RUNTIME=1`, `APP_DIR`, `INFO_PLIST`, `ARCHS` (used by the release script).
- `scripts/release.sh` (`make release`): notarized universal zip -> GitHub release (process in
  README "Releasing"). `Resources/ClaudeWatcher.entitlements`: Apple Events, release builds only.

## Commands
- `make build` (`swift build`), `make test` (`swift test`)
- `make app`: release build, assembles and signs `build/ClaudeWatcher.app`
- `make run`: kills any running instance, builds the app, opens it
- `make clean`
- `make release VERSION=X.Y.Z [DRY_RUN=1 [NOTARIZE=1]]`: bumps Info.plist, commits, tags, notarizes,
  pushes, publishes. `DRY_RUN=1` only builds a Developer ID zip (`NOTARIZE=1` also notarizes);
  needs a clean, pushed main, an Apple account in Xcode and `gh` auth.
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
  (ad-hoc resets TCC Accessibility/Automation grants on every rebuild). Dev builds stay Apple
  Development and non-hardened; releases are Developer ID (Xcode cloud-managed signing via
  `xcodebuild -exportArchive`), hardened runtime + entitlements, notarized and stapled.

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
- Claude home (`ClaudeHome`, `SessionDiscovery.defaultClaudeHome`): `CLAUDE_CONFIG_DIR` from our
  env, else `launchctl getenv`, else `$SHELL -lic` (value read after a marker, since rc files may
  print anything); 2 s timeout per probe, `~` expanded. Falls back to `~/.claude` only if no
  source gives a value or the value is relative; a configured directory that doesn't exist yet is
  honored (watchers cope). The shell probe runs in its own session with no tty and stops reading
  once the shell exits, even if a background job still holds stdout; a complete marker line is
  accepted at timeout. Resolved once and cached (up to ~4 s cold); `prewarmDefaultClaudeHome()`
  starts it off-main. Async code awaits `SessionDiscovery.resolvedClaudeHome()` (suspends on the
  resolver queue) instead of touching `defaultClaudeHome`, which blocks until resolved.
- A registry pid is live only if it runs Claude Code:
  `ProcessRules.isClaudeExecutable` accepts a binary named `claude`, the native installer's
  `…/claude/versions/<ver>`, Homebrew's `Caskroom/claude-code/`, or `node` running the npm
  package (argv read via `KERN_PROCARGS2`, only for `node`): argv[0] `claude` (`process.title`),
  any argument literally naming `@anthropic-ai/claude-code` (`node …/cli.js`), or the script
  (`ProcessRules.nodeScript`: skip leading `-` options; at `--`, the next argument) with basename
  `claude` (npm's `bin/claude` symlink) or, if absolute, a realpath into that package (a relative
  script is never resolved: it's relative to node's cwd). The hook's `is_claude_process` (used by
  `find_claude` and GC) applies the same rule, realpath only for absolute scripts; keep both in sync.
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
  - `.probe-<ttyname>.lock/owner` (`<pid> <token>`): per-tty probe lock, protocol v2, shared by
    the hook and Swift `OSC7ProbeLock` (keep both in sync): mkdir to acquire, ~1 s bounded wait
    then skip. Stale if the owner pid is dead (`kill(pid,0)` fails other than EPERM), or the owner
    is missing/unparseable and the dir mtime > 10 s, or the owner is alive but mtime > 120 s
    (pid-reuse cap). The Swift holder heartbeats (`utimes`) every 2 s; the hook holds it only
    seconds. Break is verified: rename aside, re-read owner, delete only if unchanged, else
    restore without clobbering (`RENAME_EXCL`). Release only if `owner` holds our token.
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
- Pane highlight (`TerminalHighlighter`, Ghostty 1.3.1 verified): `ESC ] 11 ; #rrggbb ESC \`
  written to a session's tty tints only that split pane's default background (cells with an
  explicit background keep theirs, but most of Claude's TUI uses the default); `ESC ] 111 ESC \`
  restores the theme background. ST-terminated. Claude Code never sends OSC 11/111 itself but
  queries OSC 11 to pick its light/dark theme by luminance, so `highlightTint` blends the
  background ~25% toward palette blue (4; another accent if that's too close) and backs the
  strength off until the result stays in the background's luminance class (relative luminance
  and perceived brightness on the same side of 0.5): never a light flash on a dark theme.
  Hover tints until `endHover`/another `beginHover`, capped at 3 s; `pulse` is one tint, then
  ~400 ms later one reset (or the hover tint, if that pane is hovered in another color). Writes
  share the tty with Claude's output, so they're kept minimal: busy sessions (`.busy`, which
  stream output) get no hover tint, and a keep-alive `beginHover` drops the tint when a session
  turns busy (the pulse is still allowed for them); re-hovering the same pane in a new color is a
  single tint write. Only for `.ghostty` sessions whose tty is a
  `/dev/ttysN` that's the pid's controlling tty and not under tmux; writes reuse the OSC 7
  probe's non-blocking `O_NOCTTY` open and bounded `writeAll`. All tty I/O is on a private
  serial queue; hover requests are coalesced (only the latest is applied, old pane reset first).
  A tint is skipped (never waits) while `.probe-<tty>.lock` exists with an mtime under 10 s, so it
  can't race a probe's restore. Stuck-tint recovery: a tty is added to
  `~/Library/Application Support/ClaudeWatcher/tinted-ttys` (atomic write) before a tint and
  removed once its reset fully went out; a failed tint write keeps an already-recorded tty, and a
  failed recolor keeps tracking the pane's old tint, so it's still reset later. `resetAll()`
  (launch, panel hide; `resetAllSync` at terminate) sends OSC 111 only to recorded paths that are
  still a `/dev/ttysN` char device **and** that some live process has as its controlling tty
  (`KERN_PROC_TTY`) with a Ghostty ancestor (`ProcessRules.terminalKind`). Only entries failing
  that (not a tty device, or no Ghostty-hosted process) are dropped silently (tty numbers get
  reused); entries whose processes can't be listed (sysctl failure, `.unknown`) or whose reset
  didn't fully go out stay recorded for the next `resetAll`. The file is rewritten only when its
  contents change (removed when empty).
- Highlight UI (`EdgeController`; the highlighter is nil in demo mode, and demo mode hides the
  highlight toggles): a focus result only ends its own row's hover tint. On show, after a click
  when the panel stays up, and when the hover pref is turned back on, the dwell is re-armed for
  the row hit-tested under the pointer (rows don't re-report a pointer that never left them):
  `SidebarView` reports laid-out row frames (a PreferenceKey) and the list viewport in a named
  pane coordinate space, and the pointer is converted via `targetFrame`. The keep-alive drops
  the tint once the pointer is no longer over that row.
- Ghostty AppleScript `focus <terminal>` switches Spaces to the target window (verified).
- Terminal.app: `activate` first, then `set index of w to 1` and `set frontmost of w to true`.
  Raising before `activate` never switches Spaces.
- Automation denial surfaces as `FocusResult.failed` whose reason contains
  `AppleScriptError.notPermittedMarker`; the panel banner then offers
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`.
- Don't name a Core type `RGBColor`: it clashes with QuickDraw's `RGBColor` in AppKit targets
  (hence `GhosttyColor`).
