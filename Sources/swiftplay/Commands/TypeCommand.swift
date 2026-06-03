import ArgumentParser
import Foundation

struct TypeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type literal text into the focused element of the frontmost (or named) app."
    )

    @Argument(help: "The text to type.")
    var text: String

    @Option(name: [.long, .customShort("b")], help: "Bundle id to activate before typing.")
    var bundleId: String?

    @Option(name: .long, help: "Per-character delay in milliseconds.")
    var charDelayMs: Int = 8

    @Flag(name: .long, help: "Bring the app to the front before typing. Default is background delivery via the pid (no focus steal).")
    var foreground: Bool = false

    func run() throws {
        guard AccessibilityPermission.isTrusted else {
            AccessibilityPermission.printGuidance()
            AccessibilityPermission.requestTrust()
            throw ExitCode(2)
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
                usleep(400_000) // let activation settle before posting events
            }
        }
        Keyboard.type(text, toPid: targetPid, charDelayMs: charDelayMs)
    }
}
