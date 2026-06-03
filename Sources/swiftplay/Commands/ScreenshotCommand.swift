import AppKit
import ArgumentParser
import Foundation
import SwiftplayCore

struct ScreenshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a window of the target app to a PNG via ScreenCaptureKit.",
        discussion: """
        Captures a single window (shadow-free, wallpaper-free) at native pixel
        resolution. With no --window-title, it grabs the largest window — the
        main one. Pairs with `click`/`type`/`press` for a drive-and-screenshot
        visual pass with no in-app harness.

        Note: a window launched fully hidden (`swiftplay launch` without --show)
        may have no backing store to capture. For a reliable visual pass, launch
        with --show.
        """
    )

    @Option(name: [.long, .customShort("b")], help: "Bundle identifier, e.g. ai.rackmind.macos.")
    var bundleId: String?

    @Option(name: .long, help: "Process ID. Use either --bundle-id or --pid.")
    var pid: Int32?

    @Option(name: [.long, .customShort("o")], help: "Output PNG path.")
    var output: String = "swiftplay-screenshot.png"

    @Option(name: .long, help: "Capture only a window whose title contains this substring (case-insensitive).")
    var windowTitle: String?

    func run() throws {
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.printGuidance()
            ScreenRecordingPermission.request()
            throw ExitCode(2)
        }

        let target = try TargetApp.resolve(bundleId: bundleId, pid: pid)

        let result: Capture.Result
        do {
            result = try Capture.window(pid: target.pid, titleContains: windowTitle)
        } catch let error as CaptureError {
            FileHandle.standardError.write(Data("\(error.description)\n".utf8))
            throw ExitCode(1)
        }

        let rep = NSBitmapImageRep(cgImage: result.image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Failed to PNG-encode the captured image.\n".utf8))
            throw ExitCode(1)
        }

        let url = resolvedOutputURL()
        do {
            try data.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("Could not write \(output): \(error.localizedDescription)\n".utf8))
            throw ExitCode(1)
        }

        let px = "\(result.image.width)×\(result.image.height)"
        let pt = "\(Int(result.pointSize.width))×\(Int(result.pointSize.height))pt"
        FileHandle.standardError.write(Data("captured \"\(result.windowTitle)\" (\(pt), \(px)) → \(url.path)\n".utf8))
    }

    /// Resolve the output path. A bare filename (no `/`) is placed in the
    /// configured `screenshot.dir`; an explicit path is used as-is.
    private func resolvedOutputURL() -> URL {
        guard !output.contains("/") else { return URL(fileURLWithPath: output) }
        let dir = ConfigStore.load().screenshot.dir
        return URL(fileURLWithPath: dir).appendingPathComponent(output)
    }
}
