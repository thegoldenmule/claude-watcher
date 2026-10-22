import AppKit
import ClaudeWatcherCore
import SwiftUI

/// The sidebar's content: a header with counts and a list of sessions. Waiting sessions sort
/// to the top and are tinted, since that's when the user needs to act.
struct SidebarView: View {
    let sessions: [ClaudeSession]
    var isPinned: Bool = false
    let onSelect: (ClaudeSession) -> Void

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
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

            if sessions.isEmpty {
                EmptyStateView()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 4) {
                        ForEach(ordered) { session in
                            SessionRow(session: session) { onSelect(session) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

// MARK: - Header

private struct SidebarHeader: View {
    let sessions: [ClaudeSession]
    let isPinned: Bool

    private func count(_ status: SessionStatus) -> Int {
        sessions.lazy.filter { $0.status == status }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Claude Code")
                    .font(.system(size: 15, weight: .semibold))
                if !sessions.isEmpty {
                    Text("\(sessions.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                Spacer(minLength: 0)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("Pinned")
                }
            }
            if !sessions.isEmpty {
                HStack(spacing: 10) {
                    let waiting = count(.waiting), busy = count(.busy)
                    if waiting > 0 {
                        SummaryChip(color: .orange, text: "\(waiting) waiting", emphasized: true)
                    }
                    if busy > 0 {
                        SummaryChip(color: .accentColor, text: "\(busy) working", emphasized: false)
                    }
                    if waiting == 0 && busy == 0 {
                        SummaryChip(color: .secondary, text: "All idle", emphasized: false)
                    }
                }
            }
        }
    }
}

private struct SummaryChip: View {
    let color: Color
    let text: String
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
        }
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Claude Code sessions running")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct SessionRow: View {
    let session: ClaudeSession
    let action: () -> Void

    @State private var hovering = false

    private var isWaiting: Bool { session.status == .waiting }

    private var folderName: String {
        let name = URL(fileURLWithPath: session.cwd).lastPathComponent
        return name.isEmpty ? session.cwd : name
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                StatusIndicator(status: session.status)
                    .frame(width: 14, height: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isWaiting {
                        Label(session.waitingFor ?? "Waiting for you", systemImage: "exclamationmark.bubble.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .labelStyle(TightLabelStyle())
                    }

                    HStack(spacing: 4) {
                        Text(folderName)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if let branch = session.branch, !branch.isEmpty {
                            Text("·").foregroundStyle(.tertiary)
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9, weight: .medium))
                            Text(branch)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                    if let prompt = session.lastPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !prompt.isEmpty {
                        Text(prompt.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TerminalBadge(kind: session.terminal)
                    .padding(.top, 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(background)
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(RowButtonStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(session.cwd)
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if isWaiting {
            shape
                .fill(Color.orange.opacity(hovering ? 0.22 : 0.14))
                .overlay(shape.strokeBorder(Color.orange.opacity(0.45), lineWidth: 1))
        } else {
            shape.fill(Color.primary.opacity(hovering ? 0.08 : 0))
        }
    }
}

private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10))
            configuration.title
        }
    }
}

// MARK: - Status indicator

private struct StatusIndicator: View {
    let status: SessionStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        ZStack {
            switch status {
            case .busy:
                if !reduceMotion {
                    Circle()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulsing ? 2.1 : 1)
                        .opacity(pulsing ? 0 : 1)
                }
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
            case .waiting:
                Circle()
                    .fill(Color.orange.opacity(0.25))
                    .frame(width: 14, height: 14)
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
            case .idle:
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
            case .unknown:
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.2)
                    .frame(width: 8, height: 8)
            }
        }
        .onAppear { startPulse() }
        .onChange(of: status) { startPulse() }
        .accessibilityLabel(Text(label))
    }

    private var label: String {
        switch status {
        case .busy: "Working"
        case .waiting: "Waiting"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }

    private func startPulse() {
        pulsing = false
        guard status == .busy, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
            pulsing = true
        }
    }
}

// MARK: - Terminal badge

private struct TerminalBadge: View {
    let kind: TerminalKind

    var body: some View {
        Group {
            if let icon = TerminalIcons.icon(for: kind) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
            }
        }
        .opacity(0.9)
        .help(TerminalIcons.name(for: kind))
    }
}

@MainActor
private enum TerminalIcons {
    private static var cache: [String: NSImage?] = [:]

    static func name(for kind: TerminalKind) -> String {
        switch kind {
        case .ghostty: "Ghostty"
        case .appleTerminal: "Terminal"
        case .other(let name): name
        }
    }

    static func icon(for kind: TerminalKind) -> NSImage? {
        let bundleID: String
        switch kind {
        case .ghostty: bundleID = "com.mitchellh.ghostty"
        case .appleTerminal: bundleID = "com.apple.Terminal"
        case .other: return nil
        }
        if let cached = cache[bundleID] { return cached }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = image
        return image
    }
}
