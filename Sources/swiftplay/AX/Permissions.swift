import ApplicationServices
import CoreGraphics
import Foundation

/// Screen Recording is a *separate* TCC grant from Accessibility — ScreenCaptureKit
/// needs it, AX queries don't. Like Accessibility, when swiftplay runs via the
/// terminal the grant attaches to the terminal app, not the binary.
enum ScreenRecordingPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func printGuidance() {
        let message = """
        swiftplay needs Screen Recording permission to capture windows.

        This is separate from Accessibility. When you run swiftplay from a
        terminal, the permission attaches to your TERMINAL APP (Terminal.app,
        iTerm2, WezTerm, …) — not to the swiftplay binary.

        Open System Settings → Privacy & Security → Screen Recording,
        enable your terminal app, then re-run this command. (macOS may ask you
        to quit and reopen the terminal for the grant to take effect.)

        """
        FileHandle.standardError.write(Data(message.utf8))
    }
}

enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func printGuidance() {
        let message = """
        swiftplay needs Accessibility permission to inspect other apps.

        When you run swiftplay via `swift run` or directly from a terminal,
        the permission is granted to your TERMINAL APP (Terminal.app, iTerm2,
        WezTerm, etc.) — not to the swiftplay binary itself.

        Open System Settings → Privacy & Security → Accessibility,
        and enable your terminal app.

        Once swiftplay ships as a signed binary, it will get its own permission row.

        After granting, re-run this command.

        """
        FileHandle.standardError.write(Data(message.utf8))
    }
}
