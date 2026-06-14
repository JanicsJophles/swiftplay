import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit

enum RecorderError: Error, CustomStringConvertible {
    case noWindow(pid: pid_t)
    case writerSetup(String)
    case captureStart(String)

    var description: String {
        switch self {
        case .noWindow(let pid):
            return "Couldn't find a capturable window for pid \(pid) within the timeout. For the cinematic pass the app must be visible (scene `launch: show`)."
        case .writerSetup(let why):
            return "Could not set up the video writer: \(why)"
        case .captureStart(let why):
            return "ScreenCaptureKit failed to start: \(why) (Screen Recording permission may be missing)."
        }
    }
}

/// Continuous ScreenCaptureKit recording of a single window into an H.264 `.mov`,
/// plus a capture clock the scene runner timestamps interactions against.
///
/// Single-frame screenshots already live in `Capture`; this is the moving-picture
/// sibling. We capture the window *desktop-independent* (no shadow, no wallpaper)
/// with the system cursor **off** on purpose — the renderer draws its own smooth
/// cursor, so a captured one would double up.
///
/// SCStream delivers frames on its own queue; the writer state is guarded by a
/// lock, hence `@unchecked Sendable`. `start()`/`stop()` bridge SCK's async API
/// to a synchronous call site (semaphores) so the recording flow reads top-to-
/// bottom in the scene runner, the same pattern `Capture` uses.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?

    private var firstPTS: CMTime?
    private var firstSeconds: Double = 0
    private var startedSignal = DispatchSemaphore(value: 0)
    private var didSignalStart = false
    private var stopRequested = false

    /// Set once the first frame is appended. Drives `meta`.
    private(set) var meta: Timeline.Meta?
    let movURL: URL

    init(movURL: URL) {
        self.movURL = movURL
        super.init()
    }

    /// Seconds since the first captured frame, on the same clock as the footage.
    /// Returns 0 before the first frame arrives.
    func elapsed() -> Double {
        lock.lock(); defer { lock.unlock() }
        guard firstPTS != nil else { return 0 }
        return max(0, CACurrentMediaTime() - firstSeconds)
    }

    // MARK: - Lifecycle

    /// Resolve the target window, wire up the writer and stream, start capturing,
    /// and block until the first frame lands (so the caller knows recording is
    /// truly live before it starts driving the app).
    func start(pid: pid_t, titleContains: String?, fps: Int) throws {
        let window = try resolveWindow(pid: pid, titleContains: titleContains)
        let scale = Self.scale(forWindowAt: window.frame)
        let pxW = max(2, Int((window.frame.width * scale).rounded()))
        let pxH = max(2, Int((window.frame.height * scale).rounded()))

        meta = Timeline.Meta(
            windowX: window.frame.minX, windowY: window.frame.minY,
            windowWidth: window.frame.width, windowHeight: window.frame.height,
            scale: scale, sourceWidth: pxW, sourceHeight: pxH, fps: fps
        )

        // Writer
        try? FileManager.default.removeItem(at: movURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: movURL, fileType: .mov)
        } catch {
            throw RecorderError.writerSetup(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pxW,
            AVVideoHeightKey: pxH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: pxW * pxH * 8,  // ~visually-lossless for screen content
                AVVideoMaxKeyFrameIntervalKey: fps,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writerSetup("writer rejected the video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecorderError.writerSetup(writer.error?.localizedDescription ?? "startWriting() failed")
        }
        self.writer = writer
        self.input = input

        // Stream
        let config = SCStreamConfiguration()
        config.width = pxW
        config.height = pxH
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = false
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "ai.swiftplay.recorder"))
        } catch {
            throw RecorderError.captureStart(error.localizedDescription)
        }
        self.stream = stream

        let startSema = DispatchSemaphore(value: 0)
        let startBox = ErrorBox()
        stream.startCapture { err in
            startBox.error = err
            startSema.signal()
        }
        startSema.wait()
        if let err = startBox.error { throw RecorderError.captureStart(err.localizedDescription) }

        // Wait for the first real frame so the capture clock is anchored.
        if startedSignal.wait(timeout: .now() + 8) != .success {
            throw RecorderError.captureStart("no frames arrived within 8s")
        }
    }

    /// Stop capture, flush the writer, and return the recorded duration (seconds).
    @discardableResult
    func stop() -> Double {
        lock.lock(); stopRequested = true; let dur = firstPTS == nil ? 0 : max(0, CACurrentMediaTime() - firstSeconds); lock.unlock()

        // Stop the stream first so no frame callback is in flight; then finish the
        // input under the lock so a late callback can't `append` after
        // `markAsFinished` (which would raise an uncatchable ObjC exception).
        if let stream {
            let sema = DispatchSemaphore(value: 0)
            stream.stopCapture { _ in sema.signal() }
            _ = sema.wait(timeout: .now() + 5)
        }
        lock.lock(); input?.markAsFinished(); lock.unlock()
        if let writer {
            let sema = DispatchSemaphore(value: 0)
            writer.finishWriting { sema.signal() }
            if sema.wait(timeout: .now() + 15) == .timedOut {
                FileHandle.standardError.write(Data("  · warning: writer finish timed out; the .mov may be truncated\n".utf8))
            }
        }
        return dur
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only append "complete" frames — SCStream also emits idle/blank status frames.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete else { return }

        // Everything that touches the writer/input happens under the lock, so an
        // append can never interleave with `stop()`'s `markAsFinished`. The append
        // is fast; holding the lock across it is fine.
        var shouldSignal = false
        lock.lock()
        if !stopRequested, let writer, let input, writer.status != .failed, input.isReadyForMoreMediaData {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            // Anchor the capture clock on the first frame we actually persist, so
            // event times (elapsed()) and the rendered footage share an origin.
            if firstPTS == nil {
                firstPTS = pts
                firstSeconds = CMTimeGetSeconds(pts)
                writer.startSession(atSourceTime: pts)
            }
            input.append(sampleBuffer)
            if !didSignalStart { didSignalStart = true; shouldSignal = true }
        }
        lock.unlock()

        if shouldSignal { startedSignal.signal() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Surfaced via the writer status on stop(); nothing actionable here.
    }

    // MARK: - Helpers

    private final class ErrorBox: @unchecked Sendable { var error: Error? }

    /// Largest non-zero window for the pid, polled until it exists (the window
    /// may not be up the instant after launch).
    private func resolveWindow(pid: pid_t, titleContains: String?) throws -> SCWindow {
        let deadline = Date().addingTimeInterval(6)
        repeat {
            if let w = Self.findWindow(pid: pid, titleContains: titleContains) { return w }
            usleep(200_000)
        } while Date() < deadline
        throw RecorderError.noWindow(pid: pid)
    }

    private static func findWindow(pid: pid_t, titleContains: String?) -> SCWindow? {
        let sema = DispatchSemaphore(value: 0)
        let box = ContentBox()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
            box.content = content
            sema.signal()
        }
        guard sema.wait(timeout: .now() + 4) == .success, let content = box.content else { return nil }

        var mine = content.windows.filter { $0.owningApplication?.processID == pid && $0.frame.width > 1 && $0.frame.height > 1 }
        if let needle = titleContains, !needle.isEmpty {
            let lowered = needle.lowercased()
            mine = mine.filter { ($0.title ?? "").lowercased().contains(lowered) }
        }
        return mine.max { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
    }

    private final class ContentBox: @unchecked Sendable { var content: SCShareableContent? }

    /// Backing scale of the display the window sits on (2 on retina). Mirrors the
    /// derivation in `Capture` — pixelWidth/width, not the points-returning
    /// `CGDisplayPixelsWide`.
    private static func scale(forWindowAt frame: CGRect) -> CGFloat {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(center, 1, &display, &count) == .success, count > 0,
              let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 2 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }
}
