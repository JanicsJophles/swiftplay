import AppKit
import ArgumentParser
import CoreGraphics
import Foundation
import SwiftplayCore

/// Internal: the long-lived process that owns the headless virtual display for a
/// test session. `launch --offscreen` spawns this detached. It moves the target
/// app's window onto a virtual display (truly invisible, still rendered &
/// capturable), then blocks until the app exits — releasing the display on the
/// way out. If the virtual display can't be created, it falls back to parking
/// the window on a secondary physical display, or tucking it into a corner.
///
/// Not meant to be run by hand, so it's hidden from `--help`.
struct HoldDisplayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hold-display",
        abstract: "Internal: hold a headless virtual display and keep a window parked on it.",
        shouldDisplay: false
    )

    @Option(name: [.long, .customShort("b")], help: "Bundle identifier of the app to park.")
    var bundleId: String

    func run() throws {
        guard let window = waitForWindow(bundleId: bundleId, timeout: 12) else {
            FileHandle.standardError.write(Data("hold-display: no window for \(bundleId)\n".utf8))
            throw ExitCode(1)
        }
        let pid = window.pid ?? -1
        let size = window.size ?? CGSize(width: 1512, height: 868)
        let config = ConfigStore.load()

        // Strategy 1: headless virtual display — true invisibility on any machine.
        // (Unless config forces a different mode.) Size it (in pixels) generously;
        // we re-read the actual point bounds afterwards to center the window.
        if config.offscreen.mode == .virtual {
            // Display sized (in points) a bit larger than the window so we can
            // center it.
            let margin = 200
            let vdWidth = Int(size.width) + margin
            let vdHeight = Int(size.height) + margin
            if let vd = VirtualDisplay(pointWidth: vdWidth, pointHeight: vdHeight, retina: config.offscreen.retina) {
                let b = vd.bounds
                let target = CGPoint(x: b.minX + max(0, (b.width - size.width) / 2),
                                     y: b.minY + max(0, (b.height - size.height) / 2))
                window.setPosition(target)

                // Select the 2× mode *after* placing the window (same point size,
                // so the window doesn't move). Scoped to this virtual display only.
                var retinaNote = ""
                if config.offscreen.retina {
                    let ok = vd.enableRetina(pointWidth: vdWidth, pointHeight: vdHeight)
                    retinaNote = ok ? " (retina 2×)" : " (retina requested but unavailable)"
                }
                FileHandle.standardError.write(Data("hold-display: parked on virtual display \(vd.displayID)\(retinaNote) — invisible\n".utf8))

                // Hold the display alive until the app goes away. The vd local stays
                // retained for the lifetime of the run loop below.
                startExitWatch(pid: pid)  // calls exit() when the app is gone
                withExtendedLifetime(vd) {
                    RunLoop.main.run()
                }
                return
            }
            FileHandle.standardError.write(Data("hold-display: virtual display unavailable, falling back\n".utf8))
        }

        // Strategy 2: park fully on a secondary physical display (config: secondary,
        // or virtual-mode fallback).
        if config.offscreen.mode != .corner, let secondary = secondaryScreenFrame() {
            let target = CGPoint(x: secondary.minX + max(0, (secondary.width - size.width) / 2),
                                 y: secondary.minY + max(0, (secondary.height - size.height) / 2))
            window.setPosition(target)
            FileHandle.standardError.write(Data("hold-display: parked on secondary display \(secondary.integral) — off your main screen\n".utf8))
            return  // physical display persists; no need to stay alive
        }

        // Strategy 3: single display — tuck the unavoidable ~40px sliver bottom-right.
        if let main = NSScreen.main?.frame {
            window.setPosition(CGPoint(x: main.maxX - 1, y: main.maxY - 1))
            FileHandle.standardError.write(Data("hold-display: tucked ~40px sliver into bottom-right corner (couldn't fully hide)\n".utf8))
        }
    }

    private func waitForWindow(bundleId: String, timeout: TimeInterval) -> AXElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                if let window = AXElement.application(pid: running.processIdentifier).windows.first {
                    return window
                }
            }
            usleep(150_000)
        }
        return nil
    }

    /// The frame of a physical display that isn't the main one, if any.
    private func secondaryScreenFrame() -> CGRect? {
        NSScreen.screens.first { $0 != NSScreen.main }?.frame
    }

    /// Poll the target pid on a background thread; exit (releasing the virtual
    /// display) once it's gone. SIGKILL of this process also releases the display
    /// via normal process teardown, so there's no way to leak it.
    private func startExitWatch(pid: pid_t) {
        Thread.detachNewThread {
            while pid > 0 && kill(pid, 0) == 0 {
                usleep(500_000)
            }
            Darwin.exit(0)
        }
    }
}
