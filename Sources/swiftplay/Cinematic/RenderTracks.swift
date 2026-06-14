import AppKit
import CoreGraphics
import Foundation

// MARK: - Easing

/// Cubic Bézier timing solver (the same math CSS `cubic-bezier()` and WebKit use).
/// `smoothstep` reads robotic for a premium ad; a tuned bezier gives the snappy
/// "whoosh" into a long, soft settle that high-end product videos have.
struct UnitBezier {
    private let ax, bx, cx, ay, by, cy: Double
    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3 * x1; bx = 3 * (x2 - x1) - cx; ax = 1 - cx - bx
        cy = 3 * y1; by = 3 * (y2 - y1) - cy; ay = 1 - cy - by
    }
    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func sampleDX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    /// Solve for parametric t at a given x (progress), then read y (eased value).
    func eased(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        var t = x
        for _ in 0..<8 {                          // Newton-Raphson
            let dx = sampleX(t) - x
            if abs(dx) < 1e-5 { return sampleY(t) }
            let d = sampleDX(t)
            if abs(d) < 1e-6 { break }
            t -= dx / d
        }
        var lo = 0.0, hi = 1.0; t = x             // bisection fallback
        while lo < hi {
            let xt = sampleX(t)
            if abs(xt - x) < 1e-5 { break }
            if x > xt { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return sampleY(t)
    }
}

/// Camera: snappy ease-in-out — accelerates hard out of the hold, glides into the
/// next focus. This is the "whoosh".
let cameraEase = UnitBezier(0.72, 0.0, 0.18, 1.0)
/// Cursor: ease-out — leaves fast, decelerates smoothly onto the target, the way a
/// hand moves a mouse.
let cursorEase = UnitBezier(0.22, 1.0, 0.30, 1.0)

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

// MARK: - Frame layout (canvas ↔ source geometry)

/// Constant per-render geometry: where the framed window sits on the canvas, and
/// how source-pixel space maps onto it at a given camera (center + zoom).
struct FrameLayout {
    let canvas: CGSize
    let source: CGSize
    let screenRect: CGRect
    let baseScale: CGFloat
    /// Scales canvas-relative UI (cursor, pills) so they look the same at any res.
    let uiScale: CGFloat

    init(canvas: CGSize, source: CGSize, look: Look) {
        self.canvas = canvas
        self.source = source
        self.uiScale = min(canvas.width, canvas.height) / 1080

        let pad = CGFloat(look.padding) * min(canvas.width, canvas.height)
        let avail = CGRect(x: pad, y: pad, width: canvas.width - 2 * pad, height: canvas.height - 2 * pad)
        let srcAspect = source.width / max(1, source.height)
        var rw = avail.width
        var rh = rw / srcAspect
        if rh > avail.height { rh = avail.height; rw = rh * srcAspect }
        self.screenRect = CGRect(x: avail.midX - rw / 2, y: avail.midY - rh / 2, width: rw, height: rh)
        self.baseScale = rw / max(1, source.width)
    }

    struct Placement {
        let drawRect: CGRect   // where to draw the *whole* source image on the canvas
        let s: CGFloat         // source-px → canvas-px scale at this zoom
        func toCanvas(sourcePoint p: CGPoint) -> CGPoint {
            CGPoint(x: drawRect.minX + p.x * s, y: drawRect.minY + p.y * s)
        }
    }

    func placement(center: CGPoint, zoom: Double) -> Placement {
        let z = CGFloat(max(1, zoom))
        let vw = source.width / z
        let vh = source.height / z
        var vx = center.x - vw / 2
        var vy = center.y - vh / 2
        vx = min(max(0, vx), max(0, source.width - vw))
        vy = min(max(0, vy), max(0, source.height - vh))
        let s = baseScale * z
        let drawRect = CGRect(
            x: screenRect.minX - vx * s,
            y: screenRect.minY - vy * s,
            width: source.width * s,
            height: source.height * s
        )
        return Placement(drawRect: drawRect, s: s)
    }
}

// MARK: - Camera track

/// The driven camera. Built from the interaction rects in the timeline: ease into
/// each focus, hold, pan to the next (or breathe back to wide on a long gap), and
/// settle wide at the end.
///
/// Two motion modes:
///   • **Spring (default).** The keyframes define a *target* signal — a piecewise
///     curve the camera should chase. A critically-ish-damped spring integrates
///     toward that target, so the camera whips across the plane on a focus change
///     and snaps into place (with the existing motion-blur selling the whip).
///   • **Eased (legacy).** Bézier-eased lerp between keyframes, for scenes that
///     opt out via `spring.enabled = false`.
///
/// On top of either mode rides a slow, never-stopping **drift**: a gentle parallax
/// orbit + a continuous zoom breath so the camera is never perfectly static.
struct CameraTrack {
    private struct KF { let t: Double; let center: CGPoint; let zoom: Double }
    private let kfs: [KF]
    private let spring: Look.SpringSpec
    private let totalDuration: Double
    private let sourceSize: CGSize
    /// Precomputed spring trajectory, sampled at a fixed step and linearly
    /// interpolated at eval time. A spring is a stateful ODE — sampling it on the
    /// fly per random `t` would be wrong, so we integrate forward once.
    private let springSamples: [(center: CGPoint, zoom: Double)]
    private let springDt: Double
    private let springT0: Double

    init(timeline: Timeline, look: Look) {
        self.spring = look.spring
        self.sourceSize = CGSize(width: Double(timeline.meta.sourceWidth), height: Double(timeline.meta.sourceHeight))
        let meta = timeline.meta
        let defCenter = CGPoint(x: Double(meta.sourceWidth) / 2, y: Double(meta.sourceHeight) / 2)
        let focus = timeline.events
            .filter { $0.rect != nil }
            .sorted { $0.t < $1.t }

        var kfs: [KF] = [KF(t: 0, center: defCenter, zoom: 1)]
        var lastT = 0.0
        var lastCenter = defCenter
        var lastZoom = 1.0

        func zoomFor(_ r: CGRect) -> Double {
            guard r.width > 1, r.height > 1 else { return look.zoom }
            // Macro/micro: size the zoom so the target element fills ~half the view.
            // Small controls get a tight, dramatic crop; big panels stay wide. The
            // contrast between wide and close is what makes it feel cinematic.
            let fill = 0.5
            let z = min(Double(meta.sourceWidth) * fill / r.width, Double(meta.sourceHeight) * fill / r.height)
            return min(look.zoom, max(1.25, z))
        }

        for ev in focus {
            guard let rectPts = ev.rect?.cg else { continue }
            let r = meta.toSource(rect: rectPts)
            let c = CGPoint(x: r.midX, y: r.midY)
            let z = zoomFor(r)

            let inStart = ev.t - look.zoomIn
            if inStart > lastT + (look.zoomOut + 0.4) {
                // Long gap: breathe back to wide and hold there until the ramp.
                let outAt = min(lastT + look.zoomOut, inStart - 0.05)
                kfs.append(KF(t: outAt, center: defCenter, zoom: 1))
                let holdWide = max(inStart, outAt + 0.01)
                kfs.append(KF(t: holdWide, center: defCenter, zoom: 1))
                lastT = holdWide; lastCenter = defCenter; lastZoom = 1
            } else if inStart > lastT {
                kfs.append(KF(t: inStart, center: lastCenter, zoom: lastZoom))
                lastT = inStart
            }

            let arrive = max(ev.t, lastT + 0.01)
            kfs.append(KF(t: arrive, center: c, zoom: z))
            lastT = arrive; lastCenter = c; lastZoom = z

            let holdEnd = lastT + look.zoomHold
            kfs.append(KF(t: holdEnd, center: c, zoom: z))
            lastT = holdEnd
        }

        kfs.append(KF(t: lastT + look.zoomOut, center: defCenter, zoom: 1))
        kfs.append(KF(t: lastT + look.zoomOut + 3600, center: defCenter, zoom: 1))
        self.kfs = kfs

        // The active part of the timeline (the trailing +3600 sentinel is just a
        // hold, not real footage). Drift spans this whole span so the camera is
        // never static, including before the first focus and after the last.
        self.totalDuration = max(0.5, lastT + look.zoomOut)

        // MARK: Spring trajectory
        // Integrate a damped spring that chases the eased keyframe target. We
        // sample the *target* (the piecewise eased curve, which is a stepwise
        // "where do I want the camera now" signal) at small steps and advance the
        // spring state semi-implicitly. The spring's overshoot/settle is what
        // turns the eased glides into snappy whip-pans.
        if look.spring.enabled {
            let dt = 1.0 / 240.0                       // fine integration step
            let end = self.totalDuration + 1.0
            let n = max(2, Int(end / dt) + 1)
            var samples: [(center: CGPoint, zoom: Double)] = []
            samples.reserveCapacity(n)

            let k = look.spring.stiffness
            let cDamp = look.spring.damping

            // State: position p and velocity v for cx, cy, zoom.
            var px = kfs.first!.center.x, py = kfs.first!.center.y, pz = kfs.first!.zoom
            var vx = 0.0, vy = 0.0, vz = 0.0
            // Zoom moves on a different scale (≈1–2) than centers (hundreds/thousands
            // of px); a single stiffness would make zoom mushy or centers jittery.
            // Zoom gets a firmer spring so it tracks crisply.
            let kZoom = k * 1.6
            let cZoom = cDamp * 1.25

            func target(_ t: Double) -> (CGPoint, Double) {
                CameraTrack.evalKeyframes(kfs, at: t)
            }

            for i in 0..<n {
                let t = Double(i) * dt
                let (tc, tz) = target(t)
                // Semi-implicit Euler: a = k(target - p) - c·v ; v += a·dt ; p += v·dt
                let ax = k * (tc.x - px) - cDamp * vx
                let ay = k * (tc.y - py) - cDamp * vy
                let az = kZoom * (tz - pz) - cZoom * vz
                vx += ax * dt; vy += ay * dt; vz += az * dt
                px += vx * dt; py += vy * dt; pz += vz * dt
                samples.append((CGPoint(x: px, y: py), max(1, pz)))
            }
            self.springSamples = samples
            self.springDt = dt
            self.springT0 = 0
        } else {
            self.springSamples = []
            self.springDt = 1
            self.springT0 = 0
        }
    }

    /// Bézier-eased sample of the raw keyframe target curve (the legacy camera,
    /// and the spring's input signal).
    private static func evalKeyframes(_ kfs: [KF], at t: Double) -> (CGPoint, Double) {
        guard let first = kfs.first else { return (.zero, 1) }
        if t <= first.t { return (first.center, first.zoom) }
        if let last = kfs.last, t >= last.t { return (last.center, last.zoom) }
        for i in 1..<kfs.count where t < kfs[i].t {
            let a = kfs[i - 1], b = kfs[i]
            let u = cameraEase.eased((t - a.t) / max(0.0001, b.t - a.t))
            return (
                CGPoint(x: lerp(a.center.x, b.center.x, u), y: lerp(a.center.y, b.center.y, u)),
                lerp(a.zoom, b.zoom, u)
            )
        }
        let last = kfs[kfs.count - 1]
        return (last.center, last.zoom)
    }

    /// Slow, continuous drift layered on top of the camera so it's never frozen.
    /// A tiny elliptical orbit of the look-at center + a sine "breath" on the zoom.
    /// Amplitudes are a fraction of the frame, so it reads as a living handheld
    /// rather than a move. Spans the whole clip.
    private func drift(at t: Double, baseZoom: Double) -> (dx: Double, dy: Double, dZoom: Double) {
        // Two slow incommensurate periods so the orbit never visibly loops.
        let orbX = sin(t * 0.18) * sourceSize.width * 0.012
        let orbY = cos(t * 0.13) * sourceSize.height * 0.012
        // Continuous gentle push-in: a slow overall zoom ramp across the clip plus
        // a small breath, both shrinking toward 0 as zoom rises (don't fight a
        // focused close-up). At baseZoom≈1 (wide) the push is most visible.
        let wideness = max(0, (2.0 - baseZoom)) / 1.0
        let pushIn = (t / max(1, totalDuration)) * 0.06       // up to +6% over the clip
        let breath = sin(t * 0.22) * 0.015
        let dZoom = (pushIn + breath) * wideness
        return (orbX, orbY, dZoom)
    }

    func eval(at t: Double) -> (center: CGPoint, zoom: Double) {
        let base: (center: CGPoint, zoom: Double)
        if spring.enabled, !springSamples.isEmpty {
            // Linear interp into the precomputed spring trajectory.
            let x = (t - springT0) / springDt
            if x <= 0 {
                base = springSamples[0]
            } else if Int(x) + 1 >= springSamples.count {
                base = springSamples[springSamples.count - 1]
            } else {
                let i = Int(x)
                let f = x - Double(i)
                let a = springSamples[i], b = springSamples[i + 1]
                base = (
                    CGPoint(x: lerp(a.center.x, b.center.x, f), y: lerp(a.center.y, b.center.y, f)),
                    lerp(a.zoom, b.zoom, f)
                )
            }
        } else {
            let (c, z) = CameraTrack.evalKeyframes(kfs, at: t)
            base = (c, z)
        }

        let d = drift(at: t, baseZoom: base.zoom)
        return (
            CGPoint(x: base.center.x + d.dx, y: base.center.y + d.dy),
            base.zoom + d.dZoom
        )
    }
}

// MARK: - Cursor track

/// Synthetic cursor path. Glides between consecutive interaction points, arriving
/// just before each action so the click reads as deliberate.
struct CursorTrack {
    private struct KF { let t: Double; let p: CGPoint }
    private let kfs: [KF]

    init(timeline: Timeline) {
        let meta = timeline.meta
        let pointed = timeline.events
            .filter { $0.point != nil }
            .sorted { $0.t < $1.t }

        var kfs: [KF] = []
        if let firstPt = pointed.first?.point?.cg {
            kfs.append(KF(t: 0, p: meta.toSource(point: firstPt)))
        }
        var lastT = 0.0
        for ev in pointed {
            guard let p = ev.point?.cg else { continue }
            let sp = meta.toSource(point: p)
            let arrival = max(ev.t - 0.08, lastT + 0.001)
            kfs.append(KF(t: arrival, p: sp))
            let settle = max(ev.t, arrival)
            kfs.append(KF(t: settle, p: sp))
            lastT = settle
        }
        self.kfs = kfs
    }

    func eval(at t: Double) -> CGPoint? {
        guard let first = kfs.first else { return nil }
        if t <= first.t { return first.p }
        if let last = kfs.last, t >= last.t { return last.p }
        for i in 1..<kfs.count where t < kfs[i].t {
            let a = kfs[i - 1], b = kfs[i]
            let u = cursorEase.eased((t - a.t) / max(0.0001, b.t - a.t))
            var p = CGPoint(x: lerp(a.p.x, b.p.x, u), y: lerp(a.p.y, b.p.y, u))
            // A slight arc — real hands don't move in straight lines. Perpendicular
            // offset peaks mid-travel (sin), scaled to distance and capped.
            let dx = b.p.x - a.p.x, dy = b.p.y - a.p.y
            let len = (dx * dx + dy * dy).squareRoot()
            if len > 40 {
                let arc = min(len * 0.12, 90) * sin(.pi * u)
                p.x += (-dy / len) * arc
                p.y += (dx / len) * arc
            }
            return p
        }
        return kfs[kfs.count - 1].p
    }
}

// MARK: - Overlay track (ripples, captions, key pills)

struct OverlayTrack {
    struct Ripple { let point: CGPoint; let progress: Double }
    private struct Timed { let t: Double; let text: String }

    private let clicks: [(t: Double, p: CGPoint)]
    private let captions: [Timed]
    private let presses: [Timed]

    private let rippleDur = 0.5
    private let captionHold = 2.6
    private let keyHold = 1.0

    init(timeline: Timeline) {
        let meta = timeline.meta
        clicks = timeline.events
            .filter { $0.kind == .click && $0.point != nil }
            .map { (t: $0.t, p: meta.toSource(point: $0.point!.cg)) }
        captions = timeline.events
            .filter { $0.kind == .caption && ($0.label?.isEmpty == false) }
            .map { Timed(t: $0.t, text: $0.label!) }
            .sorted { $0.t < $1.t }
        presses = timeline.events
            .filter { $0.kind == .press && ($0.label?.isEmpty == false) }
            .map { Timed(t: $0.t, text: $0.label!) }
            .sorted { $0.t < $1.t }
    }

    func ripples(at t: Double) -> [Ripple] {
        clicks.compactMap { c in
            let dt = t - c.t
            guard dt >= 0, dt <= rippleDur else { return nil }
            return Ripple(point: c.p, progress: dt / rippleDur)
        }
    }

    /// The active caption: latest one whose start has passed and that hasn't been
    /// superseded by the next caption (or timed out).
    func caption(at t: Double) -> String? {
        var active: String?
        for (i, cap) in captions.enumerated() where cap.t <= t {
            let nextT = i + 1 < captions.count ? captions[i + 1].t : Double.greatestFiniteMagnitude
            let end = min(cap.t + captionHold, nextT)
            if t < end { active = cap.text }
        }
        return active
    }

    func keyPill(at t: Double) -> String? {
        var active: String?
        for (i, pr) in presses.enumerated() where pr.t <= t {
            let nextT = i + 1 < presses.count ? presses[i + 1].t : Double.greatestFiniteMagnitude
            let end = min(pr.t + keyHold, nextT)
            if t < end { active = pr.text }
        }
        return active
    }
}

// MARK: - Gradient background

struct Gradient {
    private let colors: [CGColor]

    init(spec: String) {
        let parsed = spec.split(separator: ",").compactMap { Gradient.color(from: $0.trimmingCharacters(in: .whitespaces)) }
        colors = parsed.isEmpty ? [Gradient.color(from: "#0e1116")!, Gradient.color(from: "#1b2030")!] : parsed
    }

    func draw(in ctx: CGContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        guard colors.count > 1 else {
            ctx.setFillColor(colors.first ?? NSColor.black.cgColor)
            ctx.fill(rect)
            return
        }
        let locations = (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations) else {
            ctx.setFillColor(colors[0]); ctx.fill(rect); return
        }
        // Bottom-left context: first color at the top means start at high y.
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: size.width / 2, y: size.height),
            end: CGPoint(x: size.width / 2, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    /// Parse "#rgb" / "#rrggbb" / "#rrggbbaa" into an sRGB CGColor.
    static func color(from raw: String) -> CGColor? {
        var hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if hex.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Text rendering (cached, drawn to images to dodge flipped-context CoreText)

/// Renders text to upright CGImages so the flipped (top-left) draw context can
/// blit them like any other image. Cached because captions/pills repeat across
/// many frames.
final class TextCache {
    private var cache: [String: CGImage] = [:]

    func image(_ text: String, fontSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> CGImage? {
        let key = "\(Int(fontSize))|\(weight.rawValue)|\(color.hashValue)|\(text)"
        if let hit = cache[key] { return hit }
        // Rounded system design reads softer/friendlier — the Figma/Apple caption feel.
        let plain = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let font = plain.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: fontSize) } ?? plain
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let astr = NSAttributedString(string: text, attributes: attrs)
        let size = astr.size()
        let w = Int(ceil(size.width)) + 2
        let h = Int(ceil(size.height)) + 2
        guard w > 2, h > 2,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        astr.draw(at: NSPoint(x: 1, y: 1))
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return nil }
        cache[key] = cg
        return cg
    }
}
