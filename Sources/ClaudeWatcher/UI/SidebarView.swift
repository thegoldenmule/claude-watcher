import AppKit
import ClaudeWatcherCore
import SwiftUI

/// The sidebar's content, drawn as a Ghostty pane: the theme's background and font, a prompt
/// header with status counts, then one block per session. Waiting sessions sort to the top and
/// are marked in the palette's yellow, since that's when the user needs to act.
struct SidebarView: View {
    let sessions: [ClaudeSession]
    var isPinned: Bool = false
    /// Row whose focus request is in flight.
    var pendingSessionID: String? = nil
    /// Banner for the last focus attempt that didn't fully succeed.
    var notice: FocusNotice? = nil
    let onSelect: (ClaudeSession) -> Void
    var onDismissNotice: () -> Void = {}
    var onOpenAutomationSettings: () -> Void = {}

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
            SidebarHeader(sessions: sessions, isPinned: isPinned)
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
                            SessionRow(session: session, isPending: session.id == pendingSessionID) {
                                onSelect(session)
                            }
                        }
                    }
                    .padding(.vertical, style.lineHeight * 0.25)
                }
                .scrollIndicators(.never)
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

/// `❯ claude sessions` plus a line of colored counts, like a prompt and its output.
private struct SidebarHeader: View {
    let sessions: [ClaudeSession]
    let isPinned: Bool

    @Environment(\.terminalStyle) private var style

    private var counts: [SessionStatus: Int] {
        sessions.reduce(into: [:]) { $0[$1.status, default: 0] += 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(.span("❯ ", style.success, font: style.boldFont)
                    + .span("claude", font: style.boldFont) + .span(" sessions"))
                Spacer(minLength: style.cellWidth)
                if isPinned {
                    Text("[pinned] ").foregroundStyle(style.faint).help("Pinned")
                }
                if !sessions.isEmpty {
                    Text("\(sessions.count)").foregroundStyle(style.faint)
                }
            }
            .lineLimit(1)
            if !sessions.isEmpty {
                summary.lineLimit(2).truncationMode(.tail)
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
        if busy > 0 { parts.append(part("✳ \(busy) working", style.busy)) }
        if idle > 0 { parts.append(part("○ \(idle) idle", style.idle)) }
        if unknown > 0 { parts.append(part("? \(unknown) unknown", style.faint)) }
        return Text(parts.dropFirst().reduce(parts.first ?? "") { $0 + .span("  ") + $1 })
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
            Text("no claude code sessions running").foregroundStyle(style.faint)
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
        .accessibilityLabel("No Claude Code sessions running")
    }
}

// MARK: - Row

private struct SessionRow: View {
    let session: ClaudeSession
    var isPending = false
    let action: () -> Void

    @Environment(\.terminalStyle) private var style
    @State private var hoverState = false
    private var hovering: Bool { hoverState || DemoMode.previewHoverID == session.id }

    private var isWaiting: Bool { session.status == .waiting }
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

    var body: some View {
        Button(action: action) {
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
                            BrailleSpinner().padding(.leading, style.cellWidth)
                        }
                    }

                    if isWaiting {
                        Text(waitingTag + .span(" ")
                            + .span(session.waitingFor ?? "needs your input", ink(style.waiting)))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, style.paddingX)
            .padding(.trailing, style.paddingX)
            .padding(.vertical, style.lineHeight * 0.35)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .onHover { hoverState = $0 }
        .help(session.cwd)
    }

    /// Inverse-video ` waiting ` tag, as a terminal would draw it with SGR 7.
    private var waitingTag: AttributedString {
        .span(" waiting ", style.background, font: style.boldFont, background: style.waiting)
    }

    /// `folder (branch)`, like git's `__git_ps1` prompt.
    private var locationLine: Text {
        let punctuation = ink(style.faint, faint: true)
        var line = AttributedString.span(folderName, ink(style.cyan))
        if let branch = session.branch, !branch.isEmpty {
            line += .span(" (", punctuation) + .span(branch, ink(style.magenta)) + .span(")", punctuation)
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
            if isWaiting { style.waiting.opacity(0.10) }
            if isSelected { style.selection }
            if isWaiting {
                Rectangle().fill(style.waiting).frame(width: 3)
            }
        }
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
/// waiting, a hollow dot when idle.
private struct StatusGlyph: View {
    let status: SessionStatus
    /// Replaces the dim idle/unknown colors (which vanish on a selection highlight).
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
            case .idle: Text("○")
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
        case .idle: dimColor ?? style.idle
        case .unknown: dimColor ?? style.faint
        }
    }

    private var label: String {
        switch status {
        case .busy: "Working"
        case .waiting: "Waiting"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }
}

/// Focus request in flight: a braille spinner, as CLI tools draw them.
private struct BrailleSpinner: View {
    @Environment(\.terminalStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelVisible) private var panelVisible

    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion || !panelVisible)) { context in
            let tick = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate / 0.08)
            Text(Self.frames[tick % Self.frames.count])
        }
        .foregroundStyle(style.foreground)
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
