import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// A finished video of a device's screen.
public struct ScreenRecording: Sendable, Equatable {
    public var url: URL
    /// Screens read from the device. The last one is shown `hold` seconds longer.
    public var frames: Int
    public var seconds: TimeInterval
    public var width: Int
    public var height: Int
}

/// Records a device's screen to an H.264 .mp4, e.g. while a flow runs.
///
/// Frames are read on a thread of its own, so a slow read (about 260 ms over adb) never holds up
/// the flow, and each keeps the time it was read: about 10 a second where reads are cheap
/// (simulators, iPhones), and back to back with a short break where they are not (Android: two or
/// three, about one while uiautomator reads the tree). A frame the encoder is not ready for is
/// dropped, never queued. Frames are scaled like
/// screenshots, to a long edge of 1280 pixels. Recording goes on for `tail` seconds after
/// `finish`, so the last step's animation plays out, and the screen as the run left it then stays
/// in the video for `hold` seconds, so a failure is easy to see.
public final class ScreenRecorder: Sendable {
    private struct State {
        /// When `finish` was called, plus the tail.
        var stopAt: TimeInterval?
        var outcome: Result<ScreenRecording, any Error>?
        var waiters: [CheckedContinuation<ScreenRecording, any Error>] = []
    }

    private let url: URL
    private let read: @Sendable () -> CGImage?
    private let interval: TimeInterval
    private let tail: TimeInterval
    private let hold: TimeInterval
    private let longEdge: Int
    private let state = Locked(State())
    /// Cuts the wait between frames short when the recording stops.
    private let wake = DispatchSemaphore(value: 0)

    private init(
        url: URL, interval: TimeInterval, tail: TimeInterval, hold: TimeInterval, longEdge: Int,
        read: @escaping @Sendable () -> CGImage?
    ) {
        self.url = url
        self.interval = interval
        self.tail = tail
        self.hold = hold
        self.longEdge = longEdge
        self.read = read
    }

    /// Starts recording `frame` to `url`, replacing a file there. Call `finish` to stop.
    public static func start(
        to url: URL, interval: TimeInterval = 0.1, tail: TimeInterval = 0.5, hold: TimeInterval = 1.5,
        longEdge: Int = ScreenGeometry.screenshotLongEdge, frame: @escaping @Sendable () -> CGImage?
    ) -> ScreenRecorder {
        let recorder = ScreenRecorder(
            url: url, interval: interval, tail: tail, hold: hold, longEdge: longEdge, read: frame)
        // At once, so a run that ends without a video does not leave an older one looking like its own.
        try? FileManager.default.removeItem(at: url)
        let thread = Thread { recorder.record() }
        thread.name = "Mobdev screen recorder"
        thread.qualityOfService = .userInitiated
        thread.start()
        return recorder
    }

    /// Records `tail` seconds more, then finishes the file. Throws when there is no video: the
    /// device never showed a frame, or the file could not be written.
    @discardableResult
    public func finish() async throws -> ScreenRecording {
        try await withCheckedThrowingContinuation { continuation in
            let outcome = state.withLock { state -> Result<ScreenRecording, any Error>? in
                if state.stopAt == nil { state.stopAt = Self.now + tail }
                if state.outcome == nil { state.waiters.append(continuation) }
                return state.outcome
            }
            wake.signal()
            if let outcome { continuation.resume(with: outcome) }
        }
    }

    /// The video's size for a screen: scaled like a screenshot, with even sides as H.264 wants.
    static func videoSize(width: Int, height: Int, longEdge: Int) -> (width: Int, height: Int) {
        let size = ScreenGeometry.screenshotSize(forFrameWidth: width, height: height, longEdge: longEdge)
        return (max(2, size.width & ~1), max(2, size.height & ~1))
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The recording thread: reads frames until `finish`, then writes the file.
    private func record() {
        var writer: VideoWriter?
        var failure: (any Error)?
        func add(_ image: CGImage, at time: TimeInterval, waiting: Bool) {
            do {
                if writer == nil {
                    let size = Self.videoSize(width: image.width, height: image.height, longEdge: longEdge)
                    writer = try VideoWriter(url: url, width: size.width, height: size.height)
                }
                writer?.append(image, at: time, waiting: waiting)
            } catch {
                failure = error
            }
        }
        while failure == nil {
            if let stopAt = state.get().stopAt, Self.now >= stopAt { break }
            let started = Self.now
            if let image = read() { add(image, at: started, waiting: false) }
            let took = Self.now - started
            // Slow reads leave the device a break for the flow's own commands.
            var pause = max(interval - took, took / 4)
            if let stopAt = state.get().stopAt { pause = min(pause, stopAt - Self.now) }
            if pause > 0 { _ = wake.wait(timeout: .now() + pause) }
        }
        // The last screen, waited for rather than dropped: it is the one the video holds.
        let last = Self.now
        if failure == nil, let image = read() { add(image, at: last, waiting: true) }

        let outcome: Result<ScreenRecording, any Error>
        if let failure {
            writer?.cancel()
            outcome = .failure(failure)
        } else if let writer {
            outcome = Result { try writer.finish(hold: hold) }
        } else {
            outcome = .failure(ToolFailure("The device showed no screen to record."))
        }
        let waiters = state.withLock { state in
            state.outcome = outcome
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(with: outcome) }
    }
}

/// Encodes frames into an .mp4 with their own timestamps. Used from one thread only.
private final class VideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int
    /// When the first frame was read; it is at 0 in the video.
    private var origin: TimeInterval?
    private var last: (time: CMTime, buffer: CVPixelBuffer)?
    private var frames = 0

    init(url: URL, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        // Not shouldOptimizeForNetworkUse: it rewrites the file at the end and removes its temporary
        // copy only after finishWriting returns, too late for `Mobdev flow`, which exits then.
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    // About 2 Mbit/s at 590×1280: sharp text, about 15 MB a minute.
                    AVVideoAverageBitRateKey: width * height * 3,
                    AVVideoExpectedSourceFrameRateKey: 10,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                    // Frames stay in the order they were read, which suits uneven timestamps.
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw ToolFailure("Could not set up the video encoder.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ToolFailure("Could not write \(url.path): \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Adds a frame read at `uptime`. Dropped when the encoder is busy, unless `waiting`.
    func append(_ image: CGImage, at uptime: TimeInterval, waiting: Bool) {
        let origin = self.origin ?? uptime
        self.origin = origin
        let time = CMTime(seconds: uptime - origin, preferredTimescale: 600)
        if let last, time <= last.time { return }
        guard ready(waiting: waiting), let buffer = render(image),
            adaptor.append(buffer, withPresentationTime: time)
        else { return }
        last = (time, buffer)
        frames += 1
    }

    /// Shows the last frame `hold` seconds longer and closes the file.
    func finish(hold: TimeInterval) throws -> ScreenRecording {
        guard let last else {
            cancel()
            throw ToolFailure(
                "Could not encode the video\(writer.error.map { ": \($0.localizedDescription)" } ?? ".")")
        }
        let end = last.time + CMTime(seconds: max(hold, 0.1), preferredTimescale: 600)
        // The same picture again at the end: players keep showing it until then.
        if ready(waiting: true) { adaptor.append(last.buffer, withPresentationTime: end) }
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw ToolFailure(
                "Could not finish the video: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        return ScreenRecording(url: writer.outputURL, frames: frames, seconds: end.seconds, width: width, height: height)
    }

    /// Stops without a file.
    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: writer.outputURL)
    }

    private func ready(waiting: Bool) -> Bool {
        guard writer.status == .writing else { return false }
        if input.isReadyForMoreMediaData || !waiting { return input.isReadyForMoreMediaData }
        for _ in 0..<200 where !input.isReadyForMoreMediaData && writer.status == .writing {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return input.isReadyForMoreMediaData
    }

    /// The image scaled into a pixel buffer, centered on black when its shape differs (a rotation).
    private func render(_ image: CGImage) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let buffer = created else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(bounds)
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width,
                height: size.height))
        return buffer
    }
}
