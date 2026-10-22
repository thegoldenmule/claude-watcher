# ClaudeWatcher

A small macOS menu-bar app that lists your running [Claude Code](https://claude.com/claude-code)
CLI sessions in an auto-hiding bar on the left edge of the screen, like the Dock. Each row
shows the session title, folder, git branch and status (working / waiting for you / idle).
Sessions waiting for input float to the top. Click a row to jump to its terminal tab, even
when that tab is on another Space.

Supported terminals: **Ghostty** (exact tab) and **Terminal.app** (exact tab). For other
terminals the hosting app is brought to the front.

Requires macOS 26 and Swift 6.2 (Xcode 26 command-line tools).

## Build and run

```sh
make run      # release build, assemble + sign build/ClaudeWatcher.app, launch it
make app      # build the .app only
make test     # unit tests
```

Move the pointer to the left edge of the screen to reveal the bar. The menu-bar icon has:

- **Pin Sidebar**: keep the bar visible.
- **Claude Code Hook**: status, plus Install / Update / Uninstall (see below).
- **Launch at Login**: off by default.
- **Quit**.

`open build/ClaudeWatcher.app --args --demo` shows fake sessions for trying the UI.

The app is signed with your first "Apple Development" identity (or `$CODESIGN_IDENTITY`), so
macOS permission grants survive rebuilds. Without one it is signed ad hoc and the grants
reset on every build.

## Permissions

- **Automation (Apple Events)**: the first time you click a Ghostty or Terminal.app session,
  macOS asks "ClaudeWatcher wants access to control Ghostty / Terminal". Allow it, or the app
  can only bring the terminal app forward. If you denied it, the bar shows an
  **Open Automation Settings…** button (System Settings → Privacy & Security → Automation).
- Nothing else. The bar follows the pointer with ordinary mouse-moved monitoring, which
  needs no Accessibility or Input Monitoring access.

## The Claude Code hook (optional, recommended for Ghostty)

Sessions are discovered without any setup from `~/.claude/sessions/` and the session
transcripts. The hook adds what those lack: a reliable link from a session to its tty and,
in Ghostty, to the exact terminal, recorded once when the session starts.

**Install Hook** in the menu:

- copies `claude-watcher-hook.sh` to `~/Library/Application Support/ClaudeWatcher/`;
- adds `SessionStart`, `UserPromptSubmit`, `Stop`, `Notification` and `SessionEnd` entries to
  `~/.claude/settings.json`. Other settings and hooks are left untouched, and a timestamped
  backup is written next to the file first.

The hook never blocks Claude and prints nothing. It writes small JSON files to
`~/Library/Application Support/ClaudeWatcher/hook-state/`. It only affects sessions started
after it is installed. **Uninstall Hook** removes the entries and the script.

Without the hook, Ghostty tabs are still found on first click, by a quick probe of the
session's tty, and then cached.
