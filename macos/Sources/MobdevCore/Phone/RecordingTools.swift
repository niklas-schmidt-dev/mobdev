import Foundation

/// A screen recording started by `start_recording`.
struct ActiveRecording: Sendable {
    let recorder: ScreenRecorder
    let url: URL
    let started: Date
    /// The project it went into, told when the video is complete.
    let project: URL?
    /// Ends the recording after `RecordingTools.longest` so a forgotten one does not fill the disk.
    let limit: Task<Void, Never>
}

/// Recording the screen on demand, for agents and scripts: a bug report, a demo, proof that a
/// change works; and saving a full-resolution screenshot into the project, such as for a store
/// listing. Flows and tests record their own runs.
extension PhoneTools {
    /// A recording stops by itself after this many seconds.
    static let longestRecording: TimeInterval = 30 * 60

    static let recordingDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "start_recording", title: "Start recording",
            description:
                "Start recording the screen to an .mp4 on the Mac that runs Mobdev: about 10 frames a second on simulators and iPhones, fewer on Android. Without path it goes to the project's output/recordings (see list_projects), else Mobdev's recordings folder. Stop it with stop_recording; it stops by itself after 30 minutes.",
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
        ToolDefinition(
            name: "save_screenshot", title: "Save screenshot",
            description:
                "Save the screen as a PNG at the device's full resolution into the project's screenshots folder, e.g. path de-DE/iphone-6.9/01-home for App Store screenshots; a file there is replaced. Works as a step in flows and tests, so a test run with --language saves every language. Use screenshot to look at the screen instead.",
            inputSchema: schema(
                [
                    "path": [
                        "type": "string",
                        "description":
                            "Relative to the project's screenshots/ folder, .png added if missing; or an absolute path ending in .png",
                    ]
                ], required: ["path"], screenshot: false),
            readOnly: false),
    ]

    func runRecordingTool(_ name: String, _ args: Arguments) async throws -> ToolOutput? {
        switch name {
        case "start_recording":
            if let active = recording.get() {
                throw ToolFailure("Already recording to \(active.url.path). Call stop_recording first.")
            }
            _ = try currentFrame()
            let project = args.has("path") ? nil : projects.current()
            let url = try args.has("path") ? Flow.videoURL(try args.string("path")) : Self.newRecordingURL(in: project)
            let phone = self.phone
            let recorder = ScreenRecorder.start(to: url, hold: 0.5) { phone.frame() }
            let limit = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.longestRecording * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                _ = try? await self.stopRecording()
            }
            let started = recording.withLock { current -> Bool in
                guard current == nil else { return false }
                current = ActiveRecording(recorder: recorder, url: url, started: Date(), project: project, limit: limit)
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
        case "save_screenshot":
            return try saveScreenshot(args)
        default:
            return nil
        }
    }

    private func saveScreenshot(_ args: Arguments) throws -> ToolOutput {
        let path = try args.string("path")
        let absolute = (path as NSString).expandingTildeInPath.hasPrefix("/")
        let project = absolute ? nil : projects.current()
        guard absolute || project != nil else { throw ToolFailure(projects.missingProject + " Or pass an absolute path.") }
        let base = project.map { $0.appendingPathComponent(TestProject.screenshotsFolderName, isDirectory: true) }
        let url = try Self.file(path, in: base ?? URL(fileURLWithPath: "/"), fileExtension: "png")
        let (frame, _) = try currentFrame()
        guard let png = ImageTools.encode(frame, png: true) else { throw ToolFailure("Could not encode the screenshot.") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.data.write(to: url, options: .atomic)
        } catch {
            throw ToolFailure("Could not write \(url.path): \(error.localizedDescription)")
        }
        if let project { projects.notifyOutput(project, nil) }
        return ToolOutput(
            text: "Saved \(url.path) (\(png.width)×\(png.height) px).",
            data: ["path": .string(url.path), "width": .number(Double(png.width)), "height": .number(Double(png.height))])
    }

    private func stopRecording() async throws -> ScreenRecording {
        guard let active = recording.withLock({ current -> ActiveRecording? in
            defer { current = nil }
            return current
        }) else { throw ToolFailure("Nothing is being recorded. Start with start_recording.") }
        active.limit.cancel()
        let video = try await active.recorder.finish()
        if let project = active.project { projects.notifyOutput(project, .recordings) }
        return video
    }

    /// recording-2026-10-07-153012.mp4 in the project's output/recordings, else in Mobdev's folder.
    static func newRecordingURL(in project: URL? = nil) throws -> URL {
        let folder =
            try project.map { try TestProject.output(.recordings, in: $0) }
            ?? MobdevPaths.home.appendingPathComponent("recordings", isDirectory: true)
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
