# ClaudeWatcher

Auto-hiding left-edge bar (like the Dock) listing running Claude Code CLI sessions
(title, git branch, status), styled as a Ghostty pane themed from the user's Ghostty config.
Clicking a session focuses its terminal (Ghostty or Terminal.app), even across Spaces.
Menu-bar-only accessory app (LSUIElement), unsandboxed. MIT licensed.
macOS 26, Swift 6 language mode, SwiftPM (no Xcode project).

## Layout
- `Sources/ClaudeWatcherCore/Model/`: shared types (`ClaudeSession`, `SessionStatus`,
  `TerminalKind`, `FocusResult`, `SubagentInfo`; `SubagentTree` draws the tree prefixes,
  `ElapsedFormat` the short elapsed labels).
- `Sources/ClaudeWatcherCore/Sessions/`: `SessionStore` (`@MainActor @Observable`) over
  `SessionDiscovery` (actor): registry + transcripts + liveness, joined with hook state.
  `SubagentTracker` (owned by discovery, like `TranscriptReader`): a session's running
  subagents (see "Subagents" below).
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
- `Sources/ClaudeWatcherCore/Edge/`: `EdgeRevealPolicy`, pure auto-hide logic; `suspendedUntil`
  pauses the reveal (a hidden panel never shows; a visible one still hides; `reset()` keeps it).
  Menu "Pause Edge Reveal" (`EdgeController.pauseReveal(until:)`/`resumeReveal()`, not in demo):
  persisted (UserDefaults `edgeRevealPausedUntil`, re-armed at launch; demo ignores it), menu-bar
  icon `moon.zzz` while paused. The expiry task only clears it, never ticks, so the panel can't
  pop up without pointer movement. `PanelWidth`: clamps the
  user's panel width (UserDefaults `sidebarPanelWidth`, both modes) to 200 pt...half the visible
  screen; `EdgeController.frame(on:)` applies it without writing the clamp back.
- `Sources/ClaudeWatcherCore/Update/`: `SemanticVersion` (semver precedence, `v` prefix),
  `AppVersionInfo` (Info.plist version + build), `ReleaseInfo` (decodes GitHub's
  `releases/latest`; drafts/pre-releases rejected), `UpdateChecker` (unauthenticated GET, no
  `gh`/token, injectable `Fetch`; `If-None-Match` from the cached ETag only with a cached
  release; ephemeral session, no URLCache, so a 304 reaches us; 429, or 403 with
  `x-ratelimit-remaining: 0`, is a rate limit with a retry time), `UpdateSchedule` (launch: unless
  checked < 1 h ago; then 12 h after a success, 30 min after a failure or the rate-limit reset),
  `UpdateMenuState` (derived at display time from running version + cached release: a newer
  release wins over a later failure; a build >= latest is up to date; no version = no claim).
  Outgoing HTTPS needs no entitlement: the app is unsandboxed (`network.client` is a sandbox
  entitlement) and the hardened runtime doesn't gate network access.
- `Sources/ClaudeWatcher/App/`: `AppDelegate` (owns the store, the single `RoutingFocuser`,
  `EdgeController`, `MenuModel`, `UpdateModel`), `ClaudeWatcherApp` (menu bar extra), `DemoMode`.
  `UpdateModel`: version line + update status + "Check for Updates" at the bottom of the menu;
  first check 10 s after launch, a 15 min wall-clock tick and every menu open check when due;
  the answer is cached in UserDefaults `updateCheckCache` (JSON `UpdateCache`). Links to the
  release page only, never downloads. Demo mode never hits the network or the cache. Nothing may
  resolve `SessionDiscovery.defaultClaudeHome` on main at launch: `AppDelegate.init` prewarms it,
  the store is created once it resolves off-main, and `MenuModel` computes statuses off-main.
- `Sources/ClaudeWatcher/UI/`: `EdgeController` (panel show/hide, focus + result banner, owns
  `ThemeStore`), `SidebarView` (its `TimelineView`s pause while the panel is hidden, via
  `\.panelVisible`: they keep firing after `orderOut`; a session with running subagents gets a
  `▸ N agents running` line that toggles a `SubagentTree` under it: sibling buttons in one
  `SessionRow` block, never nested, so hover/selection/tint and the row frame cover the whole
  block and only the toggle doesn't focus; trees start expanded, the toggle collapses one into
  `EdgeController.collapsedSessionIDs`, not the lazily recycled row, unpersisted and kept while
  the session has no agents; the header
  adds `⑂ N agents`), `SidebarPanel`, `TerminalStyle` (SwiftUI
  colors/font/metrics from a `GhosttyTheme`, injected via `\.terminalStyle`), `ThemeStore` (reloads when a watched config/theme
  file changes, stat-polled every 2 s, and on system appearance flips for light:/dark: themes).
  `PanelResizeHandle`: 8 pt AppKit strip on the pane's right edge, pinned or auto-shown (not in
  demo): drag resizes, double-click (or the menu's "Reset Sidebar Width") goes back to the theme
  width. It reports hover/drag to `EdgeController`'s `ResizeEdge`, which draws a 2 pt line inside
  the border; `tick()` ignores the drag (`isResizing`) and runs once it ends. The header's
  `[pin]`/`[pinned]` toggles `isPinned` (persisted as `sidebarPinned`, not in demo); pinning an
  auto-shown panel keeps it on its screen.
- `hooks/claude-watcher-hook.sh`: the Claude Code hook; bundled into Contents/Resources.
- `Tests/ClaudeWatcherCoreTests/`: Swift Testing (`import Testing`). Keep logic in Core so it is testable.
  Tests run in parallel on the shared cooperative pool and must never block it (`waitUntilExit`,
  `Thread.sleep`, blocking reads/`queue.sync` starve other tests): use `TestSupport.swift`'s
  `runProcess` (async subprocess) and `onDedicatedThread` (blocking work on its own thread), and
  `Task.sleep` for waits.
- `Resources/AppIcon.icns` (+ `docs/icon.png` for the README): the app icon, generated by
  `scripts/make-icon.swift` via `make icon` and committed; `build-app.sh` bundles it.
- `Resources/Info.plist`, `scripts/build-app.sh`, `Makefile`: build tooling. `build-app.sh` also
  takes `HARDENED_RUNTIME=1`, `APP_DIR`, `INFO_PLIST`, `ARCHS` (used by the release script).
- `scripts/release.sh` (`make release`): notarized universal DMG + zip -> GitHub release (see
  "Releasing" below). `Resources/ClaudeWatcher.entitlements`: Apple Events, release builds only.
- `scripts/build-dmg.sh` (`make dmg`, and `release.sh`): drag-to-Applications DMG via dmgbuild
  (hash-pinned in `scripts/dmg-requirements.txt`, venv in `$DMG_VENV`, default
  `.build/dmgbuild-venv`; needs Python 3.10+). Layout in `scripts/dmg-settings.py`, background
  rendered by `scripts/dmg-background.swift` (660x400 pt, 1x/2x; keep both geometries in sync),
  volume icon `Resources/AppIcon.icns`. Don't use dmgbuild's `hide_extensions`: it breaks
  `codesign --strict` on the app ("detritus").

## Commands
- `make build` (`swift build`), `make test` (`swift test`)
- `make app`: release build, assembles and signs `build/ClaudeWatcher.app`
- `make run`: kills any running instance, builds the app, opens it
- `make clean`
- `make icon`: regenerates `Resources/AppIcon.icns` and `docs/icon.png`.
- `make dmg`: `make app`, then `build/ClaudeWatcher.dmg` from the dev app, to preview the DMG
  window (`open` it; eject with `hdiutil detach /Volumes/ClaudeWatcher`). Not for distribution.
- `make release VERSION=X.Y.Z [DRY_RUN=1 [NOTARIZE=1]]`: see "Releasing" below.
- Demo data, panel pinned: `open build/ClaudeWatcher.app --args --demo` (or `CW_DEMO=1`;
  `CW_APPEARANCE=dark|light`). Demo Terminal rows fail with the permission banner, "other" rows
  show the info banner. Screenshot helpers (demo only): `CW_DEMO_NOTICE=error|info`,
  `CW_DEMO_HOVER=<id>`, `CW_DEMO_PENDING=<id>`, `CW_DEMO_COLLAPSED=<id>[,<id>…]` (collapse those
  rows' agent trees; demo-1 has a nested one, demo-3 one agent), `CW_DEMO_EMPTY=1`,
  `CW_DEMO_UPDATE=X.Y.Z|fail|checking` (menu update line; default "Up to Date").
- Theme overrides: `CW_GHOSTTY_CONFIG=<path>` (read only that config),
  `CW_GHOSTTY_THEME=<name or light:A,dark:B>` (preview a theme, ignoring config colors).
- Live discovery dump: `CW_LIVE=1 swift test --filter liveDiscovery`. Live update check against
  GitHub (repo's Info.plist version vs `releases/latest`, plus an ETag revalidation):
  `CW_LIVE=1 swift test --filter liveUpdateCheck`.
- Logs: `/usr/bin/log stream --predicate 'subsystem == "com.thegoldenmule.ClaudeWatcher"'`
  (in zsh, bare `log` is a builtin). Focus lines show the resolver and the hook id.
- Signing (dev): `$CODESIGN_IDENTITY`, else first "Apple Development" identity, else ad-hoc
  (ad-hoc resets TCC Accessibility/Automation grants on every rebuild).

## Releasing
Only when the user asks. It publishes a public GitHub release and can't really be undone (the
tag and build number stay). Pick `X.Y.Z` by semver; ask the user if the bump is unclear. Real
releases take plain `MAJOR.MINOR.PATCH` (dry runs also accept `X.Y.Z-suffix`).
- Dev vs release signing: dev builds (`make app`/`make run`) are Apple Development, not hardened,
  not notarized, so TCC grants survive rebuilds. Releases are Developer ID via Xcode cloud-managed
  signing (team `QKMK66X2FU`, no local Developer ID cert), hardened runtime + entitlements,
  notarized and stapled.
- Preconditions (preflight fails a real release on each; a dry run only warns, except Xcode):
  clean tree; on main; main pushed and equal to origin/main (it fetches); tag `vX.Y.Z` unused
  locally and on origin; an Apple account in Xcode > Settings > Accounts (Account Holder/Admin);
  `gh` authenticated; a Python 3.10+ (`$PYTHON`, `python3`, Homebrew's; checked even in dry runs)
  for dmgbuild, whose venv is `.build-release/dmgbuild-venv`. macOS's `/usr/bin/python3` (3.9)
  only gets dmgbuild 1.6.5, whose `pBBk` bookmark makes Finder on macOS 26 drop the background;
  `build-dmg.sh` rejects < 3.10 and checks the built `.DS_Store`. Run `make test` first (the
  script doesn't).
- Dry runs commit, tag, push and publish nothing (Info.plist is stamped on a copy):
  `DRY_RUN=1` builds a Developer ID-signed, un-notarized DMG + zip (Gatekeeper rejection expected);
  `DRY_RUN=1 NOTARIZE=1` also notarizes, staples and verifies like a real release.
- Steps, as bare commands: `git push origin main`, then `make release VERSION=X.Y.Z`. A local,
  git-excluded `.claude/settings.local.json` allows `git push` and `make`; piped forms
  (`make release ... | tail`) don't match the allow rule and are denied.
- What it does: sets `CFBundleShortVersionString` and `CFBundleVersion` (`git rev-list --count
  HEAD` + 1, bumped past the current value; v0.1.0 was 75), commits "Release vX.Y.Z" (Info.plist
  only) and an annotated tag, locally. `build-app.sh` builds universal arm64 + x86_64 in
  `.build-release` (`HARDENED_RUNTIME=1`, the entitlements file holds only
  `com.apple.security.automation.apple-events`), wrapped in an `.xcarchive`;
  `xcodebuild -exportArchive -allowProvisioningUpdates` (developer-id) signs and uploads it, and
  `-exportNotarizedApp` is polled for up to `NOTARY_TIMEOUT` s (default 1800; pass
  `NOTARY_TIMEOUT=3600` on the make line). It checks team, runtime flag and entitlements, builds
  the DMG (`build-dmg.sh`) and the zip from the stapled app, and verifies both as quarantined
  downloads: the DMG must be unsigned and hold the app, the `Applications` symlink and its
  layout; the app in the mounted DMG (detached again in `on_exit` on failure) and in the
  extracted zip each pass `codesign --strict`, `spctl`, `stapler`, `syspolicy_check
  distribution`. It writes one SHA-256 file for both, runs `git push --atomic origin main
  vX.Y.Z`, then `gh release create ... --repo thegoldenmule/claude-watcher --verify-tag
  --generate-notes --notes-file ...` (install notes: open the DMG, drag to Applications).
  Assets `ClaudeWatcher-X.Y.Z.dmg`, `.zip` and `.sha256`, in `build/dist/`.
- Never sign the DMG. The cloud-managed Developer ID can only sign through xcodebuild's export
  (apps, not disk images), it can't be notarized either, and a DMG signed with any other
  identity (e.g. Apple Development) is refused by Gatekeeper on open. Unsigned DMGs mount
  without a prompt; Gatekeeper checks the notarized, stapled app inside. Verification fails if
  the DMG has a signature.
- Failure before the push (incl. notarization timeout): deletes the tag and drops the release
  commit (`git reset --keep`, only if both still point at it), or restores Info.plist; fix and
  re-run. A failed push asks `git ls-remote origin refs/tags/vX.Y.Z`: our tag there = pushed;
  empty = rolled back; unreachable or a different tag = local commit/tag left with undo steps
  printed. Failure after the push (e.g. `gh`): nothing is undone and it prints the
  `gh release create` to finish by hand; don't re-run `make release`. Once the release exists
  (`RELEASED`), a later failure or interrupt only reports the URL.
- Verify: `gh release view vX.Y.Z` lists the dmg, zip and sha256; download all three into an
  empty dir, `shasum -a 256 -c ClaudeWatcher-X.Y.Z.sha256`; quarantine the DMG, `hdiutil
  attach -nobrowse -readonly`, then `spctl -a -vvv -t exec` and `xcrun stapler validate` on the
  app inside, detach; same for the unzipped app; `git rev-parse main origin/main` match.
  (v0.1.0 shipped only a zip and `.zip.sha256`.)
- Afterwards: `make run` to rebuild the local dev app (Apple Development, not hardened, so TCC
  grants persist), and check `build/ClaudeWatcher.app/Contents/Resources/claude-watcher-hook.sh`
  matches `~/Library/Application Support/ClaudeWatcher/claude-watcher-hook.sh` (`cmp`); if not,
  the menu shows "Claude Code Hook: Needs Update"; use its "Update Hook".

## Conventions
- Commit with one-line messages only (no body/trailers). Don't push (except to release, above).
- If several agents work at once: give each its own SwiftPM scratch dir
  (`swift build --scratch-path .build-<name>`; `scripts/build-app.sh` honours `SCRATCH_PATH`)
  and stage only your own paths (never `git add -A`).

## Platform facts / gotchas
- `~/.claude/sessions/<pid>.json` is Claude Code's live session registry (one file per CLI
  process). It is rewritten **in place** on every status change (same inode for the whole
  session, directory mtime unchanged), so a directory vnode source never sees status flips:
  `SessionStore` keeps one vnode source per live registry file, plus directory sources and a
  2 s poll as safety net. Registry `status` "shell" (idle at the prompt) maps to `.idle`.
- Subagents (`SubagentTracker`, Claude Code 2.1.280): next to the transcript `<sid>.jsonl`, in
  `<sid>/subagents/`, `agent-<agentId>.jsonl` + `agent-<agentId>.meta.json`, all nesting levels
  flat; other files (`*.forked-skill*.json`) are ignored. The agentId isn't always hex. Meta:
  `agentType`, `description`/`name` (label = description ?? name ?? agentType), `requestShape`
  (background/foreground), `parentAgentId` + `spawnDepth` for nested agents; it is rewritten
  later (`stoppedByUser: true`), so it's cached on its stat. Agent records: `timestamp`, one
  assistant record per content block, `message.stop_reason` null/tool_use/pause_turn while
  running, end_turn/stop_sequence/max_tokens at the end. Finished notifications (agentId =
  `<task-id>`, `<status>` required, `enqueue` only, dequeue/remove ignored): the parent
  transcript's `queue-operation` lines, and for nested agents a `queued_command` attachment in
  the parent agent's jsonl. Parked: a "completed" notification whose `<note>` says the agent
  "stopped with background work of its own still running" (e.g. its own `run_in_background`
  CI wait). It's still alive, Claude Code shows it as running, and it resumes and notifies
  again when that work reports; the registry meanwhile goes idle, so discovery reports an idle
  session with running agents as `.busy` (`SessionDiscovery.status`). A parked agent is running
  ("waiting on <its last background launch>") until a later notification, or a 24 h backstop
  while the session isn't busy; the end-of-turn and 10 min stale rules don't apply to it. An
  agent is finished if: stopped by the user; notified (not parked) at or after its last record
  (a SendMessage resume appends records, and a later notification); its last
  assistant record ended the turn with no user record after it, or its last record is
  "[Request interrupted by user…]" (a failed agent writes it ~ms after its notification); a
  foreground root agent while the session is `.idle` (not `.waiting`: that may be its
  permission prompt); a nested foreground agent whose parent agent isn't running; stale (no
  record for 10 min while the session isn't busy). Agent files last written before the
  session's process started (or over 24 h ago while it isn't busy) are never opened
  (long-lived sessions keep hundreds). Reads are incremental (stat-keyed, 64 KB tails); the
  parent transcript (can be 15 MB+) is indexed once, lazily, then only appended lines; it is
  always consulted for agents still in play, since a parked notice overrides their end_turn. Poll-only (no watchers): running agents append many times
  a second, and the 2 s poll lag is fine.
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
  `…/claude/versions/<ver>`, Homebrew's `Caskroom/claude-code/`, any path inside the npm package
  (newer npm installs exec a native `…/@anthropic-ai/claude-code/bin/claude.exe`), or `node` running the npm
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
- Cursor from the background: the app is never active (accessory app, non-activating panel), so
  the window server ignores its `NSCursor.set()` unless the private CGS connection property
  `SetsCursorInBackground` is on. `BackgroundCursor.enable()` (`PanelResizeHandle.swift`, from
  `EdgeController.start()`, not in demo) sets it once via `dlsym` (default handle; Swift can't
  import `RTLD_DEFAULT`) of `CGSMainConnectionID` + `CGSSetConnectionProperty`, skipping if
  missing. A set cursor then persists, so the arrow is restored whenever the strip leaves the
  pointer without a `mouseExited` (`hide()`, `\.panelVisible` false, view removed).
- Don't name a Core type `RGBColor`: it clashes with QuickDraw's `RGBColor` in AppKit targets
  (hence `GhosttyColor`).
