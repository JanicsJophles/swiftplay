import ArgumentParser
import Foundation

struct RenderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Render raw footage + a timeline into a polished promo video.",
        discussion: """
        Takes the <name>.mov and <name>.timeline.json produced by `swiftplay
        record` and composites the cinematic pass: eased zoom-ins driven by the
        recorded interaction rects, a synthetic cursor that glides between them,
        click ripples, a framed gradient background, and captions.

        Look knobs (zoom, padding, background, fps…) come from the timeline's
        originating scene by default; override per-render with the flags below.
        """
    )

    @Argument(help: "Path to the recorded .mov.")
    var footage: String

    @Argument(help: "Path to the .timeline.json. Defaults to <footage-base>.timeline.json.")
    var timeline: String?

    @Option(name: [.long, .customShort("o")], help: "Output .mp4 path. Defaults to <footage-base>.mp4.")
    var output: String?

    @Option(name: .long, help: "Override peak zoom factor (1 = no zoom).")
    var zoom: Double?

    @Option(name: .long, help: "Override background gradient, comma-separated hex (e.g. \"#0b1020,#1a1f3a\").")
    var background: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Draw the synthetic cursor + ripples.")
    var cursor: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Draw captions and key pills.")
    var captions: Bool = true

    @Option(name: .long, help: "Override tilt about the vertical axis, degrees (negative = right edge back). 0 = flat.")
    var tiltY: Double?

    @Option(name: .long, help: "Override tilt about the horizontal axis, degrees (positive = top edge back).")
    var tiltX: Double?

    @Option(name: .long, help: "Override perspective focal distance (multiples of panel side; larger = subtler).")
    var perspective: Double?

    @Flag(name: .long, inversion: .prefixedNo, help: "Use the spring whip-pan camera (vs legacy eased).")
    var spring: Bool = true

    @Option(name: .long, help: "Override spring stiffness.")
    var stiffness: Double?

    @Option(name: .long, help: "Override spring damping.")
    var damping: Double?

    @Option(name: .long, help: "Scale output resolution by this factor (e.g. 0.5 for fast preview renders). Default 1.")
    var scale: Double?

    func run() throws {
        let footageURL = URL(fileURLWithPath: footage)
        let base = footageURL.deletingPathExtension().path
        let timelineURL = URL(fileURLWithPath: timeline ?? "\(base).timeline.json")
        let outURL = URL(fileURLWithPath: output ?? "\(base).mp4")

        let tl: Timeline
        do {
            tl = try Timeline.load(from: timelineURL)
        } catch {
            err("Could not read timeline \(timelineURL.path): \(error.localizedDescription)")
            throw ExitCode(1)
        }

        // Look defaults come from the timeline's capture meta (fps + source size);
        // the rest are renderer defaults overridable by flags.
        var look = Look()
        look.fps = tl.meta.fps
        if let zoom { look.zoom = zoom }
        if let background { look.background = background }
        look.cursor = cursor
        look.captions = captions
        if let tiltY { look.tilt.y = tiltY }
        if let tiltX { look.tilt.x = tiltX }
        if let perspective { look.perspective = perspective }
        look.spring.enabled = spring
        if let stiffness { look.spring.stiffness = stiffness }
        if let damping { look.spring.damping = damping }
        if let scale, scale > 0, scale != 1 {
            // Even dimensions keep H.264 happy.
            look.width = max(2, (Int(Double(look.width) * scale) / 2) * 2)
            look.height = max(2, (Int(Double(look.height) * scale) / 2) * 2)
        }

        err("● rendering \(footageURL.lastPathComponent) → \(outURL.lastPathComponent)")
        do {
            try CinematicRenderer.render(movURL: footageURL, timeline: tl, look: look, outURL: outURL) { line in
                err("  \(line)")
            }
        } catch let e as RenderError {
            err(e.description); throw ExitCode(1)
        }
        err("✔ \(outURL.path)")
    }

    private func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}
