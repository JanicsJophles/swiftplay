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

        let resolvedBundleId = bundleId ?? Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
        let initialFrontmost = NSWorkspace.shared.frontmostApplication

        if offscreen, !AccessibilityPermission.isTrusted {
            // --offscreen has to move the window via AX after launch.
            AccessibilityPermission.printGuidance()
            AccessibilityPermission.requestTrust()
            throw ExitCode(2)
        }

        // A non-foreground launch (`open -g`) never *activates* the app, and a
        // SwiftUI `WindowGroup`'s default window is created on first activation —
        // so on `-g`/`-g -j` the only path that yields a content window is macOS
        // *state restoration*. When a code change alters the mangled type name of
        // the window's content (most scene-level modifier edits), restoration
        // finds no matching scene and silently creates nothing: the app comes up
        // menu-bar-only (a 1512×33 sliver), the AX tree is empty, and `screenshot`
        // captures a tiny blank placeholder (~15 KB). This is the flake behind
        // RAC-432 — it presents as "focus stayed elsewhere" because the app never
        // came forward to build its window. Suppressing restoration forces the
        // default-window path to run even without activation, so the real content
        // window (e.g. 1200×800) renders and captures. Harmless for `--show`
        // (foreground activation builds the window anyway), so we only set it for
        // the headless modes; the caller is expected to clear it after the run
        // (the smoke scripts' cleanup trap does). See examples/rackmind-macos
        // FINDINGS.md "Gotcha 4".
        if !show, let restorationBundleId = resolvedBundleId {
            suppressWindowRestoration(bundleId: restorationBundleId)
        } else if show, let restorationBundleId = resolvedBundleId {
            clearWindowRestorationSuppression(bundleId: restorationBundleId)
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

        // `/usr/bin/open` only confirms that Launch Services accepted the
        // request. It can return before a SwiftUI app creates its first window,
        // and reopening an already-running hidden app does not reliably unhide
        // or activate it. For the visible mode, explicitly restore foreground
        // state while waiting for AX to expose a real content window. This gives
        // `launch --show` deterministic semantics even after a headless run.
        if show {
            requestApplicationActivation(bundleId: resolvedBundleId)
            guard let resolvedBundleId, waitForWindow(bundleId: resolvedBundleId, timeout: 12) else {
                FileHandle.standardError.write(Data("Launched \(appPath), but no app window became available within 12 seconds.\n".utf8))
                throw ExitCode(1)
            }
        }

        if offscreen {
            guard let resolvedBundleId else {
                FileHandle.standardError.write(Data("Launched \(appPath), but couldn't resolve its bundle id to park it off-screen.\n".utf8))
                return
            }
            try spawnHolder(bundleId: resolvedBundleId)
            // Give the detached holder time to park the window while defending
            // the user's foreground app from targets that activate themselves.
            FocusPreserver.guardBackgroundLaunch(
                bundleId: resolvedBundleId,
                initialFrontmost: initialFrontmost,
                duration: 2.5,
                hideTarget: false
            )
            FileHandle.standardError.write(Data("Launched \(appPath) (offscreen — headless holder running for \(resolvedBundleId)).\n".utf8))
            return
        }

        if !show {
            FocusPreserver.guardBackgroundLaunch(
                bundleId: resolvedBundleId,
                initialFrontmost: initialFrontmost,
                duration: 1.25,
                hideTarget: true
            )
        }

        let mode = show ? "visible" : "hidden/background"
        FileHandle.standardError.write(Data("Launched \(appPath) (\(mode)).\n".utf8))
    }

    /// Write `ApplePersistenceIgnoreState = true` into the target app's defaults
    /// domain so its next launch ignores stale saved window state and runs the
    /// default-window code path (which, for a `WindowGroup`, builds the content
    /// window). Done via `/usr/bin/defaults` so it lands in the *app's* domain,
    /// not swiftplay's own. Best-effort: a failure here just means we're back to
    /// the pre-fix behaviour, so we don't abort the launch on it.
    ///
    /// Note: this persists in the app's prefs until cleared. The headless smoke
    /// scripts clear it in their cleanup trap; an interactive user who hits a
    /// menu-bar-only relaunch can clear it with
    /// `defaults delete <bundleId> ApplePersistenceIgnoreState`.
    private func suppressWindowRestoration(bundleId: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        proc.arguments = ["write", bundleId, "ApplePersistenceIgnoreState", "-bool", "true"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // best-effort — fall through to the original behaviour
        }
    }

    /// Headless launches deliberately persist `ApplePersistenceIgnoreState`.
    /// A later cold visible launch must undo that override or SwiftUI can start
    /// menu-bar-only even though the app is activated in the foreground.
    private func clearWindowRestorationSuppression(bundleId: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        proc.arguments = ["delete", bundleId, "ApplePersistenceIgnoreState"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // best-effort — the key may not exist yet
        }
    }

    /// A cold SwiftUI `WindowGroup` may not instantiate its first scene from
    /// `open` plus `NSRunningApplication.activate` alone. Sending the standard
    /// application `activate` Apple event mirrors Finder/Dock activation and
    /// reliably asks SwiftUI to create that initial window. The bundle id is an
    /// argv value, never interpolated into AppleScript source.
    private func requestApplicationActivation(bundleId: String?) {
        guard let bundleId else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = [
            "-e", "on run argv",
            "-e", "tell application id (item 1 of argv) to activate",
            "-e", "end run",
            bundleId
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // best-effort — waitForWindow still retries AppKit activation
        }
    }

    private func waitForWindow(bundleId: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                if running.isHidden { running.unhide() }
                if !running.isActive { running.activate(options: [.activateAllWindows]) }
                if !AXElement.application(pid: running.processIdentifier).windows.isEmpty {
                    return true
                }
            }
            usleep(150_000)
        }
        return false
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
