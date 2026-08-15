import AppKit
import Foundation

/// Tracks the user's most recently focused non-target app. If the test target
/// activates itself during a background launch, this tells the runtime where to
/// return focus without undoing a focus change the user made while the test was
/// starting.
struct FrontmostAppTracker {
    private(set) var lastNonTargetPID: pid_t?

    init(initialPID: pid_t?) {
        lastNonTargetPID = initialPID
    }

    mutating func observe(frontmostPID: pid_t?, targetPID: pid_t) -> pid_t? {
        guard let frontmostPID else { return nil }
        if frontmostPID != targetPID {
            lastNonTargetPID = frontmostPID
            return nil
        }
        guard lastNonTargetPID != targetPID else { return nil }
        return lastNonTargetPID
    }
}

enum FocusPreserver {
    /// Defensively enforces SwiftPlay's background-launch contract. Most apps
    /// respect `open -g`/`-j`, but some call `NSApp.activate` from their launch
    /// delegate. Monitor the short startup window and immediately return focus
    /// to the user's latest non-target app if that happens.
    static func guardBackgroundLaunch(
        bundleId: String?,
        initialFrontmost: NSRunningApplication?,
        duration: TimeInterval,
        hideTarget: Bool
    ) {
        guard let bundleId else { return }
        var tracker = FrontmostAppTracker(initialPID: initialFrontmost?.processIdentifier)
        let deadline = Date().addingTimeInterval(duration)

        while Date() < deadline {
            let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
            let targetPID = target?.processIdentifier
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

            if let targetPID,
               let restorePID = tracker.observe(frontmostPID: frontmostPID, targetPID: targetPID),
               let restore = NSRunningApplication(processIdentifier: restorePID),
               !restore.isTerminated {
                restore.activate(options: [])
            }

            // `-j` asks Launch Services to hide the app. Re-assert it because a
            // target can unhide/order its own window without becoming frontmost.
            if hideTarget, let target, !target.isHidden {
                target.hide()
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
