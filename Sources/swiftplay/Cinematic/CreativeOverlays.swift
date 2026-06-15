import AppKit
import CoreGraphics
import Foundation

/// The "ad" layer: everything that makes the render feel authored rather than a
/// screen-recording paste-up. A cold-open title card, a brand end card, a soft
/// emerald glow behind the panel, a vignette, and the animation envelope for
/// captions. All of it is driven purely by the frame time `t` (and the clip
/// duration for the outro), so it composites deterministically per frame.
///
/// Drawing conventions match `CinematicRenderer.drawFrame`: the context is CG's
/// native bottom-left space. Helpers here take canvas-space rects/points already
/// converted by the caller, or work in full-canvas space where the vertical flip
/// is symmetric (radial gradients, centered text) and doesn't matter.
enum CreativeLayer {
    // MARK: Easing helpers

    /// Smooth 0→1 ramp with ease-in-out. Cheap and good enough for opacity/scale.
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        if b <= a { return x < a ? 0 : 1 }
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Ease-out cubic — fast start, soft landing. For things that fly in.
    static func easeOut(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return 1 - pow(1 - t, 3)
    }

    /// Ease-out-back — overshoots past 1 then settles. The "elastic pop" that
    /// gives kinetic type tangible momentum (`overshoot` ~1.7 ≈ +10% overshoot;
    /// bigger = more bounce).
    static func easeOutBack(_ x: Double, overshoot s: Double = 2.2) -> Double {
        let c1 = s, c3 = s + 1
        let t = min(1, max(0, x))
        let u = t - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    // MARK: Accent glow

    /// A soft emerald radial bloom centered behind the panel. Pulses gently so the
    /// frame breathes. Drawn after the background, before the panel.
    static func drawGlow(ctx: CGContext, canvas: CGSize, panelRect: CGRect, spec: Look.GlowSpec, t: Double) {
        guard spec.intensity > 0.001, let base = Gradient.color(from: spec.color) else { return }
        let pulse = 0.85 + 0.15 * sin(t * 0.6)                 // slow breath
        let peak = CGFloat(spec.intensity) * CGFloat(pulse)
        let center = CGPoint(x: panelRect.midX, y: canvas.height - panelRect.midY)
        let radius = max(panelRect.width, panelRect.height) * 0.95

        guard let comps = base.components, comps.count >= 3 else { return }
        let inner = CGColor(srgbRed: comps[0], green: comps[1], blue: comps[2], alpha: peak)
        let outer = CGColor(srgbRed: comps[0], green: comps[1], blue: comps[2], alpha: 0)
        guard let grad = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [inner, outer] as CFArray, locations: [0, 1]
        ) else { return }

        ctx.saveGState()
        ctx.drawRadialGradient(
            grad, startCenter: center, startRadius: 0,
            endCenter: center, endRadius: radius, options: []
        )
        ctx.restoreGState()
    }

    // MARK: Vignette

    /// Darkens the canvas corners to pull focus to the panel. Radial, clear in the
    /// middle, black (alpha `intensity`) at the corners.
    static func drawVignette(ctx: CGContext, canvas: CGSize, intensity: Double) {
        guard intensity > 0.001 else { return }
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let radius = (canvas.width * canvas.width + canvas.height * canvas.height).squareRoot() / 2
        let clear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        let dark = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: CGFloat(intensity))
        guard let grad = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [clear, clear, dark] as CFArray, locations: [0, 0.55, 1]
        ) else { return }
        ctx.saveGState()
        ctx.drawRadialGradient(
            grad, startCenter: center, startRadius: 0,
            endCenter: center, endRadius: radius, options: []
        )
        ctx.restoreGState()
    }

    // MARK: Intro cold-open

    /// True while the intro title card is still covering the app (so the caller
    /// suppresses the normal step caption underneath it).
    static func introActive(spec: Look.IntroSpec, t: Double) -> Bool {
        t < spec.hold + spec.settle + 0.05
    }

    /// Cold open: a depth-ring backdrop + a headline whose words explode in one
    /// after another with elastic overshoot, hold, then the scrim dissolves to
    /// reveal the app as the whole line lifts away.
    static func drawIntro(
        ctx: CGContext, canvas: CGSize, spec: Look.IntroSpec, t: Double,
        scale: CGFloat, textCache: TextCache
    ) {
        let revealStart = spec.hold
        let revealEnd = spec.hold + spec.settle
        let scrimAlpha = 1 - smoothstep(revealStart, revealEnd, t)
        if scrimAlpha <= 0.001 { return }

        // Near-black scrim tinted toward the bg's deep blue.
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 0.02, green: 0.03, blue: 0.06, alpha: CGFloat(scrimAlpha)))
        ctx.fill(CGRect(origin: .zero, size: canvas))
        ctx.restoreGState()

        let cx = canvas.width / 2, cy = canvas.height / 2

        // Receding depth rings tracking outward — sells motion behind the type.
        drawDepthRings(ctx: ctx, canvas: canvas, t: t, alpha: scrimAlpha * 0.5, accent: spec.accent, scale: scale)

        // The headline lifts + fades away as the scrim dissolves.
        let outP = smoothstep(revealStart, revealEnd, t)
        let groupAlpha = scrimAlpha
        let yLift = CGFloat(outP) * 70 * scale
        let yOffset = -yLift

        // Accent eyebrow rule above the headline, drawing in from center.
        if let accent = Gradient.color(from: spec.accent) {
            let barW = CGFloat(easeOut(t / 0.5)) * 130 * scale
            let barH = 4 * scale
            ctx.saveGState()
            ctx.setAlpha(CGFloat(groupAlpha * (1 - outP)))
            ctx.setFillColor(accent)
            let bar = CGRect(x: cx - barW / 2, y: cy + 78 * scale + yOffset, width: barW, height: barH)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }

        // Kinetic headline — words pop in sequentially with elastic overshoot.
        let words = spec.headline.split(separator: " ").map(String.init)
        drawKineticWords(
            ctx: ctx, words: words, cx: cx, cy: cy + yOffset,
            fontSize: 86 * scale, weight: .bold, color: .white,
            t: t, startDelay: 0.06, stagger: 0.11, wordDur: 0.5,
            baseAlpha: groupAlpha, exitLift: 0, textCache: textCache, shadow: true
        )

        // Sub-headline fades up after the words land.
        if let sub = spec.sub, !sub.isEmpty {
            let subAlpha = smoothstep(0.45, 0.95, t) * groupAlpha
            let subRise = CGFloat(1 - easeOut((t - 0.45) / 0.5)) * 18 * scale
            if let simg = textCache.image(sub, fontSize: 30 * scale, weight: .medium, color: NSColor(white: 0.74, alpha: 1)) {
                drawCenteredImage(ctx: ctx, img: simg, cx: cx, cy: cy - 64 * scale + yOffset - subRise, alpha: subAlpha, scale: 1, shadow: false)
            }
        }
    }

    /// Lays out `words` in a centered row at fixed positions and pops each in with
    /// an elastic overshoot, staggered by index. Positions are fixed so the line
    /// never reflows — only each word's scale/alpha/rise animates.
    private static func drawKineticWords(
        ctx: CGContext, words: [String], cx: CGFloat, cy: CGFloat,
        fontSize: CGFloat, weight: NSFont.Weight, color: NSColor,
        t: Double, startDelay: Double, stagger: Double, wordDur: Double,
        baseAlpha: Double, exitLift: CGFloat, textCache: TextCache, shadow: Bool
    ) {
        guard !words.isEmpty else { return }
        let imgs = words.map { textCache.image($0, fontSize: fontSize, weight: weight, color: color) }
        let spaceW = fontSize * 0.34
        let widths = imgs.map { $0.map { CGFloat($0.width) } ?? 0 }
        let total = widths.reduce(0, +) + spaceW * CGFloat(max(0, words.count - 1))

        var runX = cx - total / 2
        for (i, img) in imgs.enumerated() {
            let w = widths[i]
            guard let img else { runX += w + spaceW; continue }
            let p = (t - startDelay - Double(i) * stagger) / wordDur
            let pop = easeOutBack(p)                          // 0 → ~1.1 → 1
            let appear = smoothstep(0, 0.35, p)
            if appear > 0.001 {
                let s = CGFloat(0.62 + 0.38 * pop)            // scale 0.62 → overshoot → 1
                let rise = CGFloat(1 - easeOut(p)) * 26 * (fontSize / 86)
                drawCenteredImage(ctx: ctx, img: img, cx: runX + w / 2, cy: cy + rise, alpha: appear * baseAlpha, scale: s, shadow: shadow)
            }
            runX += w + spaceW
        }
    }

    /// Concentric rounded rectangles expanding outward from center — a faint,
    /// continuously tracking "flying through space" depth field behind the intro.
    private static func drawDepthRings(ctx: CGContext, canvas: CGSize, t: Double, alpha: Double, accent: String, scale: CGFloat) {
        guard alpha > 0.001, let base = Gradient.color(from: accent), let comps = base.components, comps.count >= 3 else { return }
        let cx = canvas.width / 2, cy = canvas.height / 2
        let rings = 7
        let speed = 0.22
        ctx.saveGState()
        for i in 0..<rings {
            // Phase 0→1 per ring, offset so rings are evenly spaced in depth.
            let phase = (t * speed + Double(i) / Double(rings)).truncatingRemainder(dividingBy: 1)
            let size = CGFloat(phase) * max(canvas.width, canvas.height) * 1.2
            // Fade in from center, out at the edge.
            let a = alpha * sin(phase * Double.pi) * 0.5
            if a <= 0.002 { continue }
            let rect = CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
            let r = min(size / 2, 60 * scale)
            ctx.setStrokeColor(CGColor(srgbRed: comps[0], green: comps[1], blue: comps[2], alpha: CGFloat(a)))
            ctx.setLineWidth(1.5 * scale)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: Outro brand card

    static func outroActive(spec: Look.OutroSpec, t: Double, duration: Double) -> Bool {
        t >= duration - spec.fromEnd - 0.05
    }

    /// End card: the app fades under a dark scrim, then a staged brand reveal —
    /// depth rings, an elastic wordmark, an accent underline that draws in, the
    /// tagline, and a CTA pill — all in the brand typeface. Designed to breathe
    /// over a longer hold so it lands as a real closing card, not a quick fade.
    static func drawOutro(
        ctx: CGContext, canvas: CGSize, spec: Look.OutroSpec, t: Double,
        duration: Double, scale: CGFloat, textCache: TextCache
    ) {
        let start = duration - spec.fromEnd
        let p = min(1, max(0, (t - start) / max(0.001, spec.fromEnd)))
        if p <= 0 { return }

        let cx = canvas.width / 2, cy = canvas.height / 2
        let accent = Gradient.color(from: spec.accent)

        // Scrim fades the app to near-black over the first ~40%.
        let scrimAlpha = smoothstep(0, 0.4, p) * 0.97
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 0.02, green: 0.03, blue: 0.06, alpha: CGFloat(scrimAlpha)))
        ctx.fill(CGRect(origin: .zero, size: canvas))
        ctx.restoreGState()

        // Faint depth rings (continuity with the intro) once the scrim is down.
        drawDepthRings(ctx: ctx, canvas: canvas, t: t, alpha: smoothstep(0.25, 0.6, p) * 0.4, accent: spec.accent, scale: scale)

        // Emerald bloom behind the lockup.
        if let comps = accent?.components, comps.count >= 3 {
            let bloom = smoothstep(0.15, 0.75, p)
            let inner = CGColor(srgbRed: comps[0], green: comps[1], blue: comps[2], alpha: 0.30 * CGFloat(bloom))
            let outer = CGColor(srgbRed: comps[0], green: comps[1], blue: comps[2], alpha: 0)
            if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [inner, outer] as CFArray, locations: [0, 1]) {
                ctx.saveGState()
                ctx.drawRadialGradient(grad, startCenter: CGPoint(x: cx, y: cy + 30 * scale), startRadius: 0, endCenter: CGPoint(x: cx, y: cy + 30 * scale), endRadius: 560 * scale, options: [])
                ctx.restoreGState()
            }
        }

        // Wordmark: elastic pop (overshoot then settle).
        let wmPop = easeOutBack((p - 0.12) / 0.45)
        let wmIn = smoothstep(0.12, 0.4, p)
        let wmScale = CGFloat(0.74 + 0.26 * wmPop)
        if let img = textCache.image(spec.wordmark, fontSize: 104 * scale, weight: .bold, color: .white) {
            drawCenteredImage(ctx: ctx, img: img, cx: cx, cy: cy + 40 * scale, alpha: wmIn, scale: wmScale, shadow: true)
        }

        // Accent underline drawing in beneath the wordmark.
        if let accent {
            let lineW = CGFloat(easeOut((p - 0.3) / 0.4)) * 150 * scale
            let lineH = 4 * scale
            let lineY = cy - 6 * scale
            ctx.saveGState()
            ctx.setAlpha(CGFloat(smoothstep(0.3, 0.5, p)))
            ctx.setFillColor(accent)
            let bar = CGRect(x: cx - lineW / 2, y: lineY, width: lineW, height: lineH)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }

        // Tagline.
        if let tag = spec.tagline, !tag.isEmpty {
            let tagIn = smoothstep(0.42, 0.72, p)
            let tagRise = CGFloat(1 - easeOut((p - 0.42) / 0.3)) * 14 * scale
            if let timg = textCache.image(tag, fontSize: 34 * scale, weight: .medium, color: NSColor(white: 0.80, alpha: 1)) {
                drawCenteredImage(ctx: ctx, img: timg, cx: cx, cy: cy - 56 * scale - tagRise, alpha: tagIn, scale: 1, shadow: false)
            }
        }

        // CTA pill near the bottom — fades in last and holds.
        if let cta = spec.cta, !cta.isEmpty, let accent, let comps = accent.components, comps.count >= 3 {
            let ctaIn = smoothstep(0.62, 0.9, p)
            if ctaIn > 0.01, let img = textCache.image(cta, fontSize: 28 * scale, weight: .semibold, color: NSColor(white: 0.98, alpha: 1)) {
                let tw = CGFloat(img.width), th = CGFloat(img.height)
                let padX = 30 * scale, padY = 15 * scale
                let pillW = tw + padX * 2, pillH = th + padY * 2
                let pillY = cy - 150 * scale
                let pill = CGRect(x: cx - pillW / 2, y: pillY - pillH / 2, width: pillW, height: pillH)
                ctx.saveGState()
                ctx.setAlpha(CGFloat(ctaIn))
                ctx.setStrokeColor(CGColor(srgbRed: comps[0], green: comps[1], blue: comps[2], alpha: 0.9))
                ctx.setFillColor(CGColor(srgbRed: comps[0], green: comps[1], blue: comps[2], alpha: 0.14))
                ctx.setLineWidth(1.5 * scale)
                let path = CGPath(roundedRect: pill, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil)
                ctx.addPath(path); ctx.fillPath()
                ctx.addPath(path); ctx.strokePath()
                ctx.draw(img, in: CGRect(x: cx - tw / 2, y: pillY - th / 2, width: tw, height: th))
                ctx.restoreGState()
            }
        }
    }

    // MARK: Shared text blit

    /// Blits a cached (upright) text image centered at (cx, cy) in bottom-left
    /// canvas space, with global alpha, uniform scale, and an optional shadow.
    private static func drawCenteredImage(
        ctx: CGContext, img: CGImage, cx: CGFloat, cy: CGFloat,
        alpha: Double, scale: CGFloat, shadow: Bool
    ) {
        guard alpha > 0.001 else { return }
        let w = CGFloat(img.width) * scale
        let h = CGFloat(img.height) * scale
        let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        if shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 24, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        }
        ctx.draw(img, in: rect)
        ctx.restoreGState()
    }
}
