# ClaudeWatcher

Auto-hiding left-edge bar (like the Dock) listing running Claude Code CLI sessions
(title, git branch, status). Clicking a session focuses its terminal (Ghostty or
Terminal.app), even across Spaces. Menu-bar-only accessory app (LSUIElement),
unsandboxed, personal use. macOS 26, Swift 6 language mode, SwiftPM (no Xcode project).

## Layout
- `Sources/ClaudeWatcherCore/Model/`: shared types (`ClaudeSession`, `SessionStatus`,
  `TerminalKind`, `FocusResult`).
- `Sources/ClaudeWatcherCore/Sessions/`: `SessionStore` (`@MainActor @Observable`) over
  `SessionDiscovery` (actor): registry + transcripts + liveness, joined with hook state.
- `Sources/ClaudeWatcherCore/Hook/`: `HookState`/`HookStateStore`/`HookStateCache` (reads the
  hook's output), `HookInstaller` (edits `~/.claude/settings.json`, order-preserving).
- `Sources/ClaudeWatcherCore/Focus/`: `RoutingFocuser` -> `GhosttyFocuser` (resolver chain) /
  `AppleTerminalFocuser` / activate-hosting-app fallback. `AppleScriptRunner` runs scripts.
- `Sources/ClaudeWatcherCore/Edge/`: `EdgeRevealPolicy`, pure auto-hide logic.
- `Sources/ClaudeWatcher/App/`: `AppDelegate` (owns the store, the single `RoutingFocuser`,
  `EdgeController`, `MenuModel`), `ClaudeWatcherApp` (menu bar extra), `DemoMode`.
- `Sources/ClaudeWatcher/UI/`: `EdgeController` (panel show/hide, focus + result banner),
  `SidebarView`, `SidebarPanel`.
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
  show the info banner.
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
- The hook writes `~/Library/Application Support/ClaudeWatcher/hook-state/<session_id>.json`
  atomically (temp + rename). Discovery joins it by session id, else newest-by-pid; the pid,
  tty and "written after process start" must all agree. `ghostty_terminal_id` is only filled
  for sessions that started (SessionStart) after the hook was installed.
- `NSAppleScript` must run on the main thread: off-main, Ghostty's replies to element
  queries (`every terminal`) never arrive and the script hangs past its `with timeout`.
  `AppleScriptRunner` hops to the MainActor; every generated script carries
  `with timeout of 3 seconds`. The first run per target app blocks on the TCC Automation prompt.
- Ghostty 1.3.1 has no `tty` terminal property. The OSC 7 probe identifies a terminal by
  writing an OSC 7 with a nonce cwd to the session's tty and asking Ghostty which terminal's
  `working directory` matches, then restoring the real cwd. The hook runs it once at
  SessionStart; `GhosttyFocuser` runs it on demand (cached per pid) when no hook id exists.
- Ghostty AppleScript `focus <terminal>` switches Spaces to the target window (verified).
- Terminal.app: `activate` first, then `set index of w to 1` and `set frontmost of w to true`.
  Raising before `activate` never switches Spaces.
- Automation denial surfaces as `FocusResult.failed` whose reason contains
  `AppleScriptError.notPermittedMarker`; the panel banner then offers
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`.
