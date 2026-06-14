import CoreGraphics
import Foundation

/// A declarative recording script. One scene = one promo take.
///
/// The whole point of the cinematic pipeline is that a promo video is a
/// *re-runnable artifact*, not a hand-edited timeline. You describe the steps
/// (launch, press, click, type, wait) once; `swiftplay record` drives the app
/// through them while capturing video AND emitting a `Timeline` of exactly where
/// each interaction landed. `swiftplay render` then turns that into the polished
/// video. Tweak the scene, regenerate the ad.
///
/// Decoded from JSON — see `examples/rackmind-macos/promo.scene.json`.
struct Scene: Decodable {
    /// Bundle id of the app to drive, e.g. `ai.rackmind.macos`. Optional if the
    /// app is already running and `--pid` / a default is supplied at the CLI.
    var bundleId: String?
    /// How to bring the app up before recording.
    var launch: Launch = .show
    /// Only capture a window whose title contains this (case-insensitive). With
    /// no title we capture the app's largest window — the main one.
    var title: String?
    /// Output base name (no extension). Produces `<output>.mov` + `<output>.timeline.json`,
    /// and `<output>.mp4` when rendering. CLI `-o` overrides this.
    var output: String = "swiftplay-promo"
    /// Cinematic look knobs consumed by the renderer.
    var look: Look = Look()
    /// The ordered steps to perform while recording.
    var steps: [Step] = []

    enum Launch: String, Decodable {
        case show     // launch (or reactivate) visible + frontmost, then record
        case attach   // assume already running; just bring frontmost
    }

    /// One scripted action. A single `do` discriminator selects the kind; the
    /// other fields are read per-kind. Kept deliberately flat so the JSON reads
    /// like a Playwright test transcript.
    struct Step: Decodable {
        var action: Kind
        // press: chord like "cmd+2" / "return". type: literal text.
        var keys: String?
        var text: String?
        // click/hover targeting (same vocabulary as `swiftplay click`).
        var role: String?
        var label: String?      // matched against value/title/description/identifier
        // wait: milliseconds.
        var ms: Int?
        // Optional caption shown over the frame for this step (storytelling).
        var say: String?
        var maxDepth: Int?

        enum Kind: String, Decodable {
            case wait, press, type, click, hover, activate
        }

        private enum CodingKeys: String, CodingKey {
            case action = "do"
            case keys, text, role, label, ms, say, maxDepth
            // tolerate "name"/"title" as aliases for the click target label
            case name, titleAlias = "title"
            // tolerate "wait"/"delay" as aliases for ms
            case wait, delay
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            action = try c.decode(Kind.self, forKey: .action)
            keys = try c.decodeIfPresent(String.self, forKey: .keys)
            text = try c.decodeIfPresent(String.self, forKey: .text)
            role = try c.decodeIfPresent(String.self, forKey: .role)
            label = try c.decodeIfPresent(String.self, forKey: .label)
                ?? c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decodeIfPresent(String.self, forKey: .titleAlias)
            ms = try c.decodeIfPresent(Int.self, forKey: .ms)
                ?? c.decodeIfPresent(Int.self, forKey: .wait)
                ?? c.decodeIfPresent(Int.self, forKey: .delay)
            say = try c.decodeIfPresent(String.self, forKey: .say)
            maxDepth = try c.decodeIfPresent(Int.self, forKey: .maxDepth)
        }
    }

    static func load(from url: URL) throws -> Scene {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Scene.self, from: data)
    }
}

/// Renderer styling. All sizes that scale with the canvas are expressed as
/// fractions so a scene looks the same at 1080p or 4K.
struct Look: Decodable {
    /// Output canvas, pixels. Defaults to 1080p.
    var width: Int = 1920
    var height: Int = 1080
    /// Output frame rate. The renderer re-times source frames 1:1, so this only
    /// affects the render's declared rate, not the capture cadence.
    var fps: Int = 60
    /// Comma-separated hex colors for the background gradient ("#0b1020,#1a1f3a").
    /// A single color = flat background.
    var background: String = "#0e1116,#1b2030"
    /// Margin around the framed window, as a fraction of the smaller canvas side.
    var padding: Double = 0.07
    /// Window corner radius, fraction of the smaller canvas side.
    var cornerRadius: Double = 0.012
    /// Peak zoom factor when focusing an interaction (1 = no zoom).
    var zoom: Double = 1.6
    /// Seconds to ease into a focus, to hold it, and to ease back out.
    var zoomIn: Double = 0.55
    var zoomHold: Double = 1.1
    var zoomOut: Double = 0.6
    /// Draw the synthetic cursor + click ripples.
    var cursor: Bool = true
    /// Draw step captions (the `say` field) as a lower-third pill.
    var captions: Bool = true

    // MARK: 3D tilt

    /// Constant isometric tilt of the framed window. `y` rotates about the
    /// vertical axis (negative turns the right edge away — the Apple/Figma hero
    /// angle), `x` tips the top edge back. Zero on both = the old flat 2D path.
    var tilt: TiltSpec = TiltSpec()
    /// Focal distance for the perspective divide, in multiples of the panel's
    /// larger side. Larger = subtler/longer lens; smaller = stronger
    /// foreshortening. Tuned (from reading rendered stills) to read clearly 3D
    /// while keeping the leftmost UI legible at the default −8°/4° tilt.
    var perspective: Double = 3.8

    // MARK: Camera spring

    /// Spring constants for the whip-pan camera. The camera chases its target
    /// focus with a damped spring instead of an eased lerp, so it whips across
    /// the plane and snaps. `stiffness` ~ how hard it pulls; `damping` ~ how much
    /// it resists overshoot (critical damping ≈ 2·√stiffness).
    var spring: SpringSpec = SpringSpec()

    struct TiltSpec: Decodable {
        var y: Double = -8
        var x: Double = 4
        init() {}
        private enum K: String, CodingKey { case y, x }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            let d = TiltSpec()
            y = try c.decodeIfPresent(Double.self, forKey: .y) ?? d.y
            x = try c.decodeIfPresent(Double.self, forKey: .x) ?? d.x
        }
    }

    struct SpringSpec: Decodable {
        /// `enabled` lets a scene opt back into the legacy eased camera even with
        /// non-zero stiffness defaults present.
        var enabled: Bool = true
        var stiffness: Double = 150
        var damping: Double = 18
        init() {}
        private enum K: String, CodingKey { case enabled, stiffness, damping }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            let d = SpringSpec()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            stiffness = try c.decodeIfPresent(Double.self, forKey: .stiffness) ?? d.stiffness
            damping = try c.decodeIfPresent(Double.self, forKey: .damping) ?? d.damping
        }
    }

    /// The resolved `Tilt` value the renderer consumes.
    var tiltValue: Tilt { Tilt(yDeg: tilt.y, xDeg: tilt.x, perspective: perspective) }

    private enum CodingKeys: String, CodingKey {
        case width, height, fps, background, padding, cornerRadius
        case zoom, zoomIn, zoomHold, zoomOut, cursor, captions
        case tilt, perspective, spring
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Look()
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? d.width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? d.height
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? d.background
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? d.zoom
        zoomIn = try c.decodeIfPresent(Double.self, forKey: .zoomIn) ?? d.zoomIn
        zoomHold = try c.decodeIfPresent(Double.self, forKey: .zoomHold) ?? d.zoomHold
        zoomOut = try c.decodeIfPresent(Double.self, forKey: .zoomOut) ?? d.zoomOut
        cursor = try c.decodeIfPresent(Bool.self, forKey: .cursor) ?? d.cursor
        captions = try c.decodeIfPresent(Bool.self, forKey: .captions) ?? d.captions
        tilt = try c.decodeIfPresent(TiltSpec.self, forKey: .tilt) ?? d.tilt
        perspective = try c.decodeIfPresent(Double.self, forKey: .perspective) ?? d.perspective
        spring = try c.decodeIfPresent(SpringSpec.self, forKey: .spring) ?? d.spring
    }
}
