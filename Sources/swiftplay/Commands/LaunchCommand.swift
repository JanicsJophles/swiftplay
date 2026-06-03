import AppKit
import ArgumentParser
import Foundation

struct LaunchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch the target app hidden + in the background (headless-style) so it never appears on screen. swiftplay then drives it via the pid + AX."
    )

    @Option(name: [.long, .customShort("b")], help: "Bundle identifier to resolve, e.g. ai.rackmind.macos.")
    var bundleId: String?

    @Option(name: .long, help: "Path to the .app bundle. Use either --bundle-id or --path.")
    var path: String?

    @Flag(name: .long, help: "Launch normally (visible + foreground) instead of hidden/background.")
    var show: Bool = false

    func run() throws {
        let appPath: String
        if let path {
            appPath = path
        } else if let bundleId {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                FileHandle.standardError.write(Data("Could not resolve a path for bundle id '\(bundleId)'.\n".utf8))
                throw ExitCode(1)
            }
            appPath = url.path
        } else {
            FileHandle.standardError.write(Data("Specify --bundle-id or --path.\n".utf8))
            throw ExitCode(1)
        }

        // `open -g` = don't bring to foreground; `-j` = launch hidden. Together the
        // app starts off-screen and keeps your current app focused. AX queries and
        // CGEvent.postToPid still reach a hidden app, so swiftplay drives it fully
        // headless. (Mouse `click` and menu key-equivalents still need --show, since
        // those require a visible/frontmost window.)
        var args = ["open"]
        if !show { args += ["-g", "-j"] }
        args.append(appPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = Array(args.dropFirst())
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            FileHandle.standardError.write(Data("`open` failed for \(appPath) (status \(proc.terminationStatus)).\n".utf8))
            throw ExitCode(proc.terminationStatus)
        }
        let mode = show ? "visible" : "hidden/background"
        FileHandle.standardError.write(Data("Launched \(appPath) (\(mode)).\n".utf8))
    }
}
