import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

enum RenderError: Error, CustomStringConvertible {
    case noVideoTrack
    case reader(String)
    case writer(String)

    var description: String {
        switch self {
        case .noVideoTrack: return "The footage has no video track."
        case .reader(let s): return "Could not read footage: \(s)"
        case .writer(let s): return "Could not write output: \(s)"
        }
    }
}

/// Turns raw footage + a `Timeline` into a polished promo.
///
/// This is where swiftplay's structural advantage pays off: the camera is *driven*
/// by the recorded interaction rects, not inferred from cursor motion. For each
/// output frame we evaluate a camera (where to look + how far to zoom) and a
/// synthetic cursor position from the timeline, then composite: gradient
/// background, a shadowed rounded-corner "device frame" of the zoomed window, the
/// cursor with click ripples, and captions.
///
/// Compositing is done with Core Graphics rather than a Core Image filter graph —
/// gradients, rounded rects, shadows, and text are first-class in CG and the
/// offline frame rate (no realtime constraint) makes per-frame CGContext draws
/// perfectly affordable.
enum CinematicRenderer {
    static func render(
        movURL: URL,
        timeline: Timeline,
        look: Look,
        outURL: URL,
        progress: (String) -> Void = { _ in }
    ) throws {
        let W = look.width, H = look.height
        let meta = timeline.meta

        // MARK: Reader
        let asset = AVURLAsset(url: movURL)
        let duration = max(0.5, CMTimeGetSeconds(asset.duration))
        guard let track = asset.tracks(withMediaType: .video).first else { throw RenderError.noVideoTrack }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw RenderError.reader(error.localizedDescription) }
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw RenderError.reader("reader rejected the track output") }
        reader.add(readerOutput)
        guard reader.startReading() else { throw RenderError.reader(reader.error?.localizedDescription ?? "startReading() failed") }

        // MARK: Writer
        try? FileManager.default.removeItem(at: outURL)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4) } catch { throw RenderError.writer(error.localizedDescription) }
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: W,
            AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: W * H * 10],
        ])
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: W,
                kCVPixelBufferHeightKey as String: H,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(writerInput) else { throw RenderError.writer("writer rejected the input") }
        writer.add(writerInput)
        guard writer.startWriting() else { throw RenderError.writer(writer.error?.localizedDescription ?? "startWriting() failed") }
        writer.startSession(atSourceTime: .zero)

        // MARK: Tracks derived from the timeline
        let camera = CameraTrack(timeline: timeline, look: look)
        let cursor = CursorTrack(timeline: timeline)
        let overlays = OverlayTrack(timeline: timeline)

        // Geometry that's constant across frames.
        let layout = FrameLayout(canvas: CGSize(width: W, height: H), source: CGSize(width: meta.sourceWidth, height: meta.sourceHeight), look: look)
        let bg = Gradient(spec: look.background)
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let textCache = TextCache()

        // Time compression: fast-forward dead stretches. `lastWrittenOut` lets the
        // loop drop frames that would crowd the output cadence inside a segment.
        let warp = TimeWarp(look.timeWarp)
        var lastWrittenOut = -1.0

        var firstPTS: CMTime?
        var frameCount = 0
        var writtenCount = 0

        while reader.status == .reading, let sample = readerOutput.copyNextSampleBuffer() {
            // Drain Core Image / Core Graphics temporaries every frame. The
            // compositing path allocates several CGImages + CIImages per frame
            // (source decode, motion blur, the tilted off-screen panel, and the
            // perspective warp); without an explicit pool they pile up to many GB
            // because nothing returns to the run loop in this tight read/write
            // loop. This is the single thing that keeps the renderer flat in RAM.
            try autoreleasepool {
                let wrote = try renderOneFrame(
                    sample: sample, firstPTS: &firstPTS, reader: reader,
                    writer: writer, writerInput: writerInput, adaptor: adaptor,
                    W: W, H: H, meta: meta, layout: layout, bg: bg,
                    camera: camera, cursor: cursor, overlays: overlays, look: look,
                    textCache: textCache, ciContext: ciContext, colorSpace: colorSpace,
                    frameCount: frameCount, duration: duration,
                    warp: warp, lastWrittenOut: &lastWrittenOut, progress: progress
                )
                if wrote { writtenCount += 1 }
            }
            frameCount += 1
        }

        writerInput.markAsFinished()
        let finishSema = DispatchSemaphore(value: 0)
        writer.finishWriting { finishSema.signal() }
        _ = finishSema.wait(timeout: .now() + 60)

        if writer.status == .failed {
            throw RenderError.writer(writer.error?.localizedDescription ?? "finishWriting() failed")
        }
        if warp.isActive {
            progress("\(writtenCount)/\(frameCount) frames (time-compressed)")
        } else {
            progress("\(frameCount) frames")
        }
    }

    /// One frame of the read → composite → write pipeline, factored out so the
    /// caller can wrap it in an `autoreleasepool` (see the loop above).
    private static func renderOneFrame(
        sample: CMSampleBuffer, firstPTS: inout CMTime?, reader: AVAssetReader,
        writer: AVAssetWriter, writerInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        W: Int, H: Int, meta: Timeline.Meta, layout: FrameLayout, bg: Gradient,
        camera: CameraTrack, cursor: CursorTrack, overlays: OverlayTrack, look: Look,
        textCache: TextCache, ciContext: CIContext, colorSpace: CGColorSpace,
        frameCount: Int, duration: Double,
        warp: TimeWarp, lastWrittenOut: inout Double, progress: (String) -> Void
    ) throws -> Bool {
        guard let srcBuffer = CMSampleBufferGetImageBuffer(sample) else { return false }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if firstPTS == nil { firstPTS = pts }
        let t = max(0, CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS!)))   // source time

        // Time warp: where does this source frame land in the final cut, and is it
        // inside a compressed segment? Drop frames that would crowd the output
        // cadence (that's what turns 18s of logs into a ~2s scrub).
        let outT = warp.output(forSource: t)
        let warpSeg = warp.segment(atSource: t)
        if lastWrittenOut >= 0, outT - lastWrittenOut < 0.75 / Double(max(1, look.fps)) {
            return false   // skip — too close to the last written frame
        }
        let outPTS = CMTime(seconds: outT, preferredTimescale: 600)

        let srcCG = ciContext.createCGImage(CIImage(cvPixelBuffer: srcBuffer), from: CGRect(x: 0, y: 0, width: meta.sourceWidth, height: meta.sourceHeight))
        guard let srcCG else { return false }

        // Output pixel buffer + a top-left-origin CG context over it. The pool
        // can be briefly nil right after startSession — wait for it rather than
        // aborting the whole render on the first frame.
        var pool = adaptor.pixelBufferPool
        var poolWait = 0
        while pool == nil, poolWait < 1000, writer.status != .failed {
            usleep(2000); poolWait += 1; pool = adaptor.pixelBufferPool
        }
        guard let pool, let pb = makePixelBuffer(pool: pool) else {
            throw RenderError.writer(writer.error?.localizedDescription ?? "pixel buffer pool unavailable")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: W, height: H, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            CVPixelBufferUnlockBaseAddress(pb, [])
            throw RenderError.writer("could not create a drawing context")
        }
        // No context flip: a CVPixelBuffer-backed context writes row 0 to the
        // top of the encoded frame, so drawing in CG's native bottom-left space
        // yields upright video (verified end-to-end). The layout math is done
        // in top-left coords and converted to bottom-left at draw time via the
        // `bl` helpers in drawFrame.
        ctx.interpolationQuality = .high

        drawFrame(
            ctx: ctx, srcCG: srcCG, t: t, layout: layout, bg: bg,
            camera: camera, cursor: cursor, overlays: overlays,
            look: look, canvas: CGSize(width: W, height: H),
            textCache: textCache, ciContext: ciContext, duration: duration,
            warpBlur: warpSeg?.blur ?? 0
        )

        CVPixelBufferUnlockBaseAddress(pb, [])

        while !writerInput.isReadyForMoreMediaData {
            if writer.status == .failed { break }
            usleep(2000)
        }
        if writer.status == .failed {
            throw RenderError.writer(writer.error?.localizedDescription ?? "writer failed mid-render")
        }
        adaptor.append(pb, withPresentationTime: outPTS)
        lastWrittenOut = outT

        if frameCount % 120 == 0 { progress("frame \(frameCount) · src \(String(format: "%.1fs", t)) → out \(String(format: "%.1fs", outT))") }
        return true
    }

    // MARK: - Per-frame compositing

    private static func drawFrame(
        ctx: CGContext, srcCG: CGImage, t: Double,
        layout: FrameLayout, bg: Gradient,
        camera: CameraTrack, cursor: CursorTrack, overlays: OverlayTrack,
        look: Look, canvas: CGSize, textCache: TextCache, ciContext: CIContext,
        duration: Double, warpBlur: Double = 0
    ) {
        // All layout is computed in top-left (y-down) coords; the context is CG's
        // native bottom-left (y-up). Convert rects/points at the moment of drawing
        // with these helpers — one consistent vertical flip of the whole canvas.
        let H = canvas.height
        func blRect(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }
        func blPt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: H - p.y) }

        // Background gradient.
        bg.draw(in: ctx, size: canvas)

        // Emerald brand bloom behind where the panel sits (top-left screenRect).
        CreativeLayer.drawGlow(ctx: ctx, canvas: canvas, panelRect: layout.screenRect, spec: look.glow, t: t)

        // Camera → where the source maps onto the canvas this frame.
        let cam = camera.eval(at: t)
        let placement = layout.placement(center: cam.center, zoom: cam.zoom)
        let screenRect = blRect(layout.screenRect)
        let radius = look.cornerRadius * min(canvas.width, canvas.height)
        let roundedPath = CGPath(roundedRect: screenRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // 3D tilt: project the (top-left) screen rect's four corners into a tilted
        // quad. `quad` is in top-left coords; the renderer warps the flat panel
        // image onto it and routes overlays through `quad.map`. When the tilt is
        // identity the quad *is* the rect and we take the original 2D path.
        let tilt = look.tiltValue
        // Project, then fit the tilted quad inside the canvas safe area so the
        // perspective-widened near edge never clips against the output bounds.
        let quad = Projector.project(rect: layout.screenRect, tilt: tilt)
            .fitted(inCanvas: canvas, padding: look.padding)
        let tilted = !tilt.isIdentity

        // Motion blur during fast camera moves — the single biggest "commercial"
        // upgrade. Sample the camera one frame back, measure how far the content
        // slid on screen, and directionally blur the window proportional to that
        // speed. Blur is symmetric so the angle's sign doesn't matter (dodges the
        // source/canvas flip). Overlays are drawn after, so they stay razor sharp.
        var windowImage = srcCG
        let dt = 1.0 / Double(max(1, look.fps))
        let prevCam = camera.eval(at: max(0, t - dt))
        let prevPlace = layout.placement(center: prevCam.center, zoom: prevCam.zoom)
        let ref = CGPoint(x: layout.source.width / 2, y: layout.source.height / 2)
        let nowP = placement.toCanvas(sourcePoint: ref)
        let wasP = prevPlace.toCanvas(sourcePoint: ref)
        let vx = nowP.x - wasP.x, vy = nowP.y - wasP.y
        let speed = (vx * vx + vy * vy).squareRoot()
        if speed > 3.5 {
            let radiusSource = min((speed - 3.5) * 0.9, 36) / max(0.001, placement.s)
            if radiusSource > 0.6 {
                let ci = CIImage(cgImage: srcCG)
                let blurred = ci
                    .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radiusSource, kCIInputAngleKey: atan2(vy, vx)])
                    .cropped(to: ci.extent)
                if let cg = ciContext.createCGImage(blurred, from: ci.extent) { windowImage = cg }
            }
        }

        // Time-warp speed-blur: while inside a compressed segment the content is
        // scrubbing past 8× faster than capture, so streak it vertically to sell
        // the high-speed scroll (camera motion-blur above is content-agnostic).
        if warpBlur > 0.5 {
            let ci = CIImage(cgImage: windowImage)
            let blurred = ci
                .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: warpBlur, kCIInputAngleKey: Double.pi / 2])
                .cropped(to: ci.extent)
            if let cg = ciContext.createCGImage(blurred, from: ci.extent) { windowImage = cg }
        }

        if tilted {
            drawTiltedPanel(
                ctx: ctx, windowImage: windowImage, placement: placement,
                layout: layout, quad: quad, radius: radius, canvas: canvas,
                ciContext: ciContext
            )
        } else {
            // ---- Flat 2D path (unchanged) ----
            // Drop shadow behind the framed window.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -radius * 0.6), blur: radius * 1.6, color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.addPath(roundedPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            // The zoomed window content, clipped to the rounded frame.
            ctx.saveGState()
            ctx.addPath(roundedPath)
            ctx.clip()
            ctx.draw(windowImage, in: blRect(placement.drawRect))
            ctx.restoreGState()

            // Device bezel: soft dark outer edge + faint inner highlight.
            ctx.saveGState()
            ctx.addPath(roundedPath)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokePath()
            ctx.addPath(roundedPath)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Synthetic cursor + click ripples, mapped through the same placement AND,
        // when tilted, through the quad homography so they stay glued to the
        // tilted surface. `placement.toCanvas` → top-left canvas point on the flat
        // panel → `quad.map` → its position on the tilted panel → bl-convert.
        func surfacePoint(_ src: CGPoint) -> CGPoint {
            let flat = placement.toCanvas(sourcePoint: src)   // top-left, flat panel
            let onSurface = tilted ? quad.map(flat) : flat    // top-left, tilted
            return blPt(onSurface)
        }
        if look.cursor {
            for ripple in overlays.ripples(at: t) {
                let p = surfacePoint(ripple.point)
                drawRipple(ctx: ctx, at: p, progress: ripple.progress, scale: layout.uiScale)
            }
            if let cs = cursor.state(at: t), cs.alpha > 0.01 {
                let p = surfacePoint(cs.point)
                drawCursor(ctx: ctx, tip: p, scale: layout.uiScale, alpha: cs.alpha)
            }
        }

        // Vignette: darken the corners to pull focus to the panel. Sits above the
        // panel + cursor but below text so captions stay crisp.
        CreativeLayer.drawVignette(ctx: ctx, canvas: canvas, intensity: look.vignette)

        // Is the intro title card still covering the app this frame? If so, the
        // step caption underneath it is suppressed (the headline carries it).
        let introCovering = look.intro.map { CreativeLayer.introActive(spec: $0, t: t) } ?? false

        // Captions and key pills live in the letterbox margins (below / above the
        // window) so they never cover the UI — cleaner than a lower-third overlay.
        if look.captions, !introCovering {
            let frame = layout.screenRect                                  // top-left
            let captionCY = H - (frame.maxY + canvas.height) / 2           // bottom margin → bl
            let keyCY = H - frame.minY / 2                                 // top margin → bl
            if let cap = overlays.captionState(at: t) {
                // Fade + rise in over 0.3s, fade out over the last 0.3s.
                let fadeIn = CreativeLayer.smoothstep(0, 0.3, cap.age)
                let fadeOut = CreativeLayer.smoothstep(0, 0.3, cap.remaining)
                let a = min(fadeIn, fadeOut)
                let rise = CGFloat((1 - fadeIn)) * 14 * layout.uiScale     // starts low, settles up
                drawCaption(ctx: ctx, text: cap.text, canvas: canvas, centerY: captionCY, scale: layout.uiScale, textCache: textCache, alpha: a, rise: -rise)
            }
            if let key = overlays.keyPill(at: t) {
                drawKeyPill(ctx: ctx, text: key, canvas: canvas, centerY: keyCY, scale: layout.uiScale, textCache: textCache)
            }
        }

        // Creative bookends, drawn on top of everything.
        if let intro = look.intro, CreativeLayer.introActive(spec: intro, t: t) {
            CreativeLayer.drawIntro(ctx: ctx, canvas: canvas, spec: intro, t: t, scale: layout.uiScale, textCache: textCache)
        }
        if let outro = look.outro, CreativeLayer.outroActive(spec: outro, t: t, duration: duration) {
            CreativeLayer.drawOutro(ctx: ctx, canvas: canvas, spec: outro, t: t, duration: duration, scale: layout.uiScale, textCache: textCache)
        }
    }

    // MARK: - Tilted panel (3D)

    /// Renders the framed window (clipped content + rounded corners + bezel) into a
    /// flat off-screen image, then warps that image onto the tilted `quad` with a
    /// `CIPerspectiveTransform` and composites it — with a tilt-riding drop shadow
    /// behind it — into the bottom-left output context.
    ///
    /// Coordinate spaces:
    ///   • `layout.screenRect` is top-left. The off-screen panel is rendered
    ///     upright in its own bitmap (0,0 = its top-left).
    ///   • `quad` corners are top-left canvas points. `CIPerspectiveTransform`
    ///     works in CI's bottom-left space, so we flip the quad corners by canvas
    ///     height before handing them over, and the perspective filter maps the
    ///     panel image's extent corners onto them.
    private static func drawTiltedPanel(
        ctx: CGContext, windowImage: CGImage, placement: FrameLayout.Placement,
        layout: FrameLayout, quad: Quad, radius: CGFloat, canvas: CGSize,
        ciContext: CIContext
    ) {
        let H = canvas.height
        let panelRect = layout.screenRect                  // top-left
        let pw = Int(ceil(panelRect.width))
        let ph = Int(ceil(panelRect.height))
        guard pw > 1, ph > 1 else { return }

        // 1) Render the flat panel into its own upright bitmap (bottom-left CG, so
        //    the resulting CGImage is upright and CIPerspectiveTransform receives a
        //    normally-oriented image). Local space: rect at origin.
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let panelCtx = CGContext(
            data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        panelCtx.interpolationQuality = .high

        let localRect = CGRect(x: 0, y: 0, width: CGFloat(pw), height: CGFloat(ph))
        let localRounded = CGPath(roundedRect: localRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Content: the placement.drawRect is in canvas top-left space relative to
        // screenRect; re-base it to the panel's local origin, then bl-flip for the
        // panel context.
        let drawLocalTL = CGRect(
            x: placement.drawRect.minX - panelRect.minX,
            y: placement.drawRect.minY - panelRect.minY,
            width: placement.drawRect.width, height: placement.drawRect.height
        )
        let drawLocalBL = CGRect(
            x: drawLocalTL.minX, y: CGFloat(ph) - drawLocalTL.maxY,
            width: drawLocalTL.width, height: drawLocalTL.height
        )

        panelCtx.saveGState()
        panelCtx.addPath(localRounded)
        panelCtx.clip()
        panelCtx.draw(windowImage, in: drawLocalBL)
        panelCtx.restoreGState()

        // Bezel, baked into the panel so it warps with the tilt.
        panelCtx.saveGState()
        panelCtx.addPath(localRounded)
        panelCtx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        panelCtx.setLineWidth(2.5)
        panelCtx.strokePath()
        panelCtx.addPath(localRounded)
        panelCtx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        panelCtx.setLineWidth(1)
        panelCtx.strokePath()
        panelCtx.restoreGState()

        guard let panelImage = panelCtx.makeImage() else { return }

        // 2) Drop shadow that rides the tilt: fill the quad (in bottom-left canvas
        //    space) with black under a soft shadow, offset slightly down. Drawn
        //    before the warped panel so the panel sits on top of its own shadow.
        func bl(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: H - p.y) }
        let qTL = bl(quad.topLeft), qTR = bl(quad.topRight)
        let qBR = bl(quad.bottomRight), qBL = bl(quad.bottomLeft)

        let shadowPath = CGMutablePath()
        shadowPath.move(to: qTL)
        shadowPath.addLine(to: qTR)
        shadowPath.addLine(to: qBR)
        shadowPath.addLine(to: qBL)
        shadowPath.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -radius * 0.6), blur: radius * 1.8, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.addPath(shadowPath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // 3) Warp the flat panel onto the quad with CIPerspectiveTransform. The
        //    filter maps the input image's extent corners (BL,BR,TR,TL) to the four
        //    given points — so we feed the bottom-left-space quad corners. The
        //    output is an infinite CIImage we crop to the quad's bounding box and
        //    blit into the canvas at that box.
        // Bounding box of the projected quad in bottom-left canvas space.
        let xs = [qTL.x, qTR.x, qBR.x, qBL.x], ys = [qTL.y, qTR.y, qBR.y, qBL.y]
        let bbox = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -2, dy: -2)

        let ci = CIImage(cgImage: panelImage)
        // CIPerspectiveTransform's output extent is effectively infinite; crop it
        // to the projected bounding box before rasterizing so `createCGImage`
        // doesn't try to realize an unbounded image (the runaway-memory trap).
        let warped = ci.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(x: qTL.x, y: qTL.y),
            "inputTopRight": CIVector(x: qTR.x, y: qTR.y),
            "inputBottomRight": CIVector(x: qBR.x, y: qBR.y),
            "inputBottomLeft": CIVector(x: qBL.x, y: qBL.y),
        ]).cropped(to: bbox)

        guard let warpedCG = ciContext.createCGImage(warped, from: bbox) else { return }
        ctx.draw(warpedCG, in: bbox)
    }

    // MARK: - Cursor / ripple / captions

    private static func drawCursor(ctx: CGContext, tip: CGPoint, scale: CGFloat, alpha: Double = 1) {
        // Classic macOS arrow, tip at the origin. Shape is authored y-down (the
        // arrow hangs below the tip); the context is bottom-left, so down is -y.
        let s = 1.9 * scale
        let pts: [CGPoint] = [
            (0, 0), (0, 16), (3.7, 12.3), (6.4, 18.6),
            (8.9, 17.4), (6.2, 11.2), (11, 11),
        ].map { CGPoint(x: tip.x + $0.0 * s, y: tip.y - $0.1 * s) }

        let path = CGMutablePath()
        path.addLines(between: pts)
        path.closeSubpath()

        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * scale), blur: 3 * scale, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()

        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.2 * scale)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawRipple(ctx: CGContext, at p: CGPoint, progress: Double, scale: CGFloat) {
        let eased = 1 - pow(1 - progress, 3)           // ease-out
        let radius = (6 + eased * 34) * scale
        let alpha = (1 - progress) * 0.5
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(2.5 * scale)
        ctx.addEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        ctx.strokePath()
        // soft fill flash early in the ripple
        ctx.setFillColor(NSColor.white.withAlphaComponent(alpha * 0.25).cgColor)
        ctx.addEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawCaption(ctx: CGContext, text: String, canvas: CGSize, centerY: CGFloat, scale: CGFloat, textCache: TextCache, alpha: Double = 1, rise: CGFloat = 0) {
        guard alpha > 0.001 else { return }
        let fontSize = 26 * scale
        guard let img = textCache.image(text, fontSize: fontSize, weight: .semibold, color: .white) else { return }
        let tw = CGFloat(img.width), th = CGFloat(img.height)
        let padX = 28 * scale, padY = 14 * scale
        let pillW = tw + padX * 2, pillH = th + padY * 2
        let x = (canvas.width - pillW) / 2
        let y = centerY - pillH / 2 + rise               // centered in the bottom margin (+ rise-in offset)
        let pill = CGRect(x: x, y: y, width: pillW, height: pillH)
        let r = pillH / 2
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        ctx.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 16 * scale, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
        ctx.fillPath()
        ctx.draw(img, in: CGRect(x: x + padX, y: y + padY, width: tw, height: th))
        ctx.restoreGState()
    }

    private static func drawKeyPill(ctx: CGContext, text: String, canvas: CGSize, centerY: CGFloat, scale: CGFloat, textCache: TextCache) {
        let pretty = prettyChord(text)
        let fontSize = 22 * scale
        guard let img = textCache.image(pretty, fontSize: fontSize, weight: .bold, color: .white) else { return }
        let tw = CGFloat(img.width), th = CGFloat(img.height)
        let padX = 18 * scale, padY = 12 * scale
        let pillW = tw + padX * 2, pillH = th + padY * 2
        let x = (canvas.width - pillW) / 2
        let y = centerY - pillH / 2                     // centered in the top margin
        let pill = CGRect(x: x, y: y, width: pillW, height: pillH)
        let r = 10 * scale
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 12 * scale, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setFillColor(NSColor(white: 0.16, alpha: 0.92).cgColor)
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1 * scale)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.draw(img, in: CGRect(x: x + padX, y: y + padY, width: tw, height: th))
    }

    /// "cmd+shift+s" → "⌘⇧S", "return" → "Return". Mirrors `Keyboard`'s tokens.
    private static func prettyChord(_ spec: String) -> String {
        let map: [String: String] = [
            "cmd": "⌘", "command": "⌘", "shift": "⇧", "opt": "⌥", "option": "⌥",
            "alt": "⌥", "ctrl": "⌃", "control": "⌃", "return": "Return", "enter": "Return",
            "tab": "⇥", "space": "Space", "escape": "Esc", "esc": "Esc",
            "comma": ",", "period": ".", "slash": "/",
            "left": "←", "right": "→", "up": "↑", "down": "↓",
        ]
        let parts = spec.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.map { map[$0.lowercased()] ?? $0.uppercased() }.joined()
    }

    // MARK: - Pixel buffer helper

    private static func makePixelBuffer(pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }
}
