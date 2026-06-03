import AppKit
import ArgumentParser
import Foundation

struct ClickCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Find the first element matching role/text and click its center."
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

    @Flag(name: .long, help: "Activate via the element's AX press action instead of a mouse click — works in the background, no cursor movement or foreground needed.")
    var ax: Bool = false

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

        // Mouse mode needs the target frontmost so the click hit-tests against it.
        // AX-press mode delivers straight to the element, so leave focus alone.
        if !ax {
            NSRunningApplication(processIdentifier: target.pid)?.activate(options: [.activateAllWindows])
            usleep(300_000)
        }

        let app = AXElement.application(pid: target.pid)
        let matches = Query.find(in: app, role: role, text: text, maxDepth: maxDepth)
        guard let first = matches.first else {
            FileHandle.standardError.write(Data("No matching element.\n".utf8))
            throw ExitCode(1)
        }

        if ax {
            print("AX-pressing \(first.role) \"\(first.text)\"")
            guard first.element.perform(kAXPressAction as String) else {
                FileHandle.standardError.write(Data("Element does not support AXPress (try mouse click without --ax).\n".utf8))
                throw ExitCode(1)
            }
        } else {
            guard let pos = first.position, let size = first.size else {
                FileHandle.standardError.write(Data("Matched element has no geometry to click.\n".utf8))
                throw ExitCode(1)
            }
            let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
            print("clicking \(first.role) \"\(first.text)\" @ (\(Int(center.x)),\(Int(center.y)))")
            Mouse.click(at: center)
        }
    }
}
