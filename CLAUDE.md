# ClaudeWatcher

Auto-hiding left-edge bar (like the Dock) listing running Claude Code CLI sessions
(title, git branch, status). Clicking a session focuses its terminal (Ghostty or
Terminal.app), even across Spaces. Menu-bar-only accessory app (LSUIElement),
unsandboxed, personal use. macOS 26, Swift 6 language mode, SwiftPM (no Xcode project).

## Layout / ownership
- `Sources/ClaudeWatcherCore/Model/`: shared types (`ClaudeSession`, `SessionStatus`,
  `TerminalKind`, `FocusResult`). Change only with coordination; everyone depends on them.
- `Sources/ClaudeWatcherCore/Sessions/`: discovery agent (`SessionStore`).
- `Sources/ClaudeWatcherCore/Focus/`: focus agent (`SessionFocuser` + implementations).
- `Sources/ClaudeWatcherCore/Hook/` and `hooks/`: hook agent (`HookSupport`, hook scripts).
- `Sources/ClaudeWatcher/App/`: app entry (`ClaudeWatcherApp`, `AppDelegate`); integration wiring.
- `Sources/ClaudeWatcher/UI/`: UI agent (`SidebarView`, edge window).
- `Tests/ClaudeWatcherCoreTests/`: Swift Testing (`import Testing`). Keep logic in Core so it is testable.
- `Resources/Info.plist`, `scripts/build-app.sh`, `Makefile`: build tooling.

## Commands
- `make build` (`swift build`), `make test` (`swift test`)
- `make app`: release build, assembles and signs `build/ClaudeWatcher.app`
- `make run`: kills any running instance, builds the app, opens it
- `make clean`
- Signing: `$CODESIGN_IDENTITY`, else first "Apple Development" identity, else ad-hoc
  (ad-hoc resets TCC Accessibility/Automation grants on every rebuild). No hardened runtime.

## Parallel agents
- Use a private scratch dir to avoid SwiftPM lock contention:
  `swift build --scratch-path .build-<agentname>` (same for `swift test`).
  `scripts/build-app.sh` honours `SCRATCH_PATH=.build-<agentname>`.
- Commit with one-line messages only (no body/trailers), staging only paths you own
  (`git add <your paths>`, never `git add -A`). Don't push.

## Platform facts
- `~/.claude/sessions/<pid>.json` is Claude Code's live session registry (one file per CLI process).
- Ghostty 1.3.1 AppleScript `focus <terminal>` switches Spaces to the target window (verified).
