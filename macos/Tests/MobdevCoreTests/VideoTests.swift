import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// H.264 encoding never finished on GitHub's virtualized Macs and stalled the whole test run
/// (2026-10-01), so these run on real Macs only, like the text recognition tests.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "Video encoding stalls on CI runners"))
struct VideoTests {
    func temporaryVideo() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-video-\(UUID().uuidString).mp4")
    }

    func tools(_ phone: FakePhone) -> PhoneTools {
        PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
    }

    /// Duration, the size of the only video track and the number of frames.
    func inspect(_ url: URL) async throws -> (seconds: Double, tracks: Int, size: CGSize, frames: Int) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return (duration.seconds, 0, .zero, 0) }
        let size = try await track.load(.naturalSize)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { frames += 1 }
        }
        return (duration.seconds, tracks.count, size, frames)
    }

    @Test func aFlowRunLeavesAPlayableVideo() async throws {
        let video = temporaryVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let output = try await tools(FakePhone(lines: [("Settings", 420, 300)])).call(
            "run_flow", arguments: ["steps": ["home", ["tap": ["x": 100, "y": 200]]], "video": .string(video.path)],
            source: "test", screenshotByDefault: false)
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("Video: \(video.path) ("), "\(output.text)")
        #expect(output.data?["video"] == .string(video.path))
        let file = try await inspect(video)
        // The 1179×2556 screen scaled like a screenshot: half a second after the flow, then the last
        // frame held 1.5 s.
        #expect(file.tracks == 1)
        #expect(file.size == CGSize(width: 590, height: 1280))
        #expect(file.seconds >= 1.9 && file.seconds < 5, "\(file.seconds)")
        #expect(file.frames >= 2)
    }

    @Test func aFailingFlowStillFinishesItsVideo() async throws {
        let video = temporaryVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let phone = FakePhone(lines: [])
        let output = try await tools(phone).call(
            "run_flow", arguments: ["steps": ["home", ["tap": ["x": 5000, "y": 1]], "home"], "video": .string(video.path)],
            source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.hasPrefix("Flow \"Flow\" failed at step 2 of 3"))
        #expect(output.text.contains("Video: \(video.path)"))
        let file = try await inspect(video)
        #expect(file.tracks == 1)
        #expect(file.seconds > 1)
    }

    @Test func aCancelledFlowStopsAndStillFinishesItsVideo() async throws {
        let video = temporaryVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let phone = FakePhone(lines: [])
        let tools = tools(phone)
        let output = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await tools.call(
                "run_flow", arguments: ["steps": ["home", "home"], "video": .string(video.path)], source: "test",
                screenshotByDefault: false)
        }.value
        #expect(output.text.hasPrefix("Flow \"Flow\" failed at step 1 of 2: home."), "\(output.text)")
        #expect(output.text.contains("✗ 1. home: Cancelled."))
        #expect(phone.events.get().isEmpty)
        #expect(try await inspect(video).tracks == 1)
    }

    @Test func refusesVideoPathsItCannotWrite() async throws {
        let phone = FakePhone(lines: [])
        let tools = tools(phone)
        for (path, message) in [
            ("run.mp4", "absolute path"), ("/tmp/run.mov", "ending in .mp4"),
            ("/nonexistent-\(UUID().uuidString)/run.mp4", "does not exist"),
        ] {
            let output = try await tools.call(
                "run_flow", arguments: ["steps": ["home"], "video": .string(path)], source: "test",
                screenshotByDefault: false)
            #expect(output.isError)
            #expect(output.text.contains(message), "\(output.text)")
        }
        #expect(phone.events.get().isEmpty, "nothing ran")
    }

    @Test func samplesInTheBackgroundAndHoldsTheLastScreen() async throws {
        let video = temporaryVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let white = solid(1), dark = solid(0)
        let stopping = Locked(false)
        // Slow reads, like adb's: the recorder waits for them, never the caller.
        let recorder = ScreenRecorder.start(to: video, hold: 1) {
            Thread.sleep(forTimeInterval: 0.05)
            return stopping.get() ? dark : white
        }
        let started = Date()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        stopping.set(true)
        let recording = try await recorder.finish()
        // Half a second more after finish, for the last step's animation.
        let took = Date().timeIntervalSince(started)
        #expect(took >= 1.5 && took < 2.2, "\(took)")
        // About 10 a second, plus the last screen read when stopping.
        #expect(recording.frames >= 10 && recording.frames <= 18, "\(recording.frames)")
        #expect((recording.width, recording.height) == (588, 1280))
        #expect(recording.seconds >= 2.3 && recording.seconds < 3, "\(recording.seconds)")
        let file = try await inspect(video)
        #expect(file.size == CGSize(width: 588, height: 1280))
        #expect(abs(file.seconds - recording.seconds) < 0.05, "\(file.seconds)")

        // The picture half a second before the end is the last screen.
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let late = try await generator.image(at: CMTime(seconds: recording.seconds - 0.5, preferredTimescale: 600)).image
        let early = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        #expect(brightness(late) < 0.1, "the held frame is the last screen")
        #expect(brightness(early) > 0.9)
    }

    @Test func finishingWithoutAScreenSaysSo() async throws {
        let video = temporaryVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        // An older video there must not pass for this run's.
        try Data("old".utf8).write(to: video)
        let recorder = ScreenRecorder.start(to: video) { nil }
        await #expect(throws: (any Error).self) { try await recorder.finish() }
        #expect(!FileManager.default.fileExists(atPath: video.path))
    }

    @Test func videoSizesAreEvenAndScaledLikeScreenshots() {
        #expect(ScreenRecorder.videoSize(width: 1179, height: 2556, longEdge: 1280) == (590, 1280))
        #expect(ScreenRecorder.videoSize(width: 1280, height: 2856, longEdge: 1280) == (574, 1280))
        #expect(ScreenRecorder.videoSize(width: 2622, height: 1206, longEdge: 1280) == (1280, 588))
        #expect(ScreenRecorder.videoSize(width: 721, height: 401, longEdge: 1280) == (720, 400))
    }

    /// A 1206×2622 screen, like an iPhone 17 simulator's, in one shade of grey.
    func solid(_ gray: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 1206, height: 2622, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1206, height: 2622))
        return context.makeImage()!
    }

    /// The mean brightness from 0 to 1.
    func brightness(_ image: CGImage) -> Double {
        let width = 30, height = 64
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height)
        return Double((0..<width * height).reduce(0) { $0 + Int(pixels[$1]) }) / Double(width * height * 255)
    }
}
