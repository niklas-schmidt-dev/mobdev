import CoreGraphics
import Foundation

/// What one run of a project's tests takes.
public struct TestRunOptions: Sendable {
    /// Tests by file name or name; empty runs every test.
    public var tests: [String]
    /// Values for `${NAME}`, over the environment and the project file.
    public var variables: [String: String]
    /// Record each test's screen to `<test>/run.mp4` in the output folder.
    public var video: Bool
    /// Where results.json, junit.xml and each test's files go. Created.
    public var output: URL

    public init(output: URL, tests: [String] = [], variables: [String: String] = [:], video: Bool = true) {
        self.output = output
        self.tests = tests
        self.variables = variables
        self.video = video
    }
}

/// One run of a project's tests on one device, as `results.json` keeps it.
public struct TestRunResult: Sendable, Codable, Equatable {
    public enum Status: String, Sendable, Codable {
        case passed, failed, skipped
    }

    public struct Device: Sendable, Codable, Equatable {
        public var id: String
        public var name: String
        /// "iPhone", "simulator" or "android".
        public var kind: String

        public init(id: String, name: String, kind: String) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    public struct Step: Sendable, Codable, Equatable {
        /// The step as written in the test, so a secret's value never appears here.
        public var summary: String
        public var text: String
        public var passed: Bool
        public var seconds: Double

        public init(summary: String, text: String, passed: Bool, seconds: Double) {
            self.summary = summary
            self.text = text
            self.passed = passed
            self.seconds = seconds
        }
    }

    public struct Test: Sendable, Codable, Equatable {
        public var name: String
        public var slug: String
        public var file: String
        public var status: Status
        public var seconds: Double
        /// The steps that ran, `before_each` first; the last one failed when the test did.
        public var steps: [Step]
        /// 1-based, counting `before_each`, when a step failed.
        public var failedStep: Int?
        /// Why the test failed or was skipped.
        public var message: String
        /// The screen when the test failed, as a PNG on the Mac.
        public var screenshot: String?
        public var video: String?

        /// "✓ Sign in (4.2 s)", "✗ Checkout (1.0 s): step 3 of 5, tap_element {…}: …", "– Pay: not for android".
        public var line: String {
            let time = String(format: "%.1f s", seconds)
            switch status {
            case .passed: return "✓ \(name) (\(time))"
            case .failed: return "✗ \(name) (\(time)): \(message)"
            case .skipped: return "– \(name): \(message)"
            }
        }

        /// "✓ 1. launch_app {…}: Launched …", one per step that ran.
        public var stepLines: [String] {
            steps.enumerated().map { index, step in
                let first = step.text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                return "\(step.passed ? "✓" : "✗") \(index + 1). \(step.summary): \(step.passed ? first : step.text)"
            }
        }
    }

    public static let resultsFileName = "results.json"
    public static let junitFileName = "junit.xml"

    public var project: String
    /// The project folder.
    public var folder: String
    public var device: Device
    public var started: Date
    public var seconds: Double
    /// The build's installation, when the project names one for the device.
    public var setup: [Step]
    /// Why nothing (or nothing more) ran: a test that does not exist, a build that did not install.
    public var error: String?
    public var cancelled: Bool
    public var tests: [Test]
    /// Where results.json and the tests' files are.
    public var output: String
    /// The first failure's screen as a tool returns it. Not saved; `screenshot` names the file.
    public var failureImage: EncodedImage? = nil

    enum CodingKeys: String, CodingKey {
        case project, folder, device, started, seconds, setup, error, cancelled, tests, output
    }

    public init(project: TestProject, device: Device, output: URL) {
        self.project = project.name
        folder = project.folder.path
        self.device = device
        started = Date()
        seconds = 0
        setup = []
        cancelled = false
        tests = []
        self.output = output.path
    }

    public var counts: (passed: Int, failed: Int, skipped: Int) {
        (
            tests.filter { $0.status == .passed }.count, tests.filter { $0.status == .failed }.count,
            tests.filter { $0.status == .skipped }.count
        )
    }

    /// Every test that ran passed, nothing stopped the run, and nothing was cancelled.
    public var passed: Bool { error == nil && !cancelled && tests.allSatisfy { $0.status != .failed } }

    /// "Tests \"My App\" on iPhone 17: 2 passed, 1 failed, 1 skipped in 12.3 s."
    public var summaryLine: String {
        let (passed, failed, skipped) = counts
        var parts = ["\(passed) passed"]
        if failed > 0 || passed == 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        var line = "Tests \"\(project)\" on \(device.name): \(parts.joined(separator: ", ")) in \(String(format: "%.1f", seconds)) s."
        if cancelled { line += " Cancelled." }
        if let error { line += " \(error)" }
        return line
    }

    public var text: String {
        var lines = [summaryLine]
        for step in setup where !step.passed { lines.append("✗ \(step.summary): \(step.text)") }
        for test in tests {
            lines.append(test.line)
            if test.status == .failed {
                if let screenshot = test.screenshot { lines.append("  Screenshot: \(screenshot)") }
                if let video = test.video { lines.append("  Video: \(video)") }
            }
        }
        lines.append("Results: \(output)/\(Self.resultsFileName)")
        return lines.joined(separator: "\n")
    }

    public var json: JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? JSONValue.parse(try encoder.encode(self))) ?? .null
    }

    /// The run as a JUnit report: one suite, one case per test, `before_each` and the test's steps
    /// as its output. A build that did not install is a case of its own with an error.
    public var junit: String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func time(_ seconds: Double) -> String { String(format: "%.3f", seconds) }
        let (_, failed, skipped) = counts
        let errors = error == nil ? 0 : 1
        let suite = "\(project) on \(device.name)"
        let timestamp = ISO8601DateFormatter().string(from: started)
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<testsuites name=\"Mobdev\" tests=\"\(tests.count + errors)\" failures=\"\(failed)\" errors=\"\(errors)\" skipped=\"\(skipped)\" time=\"\(time(seconds))\">",
            "  <testsuite name=\"\(escape(suite))\" tests=\"\(tests.count + errors)\" failures=\"\(failed)\" errors=\"\(errors)\" skipped=\"\(skipped)\" time=\"\(time(seconds))\" timestamp=\"\(timestamp)\">",
        ]
        if let error {
            lines.append("    <testcase name=\"Setup\" classname=\"\(escape(project))\" time=\"\(time(setup.map(\.seconds).reduce(0, +)))\">")
            lines.append("      <error message=\"\(escape(error))\">\(escape(setup.map { "\($0.summary): \($0.text)" }.joined(separator: "\n")))</error>")
            lines.append("    </testcase>")
        }
        for test in tests {
            lines.append(
                "    <testcase name=\"\(escape(test.name))\" classname=\"\(escape(project))\" file=\"\(escape(test.file))\" time=\"\(time(test.seconds))\">"
            )
            switch test.status {
            case .failed:
                lines.append("      <failure message=\"\(escape(test.message))\">\(escape(test.stepLines.joined(separator: "\n")))</failure>")
            case .skipped:
                lines.append("      <skipped message=\"\(escape(test.message))\"/>")
            case .passed:
                lines.append("      <system-out>\(escape(test.stepLines.joined(separator: "\n")))</system-out>")
            }
            lines.append("    </testcase>")
        }
        lines.append("  </testsuite>")
        lines.append("</testsuites>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes results.json and junit.xml into the output folder.
    public func write() throws {
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.resultsFileName), options: .atomic)
        try Data(junit.utf8).write(to: folder.appendingPathComponent(Self.junitFileName), options: .atomic)
    }

    /// The run saved in a folder.
    public static func load(_ folder: URL) throws -> TestRunResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TestRunResult.self, from: try Data(contentsOf: folder.appendingPathComponent(resultsFileName)))
    }
}

/// Runs are kept in the app's folder, the newest 20 per project, for the Tests window,
/// `run_tests` and `test_result`. `Mobdev test` writes wherever `--artifacts` says instead.
public enum TestRuns {
    /// Another root than the app's folder, for tests.
    static let rootOverride = Locked<URL?>(nil)
    public static var folder: URL { (rootOverride.get() ?? MobdevPaths.home).appendingPathComponent("test-runs", isDirectory: true) }
    public static let kept = 20

    /// A project's runs live under its name and a hash of its folder, so two projects called
    /// "App" stay apart.
    public static func projectFolder(_ project: TestProject) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in project.folder.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        let name = "\(TestProject.slug(project.name))-\(String(hash, radix: 16).prefix(8))"
        return folder.appendingPathComponent(name, isDirectory: true)
    }

    /// A new folder for a run, named after the time, after removing the oldest runs.
    public static func newRunFolder(for project: TestProject) throws -> URL {
        let parent = projectFolder(project)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        for old in runs(for: project).dropFirst(kept - 1) { try? FileManager.default.removeItem(at: old) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        var url = parent.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(formatter.string(from: Date())) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A project's run folders, newest first.
    public static func runs(for project: TestProject) -> [URL] {
        let parent = projectFolder(project)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted(by: >).map { parent.appendingPathComponent($0, isDirectory: true) }
    }

    /// The newest run with results, or the one in the named folder.
    public static func result(for project: TestProject, run: String? = nil) -> TestRunResult? {
        if let run {
            guard !run.contains("/"), !run.hasPrefix(".") else { return nil }
            return try? TestRunResult.load(projectFolder(project).appendingPathComponent(run, isDirectory: true))
        }
        for folder in runs(for: project) {
            if let result = try? TestRunResult.load(folder) { return result }
        }
        return nil
    }
}

// MARK: - Running

extension PhoneTools {
    /// Runs a project's tests on this device: installs its build for the device once, then plays
    /// `before_each` and each test's steps as a flow, records a video per test, keeps a screenshot
    /// of each failure, notices when the app crashed, and writes results.json and junit.xml.
    /// Every step shows in the device's activity. Stops after the current test once cancelled.
    public func runTests(
        _ project: TestProject, options: TestRunOptions, source: String,
        progress: (@Sendable (TestRunResult.Test) -> Void)? = nil
    ) async -> TestRunResult {
        let device = phone as? any Device
        let kind = device?.kind ?? (phone.status().input == .bluetooth ? DeviceKind.iPhone : .simulator)
        var result = TestRunResult(
            project: project, device: .init(id: device?.id ?? "", name: device?.name ?? "Device", kind: kind.rawValue),
            output: options.output)

        do {
            try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        } catch {
            result.error = "Could not create \(options.output.path): \(error.localizedDescription)"
            return finished(result)
        }
        var selected: [TestCase] = []
        for query in options.tests {
            guard let test = project.test(query) else {
                let names = project.tests.map(\.slug).joined(separator: ", ")
                result.error = "No test \"\(query)\" in \(project.name). Tests: \(names.isEmpty ? "none" : names)."
                return finished(result)
            }
            if !selected.contains(where: { $0.slug == test.slug }) { selected.append(test) }
        }
        if options.tests.isEmpty { selected = project.tests }
        let variables = Variables(
            project: project, overrides: options.variables, environment: ProcessInfo.processInfo.environment)

        if let build = project.build(for: kind) {
            let install = Flow.Step("install_app", ["path": .string(build.path)])
            let stepStarted = Date()
            let output = await step(install, variables: variables, source: source)
            result.setup = [
                .init(
                    summary: install.summary, text: variables.redact(output.text), passed: !output.isError,
                    seconds: Date().timeIntervalSince(stepStarted))
            ]
            if output.isError {
                result.error = "Could not install \(build.lastPathComponent): \(output.text)"
                return finished(result)
            }
        }

        for test in selected {
            if Task.isCancelled {
                result.cancelled = true
                break
            }
            if !test.runs(on: kind) {
                let skipped = TestRunResult.Test(
                    name: test.name, slug: test.slug, file: test.file.path, status: .skipped, seconds: 0, steps: [],
                    failedStep: nil, message: "not for \(TestCase.platformName(kind))", screenshot: nil, video: nil)
                result.tests.append(skipped)
                progress?(skipped)
                continue
            }
            let (outcome, image) = await run(
                test, in: project, variables: variables, folder: options.output.appendingPathComponent(test.slug, isDirectory: true),
                video: options.video, source: source)
            if let image, result.failureImage == nil { result.failureImage = image }
            result.tests.append(outcome)
            progress?(outcome)
            if Task.isCancelled {
                result.cancelled = true
                break
            }
        }
        return finished(result)
    }

    private func finished(_ result: TestRunResult) -> TestRunResult {
        var result = result
        result.seconds = Date().timeIntervalSince(result.started)
        do {
            try result.write()
        } catch {
            result.error = result.error ?? "Could not write \(result.output): \(error.localizedDescription)"
        }
        return result
    }

    /// One tool call of a test, with its variables filled in.
    private func step(_ step: Flow.Step, variables: Variables, source: String) async -> ToolOutput {
        var arguments = step.arguments
        arguments["screenshot"] = false
        do {
            let filled = try variables.substitute(.object(arguments))
            return try await call(step.tool, arguments: filled, source: source, screenshotByDefault: false)
        } catch {
            return ToolOutput(text: String(describing: error), isError: true)
        }
    }

    private func run(
        _ test: TestCase, in project: TestProject, variables: Variables, folder: URL, video: Bool, source: String
    ) async -> (TestRunResult.Test, EncodedImage?) {
        let written = project.beforeEach + test.flow.steps
        var outcome = TestRunResult.Test(
            name: test.name, slug: test.slug, file: test.file.path, status: .passed, seconds: 0, steps: [], failedStep: nil,
            message: "", screenshot: nil, video: nil)
        // Every variable first, so a test never half-runs because of a typo in its last step.
        var prepared: [Flow.Step] = []
        for (index, step) in written.enumerated() {
            do {
                let filled = try variables.substitute(.object(step.arguments))
                prepared.append(Flow.Step(step.tool, filled.objectValue ?? [:]))
            } catch {
                outcome.status = .failed
                outcome.failedStep = index + 1
                outcome.message = "step \(index + 1) of \(written.count), \(step.summary): \(error)"
                return (outcome, nil)
            }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bundleID = project.app.bundleID
        let statusBefore = bundleID.flatMap { phone.apps?.logs.status(for: $0) }
        let flow = Flow(name: test.name, steps: prepared)
        let result = await Flow.recording(phone, to: video ? folder.appendingPathComponent("run.mp4") : nil) {
            await run(flow, source: source)
        }
        outcome.seconds = result.seconds
        outcome.steps = result.steps.enumerated().map { index, step in
            .init(summary: written[index].summary, text: variables.redact(step.text), passed: step.passed, seconds: step.seconds)
        }
        outcome.video = result.video?.url.path
        if !result.passed {
            outcome.status = .failed
            let index = result.steps.count
            outcome.failedStep = index
            let text = variables.redact(result.steps.last?.text ?? "")
            outcome.message = "step \(index) of \(written.count), \(written[max(index - 1, 0)].summary): \(text)"
        }
        if let bundleID, let after = phone.apps?.logs.status(for: bundleID), after.hasPrefix("crashed"), after != statusBefore {
            outcome.status = .failed
            let crash = "\(bundleID) \(after)"
            outcome.message = outcome.message.isEmpty ? crash : "\(outcome.message) \(crash)"
        }
        var image: EncodedImage?
        if outcome.status == .failed, let frame = phone.frame() {
            if let png = ImageTools.encode(frame, png: true) {
                let file = folder.appendingPathComponent("failure.png")
                if (try? png.data.write(to: file)) != nil { outcome.screenshot = file.path }
            }
            image = ImageTools.screenshot(frame)
        }
        return (outcome, image)
    }
}
