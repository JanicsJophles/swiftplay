import AppKit
import ArgumentParser
import Foundation
import SwiftplayCore

struct TargetApp {
    let pid: pid_t
    let bundleId: String?
    let localizedName: String?

    /// Resolve a running target from an explicit `--bundle-id`/`--pid`, falling
    /// back to the configured `defaults.bundleId`. Prints guidance and throws an
    /// ExitCode on failure, so commands can `let app = try TargetApp.resolve(...)`.
    static func resolve(bundleId: String?, pid: Int32?) throws -> TargetApp {
        if let pid {
            guard let found = find(pid: pid) else {
                FileHandle.standardError.write(Data("No process with pid \(pid).\n".utf8))
                throw ExitCode(1)
            }
            return found
        }
        guard let resolvedBundleId = bundleId ?? ConfigStore.load().defaults.bundleId else {
            FileHandle.standardError.write(Data("Specify --bundle-id or --pid (or set a default: swiftplay config set defaults.bundleId <id>).\n".utf8))
            throw ExitCode(1)
        }
        guard let found = find(bundleId: resolvedBundleId) else {
            FileHandle.standardError.write(Data("No running app found with bundle id '\(resolvedBundleId)'.\n".utf8))
            throw ExitCode(1)
        }
        return found
    }

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
