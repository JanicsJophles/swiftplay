import CoreGraphics
import Foundation
import ScreenCaptureKit

enum CaptureError: Error, CustomStringConvertible {
    case noWindows(pid: pid_t)
    case noMatch(titleContains: String, available: [String])
    case captureFailed(String)

    var description: String {
        switch self {
        case .noWindows(let pid):
            return "Target pid \(pid) has no capturable windows. If you launched it with `swiftplay launch` (hidden/background), the window server may have no backing store to capture — relaunch with `--show` for a visual pass."
        case .noMatch(let needle, let available):
            let list = available.isEmpty ? "(none with titles)" : available.map { "  • \($0)" }.joined(separator: "\n")
            return "No window title contained \"\(needle)\". Windows on the target:\n\(list)"
        case .captureFailed(let why):
            return "ScreenCaptureKit capture failed: \(why)"
        }
    }
}

/// ScreenCaptureKit window capture.
///
/// We capture a single *desktop-independent* window (no shadow, no wallpaper
/// behind it) belonging to the target pid, at native pixel resolution. SCK is
/// the supported substrate — `CGWindowListCreateImage` was obsoleted in macOS 15.
///
/// Capture works against off-screen windows (`onScreenWindowsOnly: false`) as
/// long as the window server still holds a backing store, so a window on
/// another Space or behind other apps still captures. A window that was *never*
/// shown (e.g. an app launched fully hidden via `open -j`) may capture blank or
/// not appear at all — see `CaptureError.noWindows`.
enum Capture {
    /// The metadata of the window that actually got captured, for honest logging.
    struct Result {
        let image: CGImage
        let windowTitle: String
        let pointSize: CGSize
    }

    /// Synchronous bridge over SCK's async API. The root command is a plain
    /// `ParsableCommand`, so we block the calling thread on a semaphore while the
    /// capture runs on the Swift concurrency pool (a different thread — no
    /// deadlock).
    static func window(pid: pid_t, titleContains: String?) throws -> Result {
        let sema = DispatchSemaphore(value: 0)
        var outcome: Swift.Result<Result, Error>!
        Task {
            do {
                outcome = .success(try await captureWindow(pid: pid, titleContains: titleContains))
            } catch {
                outcome = .failure(error)
            }
            sema.signal()
        }
        // Bound the wait so a stalled ScreenCaptureKit call can't hang the caller
        // (and, in a sweep, freeze the whole run holding the lock).
        guard sema.wait(timeout: .now() + 30) == .success else {
            throw CaptureError.captureFailed("ScreenCaptureKit did not return within 30s")
        }
        return try outcome.get()
    }

    /// Backing scale of the display the window sits on, derived from CGS so it's
    /// correct for physical retina (2×), external (1×), and the headless virtual
    /// display alike — capturing at the wrong scale would up/down-sample.
    private static func scale(forWindowAt frame: CGRect) -> CGFloat {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(center, 1, &display, &count) == .success, count > 0,
              let mode = CGDisplayCopyDisplayMode(display) else { return 2 }
        // pixelWidth is the true backing-store width; width is in points. Their
        // ratio is the backing scale (2 on retina, 1 elsewhere). CGDisplayPixelsWide
        // returns *points*, not pixels — using it here was the 1×-on-retina bug.
        guard mode.width > 0 else { return 2 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    private static func captureWindow(pid: pid_t, titleContains: String?) async throws -> Result {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.captureFailed("\(error.localizedDescription) (Screen Recording permission may be missing)")
        }

        let mine = content.windows.filter { $0.owningApplication?.processID == pid }
        guard !mine.isEmpty else { throw CaptureError.noWindows(pid: pid) }

        let window: SCWindow
        if let needle = titleContains, !needle.isEmpty {
            let lowered = needle.lowercased()
            let matches = mine.filter { ($0.title ?? "").lowercased().contains(lowered) }
            guard let best = largestByArea(matches) else {
                throw CaptureError.noMatch(titleContains: needle, available: mine.compactMap { $0.title }.filter { !$0.isEmpty })
            }
            window = best
        } else {
            // No filter: capture the main window — the largest by area, which
            // skips tooltip/helper windows that SwiftUI apps spawn.
            window = largestByArea(mine)!
        }

        let scale = scale(forWindowAt: window.frame)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((window.frame.width * scale).rounded()))
        config.height = max(1, Int((window.frame.height * scale).rounded()))
        config.showsCursor = false
        config.scalesToFit = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }

        return Result(
            image: image,
            windowTitle: window.title ?? "(untitled)",
            pointSize: window.frame.size
        )
    }

    private static func largestByArea(_ windows: [SCWindow]) -> SCWindow? {
        windows.max { a, b in
            (a.frame.width * a.frame.height) < (b.frame.width * b.frame.height)
        }
    }
}
