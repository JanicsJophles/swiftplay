import ArgumentParser
import Foundation

struct PressCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "press",
        abstract: "Press a key or chord, e.g. down, tab, return, cmd+k, cmd+shift+p."
    )

    @Argument(help: "Key or chord: a named key (down/tab/return/escape/space/delete/arrows), a letter/digit, or a chord like cmd+k.")
    var key: String

    @Option(name: [.long, .customShort("b")], help: "Bundle id to activate before pressing.")
    var bundleId: String?

    @Option(name: [.customLong("repeat"), .customLong("repeat-count")], help: "Press the key this many times.")
    var repeatCount: Int = 1

    @Option(name: .long, help: "Delay between repeated presses, in milliseconds.")
    var delayMs: Int = 120

    @Flag(name: .long, help: "Bring the app to the front before pressing. Default is background delivery via the pid (no focus steal).")
    var foreground: Bool = false

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
        var targetPid: pid_t?
        if let bundleId {
            guard let target = TargetApp.find(bundleId: bundleId) else {
                FileHandle.standardError.write(Data("No running app with bundle id '\(bundleId)'.\n".utf8))
                throw ExitCode(1)
            }
            targetPid = target.pid
            if foreground {
                Keyboard.activate(bundleId: bundleId)
                usleep(400_000)
            }
        }
        // Foreground → post to the global HID tap so menu/command key-equivalents
        // (e.g. ⌘K) route through NSApplication's normal dispatch. Background →
        // postToPid, which reaches the focused field but not the menu handler.
        let postPid: pid_t? = foreground ? nil : targetPid
        for i in 0 ..< max(1, repeatCount) {
            Keyboard.press(key, toPid: postPid)
            if i < repeatCount - 1 { usleep(UInt32(delayMs * 1000)) }
        }
    }
}
