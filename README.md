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

## Releasing

```sh
make release VERSION=1.2.3                       # notarized universal app (zip) -> GitHub release
make release VERSION=1.2.3 DRY_RUN=1             # Developer ID-signed zip in build/dist/ only
make release VERSION=1.2.3 DRY_RUN=1 NOTARIZE=1  # also notarized and stapled; still nothing published
```

Releases are signed and notarized with the Apple account signed into Xcode
(Xcode › Settings › Accounts), the same way as
[claude-tray](https://github.com/thegoldenmule/claude-tray). There are no certificates,
passwords or notary profiles to set up. The account needs the Account Holder or Admin role
on the team, with access to cloud-managed Developer ID certificates.

`make release` (see `scripts/release.sh`) checks that main is clean and in sync with origin.
It sets `CFBundleShortVersionString` to the version and `CFBundleVersion` to the commit
count, then commits and tags `vX.Y.Z` locally. `scripts/build-app.sh` builds a universal
(arm64 + x86_64) app in `.build-release`, signed with the hardened runtime and
`Resources/ClaudeWatcher.entitlements`. That file holds only
`com.apple.security.automation.apple-events`, which the hardened runtime needs before the app
can script Ghostty and Terminal.app. The app stays unsandboxed.

The app is wrapped in an `.xcarchive` and exported with
`xcodebuild -exportArchive -allowProvisioningUpdates` (method `developer-id`). That signs it
with a cloud-managed Developer ID certificate, keeping the entitlements, and uploads it for
notarization. `xcodebuild -exportNotarizedApp` then returns the notarized, stapled app. The
bundled hook script (`Contents/Resources/claude-watcher-hook.sh`) is a sealed resource,
covered by the app's signature.

The script zips the app as `build/dist/ClaudeWatcher-X.Y.Z.zip` and checks that the zip
passes Gatekeeper as a quarantined download. Only then does it push the commit and tag and
create the GitHub release with the zip and its SHA-256. If anything fails before the push,
it removes the local commit and tag. Override the team with `TEAM_ID=...`.

Dev builds (`make app` / `make run`) are unchanged: Apple Development signing, no hardened
runtime and no notarization, so permission grants survive rebuilds.

## License

MIT — see [LICENSE](LICENSE).
