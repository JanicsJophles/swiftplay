import AppKit
import Foundation

struct TargetApp {
    let pid: pid_t
    let bundleId: String?
    let localizedName: String?

    static func find(bundleId: String) -> TargetApp? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard let app = apps.first else { return nil }
        return TargetApp(
            pid: app.processIdentifier,
            bundleId: app.bundleIdentifier,
            localizedName: app.localizedName
        )
    }

    static func find(pid: pid_t) -> TargetApp? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return TargetApp(
            pid: app.processIdentifier,
            bundleId: app.bundleIdentifier,
            localizedName: app.localizedName
        )
    }
}
