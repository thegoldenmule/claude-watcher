# ClaudeWatcher

A macOS auto-hiding left-edge sidebar that lists your running [Claude Code](https://claude.com/claude-code)
sessions and jumps to their Ghostty / Terminal.app tab, even across Spaces/desktops.

## Features

- Auto-hiding bar on the left screen edge, revealed by moving the pointer there (like the Dock).
- Each row shows the session title, folder, git branch and status (working / waiting for you / idle);
  sessions waiting for input float to the top.
- Click a row to focus its exact Ghostty or Terminal.app tab, switching Spaces if needed.
  Other terminals: the hosting app is brought to the front.
- Menu bar: Pin Sidebar, Claude Code Hook (install / update / uninstall), Launch at Login, Quit.
- Demo mode: `open build/ClaudeWatcher.app --args --demo`.

## Requirements

macOS 26, a Swift 6.2+ toolchain (Xcode 26 command-line tools), and Ghostty 1.3+ or Terminal.app.

## Build and run

```sh
make run    # build, sign and launch build/ClaudeWatcher.app
make test   # unit tests
```

Signing uses `$CODESIGN_IDENTITY`, else your first "Apple Development" identity, else ad hoc
(ad hoc resets permission grants on every rebuild).

## Permissions

Only **Automation** for Ghostty / Terminal.app, asked on first click. No Accessibility or
Input Monitoring access is needed.

## Optional Claude Code hook

**Install Hook** in the menu bar adds a hook to `~/.claude/settings.json` (with a backup) that
records each session's terminal id and tty to `~/Library/Application Support/ClaudeWatcher/hook-state/`.
It never blocks Claude and only affects sessions started after install. Without it, Ghostty
tabs are still found on first click by a quick probe.

## How it works

Sessions come from `~/.claude/sessions/` and their transcripts; Ghostty tabs are matched by an
OSC 7 probe (a nonce cwd written to the session's tty) via Ghostty's AppleScript.

## License

MIT — see [LICENSE](LICENSE).
