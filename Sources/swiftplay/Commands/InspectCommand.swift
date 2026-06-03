import ApplicationServices
import ArgumentParser
import CoreGraphics
import Foundation

struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Follow the mouse cursor and print the AX element under it. Ctrl-C to exit."
    )

    @Option(name: .long, help: "Poll interval in milliseconds.")
    var pollMs: Int = 100

    func run() throws {
        guard AccessibilityPermission.isTrusted else {
            AccessibilityPermission.printGuidance()
            AccessibilityPermission.requestTrust()
            throw ExitCode(2)
        }

        FileHandle.standardError.write(
            Data("Move your cursor over UI elements. Ctrl-C to exit.\n\n".utf8)
        )

        let systemWide = AXElement.systemWide
        var lastLine = ""

        while true {
            let location = CGEvent(source: nil)?.location ?? .zero
            if let elem = systemWide.element(at: location) {
                let line = format(elem, at: location)
                if line != lastLine {
                    print(line)
                    lastLine = line
                }
            }
            usleep(UInt32(pollMs * 1000))
        }
    }

    private func format(_ elem: AXElement, at point: CGPoint) -> String {
        var parts: [String] = []
        parts.append(String(format: "(%.0f,%.0f)", point.x, point.y))
        parts.append(elem.role ?? "?")
        if let sub = elem.subrole { parts.append("(\(sub))") }
        if let id = elem.identifier, !id.isEmpty { parts.append("#\(id)") }
        if let t = elem.title, !t.isEmpty { parts.append("title=\"\(t)\"") }
        if let l = elem.label, !l.isEmpty { parts.append("desc=\"\(l)\"") }
        if let pid = elem.pid { parts.append("pid=\(pid)") }
        return parts.joined(separator: " ")
    }
}
