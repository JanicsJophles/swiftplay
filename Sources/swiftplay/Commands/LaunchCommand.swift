import AppKit
import ArgumentParser
import Foundation

struct LaunchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch the target app hidden + in the background (headless-style) so it never appears on screen. swiftplay then drives it via the pid + AX.",
        discussion: """
        Default is hidden/background: AX queries and CGEvent input still reach the
        app, but its window is never rendered — so `screenshot` has no backing
        store to capture. For a visual pass use --offscreen: the window renders
        (capturable) but is parked off-screen and set to alpha 0, so it's fully
        invisible and never steals focus while still capturing real content. Use
        --show only when you actually want to watch it.
        """
    )

    @Option(name: [.long, .customShort("b")], help: "Bundle identifier to resolve, e.g. ai.rackmind.macos.")
    var bundleId: String?

    @Option(name: .long, help: "Path to the .app bundle. Use either --bundle-id or --path.")
    var path: String?

    @Flag(name: .long, help: "Launch normally (visible + foreground) instead of hidden/background.")
    var show: Bool = false

    @Flag(name: .long, help: "Render the window but make it invisible (off-screen + alpha 0) — focus-preserving and capturable by `screenshot`.")
    var offscreen: Bool = false

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

        if offscreen, !AccessibilityPermission.isTrusted {
            // --offscreen has to move the window via AX after launch.
            AccessibilityPermission.printGuidance()
            AccessibilityPermission.requestTrust()
            throw ExitCode(2)
        }

        // `open -g` = don't bring to foreground; `-j` = launch hidden.
        //   • default       → `-g -j`: off-screen + focus preserved, but NOT rendered.
        //   • --offscreen    → `-g`   : rendered + focus preserved; we then move it off-display.
        //   • --show         → (none) : visible + foreground.
        // AX queries and CGEvent.postToPid reach the app in all three modes; mouse
        // `click` and menu key-equivalents still need a visible/frontmost window.
        var args: [String] = []
        if show {
            // visible + foreground
        } else if offscreen {
            args += ["-g"]
        } else {
            args += ["-g", "-j"]
        }
        args.append(appPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = args
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            FileHandle.standardError.write(Data("`open` failed for \(appPath) (status \(proc.terminationStatus)).\n".utf8))
            throw ExitCode(proc.terminationStatus)
        }

        if offscreen {
            guard let resolvedBundleId = bundleId ?? Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier else {
                FileHandle.standardError.write(Data("Launched \(appPath), but couldn't resolve its bundle id to park it off-screen.\n".utf8))
                return
            }
            try spawnHolder(bundleId: resolvedBundleId)
            // Give the detached holder a moment to find the window and move it
            // off-screen before we return and the caller starts driving.
            usleep(2_500_000)
            FileHandle.standardError.write(Data("Launched \(appPath) (offscreen — headless holder running for \(resolvedBundleId)).\n".utf8))
            return
        }

        let mode = show ? "visible" : "hidden/background"
        FileHandle.standardError.write(Data("Launched \(appPath) (\(mode)).\n".utf8))
    }

    /// Spawn `swiftplay hold-display` detached. It owns the virtual display and
    /// keeps the window parked for the whole session, outliving this process. We
    /// inherit stderr so its strategy line (virtual / secondary / corner) is
    /// visible, but don't wait on it.
    private func spawnHolder(bundleId: String) throws {
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        holder.arguments = ["hold-display", "--bundle-id", bundleId]
        holder.standardError = FileHandle.standardError
        try holder.run()
    }
}
