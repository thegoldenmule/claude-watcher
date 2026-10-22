import AppKit

/// Helpers for finding and activating already-running apps. Nothing here launches an app.
enum AppActivation {
    static let ghosttyBundleID = "com.mitchellh.ghostty"
    static let appleTerminalBundleID = "com.apple.Terminal"

    static func runningApp(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }
    }

    /// If ClaudeWatcher is currently active, hand activation to `app` so its own activation
    /// request (from an AppleScript `focus`/`activate`) is honoured under macOS 14+ cooperative
    /// activation. No-op when we aren't active (e.g. non-activating panel).
    @MainActor
    static func yieldActivation(to app: NSRunningApplication) {
        guard let nsApp = NSApp, nsApp.isActive else { return }
        nsApp.yieldActivation(to: app)
    }

    /// Activates an already-running app (frontmost window only).
    @MainActor
    @discardableResult
    static func activate(_ app: NSRunningApplication) -> Bool {
        yieldActivation(to: app)
        return app.activate(from: NSRunningApplication.current, options: [])
            || app.activate(options: [])
    }

    /// Walks up the process tree from `pid` and returns the first ancestor that is a regular
    /// (Dock) app, e.g. the terminal emulator hosting a CLI process.
    static func hostingApp(forPID pid: Int32) -> NSRunningApplication? {
        var current = pid
        var seen = Set<Int32>()
        while current > 1, seen.insert(current).inserted {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let parent = parentPID(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
