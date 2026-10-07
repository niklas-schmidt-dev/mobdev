import Foundation

/// A screen recording started by `start_recording`.
struct ActiveRecording: Sendable {
    let recorder: ScreenRecorder
    let url: URL
    let started: Date
    /// Ends the recording after `RecordingTools.longest` so a forgotten one does not fill the disk.
    let limit: Task<Void, Never>
}

/// Recording the screen on demand, for agents and scripts: a bug report, a demo, proof that a
/// change works. Flows and tests record their own runs.
extension PhoneTools {
    /// A recording stops by itself after this many seconds.
    static let longestRecording: TimeInterval = 30 * 60

    static let recordingDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "start_recording", title: "Start recording",
            description:
                "Start recording the screen to an .mp4 on the Mac that runs Mobdev: about 10 frames a second on simulators and iPhones, fewer on Android. Without path it goes to Mobdev's recordings folder. Stop it with stop_recording; it stops by itself after 30 minutes.",
            inputSchema: schema(
                [
                    "path": [
                        "type": "string",
                        "description": "An absolute path ending in .mp4, in an existing folder. A file there is replaced.",
                    ]
                ], screenshot: false),
            readOnly: false),
        ToolDefinition(
            name: "stop_recording", title: "Stop recording",
            description: "Stop the screen recording started with start_recording and say where the video is.",
            inputSchema: schema([:], screenshot: false), readOnly: false),
    ]

    func runRecordingTool(_ name: String, _ args: Arguments) async throws -> ToolOutput? {
        switch name {
        case "start_recording":
            if let active = recording.get() {
                throw ToolFailure("Already recording to \(active.url.path). Call stop_recording first.")
            }
            _ = try currentFrame()
            let url = try args.has("path") ? Flow.videoURL(try args.string("path")) : Self.newRecordingURL()
            let phone = self.phone
            let recorder = ScreenRecorder.start(to: url, hold: 0.5) { phone.frame() }
            let limit = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.longestRecording * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                _ = try? await self.stopRecording()
            }
            let started = recording.withLock { current -> Bool in
                guard current == nil else { return false }
                current = ActiveRecording(recorder: recorder, url: url, started: Date(), limit: limit)
                return true
            }
            guard started else {
                limit.cancel()
                _ = try? await recorder.finish()
                throw ToolFailure("Another recording started at the same time. Call stop_recording first.")
            }
            return ToolOutput(text: "Recording the screen to \(url.path). Call stop_recording to finish it.")
        case "stop_recording":
            let video = try await stopRecording()
            return ToolOutput(
                text: String(format: "Saved %@ (%.1f s, %d frames).", video.url.path, video.seconds, video.frames),
                data: [
                    "path": .string(video.url.path), "seconds": .number((video.seconds * 10).rounded() / 10),
                    "frames": .number(Double(video.frames)),
                ])
        default:
            return nil
        }
    }

    private func stopRecording() async throws -> ScreenRecording {
        guard let active = recording.withLock({ current -> ActiveRecording? in
            defer { current = nil }
            return current
        }) else { throw ToolFailure("Nothing is being recorded. Start with start_recording.") }
        active.limit.cancel()
        return try await active.recorder.finish()
    }

    /// recordings/recording-2026-10-07-153012.mp4 in Mobdev's folder.
    static func newRecordingURL() throws -> URL {
        let folder = MobdevPaths.home.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        var url = folder.appendingPathComponent("recording-\(formatter.string(from: Date())).mp4")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("recording-\(formatter.string(from: Date()))-\(index).mp4")
            index += 1
        }
        return url
    }
}
