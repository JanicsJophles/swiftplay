import ApplicationServices
import Foundation

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
