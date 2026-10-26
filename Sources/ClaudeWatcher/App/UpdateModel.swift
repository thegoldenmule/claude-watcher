import AppKit
import ClaudeWatcherCore
import os

/// The running version and whether a newer release is out, for the menu bar extra.
/// Asks GitHub's `releases/latest` (unauthenticated, see `UpdateChecker`) shortly after launch
/// (unless the cached answer is under an hour old), then whenever `UpdateSchedule` says it's
/// due: a 15 min wall-clock tick (so sleep/wake is handled) and every menu open. Failures retry
/// quietly. Only links to the release page; never downloads or installs.
/// The last answer is cached in UserDefaults (`updateCheckCache`) so the menu has a state at
/// launch. Demo mode never touches the network or the cache (see `DemoMode.updatePreview`).
@MainActor
@Observable
final class UpdateModel {
    let app = AppVersionInfo.main
    private(set) var cache: UpdateCache
    private(set) var isChecking = false
    private(set) var lastFailure: UpdateCheckFailure?

    var state: UpdateMenuState {
        UpdateMenuState.resolve(current: app.version, cache: cache, isChecking: isChecking, lastFailure: lastFailure)
    }

    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var menuObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Update")

    private static let cacheKey = "updateCheckCache"
    private static let launchDelay: Duration = .seconds(10)
    private static let tick: Duration = .seconds(15 * 60)

    init(isDemo: Bool) {
        self.isDemo = isDemo
        if isDemo {
            let preview = DemoMode.updatePreview(current: app.version)
            cache = preview.cache
            lastFailure = preview.failure
            isChecking = preview.checking
        } else {
            cache = Self.loadCache()
        }
    }

    /// Starts the schedule (never in demo mode, or without a version to compare).
    func start() {
        guard !isDemo, app.version != nil, scheduler == nil else { return }
        logger.notice("""
            \(self.app.displayString, privacy: .public); cached latest \
            \(self.cache.latest?.tag ?? "none", privacy: .public) checked \
            \(self.cache.checkedAt.map { "\($0)" } ?? "never", privacy: .public)
            """)
        scheduler = Task { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            if let self, UpdateSchedule.isDueAtLaunch(cache: cache, now: .now) { await check() }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                await self?.checkIfDue()
            }
        }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.checkIfDue() }
            }
        }
    }

    func stop() {
        scheduler?.cancel()
        scheduler = nil
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        menuObserver = nil
    }

    /// The menu's "Check for Updates": checks now, whatever the schedule says.
    func checkNow() {
        Task { await check() }
    }

    func openReleasePage(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.pageURL)
    }

    private func checkIfDue() async {
        guard scheduler != nil, UpdateSchedule.isDue(cache: cache, lastFailure: lastFailure, now: .now) else { return }
        await check()
    }

    private func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        if isDemo {
            // Show the "Checking…" state briefly; the preview state stays as it was.
            try? await Task.sleep(for: .seconds(1))
            return
        }
        let cache = cache, userAgent = "ClaudeWatcher/\(app.shortVersion ?? "dev")"
        let result = await Task.detached(priority: .utility) {
            await UpdateChecker.check(cache: cache, userAgent: userAgent)
        }.value
        switch result {
        case .success(let updated):
            self.cache = updated
            lastFailure = nil
            Self.saveCache(updated)
            logger.notice("""
                update check: latest \(updated.latest?.tag ?? "none", privacy: .public), \
                running \(self.app.shortVersion ?? "?", privacy: .public)
                """)
        case .failure(let failure):
            lastFailure = failure
            let retry = UpdateSchedule.nextCheck(cache: self.cache, lastFailure: failure)
            logger.error("""
                update check failed: \(failure.reason, privacy: .public); retrying after \
                \(retry, privacy: .public)
                """)
        }
    }

    private static func loadCache() -> UpdateCache {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode(UpdateCache.self, from: data) else { return UpdateCache() }
        return cache
    }

    private static func saveCache(_ cache: UpdateCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
