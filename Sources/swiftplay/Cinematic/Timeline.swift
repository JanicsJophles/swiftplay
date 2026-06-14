import CoreGraphics
import Foundation

/// The edit-decision-list the recorder emits alongside the raw `.mov`.
///
/// This is swiftplay's structural advantage over a screen recorder: because we
/// *drove* the app, we know the exact rect of every element we touched and the
/// exact moment we touched it — no cursor-velocity heuristics. The renderer
/// reads this to decide where and when to zoom, and where to glide the cursor.
///
/// All geometry is stored in **global screen points, top-left origin** (the
/// space AX reports). The renderer converts to source-pixel space via `meta`
/// (subtract the window origin, multiply by `scale`), so capture-scale changes
/// never desync the camera from the footage.
struct Timeline: Codable {
    var meta: Meta
    var events: [Event]

    struct Meta: Codable {
        /// Captured window frame in global screen points (top-left origin).
        var windowX: Double
        var windowY: Double
        var windowWidth: Double
        var windowHeight: Double
        /// Backing scale the footage was captured at (2 on retina).
        var scale: Double
        /// Footage pixel dimensions (== windowSize * scale).
        var sourceWidth: Int
        var sourceHeight: Int
        var fps: Int

        var windowFrame: CGRect {
            CGRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)
        }
    }

    struct Event: Codable {
        /// Seconds since the first captured frame (shared clock with the footage).
        var t: Double
        var kind: Kind
        var label: String?
        /// Interaction target rect in global screen points (zoom focus).
        var rect: Rect?
        /// Pointer location in global screen points (cursor glide target).
        var point: Point?

        enum Kind: String, Codable {
            case click, hover, press, type, wait, caption
        }
    }

    struct Rect: Codable {
        var x: Double, y: Double, w: Double, h: Double
        var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
        init(_ r: CGRect) { x = r.minX; y = r.minY; w = r.width; h = r.height }
    }

    struct Point: Codable {
        var x: Double, y: Double
        var cg: CGPoint { CGPoint(x: x, y: y) }
        init(_ p: CGPoint) { x = p.x; y = p.y }
    }

    func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> Timeline {
        try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: url))
    }
}

/// Convert a global-screen-point rect/point into source-pixel space (top-left).
extension Timeline.Meta {
    func toSource(rect r: CGRect) -> CGRect {
        CGRect(
            x: (r.minX - windowX) * scale,
            y: (r.minY - windowY) * scale,
            width: r.width * scale,
            height: r.height * scale
        )
    }

    func toSource(point p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - windowX) * scale, y: (p.y - windowY) * scale)
    }
}
