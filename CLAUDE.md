# ClaudeWatcher

Auto-hiding left-edge bar (like the Dock) listing running Claude Code and Codex CLI sessions
(title, git branch, status), styled as a Ghostty pane themed from the user's Ghostty config.
Clicking a session focuses its terminal (Ghostty or Terminal.app), even across Spaces.
Menu-bar-only accessory app (LSUIElement), unsandboxed. MIT licensed.
macOS 26, Swift 6 language mode, SwiftPM (no Xcode project).

## Layout
- `Sources/ClaudeWatcherCore/Model/`: shared types (`ClaudeSession`, `SessionStatus`,
  `TerminalKind`, `FocusResult`, `SubagentInfo`; `SubagentTree` draws the tree prefixes,
  `ElapsedFormat` the short elapsed labels). `BackgroundShellInfo`: a running background shell
  (`ClaudeSession.backgroundShells`). `ClaudeSession.agent` (`AgentKind` `.claude`/`.codex`)
  and `contextWindow` (nil = Claude's assumed 1M; `effectiveContextWindow`).
- `Sources/ClaudeWatcherCore/Sessions/`: `SessionStore` (`@MainActor @Observable`) over
  `SessionDiscovery` (actor): registry + transcripts + liveness, joined with hook state.
  `SubagentTracker` (owned by discovery, like `TranscriptReader`): a session's running
  subagents (see "Subagents" below) and background shells (`backgroundShells`, see "Background
  shells" below), both from one incremental `TranscriptTaskIndex` of the session transcript. `CodexDiscovery` (actor, optional second source of the
  store, scanned concurrently, merged by `SessionDiscovery.finalize`) with `CodexStateDB`,
  `CodexRolloutReader`/`CodexRolloutParser` and `CodexMatcher` (see "Codex" below).
  `ProcessInspecting` also has `allPIDs()`, `currentDirectory(pid:)`, `processName(pid:)`
  (defaulted, so fakes needn't implement them). `CodexPaths` (`ClaudeHome.swift`) resolves
  `$CODEX_HOME` like the Claude home (shared probes, own queue; `AppDelegate` prewarms it).
- `Sources/ClaudeWatcherCore/Hook/`: `HookState`/`HookStateStore`/`HookStateCache` (reads the
  hook's output, `<sid>.json` + `<sid>.ghostty` sidecar), `HookInstaller` (edits
  `settings.json` under the resolved Claude home, order-preserving, updates our entries in place,
  retries on a concurrent-write conflict; uninstall leaves a no-op stub script; status counts only
  handlers in match-all groups, `.outdated` if one of ours sits under a restricting matcher).
- `Sources/ClaudeWatcherCore/Focus/`: `RoutingFocuser` -> `GhosttyFocuser` (resolver chain) /
  `AppleTerminalFocuser` / activate-hosting-app fallback. `AppleScriptRunner` runs scripts.
  `OSC7Probe` (`GhosttyOSC7Probe.swift`) + `OSC7ProbeLock` (cross-process lock shared with the hook).
  `GhosttyTitleReader` (`GhosttyTitles.swift`): every Ghostty terminal's title by tty (Ghostty
  1.4+), only if `AutomationPermission` (`AEDeterminePermissionToAutomateTarget`, never prompts,
  cached 30 s) says Automation was already granted: background reads must not raise the prompt.
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
  Menu "Pause Edge Reveal" (`EdgeController.pauseReveal(until:)`/`resumeReveal()`, not in demo;
  one submenu either way: while paused it's titled "Edge Reveal Paused Until …" with Resume Now):
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
- `Sources/ClaudeWatcherCore/Usage/`: plan usage (session ~5 h + weekly limits) for the sidebar header.
  `UsageTypes` (shared contract: `UsageWindow` (`displayPercent(at:)` 0 once reset),
  `UsageSnapshot` session/weekly + `asOf`, `UsageLevel` 80/95, `UsageStatus`
  unavailable|loading|ok|stale|error, `UsageSource` protocol: `poll(now:)` -> usage + `nextPollIn`,
  each source keeps its own backoff), the sources `ClaudeUsageSource` and `CodexUsageSource` (see
  "Claude usage" and Codex "Usage" below; their inits do no I/O), `UsageStore` (`@MainActor
  @Observable`): one loop per source (poll, publish, sleep `nextPollIn`, floored at 5 s),
  wall-clock deadlines; never two polls of a source at once (a restarted loop awaits the old one;
  a superseded loop's result is dropped; the poll runs unstructured so stop/suspend don't cancel
  it under the source); `suspend()`/`resume()` (each source polls at its deadline but no sooner
  than 5 s after resume; that wake hold binds `pollOverdue()` too until it passes, cleared by
  start/stop), `pollOverdue()` (deadline, or the wake hold if later, > 2 s past: poll now; while
  suspended, it only ends a will-sleep that never got its did-wake: after > 5 min of awake time
  (`systemUptime`, stopped during sleep) and only at full wake (`isFullWake`; app: main display
  awake, since dark wakes/Power Nap add up to more than 5 min over a night); a hold a backward clock step left
  more than the wake delay ahead is clamped to now + delay, never dropped); a loop sleeps at most
  1 h before polling (a backward wall-clock jump can't stall it). `UsageDisplay` (pure):
  `lines(_:agents:now:)` -> one `UsageLine` per agent: its windows (`UsageWindowDisplay`:
  session first, rounded percent, level, short reset) iff a snapshot has a window and the status
  is ok/stale (or loading with a snapshot); else a message-only line for error/stale;
  `.unavailable` and snapshot-less `.loading` show nothing. `constraining` = the window with the
  higher display percent (session wins ties). Short reset (`shortResetText`): `2h10m`/`2h`/`45m`
  under a day (minutes rounded up, never `0m`; also later the same day on a 25 h DST day), else
  weekday `Thu` 1-6 calendar days away (start of day to start of day), else `Nov 30`; nil once
  passed (the window then reads 0%). Tooltip `help`: `Claude Code: 5h 42% (resets in 2h 10m) ·
  wk 67% (resets Thu 9:00 AM)`, stale adds `<message> (as of 3:05 PM)`; one spoken
  `accessibilityText` per line. Percents display via `wholePercent` (rounded, clamped 0...9999,
  NaN 0: a malformed value can't trap); the bar fill (`fillFraction`) and level follow that
  rounded value, so "0%" draws no fill.
- `Sources/ClaudeWatcher/App/`: `AppDelegate` (owns the store, the single `RoutingFocuser`,
  `EdgeController`, `MenuModel`, `UpdateModel`, `UsageModel`), `ClaudeWatcherApp` (menu bar
  extra), `DemoMode`.
  Menu layout (`ClaudeWatcherApp`): top level is Pin Sidebar, Pause Edge Reveal, Settings, Quit,
  plus attention items only when needed (Install/Update Claude Code Hook, Approve Launch at Login,
  `lastError`, Update Available); everything else is in the Settings submenu. The status item
  is the plain `sidebar.left` symbol (`moon.zzz` while paused); usage is in the sidebar header.
  `UsageModel`: owns the `UsageStore` (`ClaudeUsageSource` + `CodexUsageSource`; demo: canned
  sources), a minute clock (`now`, truncated to the minute and set only when it changes, so the
  panel isn't re-rendered per tick; also on wake and whenever the panel shows (`EdgeController`'s
  `onShow`); each `tick()` also `pollOverdue()`; no TimelineView, so nothing to pause while the
  panel is hidden), `lines` (the header's `UsageLine`s, read by `EdgeController`'s `usage`
  closure inside `body`, so usage and clock changes re-render the pane) and NSWorkspace
  sleep/wake (`suspend`/`resume`). No App Nap activity: it would un-nap the whole app (session
  poll, panel timers); deadlines are wall-clock and the minute tick/panel show catch up.
  `UpdateModel`: version line + update status + "Check for Updates" at the end of Settings;
  first check 10 s after launch, a 15 min wall-clock tick and every menu open check when due;
  the answer is cached in UserDefaults `updateCheckCache` (JSON `UpdateCache`). Links to the
  release page only, never downloads. Demo mode never hits the network or the cache. Nothing may
  resolve `SessionDiscovery.defaultClaudeHome` on main at launch: `AppDelegate.init` prewarms it,
  the store is created once it resolves off-main, and `MenuModel` computes statuses off-main.
- `Sources/ClaudeWatcher/UI/`: `EdgeController` (panel show/hide, focus + result banner, owns
  `ThemeStore`), `SidebarView` (its `TimelineView`s pause while the panel is hidden, via
  `\.panelVisible`: they keep firing after `orderOut`; `.waiting` (yellow) and `.idle` rows
  (shown as "stopped", palette magenta via `TerminalStyle.idle`, `■` glyph; not blue, which is
  busy, nor the context meter's green/yellow/red) get a wash (stopped slightly stronger:
  magentas are darker), a 3 pt left bar and an inverse-video ` waiting `/` stopped ` tag line;
  their glyphs keep their color under the selection; only waiting rows sort first (status
  flips must not reorder rows); the header counts `● N waiting  ■ N stopped` first, bold in those
  colors, then (with or without sessions) one plan usage line per visible agent (`UsageLines`):
  `claude  5h ━━━░ 42% 2h10m  wk ━━━━░ 67% Thu`, agent label in a fixed column (longest label
  + 2), per window the kind, a `MeterBar` (the bar `ContextMeter` also draws; fill green, yellow
  from 80%, red from 95%), the percent (warning/critical in that color) and reset, both in
  reserves as wide as the widest value on any line, so lines with as many windows align;
  `ViewThatFits` drops the other window's reset (keeping the `constraining` one's, its reserve
  sized from constraining resets only, and only while every two-window line is limited by the
  same window kind, so bars still align: tooltips likely never show in the non-activating
  panel), then all resets, then all but the
  `constraining` window (with, then without its reset), then the bar (`claude  67%`), never
  wrapping a window; stale lines are faint and uncoloured with a `stale` marker (all steps tried
  with it before any without it); a message-only line is a faint `claude
  usage: <message>`; `.help` has the long form, one accessibility element per line; a session with running subagents or background shells gets a
  `▸ N agents · N shells running` line (either count alone when the other is 0) that toggles a
  tree under it (agents in pre-order, then the background shells as `shell · <description>`
  roots with a `$ <command>` line; prefixes from `SubagentTree.prefixes(depths:)`): sibling buttons in one
  `SessionRow` block, never nested, so hover/selection/tint and the row frame cover the whole
  block and only the toggle doesn't focus; trees start expanded, the toggle collapses one into
  `EdgeController.collapsedSessionIDs`, not the lazily recycled row, unpersisted and kept while
  the session has no agents or shells; the header
  adds `⑂ N agents` and `$ N shells`; a session with `contextTokens` ends in a `ContextMeter` line: a drawn bar,
  not `█░` glyphs (seams, font fallback), green/yellow/red per `ContextUsage.level`, its fill
  keeping that color under the selection, and `245k / 1M · 25%` (Codex: `/ 475k`, the session's
  window) right-aligned in a fixed 18-cell reserve so every row's bar is as long; narrow panes
  fall back to `25%`, then the bar alone; a Codex row's location line ends in ` [codex]`, an
  ambiguous Codex row (`.unknown`) says "thread unknown", and the header reads `❯ agent
  sessions` once a non-Claude session is listed), `SidebarPanel`, `TerminalStyle` (SwiftUI
  colors/font/metrics from a `GhosttyTheme`, injected via `\.terminalStyle`), `ThemeStore` (reloads when a watched config/theme
  file changes, stat-polled every 2 s, and on system appearance flips for light:/dark: themes).
  `PanelResizeHandle`: 8 pt AppKit strip on the pane's right edge, pinned or auto-shown (not in
  demo): drag resizes, double-click (or Settings › "Reset Sidebar Width") goes back to the theme
  width. It reports hover/drag to `EdgeController`'s `ResizeEdge`, which draws a 2 pt line inside
  the border; `tick()` ignores the drag (`isResizing`) and runs once it ends. The header's
  `[pin]`/`[pinned]` toggles `isPinned` (persisted as `sidebarPinned`, not in demo); pinning an
  auto-shown panel keeps it on its screen.
- `hooks/claude-watcher-hook.sh`: the Claude Code hook; bundled into Contents/Resources.
- `hooks/codex-watcher-hook.sh`: the Codex hook (bundled too; see "Codex hook" below).
  `CodexHookInstaller` registers it in `$CODEX_HOME/hooks.json` via `HookInstaller` with
  `Profile.codex` (`Profile.claude` is every existing call's default); `CodexHookState(Cache)`
  reads its output. Menu: Settings › "Codex Hook: …" (only when Codex is present or ours is
  installed), top-level Install/Update Codex Hook only when Codex is present.
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
- Without Xcode (Command Line Tools only) the app target doesn't build: no SwiftUI macro plugin.
  Core + tests still do: `swift build --target ClaudeWatcherCoreTests -Xswiftc -plugin-path
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`, then
  `swift test --skip-build`.
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
  rows' agent trees; demo-1 has a nested one and a background shell, demo-3 and demo-codex one
  agent), `CW_DEMO_EMPTY=1`,
  `CW_DEMO_UPDATE=X.Y.Z|fail|checking` (menu update line; default "Up to Date"),
  `CW_DEMO_USAGE=stale|error|none` (header usage lines; demo usage is Claude Code 5h 42% /
  week 67%, Codex 5h 18% / week 96% critical; `stale` makes Claude Code's reading stale,
  `error` fails it with no reading, `none` makes both unavailable).
- Theme overrides: `CW_GHOSTTY_CONFIG=<path>` (read only that config),
  `CW_GHOSTTY_THEME=<name or light:A,dark:B>` (preview a theme, ignoring config colors).
- Live discovery dump: `CW_LIVE=1 swift test --filter liveDiscovery` (Codex threads and TUIs:
  `--filter liveCodexDiscovery`). Live update check against
  GitHub (repo's Info.plist version vs `releases/latest`, plus an ETag revalidation):
  `CW_LIVE=1 swift test --filter liveUpdateCheck`. Live usage polls (one real poll each, no
  token printed): `--filter liveClaudeUsage`, `--filter liveCodexUsage`.
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
  the menu shows "Update Claude Code Hook" (Settings shows "Claude Code Hook: Needs Update"); use it.

## Conventions
- Commit with one-line messages only (no body/trailers).
- Always push: after committing finished work, `git push origin main` without asking (this repo
  overrides the global "never push" rule). Tags, releases and history rewrites still only when
  asked.
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
  parent transcript (can be 15 MB+) is indexed once (`TranscriptTaskIndex`), then only appended lines; it is
  always consulted for agents still in play, since a parked notice overrides their end_turn. Poll-only (no watchers): running agents append many times
  a second, and the 2 s poll lag is fine.
- Background shells (`TranscriptTaskIndex`, `BackgroundShellRules`, Claude Code 2.1.330): the
  main conversation's Bash calls that went to the background (`run_in_background`, or a
  foreground command that timed out, `timedOutAfterMs`, or was backgrounded): the `tool_result`
  user record's `toolUseResult.backgroundTaskId`; label = the call's `description`, else the
  command's first line (the call is found among the last 64 Bash `tool_use`s). Ended by a
  `<task-notification>` with that `<task-id>` and a `<status>` (completed/failed/killed/stopped)
  in any `queue-operation` (enqueue or remove), a `queued_command` attachment, or a `user`
  record with `origin.kind` "task-notification" (a resumed session's copied history, e.g. a parked `bg` job's, holds only that; it is
  also an agent notice for ids with no enqueue, whose time it would push seconds late; it can
  batch several notifications, each block parsed by `SubagentRules.finishedNotifications`), or
  by a TaskStop result (`toolUseResult.task_id`, message
  "Successfully stopped task…"). Ended ids are remembered, so an end seen before its launch
  holds. Only shells launched since the process started count (they die with it); 24 h display
  backstop while the session isn't busy. The registry goes idle while the session waits on one,
  so discovery reports an idle session with running agents, or shells launched within the last
  hour (`BackgroundShellRules.busyWindow`: past that it's likely a dev server, and the session
  waits on the user), as `.busy` (`SessionDiscovery.status(_:runningTasks:)`); Claude Code
  resumes it when the shell ends. Subagents' own background shells stay in their agent's
  "waiting on …" activity. The transcript is always indexed (once in full, ~30–60 ms for
  15–18 MB with byte-searched markers, then appended lines).
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
- Context size (`ClaudeSession.contextTokens`, `TranscriptReader`): from the session transcript's
  last main-conversation assistant record, `message.usage.input_tokens +
  cache_creation_input_tokens + cache_read_input_tokens` (missing = 0; output tokens excluded).
  Skipped: `isSidechain: true`, `model == "<synthetic>"` (API-error placeholders, all-zero
  usage) and any all-zero usage. A `/compact` writes a `system`/`compact_boundary` record whose
  `compactMetadata.postTokens` (~11k) becomes the value until the next reply (which reports
  ~40k more: system prompt + tools), so a compacted session never keeps its pre-compact size.
  Read with the transcript's tail; if the tail has none, scanned back in chunks (only lines
  containing `"input_tokens"`/`"compact_boundary"` are decoded), once per file. The window is
  assumed to be 1M (`ContextUsage.window`); transcripts don't record it.
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
- Ghostty 1.4.0 adds `tty`, `pid` (foreground process) and `name` (title) to `terminal`, so
  `TTYPropertyResolver` resolves directly there (and `GhosttyTitleReader` works); the rest of
  this paragraph is the 1.3.1 path. Ghostty 1.3.1 has no `tty` terminal property. The OSC 7 probe identifies a terminal by
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
- The panel (`.canJoinAllSpaces`) was once seen pinned on one desktop and missing on the others
  until relaunch (cause unknown). On every Space switch, `EdgeController.activeSpaceDidChange`
  re-attaches a panel that should be up but isn't `isOnActiveSpace` (orderOut, re-set behavior,
  orderFront), logged as an error with `panelState`; show/hide/screen changes log it too.
- Don't name a Core type `RGBColor`: it clashes with QuickDraw's `RGBColor` in AppKit targets
  (hence `GhosttyColor`).
- Codex (CLI 0.169, standalone installer `~/.codex/packages/standalone/releases/<ver>/bin/codex`;
  Homebrew cask `Caskroom/codex/`; npm vendors the same native binary; node never matches):
  - The TUI (`codex`, owns the tty) normally doesn't run threads: a shared daemon (`codex
    app-server --managed-daemon`, setsid, no tty, `~/.codex/app-server-daemon/daemon.pid`,
    outlives its TUIs) runs every thread and writes every rollout, so a TUI's open files say
    nothing. `--no-daemon` and a few flags run it embedded. `ProcessRules.isCodexTUI`: binary
    named `codex`, first positional argument not a non-interactive subcommand (`app-server`,
    `exec`, …); discovery also requires a tty and filters `allPIDs()` by `proc_name` first.
  - No per-process registry. Threads: `$CODEX_HOME/state_<n>.sqlite` (newest n), `threads`
    (`name` = thread name, auto-generated ~1 s after the first prompt or `/rename`; `title` =
    first message; `cwd`, `git_branch` at start, `created_at_ms`/`updated_at_ms` (or seconds),
    `thread_source` user|subagent|…, `source` cli|vscode (the daemon's TUI threads say
    "vscode")|exec|mcp|JSON for subagents, `originator` codex-tui (daemon) / codex_cli_rs
    (embedded); other clients excluded), `thread_spawn_edges(parent, child, status)` (`open`
    even after the child finished). Opened `SQLITE_OPEN_READONLY` (WAL: still sees commits,
    never checkpoints), kept open while Codex TUIs exist, closed when none.
  - Matching (`CodexMatcher`): a thread is eligible for a TUI if in its cwd (realpaths), active
    since the TUI started, and created after it (unless `codex resume`/`fork`; `/resume` inside
    the TUI isn't seen). Alone in its cwd: most recently active eligible thread, none = fresh
    TUI (idle, id `codex-pid-<pid>-<startms>`). Shared cwd: Ghostty titles containing exactly
    one candidate's name fix that TUI's thread; then every assignment of threads to eligible
    TUIs is enumerated (each TUI's threads must not overlap: `/new` starts after the previous
    one's last activity); a TUI gets a thread only if all consistent assignments agree, else
    `.unknown` ("thread unknown"). User's choice: never guess.
  - Rollouts `sessions/YYYY/MM/DD/rollout-<local ts>-<thread id>.jsonl`, created at the first
    prompt; lines `{"timestamp","ordinal","type","payload"}`. Busy = last `event_msg`
    `task_started` without a later `task_complete`/`turn_aborted`; context = last `token_count`
    `info.last_token_usage.total_tokens` / `info.model_context_window` (effective window, e.g.
    475k; never the cumulative `total_token_usage`); last prompt = `item_completed` with
    `item.type` "UserMessage". Only a 512-byte prefix is inspected per line; incremental like
    `TranscriptReader`, backward scan (≤16 MB) for fields the 256 KB tail lacks. Approval
    requests are never persisted. Subagents: child threads' rollouts (they start with a copy
    of the parent's history; their own last turn event decides), stale after 10 min idle while
    the session isn't busy; label = agent path's last component, type = nickname.
  - Waiting: a readable Ghostty title (`[ ! ] Action Required | …`, blinking with `[ . ]`) is
    authoritative; else the hook's `PermissionRequest` while its turn is open and nothing was
    recorded since (stays "waiting" until a long approved command's output lands). Titles are
    read at most once per scan, only for Ghostty Codex TUIs mid-turn or ambiguous.
  - Codex hook (`codex-watcher-hook.sh`): Codex runs hooks in the daemon (`$SHELL -lc`,
    setsid: no tty or TUI pid), JSON on stdin; events SessionStart (at the first turn, not at
    launch), UserPromptSubmit, PermissionRequest, Stop, Interrupt (async), SessionEnd (always
    sync in Codex; ≥60 s after a TUI exits, when the daemon unloads the thread). It writes
    `codex-hook-state/<root thread id>.json` (`session_id`, `last_event`, `turn_id`, `agent_id`,
    `cwd`, `updated_at` ms) atomically, removes it on SessionEnd, GCs > 48 h; prints nothing
    (SessionStart stdout becomes model context), exits 0; jq optional (`CODEX_WATCHER_NO_JQ=1`,
    `CODEX_WATCHER_STATE_DIR`). Separate dir: the Claude hook's GC deletes non-Claude state.
    `hooks.json` allows only top-level `description` and `hooks`. Trust: Codex only runs a
    user hook with `[hooks.state."<hooks.json path>:<event_snake>:<group>:<handler>"]
    trusted_hash` in `config.toml`, written when the user approves at Codex's startup "Review
    hooks" prompt; we never write it (user's choice). `CodexHookInstaller.status.needsTrust`
    ("Approve in Codex") checks presence only (not the hash), literal and realpath key forms.
  - Terminal side: Codex sets OSC 0 titles (`<spinner> <thread> | <project>`), queries OSC
    10/11 once at startup (never sets 11/111), never sends OSC 7; also OSC 7501 status for
    supporting terminals. Focus/highlight need nothing Codex-specific (pid + tty).
  - Usage (`CodexUsageSource`, `Usage/CodexUsage*.swift`): plan limits from rollouts' `token_count`
    `payload.rate_limits` (`limit_id` "codex"/null only; `primary`/`secondary` `{used_percent,
    window_minutes, resets_at}` epoch s, classified by length: < 3 days = session, else weekly; seen
    in 0.169: only `primary` 10080 min, `secondary` null; `rate_limits` may be null). `rate_limits`
    follows `info`, so the 512-byte prefix rule only gates the type; the line is decoded whole. Newest
    reading by event timestamp among the 10 most recently updated threads (`updated_at_ms`, any kind;
    not by date dir, long threads write to old ones), read newest last write first (the later of
    `updated_at_ms` and the file's mtime: Codex doesn't bump `updated_at` on every write), stopping at
    the first last written no later than the best reading. DB opened read-only per pass and closed;
    files cached by (inode, size, mtime) of the opened descriptor (`fstat`), backward chunked scan
    (≤ 8 MB), grown files scan only the new bytes; work on a private queue. Never rolls back to an
    older reading. No home/DB/reading = `.unavailable` (5 min); with a reading, a DB error or an
    unreadable rollout that may hold a newer one = `.stale` (even if a newer one was found elsewhere);
    else 30 s.
- Claude usage (`ClaudeUsageSource`, `Usage/Claude*.swift`): `GET
  https://api.anthropic.com/api/oauth/usage` with Claude Code's own OAuth access token
  (`Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, UA `ClaudeWatcher/<ver>`,
  ephemeral session, no cache or cookies). The token is read on every poll, never refreshed (that
  would rotate Claude Code's refresh token and log it out), never logged; only the access token
  and `expiresAt` (ms) are decoded; `ClaudeCredentials` redacts it from description and Mirror.
  Source: `/usr/bin/security find-generic-password -a <user> -s <service> -w` (account = login
  name if it matches `^[a-zA-Z0-9._-]+$`, else `claude-code-user`, like Claude Code; in the
  item's ACL, so no prompt; hex output when the JSON isn't printable; exit 44 = not found;
  private queue, SIGTERM after 15 s, SIGKILL 2 s later; not spawned at all while the default
  keychain is locked (`SecKeychainGetStatus`), which fails the read: `security` could raise the
  unlock dialog every poll), and `<claude home>/.credentials.json`. Service (Claude Code
  2.1.330): `Claude Code-credentials`, plus `-<sha256(raw CLAUDE_CONFIG_DIR,
  NFC).hex.prefix(8)>` whenever that variable is set (even to `~/.claude`). We only have the
  resolved path, so we hash it with and without a trailing `/`. Every location is read, in tiers
  (`locationTiers`): the home's own (default home: plain, suffixed, file; other homes: suffixed,
  file), then, for a non-default home only, the plain item (maybe another account), used only if
  the first tier has nothing. In a tier the best token wins: not expired, latest `expiresAt` (no
  expiry ranks below a known one), ties to the earlier location; with no usable token a failed
  `security` read is `.keychainUnavailable`, else the expired token ("token expired"), else
  unparseable / not logged in. Requests never follow redirects (task delegate; a 3xx is
  `.http`). Response: flat `five_hour`/`seven_day` (`utilization`, `resets_at`) or the `limits`
  array (`weekly_all`; session = active entry whose kind or group contains
  `session`/`five_hour`); lenient, but a body with none of those three keys is `.decoding`
  (keeps the old snapshot); ISO dates with any number of fractional digits. Schedule (`nextPollIn`): 5 min; 429 -> max(`retry-after`
  capped at 1 h, 5 min doubling to 30 min), no request until then; network 30 s doubling to 5
  min; Keychain 60 s doubling to 30 min; expired or rejected token -> re-read credentials every
  60 s, but a 401/403 token (kept only as its SHA-256) isn't sent again until it changes or 5 min
  pass. A clock going backwards re-anchors these waits at `now` (never longer than set).
  `URLError.cancelled` is a network error unless the poll's task was cancelled. Not logged in -> `.unavailable`, snapshot cleared (usage line hidden); other failures ->
  `.stale` with a snapshot, `.error` without.
- Usage known gaps (reviewed, accepted): Claude: a usage key present with a renamed inner schema
  parses as "no windows" (usage line hidden, no error); a `.credentials.json` read error counts as
  no file; after unlocking a locked keychain the usage line can take up to 30 min (Keychain backoff)
  to return; with `CLAUDE_CONFIG_DIR=~/.claude` plus a leftover plain item of another account,
  freshest-token-wins can switch accounts; `CLAUDE_SECURESTORAGE_CONFIG_DIR` (overrides the
  suffixed service name) isn't handled. Codex: in-place rollout rewrites aren't detected (never
  seen); the newest `state_N.sqlite` is trusted even if half-migrated; only `limit_id`
  "codex"/null is read; a window without `resets_at` never shows as reset. UI: the header's
  relative resets can read up to a minute long (minute-truncated clock); at the default panel
  width (38 columns) two windows don't fit with both resets, so usually only the constraining
  window's shows until the panel is widened, and none when a percent reaches 100% or a reset needs
  6 characters (`23h59m`, `Nov 30`), or the lines are limited by different window kinds (both
  are in the tooltip, which may never show: the panel never becomes active); a stale line's
  marker can make its bars shorter than the other lines', and at default width can cost it its
  second window.
