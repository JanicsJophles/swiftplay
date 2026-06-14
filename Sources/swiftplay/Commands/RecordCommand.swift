import AppKit
import ArgumentParser
import Foundation

struct RecordCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Drive an app through a scene while recording, producing footage + a cinematic timeline.",
        discussion: """
        Reads a declarative scene (JSON) describing steps — launch, press, type,
        click, wait — and drives the app through them while ScreenCaptureKit
        records its window. Because swiftplay is the one clicking, it knows the
        exact rect and timing of every interaction and writes them to a timeline
        alongside the footage. `swiftplay render` (or --render here) turns that
        into a polished promo: eased zoom-ins, a synthetic cursor, framed
        background.

        Produces <output>.mov and <output>.timeline.json (and <output>.mp4 with
        --render). The scene's app must be visible for capture — use the default
        `launch: show`, not the headless `swiftplay launch`.

        Needs BOTH Accessibility (to drive) and Screen Recording (to capture).
        """
    )

    @Argument(help: "Path to the scene JSON file.")
    var scenePath: String

    @Option(name: [.long, .customShort("o")], help: "Output base name (overrides the scene's `output`). Produces <base>.mov / .timeline.json / .mp4.")
    var output: String?

    @Option(name: [.long, .customShort("b")], help: "Bundle id override (else the scene's bundleId).")
    var bundleId: String?

    @Option(name: .long, help: "Attach to a specific running pid instead of launching.")
    var pid: Int32?

    @Flag(name: .long, help: "Render the final .mp4 immediately after recording.")
    var render: Bool = false

    func run() throws {
        guard AccessibilityPermission.isTrusted else {
            AccessibilityPermission.printGuidance()
            AccessibilityPermission.requestTrust()
            throw ExitCode(2)
        }
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.printGuidance()
            ScreenRecordingPermission.request()
            throw ExitCode(2)
        }

        let scene = try loadScene()
        let base = output ?? scene.output
        let movURL = URL(fileURLWithPath: "\(base).mov")
        let timelineURL = URL(fileURLWithPath: "\(base).timeline.json")

        let target = try resolveTarget(scene: scene)
        err("● recording \(target.localizedName ?? "app") (pid \(target.pid)) → \(movURL.lastPathComponent)")

        let recorder = Recorder(movURL: movURL)
        do {
            try recorder.start(pid: target.pid, titleContains: scene.title, fps: scene.look.fps)
        } catch let e as RecorderError {
            err(e.description); throw ExitCode(1)
        }

        let runner = SceneRunner(scene: scene, pid: target.pid, recorder: recorder)
        let events = runner.run()

        // Let the final UI state breathe before we cut.
        usleep(600_000)
        let duration = recorder.stop()

        guard let meta = recorder.meta else {
            err("Recording produced no frames — nothing to write."); throw ExitCode(1)
        }
        let timeline = Timeline(meta: meta, events: events)
        try timeline.save(to: timelineURL)

        err(String(format: "✔ captured %.1fs · %d events · %d×%d", duration, events.count, meta.sourceWidth, meta.sourceHeight))
        err("  \(movURL.path)")
        err("  \(timelineURL.path)")

        if render {
            let outURL = URL(fileURLWithPath: "\(base).mp4")
            err("● rendering → \(outURL.lastPathComponent)")
            try CinematicRenderer.render(movURL: movURL, timeline: timeline, look: scene.look, outURL: outURL) { line in err("  \(line)") }
            err("✔ \(outURL.path)")
        } else {
            err("→ render with: swiftplay render \(movURL.lastPathComponent) \(timelineURL.lastPathComponent)")
        }
    }

    private func loadScene() throws -> Scene {
        let url = URL(fileURLWithPath: scenePath)
        do {
            return try Scene.load(from: url)
        } catch {
            err("Could not read scene \(scenePath): \(error.localizedDescription)")
            throw ExitCode(1)
        }
    }

    /// Resolve (or launch, for `launch: show`) the target app and return it running.
    private func resolveTarget(scene: Scene) throws -> TargetApp {
        if let pid {
            guard let t = TargetApp.find(pid: pid) else { err("No process with pid \(pid)."); throw ExitCode(1) }
            return t
        }
        guard let id = bundleId ?? scene.bundleId else {
            err("Scene has no bundleId — pass --bundle-id or --pid."); throw ExitCode(1)
        }
        if let running = TargetApp.find(bundleId: id) { return running }

        guard scene.launch == .show else {
            err("App \(id) isn't running and scene `launch` is `attach`. Start it first, or set `launch: show`.")
            throw ExitCode(1)
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            err("Could not resolve an app path for bundle id '\(id)'."); throw ExitCode(1)
        }
        // Visible, foreground launch — the window must render to be captured.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [appURL.path]
        try proc.run(); proc.waitUntilExit()

        // Wait for the app to register as running.
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if let t = TargetApp.find(bundleId: id) { return t }
            usleep(250_000)
        } while Date() < deadline
        err("Launched \(id) but it never registered as running.")
        throw ExitCode(1)
    }

    private func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}
