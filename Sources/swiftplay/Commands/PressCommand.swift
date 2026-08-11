import AppKit
import ArgumentParser
import Foundation
import SwiftplayCore

struct PressCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "press",
        abstract: "Press a key or chord, e.g. down, tab, return, cmd+k, cmd+shift+p.",
        discussion: """
        Keys are delivered straight to the target process via its pid, so the app \
        never has to be frontmost and your focus is left alone.

        `--foreground` is the exception, and it is opt-in: AppKit only routes menu \
        key-equivalents (⌘K and friends) through NSApplication for the frontmost \
        app, so those chords have to be posted to the global event tap with the \
        target activated. Because a global post goes wherever focus actually is, \
        `--foreground` now REQUIRES a resolved target and verifies the target \
        really came forward before posting — previously a `--foreground` press with \
        no `--bundle-id` sent the chord into whatever window you were using.
        """
    )

    @Argument(help: "Key or chord: a named key (down/tab/return/escape/space/delete/arrows), a letter/digit, or a chord like cmd+k.")
    var key: String

    @Option(name: [.long, .customShort("b")], help: "Bundle id of the target app. Falls back to defaults.bundleId.")
    var bundleId: String?

    @Option(name: [.customLong("repeat"), .customLong("repeat-count")], help: "Press the key this many times.")
    var repeatCount: Int = 1

    @Option(name: .long, help: "Delay between repeated presses, in milliseconds.")
    var delayMs: Int = 120

    @Flag(name: .long, help: "Bring the app to the front and post to the global tap, so menu key-equivalents (cmd+k) reach NSApplication. Requires a target. Default is background delivery via the pid (no focus steal).")
    var foreground: Bool = false

    func validate() throws {
        // `--repeat 0` used to press once, via `max(1, repeatCount)`. A script
        // computing the count from a list length ("press down --repeat $n") then
        // moved the selection off the intended row whenever the list was empty.
        guard repeatCount >= 0 else {
            throw ValidationError("--repeat must be zero or greater.")
        }
    }

    func run() throws {
        guard AccessibilityPermission.isTrusted else {
            AccessibilityPermission.printGuidance()
            AccessibilityPermission.requestTrust()
            throw ExitCode(2)
        }
        guard Keyboard.parseChord(key) != nil else {
            FileHandle.standardError.write(Data("Could not parse key/chord '\(key)'. Use a named key, a letter/digit, or a chord like cmd+k.\n".utf8))
            throw ExitCode(1)
        }

        // Honour the configured default target the same way screenshot does, so
        // fewer presses end up aimed at "whoever is frontmost".
        let resolvedBundleId = bundleId ?? ConfigStore.load().defaults.bundleId
        var targetPid: pid_t?
        if let resolvedBundleId {
            guard let target = TargetApp.find(bundleId: resolvedBundleId) else {
                FileHandle.standardError.write(Data("No running app with bundle id '\(resolvedBundleId)'.\n".utf8))
                throw ExitCode(1)
            }
            targetPid = target.pid
        }

        if foreground {
            // A global post lands wherever focus is. Without a target we cannot
            // even name the app that would receive it, so refuse rather than
            // fire a chord like cmd+w into the user's editor.
            guard let targetPid, let resolvedBundleId else {
                FileHandle.standardError.write(Data(
                    "--foreground needs a target: pass --bundle-id (or set defaults.bundleId). Without one the chord is posted to the global event tap and lands in whatever window currently has focus.\n".utf8))
                throw ExitCode(1)
            }
            guard let app = NSRunningApplication(processIdentifier: targetPid) else {
                FileHandle.standardError.write(Data("Target process \(targetPid) is gone.\n".utf8))
                throw ExitCode(1)
            }
            if !app.isActive {
                // `[]` raises only the key window; `.activateAllWindows` would
                // hoist every window of the target above the user's.
                app.activate(options: [])
            }
            guard ClickCommand.waitUntilFrontmost(pid: targetPid, timeout: 1.5) else {
                FileHandle.standardError.write(Data(
                    "Could not bring '\(resolvedBundleId)' to the front; refusing to post '\(key)' to the global tap where it would hit another app.\n".utf8))
                throw ExitCode(1)
            }
        } else if targetPid == nil {
            FileHandle.standardError.write(Data(
                "Warning: no target resolved — '\(key)' goes to the frontmost app. Pass --bundle-id or set defaults.bundleId to aim it.\n".utf8))
        }

        // Foreground → post to the global HID tap so menu/command key-equivalents
        // (e.g. ⌘K) route through NSApplication's normal dispatch. Background →
        // postToPid, which reaches the focused field but not the menu handler.
        let postPid: pid_t? = foreground ? nil : targetPid
        for i in 0 ..< repeatCount {
            Keyboard.press(key, toPid: postPid)
            if i < repeatCount - 1 { usleep(UInt32(delayMs * 1000)) }
        }
    }
}
