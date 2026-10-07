import Foundation

/// A replayable list of tool calls for one device, saved as JSON:
///
///     {
///       "name": "Sign in",
///       "steps": [
///         {"launch_app": {"bundle_id": "com.example.app", "restart": true}},
///         {"tap_element": {"id": "email"}},
///         {"type_text": {"text": "me@example.com", "submit": true}},
///         {"wait_for_element": {"text": "Welcome"}},
///         "home"
///       ]
///     }
///
/// Each step is one tool with its arguments, exactly as an agent calls it; a bare name has none.
/// A plain array of steps is a flow too.
public struct Flow: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public var tool: String
        public var arguments: [String: JSONValue]

        public init(_ tool: String, _ arguments: [String: JSONValue] = [:]) {
            self.tool = tool
            self.arguments = arguments
        }

        var json: JSONValue { arguments.isEmpty ? .string(tool) : [tool: .object(arguments)] }
        /// "tap_element {"id":"email"}": the step on one line, as results and the window show it.
        public var summary: String { arguments.isEmpty ? tool : "\(tool) \(JSONValue.object(arguments).compactString)" }
    }

    public var name: String
    public var steps: [Step]

    public init(name: String, steps: [Step]) {
        self.name = name
        self.steps = steps
    }

    /// At most this many steps, so a mistaken file cannot keep a device busy for hours.
    public static let maxSteps = 500

    public static func parse(_ value: JSONValue, name fallback: String = "Flow") throws -> Flow {
        let list: [JSONValue]
        var name = fallback
        switch value {
        case .array(let items): list = items
        case .object(let object):
            guard let items = object["steps"]?.arrayValue else { throw ToolFailure("A flow needs a steps array.") }
            list = items
            if let given = object["name"]?.stringValue, !given.isEmpty { name = given }
        default: throw ToolFailure("A flow is an object with steps, or an array of steps.")
        }
        guard list.count <= maxSteps else { throw ToolFailure("A flow has at most \(maxSteps) steps.") }
        let steps = try list.enumerated().map { index, item -> Step in
            switch item {
            case .string(let tool): return Step(tool)
            case .object(let object) where object.count == 1:
                let (tool, arguments) = object.first!
                switch arguments {
                case .object(let arguments): return Step(tool, arguments)
                case .null: return Step(tool)
                default: throw ToolFailure("Step \(index + 1): the arguments of \(tool) must be an object.")
                }
            default:
                throw ToolFailure(
                    "Step \(index + 1) must be a tool name or an object with one tool, like {\"tap_element\": {\"id\": \"save\"}}.")
            }
        }
        return Flow(name: name, steps: steps)
    }

    public static func load(_ url: URL) throws -> Flow {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ToolFailure("Could not read \(url.path): \(error.localizedDescription)")
        }
        guard let value = try? JSONValue.parse(data) else { throw ToolFailure("\(url.lastPathComponent) is not JSON.") }
        var flow = try parse(value, name: url.deletingPathExtension().lastPathComponent)
        flow.resolveInstallPaths(relativeTo: url.deletingLastPathComponent())
        return flow
    }

    /// A build next to the flow file is found from wherever the flow runs: the app, an agent, CI.
    mutating func resolveInstallPaths(relativeTo folder: URL) {
        for index in steps.indices where steps[index].tool == "install_app" {
            guard let path = steps[index].arguments["path"]?.stringValue, !path.hasPrefix("/"), !path.hasPrefix("~")
            else { continue }
            steps[index].arguments["path"] = .string(folder.appendingPathComponent(path).standardizedFileURL.path)
        }
    }

    /// One step per line, so a flow reads and diffs well.
    public func encoded() -> Data {
        let lines = steps.map { "    " + $0.json.compactString }
        let text = "{\n  \"name\": \(JSONValue.string(name).compactString),\n  \"steps\": [\n"
            + lines.joined(separator: ",\n") + (lines.isEmpty ? "" : "\n") + "  ]\n}\n"
        return Data(text.utf8)
    }
}

// MARK: - Running

extension PhoneTools {
    static let flowDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "run_flow", title: "Run flow",
            description:
                "Replay a flow: a list of tool calls saved as JSON, e.g. recorded in the Mobdev app or written by hand ({\"steps\": [{\"tap_element\": {\"id\": \"login\"}}, {\"type_text\": {\"text\": \"hi\"}}, \"home\"]}). Stops at the first step that fails and says which. Pass path (a .json file on this Mac) or steps, and video to keep a recording of the run.",
            inputSchema: schema([
                "path": ["type": "string", "description": "A flow file on the Mac that runs Mobdev"],
                "steps": [
                    "type": "array", "description": "The steps inline, each a tool name or {\"tool\": {arguments}}",
                ],
                "video": [
                    "type": "string",
                    "description":
                        "Where to save a video of the run on the Mac that runs Mobdev: an absolute path ending in .mp4, in an existing folder. A file there is replaced.",
                ],
            ]),
            readOnly: false)
    ]

    /// Tools a flow may not call: another flow or the tests, and nothing that picks a different device.
    static let flowExcluded: Set<String> = ["run_flow", "run_tests", "list_devices"]

    func runFlowTool(_ args: Arguments, source: String) async throws -> ToolOutput {
        let flow: Flow
        if args.has("path") {
            let path = (try args.string("path") as NSString).expandingTildeInPath
            flow = try Flow.load(URL(fileURLWithPath: path))
        } else if let steps = args.value["steps"], !steps.isNull {
            flow = try Flow.parse(steps)
        } else {
            throw ToolFailure("Pass path or steps.")
        }
        let video = try args.has("video") ? Flow.videoURL(try args.string("video")) : nil
        let result = await Flow.recording(phone, to: video) { await run(flow, source: source) }
        return ToolOutput(text: result.text, data: result.json, isError: !result.passed)
    }

    /// Runs every step through `call`, so each shows in the device's activity and records like any
    /// other call. Stops at the first failure, and before the next step once the task is cancelled.
    public func run(
        _ flow: Flow, source: String, progress: (@Sendable (Int, Flow.Step, ToolOutput, TimeInterval) -> Void)? = nil
    ) async -> FlowResult {
        let started = Date()
        var results: [FlowResult.StepResult] = []
        for (index, step) in flow.steps.enumerated() {
            if Task.isCancelled {
                let output = ToolOutput(text: "Cancelled.", isError: true)
                results.append(.init(step: step, text: output.text, passed: false, seconds: 0))
                progress?(index, step, output, 0)
                break
            }
            let stepStarted = Date()
            var output: ToolOutput
            if Self.flowExcluded.contains(step.tool) || step.arguments["device"] != nil {
                output = ToolOutput(
                    text: "\(step.tool) cannot run inside a flow; a flow runs on one device, without device arguments.",
                    isError: true)
            } else {
                var arguments = step.arguments
                arguments["screenshot"] = false
                do {
                    output = try await call(step.tool, arguments: .object(arguments), source: source, screenshotByDefault: false)
                } catch {
                    output = ToolOutput(text: String(describing: error), isError: true)
                }
                // A wait interrupted by the cancellation says so, not "CancellationError()".
                if output.isError, Task.isCancelled { output = ToolOutput(text: "Cancelled.", isError: true) }
            }
            let seconds = Date().timeIntervalSince(stepStarted)
            results.append(.init(step: step, text: output.text, passed: !output.isError, seconds: seconds))
            progress?(index, step, output, seconds)
            if output.isError { break }
        }
        return FlowResult(flow: flow, steps: results, seconds: Date().timeIntervalSince(started))
    }
}

// MARK: - Video

extension Flow {
    /// The file `run_flow` writes its video to: an absolute .mp4 path in a folder that exists.
    static func videoURL(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ToolFailure("video must be an absolute path on the Mac, like /tmp/run.mp4.")
        }
        let url = URL(fileURLWithPath: expanded)
        guard url.pathExtension.lowercased() == "mp4" else { throw ToolFailure("video must be a path ending in .mp4.") }
        var isFolder: ObjCBool = false
        let folder = url.deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            throw ToolFailure("The folder \(folder) does not exist; create it first.")
        }
        guard !FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) || !isFolder.boolValue else {
            throw ToolFailure("\(url.path) is a folder.")
        }
        return url
    }

    /// Runs a flow while recording `phone`'s screen to `video`, and says in the result where the
    /// video went. Without `video` it only runs the flow.
    public static func recording(
        _ phone: any PhoneBackend, to video: URL?, _ run: () async throws -> FlowResult
    ) async rethrows -> FlowResult {
        guard let video else { return try await run() }
        let recorder = ScreenRecorder.start(to: video) { phone.frame() }
        var result: FlowResult
        do {
            result = try await run()
        } catch {
            _ = try? await recorder.finish()
            try? FileManager.default.removeItem(at: video)
            throw error
        }
        do {
            result.video = try await recorder.finish()
        } catch {
            result.videoProblem = String(describing: error)
        }
        return result
    }
}

public struct FlowResult: Sendable {
    public struct StepResult: Sendable {
        public var step: Flow.Step
        public var text: String
        public var passed: Bool
        public var seconds: TimeInterval
    }

    public var flow: Flow
    public var steps: [StepResult]
    public var seconds: TimeInterval
    /// The run's video, when one was asked for and written.
    public var video: ScreenRecording?
    /// Why there is no video although one was asked for.
    public var videoProblem: String?

    public var passed: Bool { steps.count == flow.steps.count && steps.allSatisfy(\.passed) }

    public var text: String {
        let total = flow.steps.count
        let lines = steps.enumerated().map { index, result in
            let mark = result.passed ? "✓" : "✗"
            let first = result.text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return "\(mark) \(index + 1). \(result.step.summary): \(result.passed ? first : result.text)"
        }
        let head =
            passed
            ? "Flow \"\(flow.name)\" passed: \(total) steps in \(String(format: "%.1f", seconds)) s."
            : "Flow \"\(flow.name)\" failed at step \(steps.count) of \(total): \(steps.last?.step.summary ?? "no steps")."
        return ([head] + lines + [videoLine].compactMap { $0 }).joined(separator: "\n")
    }

    /// "Video: /path/run.mp4 (12.3 s, 98 frames)", or why there is none.
    public var videoLine: String? {
        if let video {
            return String(format: "Video: %@ (%.1f s, %d frames)", video.url.path, video.seconds, video.frames)
        }
        return videoProblem.map { "No video: \($0)" }
    }

    /// The run as Markdown, for a CI job summary or a pull request comment.
    public var markdown: String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = [
            "### \(passed ? "✅" : "❌") Mobdev flow: \(cell(flow.name))", "",
            passed
                ? String(format: "Passed: %d steps in %.1f s.", flow.steps.count, seconds)
                : "Failed at step \(steps.count) of \(flow.steps.count).",
            "", "| | Step | Time | Result |", "|---|---|---|---|",
        ]
        for (index, result) in steps.enumerated() {
            let text = result.passed ? (result.text.split(separator: "\n").first.map(String.init) ?? "") : result.text
            lines.append(
                "| \(result.passed ? "✅" : "❌") | \(index + 1). `\(cell(result.step.summary))` | "
                    + String(format: "%.1f s", result.seconds) + " | \(cell(text)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    var json: JSONValue {
        [
            "name": .string(flow.name), "passed": .bool(passed), "seconds": .number((seconds * 10).rounded() / 10),
            "steps": .number(Double(flow.steps.count)),
            "failed_step": passed ? .null : .number(Double(steps.count)),
            "video": video.map { JSONValue.string($0.url.path) } ?? .null,
        ]
    }
}

// MARK: - Recording

/// Collects a device's steps while someone records a flow: every call made through the tools, by
/// an agent or in the app, and clicks, drags and keys in the app's window. Clicks become
/// tap_element when the tree read shortly before says what was under the pointer.
public final class FlowRecorder: Sendable {
    private struct State {
        var steps: [Flow.Step] = []
        /// The newest tree and when it was read; refreshed while recording.
        var tree: [UIElement]?
        var refresher: Task<Void, Never>?
    }

    private let state = Locked<State?>(nil)

    public init() {}

    public var isRecording: Bool { state.get() != nil }
    public var stepCount: Int { state.get()?.steps.count ?? 0 }
    var hasTree: Bool { state.get()?.tree != nil }

    /// Starts recording. With `tree`, the elements on screen are read about every second and a
    /// half so clicks can be named by element; nil devices (iPhones) record coordinates.
    public func start(tree: (@Sendable () async throws -> [UIElement]?)? = nil) {
        stop()
        state.set(State())
        if let tree {
            let refresher = Task { [weak self] in
                while !Task.isCancelled, self?.isRecording == true {
                    let elements = try? await tree()
                    self?.state.withLock { $0?.tree = elements }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
            state.withLock { $0?.refresher = refresher }
        }
    }

    /// Stops recording and returns what was recorded.
    @discardableResult
    public func stop() -> [Flow.Step] {
        let finished = state.withLock { current -> State? in
            defer { current = nil }
            return current
        }
        finished?.refresher?.cancel()
        return finished?.steps ?? []
    }

    /// Calls that only look, and so replay nothing. Waits are kept: they are what a flow checks.
    static let skipped: Set<String> = [
        "status", "screenshot", "read_screen", "find_text", "ui_tree", "list_apps", "logs", "crash_reports",
        "list_devices", "run_flow", "run_tests", "observe", "start_recording", "stop_recording",
    ]

    /// A successful tool call. Consecutive typing merges into one step.
    public func record(_ tool: String, _ arguments: [String: JSONValue]) {
        guard !Self.skipped.contains(tool) else { return }
        var arguments = arguments
        arguments["screenshot"] = nil
        arguments["device"] = nil
        state.withLock { current in
            guard current != nil else { return }
            if tool == "type_text", let last = current!.steps.last, last.tool == "type_text",
                last.arguments["submit"]?.boolValue != true,
                let before = last.arguments["text"]?.stringValue, let added = arguments["text"]?.stringValue
            {
                var merged = arguments
                merged["text"] = .string(before + added)
                current!.steps[current!.steps.count - 1] = Flow.Step(tool, merged)
            } else {
                current!.steps.append(Flow.Step(tool, arguments))
            }
        }
    }

    /// A click in the app's window, at a point given as fractions of the screen and in screenshot
    /// pixels. An element with a unique identifier or label under the point makes it tap_element.
    public func recordTap(at point: NormalizedPoint, pixels: (x: Int, y: Int)) {
        let tree = state.get()?.tree ?? []
        if let element = Self.element(at: point, in: tree) {
            record("tap_element", element)
        } else {
            record("tap", ["x": .number(Double(pixels.x)), "y": .number(Double(pixels.y))])
        }
    }

    /// Arguments for tap_element naming the smallest tappable element under the point, when its
    /// identifier (or else its label) picks it alone.
    static func element(at point: NormalizedPoint, in tree: [UIElement]) -> [String: JSONValue]? {
        let under = tree.filter { $0.tappable && $0.frame.contains(CGPoint(x: point.x, y: point.y)) }
        guard let element = under.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        if !element.identifier.isEmpty,
            ElementQuery(id: element.identifier, text: nil).matches(in: tree).count == 1
        {
            return ["id": .string(element.identifier)]
        }
        if !element.label.isEmpty, ElementQuery(id: nil, text: element.label).matches(in: tree).count == 1 {
            return ["text": .string(element.label)]
        }
        return nil
    }

    /// The name press_key knows for a key the app's window passes on.
    public static func keyName(usage: UInt8) -> String? {
        let preferred = [
            "return", "escape", "backspace", "tab", "space", "right", "left", "down", "up", "forwarddelete",
            "home", "end", "pageup", "pagedown",
        ]
        return preferred.first { KeyboardLayout.namedKeys[$0] == usage }
            ?? KeyboardLayout.namedKeys.first { $0.value == usage }?.key
    }
}
