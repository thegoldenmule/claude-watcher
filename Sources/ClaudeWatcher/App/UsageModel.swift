import AppKit
import ClaudeWatcherCore
import os

/// Plan usage for the sidebar header: owns the `UsageStore`, a minute clock and the system
/// sleep/wake handling.
///
/// - Sleep/wake: will-sleep suspends the store's loops; did-wake resumes them (each source
///   polls ~5 s later, or at its own later deadline). A did-wake that never comes is covered by
///   the tick: `pollOverdue` resumes a suspension older than 5 minutes.
/// - Clock: `now` ticks every minute (no TimelineView in the panel: it would need pausing while
///   hidden, and the tick also drives `pollOverdue`), on wake and when the panel shows, so a
///   window whose reset passed shows 0 and the reset times count down. It's truncated to the
///   minute and only assigned when the minute changed, so repeated ticks within a minute don't
///   re-render the panel (a reset passing mid-minute shows at the next minute). Each tick also
///   polls any source whose timer is overdue (`UsageStore.pollOverdue`).
/// - No App Nap activity: holding one would keep the whole app (the 2 s session poll, panel
///   timers) out of App Nap. Usage only changes on a minutes scale, deadlines are wall-clock
///   and the minute tick and the panel showing catch up on any drift.
@MainActor
@Observable
final class UsageModel {
    let store: UsageStore
    /// The minute clock the display rules are evaluated at.
    private(set) var now = UsageModel.minute(of: Date())

    /// The sidebar header's usage lines (hidden agents left out), in source order. Reading it
    /// in a view's `body` tracks both the store's usage and the minute clock.
    var lines: [UsageLine] {
        UsageDisplay.lines(store.usage, agents: store.agents, now: now)
    }

    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Usage")

    init(sources: [any UsageSource]) {
        // A dark wake (Power Nap) keeps the display asleep: never end a stuck suspension then.
        // An offline main display (-1, e.g. headless) also counts as not awake; did-wake still resumes.
        store = UsageStore(sources: sources, isFullWake: { CGDisplayIsAsleep(CGMainDisplayID()) == 0 })
    }

    /// Starts polling, the minute clock and the sleep/wake observers. Idempotent.
    func start() {
        guard !store.isRunning else { return }
        store.start()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { model in
            model.logger.notice("system will sleep: usage polling suspended")
            model.store.suspend()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { model in
            model.logger.notice("system woke: usage polling resumes")
            model.updateNow()
            model.store.resume()
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        store.stop()
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
    }

    /// Brings the clock up to date and polls overdue sources: every minute, and when the panel
    /// shows (the timer may have been coalesced while the app sat idle).
    func tick() {
        updateNow()
        store.pollOverdue()
    }

    /// Sets `now` to the current minute, only if that changed (so observers aren't invalidated).
    private func updateNow() {
        let minute = Self.minute(of: Date())
        if minute != now { now = minute }
    }

    nonisolated private static func minute(of date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (UsageModel) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, observer))
    }
}
