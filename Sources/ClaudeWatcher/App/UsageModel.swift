import AppKit
import ClaudeWatcherCore
import os

/// Plan usage for the menu bar extra: owns the `UsageStore`, a minute clock, the
/// "Show Usage in Menu Bar" pref (UserDefaults `menuBarUsage`, default on; not persisted in
/// demo mode) and the system sleep/wake handling.
///
/// - Sleep/wake: will-sleep suspends the store's loops; did-wake resumes them (each source
///   polls ~5 s later, or at its own later deadline). A did-wake that never comes is covered by
///   the tick: `pollOverdue` resumes a suspension older than 5 minutes.
/// - Clock: `now` ticks every minute (a TimelineView in a MenuBarExtra label isn't
///   re-evaluated), on wake and when a menu opens, so a window whose reset passed shows 0.
///   It's truncated to the minute and only assigned when the minute changed, so repeated
///   ticks and menu opens within a minute don't re-render the label image (a reset passing
///   mid-minute shows at the next minute). Each tick also polls any source whose timer is
///   overdue (`UsageStore.pollOverdue`).
/// - No App Nap activity: holding one would keep the whole app (the 2 s session poll, panel
///   timers) out of App Nap. Usage only changes on a minutes scale, deadlines are wall-clock
///   and the minute tick and menu open catch up on any drift.
@MainActor
@Observable
final class UsageModel {
    let store: UsageStore
    /// The minute clock the display rules are evaluated at.
    private(set) var now = UsageModel.minute(of: Date())
    var showInMenuBar: Bool {
        didSet {
            guard !isDemo, showInMenuBar != oldValue else { return }
            UserDefaults.standard.set(showInMenuBar, forKey: Self.prefKey)
        }
    }

    /// Every agent's meter (hidden agents left out), in source order.
    var meters: [UsageMeter] {
        UsageDisplay.meters(store.usage, agents: store.agents, now: now)
    }

    /// The meters for the status item: none when the pref is off.
    var menuBarMeters: [UsageMeter] { showInMenuBar ? meters : [] }

    /// The menu's disabled info lines, agent by agent.
    var menuLines: [String] {
        store.agents.flatMap { agent in
            store.usage[agent].map { UsageDisplay.menuLines(for: $0, now: now) } ?? []
        }
    }

    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Usage")

    private static let prefKey = "menuBarUsage"

    init(sources: [any UsageSource], isDemo: Bool, showInMenuBar demoShowInMenuBar: Bool = true) {
        // A dark wake (Power Nap) keeps the display asleep: never end a stuck suspension then.
        // An offline main display (-1, e.g. headless) also counts as not awake; did-wake still resumes.
        store = UsageStore(sources: sources, isFullWake: { CGDisplayIsAsleep(CGMainDisplayID()) == 0 })
        self.isDemo = isDemo
        showInMenuBar = isDemo
            ? demoShowInMenuBar
            : UserDefaults.standard.object(forKey: Self.prefKey) as? Bool ?? true
    }

    /// Starts polling, the minute clock and the sleep/wake and menu observers. Idempotent.
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
        observe(.default, NSMenu.didBeginTrackingNotification) { model in model.tick() }
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

    private func tick() {
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
