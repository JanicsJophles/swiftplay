import ArgumentParser
import Foundation

struct FindCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Find AX elements by role and/or text. Exits non-zero if none match — usable as a test assertion."
    )

    @Option(name: [.long, .customShort("b")], help: "Bundle identifier, e.g. ai.rackmind.macos.")
    var bundleId: String?

    @Option(name: .long, help: "Process ID. Use either --bundle-id or --pid.")
    var pid: Int32?

    @Option(name: .long, help: "Filter by AX role substring, e.g. AXStaticText, AXButton.")
    var role: String?

    @Option(name: [.long, .customShort("t")], help: "Case-insensitive substring matched against value/title/description/identifier.")
    var text: String?

    @Option(name: .long, help: "Maximum tree depth to search.")
    var maxDepth: Int = 40

    @Flag(name: .long, help: "Print only the match count, not each element.")
    var count: Bool = false

    func run() throws {
        guard AccessibilityPermission.isTrusted else {
            AccessibilityPermission.printGuidance()
            AccessibilityPermission.requestTrust()
            throw ExitCode(2)
        }

        let target: TargetApp
        if let bundleId {
            guard let found = TargetApp.find(bundleId: bundleId) else {
                FileHandle.standardError.write(Data("No running app found with bundle id '\(bundleId)'.\n".utf8))
                throw ExitCode(1)
            }
            target = found
        } else if let pid {
            guard let found = TargetApp.find(pid: pid) else {
                FileHandle.standardError.write(Data("No process with pid \(pid).\n".utf8))
                throw ExitCode(1)
            }
            target = found
        } else {
            FileHandle.standardError.write(Data("Specify --bundle-id or --pid.\n".utf8))
            throw ExitCode(1)
        }

        let app = AXElement.application(pid: target.pid)
        let matches = Query.find(in: app, role: role, text: text, maxDepth: maxDepth)

        if count {
            print(matches.count)
        } else {
            for m in matches {
                var parts = [m.role]
                if let id = m.identifier, !id.isEmpty { parts.append("#\(id)") }
                if !m.text.isEmpty { parts.append("\"\(m.text)\"") }
                if let p = m.position, let s = m.size {
                    parts.append(String(format: "@(%.0f,%.0f %.0fx%.0f)", p.x, p.y, s.width, s.height))
                }
                print(parts.joined(separator: " "))
            }
        }

        // Assertion semantics: no matches → non-zero exit so `find … && …` works in scripts.
        if matches.isEmpty {
            FileHandle.standardError.write(Data("No matching elements.\n".utf8))
            throw ExitCode(1)
        }
    }
}
