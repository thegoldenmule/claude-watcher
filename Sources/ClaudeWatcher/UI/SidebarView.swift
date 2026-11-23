import AppKit
import ClaudeWatcherCore
import SwiftUI

/// The sidebar's content, drawn as a Ghostty pane: the theme's background and font, a prompt
/// header with status counts and plan usage, then one block per session. Waiting sessions sort to the top and
/// are marked in the palette's yellow, since that's when the user needs to act; stopped (idle)
/// sessions get the same treatment in magenta, so a finished turn is just as easy to spot.
struct SidebarView: View {
    let sessions: [ClaudeSession]
    /// Plan usage lines for the header, one per visible agent (shown with or without sessions).
    var usage: [UsageLine] = []
    var isPinned: Bool = false
    /// Row whose focus request is in flight.
    var pendingSessionID: String? = nil
    /// Banner for the last focus attempt that didn't fully succeed.
    var notice: FocusNotice? = nil
    /// Sessions whose agent/shell tree is hidden; the others show theirs.
    var collapsedSessionIDs: Set<String> = []
    let onSelect: (ClaudeSession) -> Void
    /// A row's `▸ N agents` / `▸ N shells` line was clicked.
    var onToggleExpanded: (_ sessionID: String) -> Void = { _ in }
    /// The header's `[pin]`/`[pinned]` control was clicked.
    var onTogglePin: () -> Void = {}
    var onDismissNotice: () -> Void = {}
    var onOpenAutomationSettings: () -> Void = {}
    /// The pointer entered (true) or left (false) a session's row.
    var onHoverChange: (_ sessionID: String, _ inside: Bool) -> Void = { _, _ in }
    /// Laid-out rows' frames in `coordinateSpace` (the whole pane, top-left origin), for
    /// hit-testing the pointer; rows not currently rendered are absent.
    var onRowFrames: (_ frames: [String: CGRect]) -> Void = { _ in }
    /// The session list's visible area in `coordinateSpace`; row frames outside it are scrolled away.
    var onListViewport: (_ viewport: CGRect) -> Void = { _ in }

    /// Named coordinate space of the whole pane, which fills the panel's content view.
    nonisolated static let coordinateSpace = "sidebarPane"

    @Environment(\.terminalStyle) private var style

    private var ordered: [ClaudeSession] {
        // Only "waiting" jumps the queue; busy/idle flips don't reshuffle rows.
        sessions.enumerated().sorted { a, b in
            let wa = a.element.status == .waiting, wb = b.element.status == .waiting
            if wa != wb { return wa }
            if a.element.startedAt != b.element.startedAt {
                return a.element.startedAt > b.element.startedAt
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(sessions: sessions, usage: usage, isPinned: isPinned, onTogglePin: onTogglePin)
                .padding(.horizontal, style.paddingX)
                .padding(.top, style.paddingY)
                .padding(.bottom, style.lineHeight * 0.5)

            Rectangle().fill(style.divider).frame(height: 1)

            if sessions.isEmpty {
                EmptyStateView()
                    .padding(.horizontal, style.paddingX)
                    .padding(.top, style.lineHeight * 0.5)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(ordered) { session in
                            SessionRow(
                                session: session, isPending: session.id == pendingSessionID,
                                isExpanded: !collapsedSessionIDs.contains(session.id),
                                onHover: { onHoverChange(session.id, $0) },
                                onToggleExpanded: { onToggleExpanded(session.id) }
                            ) {
                                onSelect(session)
                            }
                            // Spans the whole block, agent tree included: hit-testing and the
                            // hover tint map it to the session.
                            .background(GeometryReader { geometry in
                                Color.clear.preference(
                                    key: RowFramesKey.self,
                                    value: [session.id: geometry.frame(in: .named(Self.coordinateSpace))])
                            })
                        }
                    }
                    .padding(.vertical, style.lineHeight * 0.25)
                }
                .scrollIndicators(.never)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.coordinateSpace)) } action: {
                    onListViewport($0)
                }
            }

            Spacer(minLength: 0)

            if let notice {
                FocusNoticeBanner(
                    notice: notice, onDismiss: onDismissNotice, onOpenSettings: onOpenAutomationSettings)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .font(style.font)
        .foregroundStyle(style.foreground)
        .animation(.easeOut(duration: 0.18), value: notice)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PaneBackground())
        .clipShape(.rect(cornerRadius: TerminalStyle.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TerminalStyle.cornerRadius, style: .continuous)
                .strokeBorder(style.border, lineWidth: 1))
        .environment(\.colorScheme, style.colorScheme)
        .onPreferenceChange(RowFramesKey.self) { onRowFrames($0) }  // [:] once the list is gone
        .coordinateSpace(.named(Self.coordinateSpace))
    }
}

/// Session rows' frames by id, in `SidebarView.coordinateSpace`.
private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The theme background at `background-opacity`, over a blur when `background-blur` is set.
private struct PaneBackground: View {
    @Environment(\.terminalStyle) private var style

    var body: some View {
        let theme = style.theme
        ZStack {
            switch theme.backgroundBlur {
            case .off:
                EmptyView()
            case .radius:
                Rectangle().fill(.ultraThinMaterial)
            case .glass(let clear):
                Rectangle().fill(.clear)
                    .glassEffect(clear ? .clear : .regular, in: .rect(cornerRadius: TerminalStyle.cornerRadius))
            }
            Rectangle().fill(style.background.opacity(theme.backgroundOpacity))
        }
    }
}

// MARK: - Header

/// `❯ claude sessions` (`❯ agent sessions` once a Codex session is listed) plus a line of
/// colored counts, like a prompt and its output, then one plan usage line per agent. The
/// `[pin]`/`[pinned]` control toggles pinning.
private struct SidebarHeader: View {
    let sessions: [ClaudeSession]
    let usage: [UsageLine]
    let isPinned: Bool
    let onTogglePin: () -> Void

    @Environment(\.terminalStyle) private var style

    /// "claude", or "agent" once any other kind of session (Codex) is listed.
    private var noun: String {
        sessions.allSatisfy { $0.agent == .claude } ? "claude" : "agent"
    }

    private var counts: [SessionStatus: Int] {
        sessions.reduce(into: [:]) { $0[$1.status, default: 0] += 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(.span("❯ ", style.success, font: style.boldFont)
                    + .span(noun, font: style.boldFont) + .span(" sessions"))
                Spacer(minLength: style.cellWidth)
                PinToggle(isPinned: isPinned, action: onTogglePin)
                Text(" ")
                if !sessions.isEmpty {
                    Text("\(sessions.count)").foregroundStyle(style.faint)
                }
            }
            .lineLimit(1)
            if !sessions.isEmpty {
                summary.lineLimit(2).truncationMode(.tail)
            }
            if !usage.isEmpty {
                UsageLines(lines: usage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: Text {
        let counts = counts
        let waiting = counts[.waiting, default: 0], busy = counts[.busy, default: 0]
        let idle = counts[.idle, default: 0], unknown = counts[.unknown, default: 0]
        // Non-breaking spaces inside each part, so a narrow pane wraps between parts only.
        func part(_ text: String, _ color: Color, bold: Bool = false) -> AttributedString {
            .span(text.replacingOccurrences(of: " ", with: "\u{00A0}"), color, font: bold ? style.boldFont : nil)
        }
        var parts: [AttributedString] = []
        if waiting > 0 { parts.append(part("● \(waiting) waiting", style.waiting, bold: true)) }
        if idle > 0 { parts.append(part("■ \(idle) stopped", style.idle, bold: true)) }
        if busy > 0 { parts.append(part("✳ \(busy) working", style.busy)) }
        if unknown > 0 { parts.append(part("? \(unknown) unknown", style.faint)) }
        let agents = sessions.reduce(0) { $0 + $1.subagents.count }
        if agents > 0 { parts.append(part("⑂ \(agents) agent\(agents == 1 ? "" : "s")", style.cyan)) }
        let shells = sessions.reduce(0) { $0 + $1.backgroundShells.count }
        if shells > 0 { parts.append(part("$ \(shells) shell\(shells == 1 ? "" : "s")", style.green)) }
        return Text(parts.dropFirst().reduce(parts.first ?? "") { $0 + .span("  ") + $1 })
    }
}

// MARK: - Plan usage

/// The header's plan usage, one line per agent:
///
///     claude  5h ━━━━━━░░░░  42% 2h10m  wk ━━━━━━━░░░  67% Thu
///     codex   wk ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  96% Tue
///
/// The label column and the percent and reset reserves are as wide as the widest value among
/// all lines, so lines with as many windows have bars of the same length.
private struct UsageLines: View {
    let lines: [UsageLine]

    /// The longest agent label plus two spaces.
    private static let labelCells = (AgentKind.allCases.map(\.label.count).max() ?? 6) + 2

    var body: some View {
        let windows = lines.flatMap(\.windows)
        let percentCells = max(3, windows.map(\.percentText.count).max() ?? 3)
        let resetCells = windows.compactMap(\.resetText?.count).max() ?? 0
        // The steps showing only the constraining window's reset size it from those resets
        // alone, and the both-windows one is offered only while every two-window line is
        // limited by the same kind of window (else their bars wouldn't line up).
        let constraining = lines.compactMap(\.constraining)
        let oneResetCells = constraining.compactMap(\.resetText?.count).max() ?? 0
        let pairs = lines.filter { $0.windows.count > 1 }
        let alignedOneReset = Set(pairs.compactMap(\.constraining?.kind)).count <= 1
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                UsageLineView(line: line, labelCells: Self.labelCells, percentCells: percentCells,
                              resetCells: resetCells, oneResetCells: oneResetCells,
                              alignedOneReset: alignedOneReset)
            }
        }
    }
}

/// One agent's usage line. Narrow panes drop the other window's reset time (keeping the most
/// constraining one's: tooltips may never show in this non-activating panel, so the line must
/// carry it), then all reset times, then all but the most constraining window (with, then
/// without its reset), then the bar (`claude  67%`); a window never wraps. A stale reading is
/// drawn faint and uncoloured, with a `stale` marker that outranks every other detail (all
/// steps are tried with it before any without it); with no reading, a faint
/// `claude usage: <message>`. The tooltip has the long form (reset clock times, the error and
/// when the reading was taken).
private struct UsageLineView: View {
    let line: UsageLine
    let labelCells: Int
    let percentCells: Int
    let resetCells: Int
    /// The reset reserve when only constraining windows' resets show.
    let oneResetCells: Int
    /// Whether both windows with only the constraining one's reset may show (see `UsageLines`).
    let alignedOneReset: Bool

    @Environment(\.terminalStyle) private var style

    private func cells(_ count: Int) -> CGFloat { style.cellWidth * CGFloat(count) }

    var body: some View {
        Group {
            if line.windows.isEmpty {
                Text("\(line.agent.label) usage: \(line.message ?? "unavailable")")
                    .foregroundStyle(style.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                ViewThatFits(in: .horizontal) {
                    if line.isStale { steps(marker: true) }
                    steps(marker: false)
                }
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(line.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityText)
    }

    private var label: some View {
        Text(line.agent.label)
            .foregroundStyle(line.isStale ? style.faint : style.foreground)
            .frame(width: cells(labelCells), alignment: .leading)
    }

    @ViewBuilder private func staleMarker(_ shown: Bool) -> some View {
        if shown {
            Text("stale").foregroundStyle(style.faint).fixedSize().padding(.leading, style.cellWidth)
        }
    }

    /// The degrade steps, most detailed first (see the type's doc).
    @ViewBuilder private func steps(marker: Bool) -> some View {
        let all = Set(line.windows.map(\.kind))
        let constraining = line.constraining.map { [$0] } ?? []
        let constrainingKind = Set(constraining.map(\.kind))
        meters(line.windows, resetsFor: all, resetCells: resetCells, marker: marker)
        if line.windows.count > 1, alignedOneReset {
            meters(line.windows, resetsFor: constrainingKind, resetCells: oneResetCells, marker: marker)
        }
        meters(line.windows, resetsFor: [], resetCells: 0, marker: marker)
        if line.windows.count > 1 {
            meters(constraining, resetsFor: constrainingKind, resetCells: oneResetCells, marker: marker)
            meters(constraining, resetsFor: [], resetCells: 0, marker: marker)
        }
        compact(marker: marker)
    }

    private func meters(_ windows: [UsageWindowDisplay], resetsFor: Set<UsageWindowKind>,
                        resetCells: Int, marker: Bool) -> some View {
        HStack(spacing: 0) {
            label
            HStack(spacing: cells(2)) {
                ForEach(windows, id: \.kind) { window in
                    meter(window, resetCells: resetsFor.contains(window.kind) ? resetCells : 0)
                }
            }
            staleMarker(marker)
        }
    }

    /// `5h ━━━━░░░  42% 2h10m`: the percent right-aligned and the reset left-aligned in their
    /// reserves; the bar takes the rest.
    /// No reset when `resetCells` is 0.
    private func meter(_ window: UsageWindowDisplay, resetCells: Int) -> some View {
        HStack(spacing: style.cellWidth) {
            Text(window.kind.shortLabel).foregroundStyle(style.faint).fixedSize()
            MeterBar(fraction: window.fillFraction, fill: fill(window), track: style.faint)
                .frame(minWidth: cells(4))
            Text(window.percentText)
                .foregroundStyle(textColor(window))
                .fixedSize()
                .frame(minWidth: cells(percentCells), alignment: .trailing)
            if resetCells > 0 {
                Text(window.resetText ?? "")
                    .foregroundStyle(style.faint)
                    .fixedSize()
                    .frame(minWidth: cells(resetCells), alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// `claude  67%`: the most constraining window's percent alone.
    private func compact(marker: Bool) -> some View {
        HStack(spacing: 0) {
            label
            if let window = line.constraining {
                Text(window.percentText).foregroundStyle(textColor(window)).fixedSize()
            }
            staleMarker(marker)
        }
    }

    private func fill(_ window: UsageWindowDisplay) -> Color {
        if line.isStale { return style.faint }
        switch window.level {
        case .normal: return style.green
        case .warning: return style.yellow
        case .critical: return style.red
        }
    }

    private func textColor(_ window: UsageWindowDisplay) -> Color {
        if line.isStale { return style.faint }
        switch window.level {
        case .normal: return style.foreground
        case .warning: return style.yellow
        case .critical: return style.red
        }
    }
}

// MARK: - Empty state

/// A prompt with nothing to show and a blinking block cursor.
private struct EmptyStateView: View {
    @Environment(\.terminalStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelVisible) private var panelVisible

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("no claude code or codex sessions running").foregroundStyle(style.faint)
            HStack(spacing: 0) {
                Text("❯ ").foregroundStyle(style.success).font(style.boldFont)
                TimelineView(.animation(minimumInterval: 0.6, paused: reduceMotion || !panelVisible)) { context in
                    let on = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
                    Rectangle()
                        .fill(style.cursor.opacity(on ? 1 : 0))
                        .frame(width: style.cellWidth, height: style.lineHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No Claude Code or Codex sessions running")
    }
}

// MARK: - Row

/// One session's block: its lines, then (with running subagents or background shells) a
/// `▸ N agents · N shells running` line that toggles the tree of both below it. These are
/// sibling buttons, never nested: the session's lines and the tree focus the session, the toggle
/// line only expands/collapses. Hover, the selection highlight and the pane tint cover the
/// whole block.
private struct SessionRow: View {
    let session: ClaudeSession
    var isPending = false
    var isExpanded = true
    var onHover: (Bool) -> Void = { _ in }
    var onToggleExpanded: () -> Void = {}
    let action: () -> Void

    @Environment(\.terminalStyle) private var style
    @Environment(\.panelVisible) private var panelVisible
    @State private var hoverState = false
    private var hovering: Bool { hoverState || DemoMode.previewHoverID == session.id }

    private var isWaiting: Bool { session.status == .waiting }
    /// Waiting and stopped rows are flagged: a wash, a bar on the left edge and a tag line.
    /// Palette magentas are darker than yellows, so the stopped wash is a little stronger.
    private var accent: (color: Color, wash: Double)? {
        switch session.status {
        case .waiting: (style.waiting, 0.10)
        case .idle: (style.idle, 0.14)
        case .busy, .unknown: nil
        }
    }
    private var isSelected: Bool { hovering || isPending }

    /// Text color under the selection highlight: the theme's `selection-foreground`, as Ghostty
    /// draws selected cells; nil keeps the palette colors.
    private func ink(_ color: Color, faint: Bool = false) -> Color {
        guard isSelected, let fg = style.selectionText else { return color }
        return faint ? fg.opacity(0.7) : fg
    }

    private var folderName: String {
        let name = URL(fileURLWithPath: session.cwd).lastPathComponent
        return name.isEmpty ? session.cwd : name
    }

    private var agents: [SubagentInfo] { session.subagents }
    private var shells: [BackgroundShellInfo] { session.backgroundShells }
    private var hasTasks: Bool { !agents.isEmpty || !shells.isEmpty }
    private var showsTree: Bool { isExpanded && hasTasks }
    private var rowPadding: CGFloat { style.lineHeight * 0.35 }
    /// The task tree hangs off the toggle line: its branches start under the first count, past
    /// the `▸ `, so the tree reads as nested inside the session.
    private var treeIndent: CGFloat { style.cellWidth * 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                sessionLines
                    .padding(.horizontal, style.paddingX)
                    .padding(.top, rowPadding)
                    .padding(.bottom, hasTasks ? 0 : rowPadding)
                    .contentShape(.rect)
            }
            .buttonStyle(RowButtonStyle())

            if hasTasks {
                Button(action: onToggleExpanded) {
                    tasksToggle
                        .padding(.leading, style.paddingX + style.gutterWidth)
                        .padding(.trailing, style.paddingX)
                        .padding(.bottom, showsTree ? 0 : rowPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityLabel("\(isExpanded ? "Hide" : "Show") \(taskCounts.map(\.text).joined(separator: ", "))")
            }

            if showsTree {
                Button(action: action) {
                    taskTree
                        .padding(.leading, style.paddingX + style.gutterWidth + treeIndent)
                        .padding(.trailing, style.paddingX)
                        .padding(.bottom, rowPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .background(background)
        .contentShape(.rect)
        .onHover { inside in
            hoverState = inside
            onHover(inside)
        }
        .help(session.cwd)
    }

    private var sessionLines: some View {
        HStack(alignment: .top, spacing: 0) {
            StatusGlyph(status: session.status, dimColor: isSelected ? style.selectionText : nil)
                .frame(width: style.gutterWidth, height: style.lineHeight, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(session.title)
                        .font(style.boldFont)
                        .foregroundStyle(ink(style.foreground))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isPending {
                        BrailleSpinner(color: ink(style.foreground)).padding(.leading, style.cellWidth)
                    }
                }

                if isWaiting {
                    Text(tag("waiting", style.waiting) + .span(" ")
                        + .span(session.waitingFor ?? "needs your input", ink(style.waiting)))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if session.status == .idle {
                    Text(tag("stopped", style.idle))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if session.agent == .codex && session.status == .unknown {
                    // CodexDiscovery couldn't tell this TUI's thread from another's in the same folder.
                    Text("? thread unknown: another codex shares this folder")
                        .foregroundStyle(ink(style.faint, faint: true))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                locationLine
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let prompt = session.lastPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !prompt.isEmpty {
                    Text("> \(prompt.replacingOccurrences(of: "\n", with: " "))")
                        .foregroundStyle(ink(style.faint, faint: true))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let tokens = session.contextTokens {
                    ContextMeter(
                        tokens: tokens, window: session.effectiveContextWindow,
                        textColor: ink(style.faint, faint: true))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "2 agents", "1 shell": the non-zero counts, in the toggle line's colors.
    private var taskCounts: [(text: String, color: Color)] {
        var counts: [(String, Color)] = []
        if !agents.isEmpty { counts.append(("\(agents.count) agent\(agents.count == 1 ? "" : "s")", style.cyan)) }
        if !shells.isEmpty { counts.append(("\(shells.count) shell\(shells.count == 1 ? "" : "s")", style.green)) }
        return counts
    }

    /// `▸ 2 agents · 1 shell running`, `▾` while the tree is open.
    private var tasksToggle: some View {
        let guide = ink(style.faint, faint: true)
        var text = AttributedString.span(isExpanded ? "▾ " : "▸ ", ink(style.foreground))
        for (i, count) in taskCounts.enumerated() {
            if i > 0 { text += .span(" · ", guide) }
            text += .span(count.text, ink(count.color))
        }
        return Text(text + .span(" running", guide))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The tree's entries: the agents in pre-order, then the session's background shells.
    private enum TreeEntry {
        case agent(SubagentInfo)
        case shell(BackgroundShellInfo)

        var id: String {
            switch self {
            case .agent(let a): "agent:\(a.id)"
            case .shell(let s): "shell:\(s.id)"
            }
        }
        var depth: Int {
            if case .agent(let a) = self { a.depth } else { 0 }
        }
    }

    private struct TreeLine: Identifiable {
        var entry: TreeEntry
        var prefix: String
        var continuation: String
        var id: String { entry.id }
    }

    private var treeLines: [TreeLine] {
        let entries = agents.map(TreeEntry.agent) + shells.map(TreeEntry.shell)
        return zip(entries, SubagentTree.prefixes(depths: entries.map(\.depth))).map {
            TreeLine(entry: $0, prefix: $1.prefix, continuation: $1.continuation)
        }
    }

    /// `├── Explore · find the hook installer    2m`, then the agent's latest action under its
    /// text; `└── shell · Wait for CI    3m`, then `$ ghx ci wait 12`. The elapsed times tick
    /// while the panel is visible.
    private var taskTree: some View {
        TimelineView(.animation(minimumInterval: 5, paused: !panelVisible)) { context in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(treeLines) { line in
                    switch line.entry {
                    case .agent(let agent):
                        treeEntryLines(line, type: agent.agentType, typeColor: style.cyan, label: agent.label,
                                  startedAt: agent.startedAt, detail: agent.activity, now: context.date)
                    case .shell(let shell):
                        treeEntryLines(line, type: "shell", typeColor: style.green, label: shell.label,
                                  startedAt: shell.startedAt, detail: shell.command.map { "$ \($0)" },
                                  now: context.date)
                    }
                }
            }
        }
    }

    @ViewBuilder private func treeEntryLines(
        _ line: TreeLine, type: String, typeColor: Color, label: String, startedAt: Date, detail: String?,
        now: Date
    ) -> some View {
        let guide = ink(style.faint, faint: true)
        HStack(spacing: 0) {
            Text(.span(line.prefix, guide) + .span(type, ink(typeColor))
                + .span(" · ", guide) + .span(label, ink(style.foreground)))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(ElapsedFormat.short(now.timeIntervalSince(startedAt)))
                .foregroundStyle(guide)
                .fixedSize()
                .padding(.leading, style.cellWidth)
        }
        if let detail {
            Text(.span(line.continuation, guide) + .span(detail, guide))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Inverse-video ` waiting ` / ` stopped ` tag, as a terminal would draw it with SGR 7.
    private func tag(_ word: String, _ color: Color) -> AttributedString {
        .span(" \(word) ", style.background, font: style.boldFont, background: color)
    }

    /// `folder (branch)`, like git's `__git_ps1` prompt, then ` [codex]` for a Codex session
    /// and ` [terminal]` for a terminal other than Ghostty.
    private var locationLine: Text {
        let punctuation = ink(style.faint, faint: true)
        var line = AttributedString.span(folderName, ink(style.cyan))
        if let branch = session.branch, !branch.isEmpty {
            line += .span(" (", punctuation) + .span(branch, ink(style.magenta)) + .span(")", punctuation)
        }
        if session.agent != .claude {
            line += .span(" [", punctuation) + .span(session.agent.label, ink(style.blue)) + .span("]", punctuation)
        }
        if case .ghostty = session.terminal {} else {
            line += .span(" [\(Self.terminalName(session.terminal))]", punctuation)
        }
        return Text(line)
    }

    private static func terminalName(_ kind: TerminalKind) -> String {
        switch kind {
        case .ghostty: "ghostty"
        case .appleTerminal: "terminal"
        case .other(let name): name.lowercased()
        }
    }

    @ViewBuilder private var background: some View {
        ZStack(alignment: .leading) {
            if let accent { accent.color.opacity(accent.wash) }
            if isSelected { style.selection }
            if let accent {
                Rectangle().fill(accent.color).frame(width: 3)
            }
        }
    }
}

/// How full the session's context window is: a bar in the level's palette color (green, then
/// yellow from 50%, red from 75%) and `245k / 1M · 25%` (Codex: `120k / 475k · 25%`). The fill
/// keeps its color under the selection highlight, like the status glyph; the track and label
/// follow `textColor`.
private struct ContextMeter: View {
    let tokens: Int
    let window: Int
    let textColor: Color

    @Environment(\.terminalStyle) private var style

    private var fraction: Double { ContextUsage.fraction(tokens, window: window) }

    private var fill: Color {
        switch ContextUsage.level(fraction) {
        case .normal: style.green
        case .warning: style.yellow
        case .critical: style.red
        }
    }

    var body: some View {
        // Narrow panes drop the token counts, then the label.
        ViewThatFits(in: .horizontal) {
            meter(label: ContextUsage.label(tokens, window: window), reserve: 18)
            meter(label: "\(ContextUsage.percent(tokens, window: window))%", reserve: 4)
            bar
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(ContextUsage.percent(tokens, window: window)) percent full, "
            + "\(ContextUsage.shortTokens(tokens)) of \(ContextUsage.windowLabel(window)) tokens")
    }

    /// The label is right-aligned in a fixed `reserve` of cells, so every row's bar is as long.
    private func meter(label: String, reserve: CGFloat) -> some View {
        HStack(spacing: style.cellWidth) {
            bar.frame(minWidth: style.cellWidth * 6)
            Text(label)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: style.cellWidth * reserve, alignment: .trailing)
        }
    }

    private var bar: some View {
        MeterBar(fraction: fraction, fill: fill, track: textColor)
    }
}

/// A meter's bar, one line high: a `track`-tinted run with `fraction` of it in `fill`.
/// Drawn, not `█░` text: block glyphs show seams between cells in many fonts, fall back to
/// another font's widths when the configured one lacks them, and only fill in eighths of a
/// cell. Square ends at about a block glyph's height still read as a run of cells.
private struct MeterBar: View {
    let fraction: Double
    let fill: Color
    let track: Color

    @Environment(\.terminalStyle) private var style

    var body: some View {
        Rectangle()
            .fill(track.opacity(0.22))
            .overlay {
                Rectangle().fill(fill).scaleEffect(x: fraction, anchor: .leading)
            }
            .frame(height: (style.lineHeight * 0.45).rounded())
            .frame(maxWidth: .infinity, minHeight: style.lineHeight)
    }
}

private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Glyphs

/// One terminal cell's worth of status: Claude's own spinner while working, a yellow dot when
/// waiting, a magenta stop square when stopped (idle).
private struct StatusGlyph: View {
    let status: SessionStatus
    /// Replaces the dim unknown color (which vanishes on a selection highlight).
    var dimColor: Color? = nil

    @Environment(\.terminalStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelVisible) private var panelVisible

    /// Claude Code's thinking spinner, played forwards then backwards.
    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]

    var body: some View {
        Group {
            switch status {
            case .busy:
                if reduceMotion {
                    Text("✳")
                } else {
                    TimelineView(.animation(minimumInterval: 0.12, paused: !panelVisible)) { context in
                        let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.12)
                        Text(Self.frames[tick % Self.frames.count])
                    }
                }
            case .waiting: Text("●").font(style.boldFont)
            case .idle: Text("■").font(style.boldFont)
            case .unknown: Text("?")
            }
        }
        .foregroundStyle(color)
        .accessibilityLabel(Text(label))
    }

    private var color: Color {
        switch status {
        case .busy: style.busy
        case .waiting: style.waiting
        case .idle: style.idle
        case .unknown: dimColor ?? style.faint
        }
    }

    private var label: String {
        switch status {
        case .busy: "Working"
        case .waiting: "Waiting"
        case .idle: "Stopped"
        case .unknown: "Unknown"
        }
    }
}

/// Focus request in flight: a braille spinner, as CLI tools draw them.
private struct BrailleSpinner: View {
    /// The row's text color: under a `selection-background` highlight, the selection foreground.
    let color: Color

    @Environment(\.terminalStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelVisible) private var panelVisible

    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion || !panelVisible)) { context in
            let tick = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate / 0.08)
            Text(Self.frames[tick % Self.frames.count])
        }
        .foregroundStyle(color)
        .accessibilityLabel("Focusing")
    }
}

// MARK: - Focus notice

/// Compiler-style diagnostic at the bottom of the pane: `error:` in red for a failed focus,
/// `note:` for informational outcomes.
private struct FocusNoticeBanner: View {
    let notice: FocusNotice
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.terminalStyle) private var style

    private var tint: Color { notice.isError ? style.failure : style.blue }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(notice.isError ? style.failure : style.divider).frame(height: 1)
            VStack(alignment: .leading, spacing: style.lineHeight * 0.25) {
                HStack(alignment: .top, spacing: 0) {
                    Text(.span(notice.isError ? "error: " : "note: ", tint)
                        + .span(notice.isError ? "couldn't focus \(notice.sessionTitle)" : notice.sessionTitle))
                        .font(style.boldFont)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: onDismiss) {
                        Text("×")
                            .foregroundStyle(style.faint)
                            .frame(width: style.cellWidth * 2, height: style.lineHeight)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                Text(notice.message)
                    .foregroundStyle(style.faint)
                    .fixedSize(horizontal: false, vertical: true)
                if notice.needsAutomationPermission {
                    TerminalButton(title: "Open Automation Settings…", tint: tint, action: onOpenSettings)
                        .padding(.top, style.lineHeight * 0.25)
                }
            }
            .padding(.horizontal, style.paddingX)
            .padding(.vertical, style.lineHeight * 0.5)
            .background(tint.opacity(notice.isError ? 0.10 : 0.06))
        }
        .accessibilityElement(children: .contain)
    }
}

/// A bracketed text button: `[ Open Automation Settings… ]`, inverse video on hover.
private struct TerminalButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    @Environment(\.terminalStyle) private var style
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("[ \(title) ]")
                .font(style.boldFont)
                .foregroundStyle(hovering ? style.background : tint)
                .background(hovering ? tint : .clear)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The header's `[pin]` / `[pinned]` control, styled like `TerminalButton` (inverse video on
/// hover) but in the header's regular font and faint color.
private struct PinToggle: View {
    let isPinned: Bool
    let action: () -> Void

    @Environment(\.terminalStyle) private var style
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(isPinned ? "[pinned]" : "[pin]")
                .foregroundStyle(hovering ? style.background : style.faint)
                .background(hovering ? style.faint : .clear)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isPinned ? "Unpin sidebar" : "Pin sidebar")
        .accessibilityLabel(isPinned ? "Unpin sidebar" : "Pin sidebar")
    }
}

extension EnvironmentValues {
    /// Whether the sidebar panel is on screen. Spinners and the blinking cursor pause while it
    /// isn't: `TimelineView` keeps firing after `orderOut`, and the panel is hidden most of the time.
    @Entry var panelVisible = true
}

extension AttributedString {
    /// A run of text with optional color, font and (inverse-video) background, for building
    /// multi-colored terminal lines.
    static func span(
        _ text: String, _ color: Color? = nil, font: Font? = nil, background: Color? = nil
    ) -> AttributedString {
        var run = AttributedString(text)
        if let color { run.foregroundColor = color }
        if let font { run.font = font }
        if let background { run.backgroundColor = background }
        return run
    }
}
