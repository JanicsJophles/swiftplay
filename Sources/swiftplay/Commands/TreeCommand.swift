import ArgumentParser
import Foundation

struct TreeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "Print the accessibility tree of a running app."
    )

    @Option(name: [.long, .customShort("b")], help: "Bundle identifier, e.g. ai.rackmind.macos.")
    var bundleId: String?

    @Option(name: .long, help: "Process ID. Use either --bundle-id or --pid.")
    var pid: Int32?

    @Option(name: .long, help: "Maximum tree depth to print.")
    var maxDepth: Int = 30

    @Flag(name: .long, help: "Show position and size for each element.")
    var showGeometry: Bool = false

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

        print("# \(target.localizedName ?? "?") (\(target.bundleId ?? "?"), pid \(target.pid))")

        let app = AXElement.application(pid: target.pid)
        printTree(
            app,
            depth: 0,
            maxDepth: maxDepth,
            prefix: "",
            isLast: true,
            showGeometry: showGeometry
        )
    }
}

private func printTree(
    _ elem: AXElement,
    depth: Int,
    maxDepth: Int,
    prefix: String,
    isLast: Bool,
    showGeometry: Bool
) {
    let connector = depth == 0 ? "" : (isLast ? "└── " : "├── ")
    print(prefix + connector + describe(elem, showGeometry: showGeometry))

    if depth >= maxDepth { return }

    let children = elem.children
    let nextPrefix: String
    if depth == 0 {
        nextPrefix = ""
    } else {
        nextPrefix = prefix + (isLast ? "    " : "│   ")
    }
    for (i, child) in children.enumerated() {
        printTree(
            child,
            depth: depth + 1,
            maxDepth: maxDepth,
            prefix: nextPrefix,
            isLast: i == children.count - 1,
            showGeometry: showGeometry
        )
    }
}

private func describe(_ elem: AXElement, showGeometry: Bool) -> String {
    var parts: [String] = []
    parts.append(elem.role ?? "?")
    if let sub = elem.subrole { parts.append("(\(sub))") }
    if let id = elem.identifier, !id.isEmpty { parts.append("#\(id)") }
    if let t = elem.title, !t.isEmpty { parts.append("title=\(quoted(t))") }
    if let l = elem.label, !l.isEmpty { parts.append("desc=\(quoted(l))") }
    if let v = elem.value, !v.isEmpty { parts.append("value=\(quoted(v))") }
    if !elem.isEnabled { parts.append("[disabled]") }
    if showGeometry, let p = elem.position, let s = elem.size {
        parts.append(String(format: "@(%.0f,%.0f %.0fx%.0f)", p.x, p.y, s.width, s.height))
    }
    return parts.joined(separator: " ")
}

private func quoted(_ s: String) -> String {
    let clipped = s.count > 60 ? String(s.prefix(57)) + "..." : s
    return "\"\(clipped.replacingOccurrences(of: "\"", with: "\\\""))\""
}
