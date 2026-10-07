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
    /// A language such as "de-DE" to run the tests in: the simulator's, or the Android app's. The
    /// run sets it before the first test, passes it as `${LANGUAGE}` and puts the old one back.
    public var language: String?

    public init(
        output: URL, tests: [String] = [], variables: [String: String] = [:], video: Bool = true, language: String? = nil
    ) {
        self.output = output
        self.tests = tests
        self.variables = variables
        self.video = video
        self.language = language
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
        /// "3", or "3.2" for the second step inside step 3, counting `before_each`. Nil in results
        /// written before steps nested.
        public var number: String?
        /// "round 2" or "attempt 2" when a repeat or retry ran the step again.
        public var round: String?
        /// It failed, and the test went on: the step was optional, or a retry ran it again.
        public var tolerated: Bool?

        public init(
            summary: String, text: String, passed: Bool, seconds: Double, number: String? = nil, round: String? = nil,
            tolerated: Bool? = nil
        ) {
            self.summary = summary
            self.text = text
            self.passed = passed
            self.seconds = seconds
            self.number = number
            self.round = round
            self.tolerated = tolerated
        }

        /// "✓ 3.2. tap {…} (round 2): Tapped …", indented by how deep the step is.
        func line(_ fallback: Int) -> String {
            let number = self.number ?? String(fallback)
            let mark = passed ? "✓" : tolerated == true ? "–" : "✗"
            let first = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let depth = number.filter { $0 == "." }.count
            return String(repeating: "  ", count: depth)
                + "\(mark) \(number). \(summary)\(round.map { " (\($0))" } ?? ""): \(passed ? first : text)"
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
        /// 1-based, counting `before_each`, when a step failed: the test's own step, also when the
        /// failure was inside it (the message says where).
        public var failedStep: Int?
        /// Why the test failed or was skipped.
        public var message: String
        /// The screen when the test failed, as a PNG on the Mac.
        public var screenshot: String?
        public var video: String?
        /// What the project's app printed during a failed test, its newest lines.
        public var log: [String]?
        /// Files the test's checks wrote, such as the diff and the actual screen of a failed
        /// `assert_screenshot`. Nil when there are none, and in results from before checks.
        public var files: [String]? = nil

        /// "✓ Sign in (4.2 s)", "✗ Checkout (1.0 s): step 3 of 5, tap_element {…}: …", "– Pay: not for android".
        public var line: String {
            let time = String(format: "%.1f s", seconds)
            switch status {
            case .passed: return "✓ \(name) (\(time))"
            case .failed: return "✗ \(name) (\(time)): \(message)"
            case .skipped: return "– \(name): \(message)"
            }
        }

        /// "✓ 1. launch_app {…}: Launched …", one per step that ran, nested ones numbered like 3.2.
        public var stepLines: [String] {
            steps.enumerated().map { index, step in step.line(index + 1) }
        }

        /// The failure's files and the app's output, indented under the test's line.
        public var detailLines: [String] {
            guard status == .failed else { return [] }
            var lines: [String] = []
            if let screenshot { lines.append("  Screenshot: \(screenshot)") }
            if let video { lines.append("  Video: \(video)") }
            for file in files ?? [] { lines.append("  File: \(file)") }
            if let log, !log.isEmpty {
                lines.append("  The app printed:")
                lines += log.suffix(TestRunResult.shownLogLines).map { "    \($0)" }
            }
            return lines
        }
    }

    /// How many of a failed test's app lines the summaries show; results.json keeps more.
    public static let shownLogLines = 12
    static let keptLogLines = 60

    public static let resultsFileName = "results.json"
    public static let junitFileName = "junit.xml"

    public var project: String
    /// The project folder.
    public var folder: String
    public var device: Device
    /// The language the tests ran in, when the run set one.
    public var language: String?
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
        case project, folder, device, language, started, seconds, setup, error, cancelled, tests, output
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
        var line = "Tests \"\(project)\" on \(device.name)\(language.map { " in \($0)" } ?? ""): \(parts.joined(separator: ", ")) in \(String(format: "%.1f", seconds)) s."
        if cancelled { line += " Cancelled." }
        if let error { line += " \(error)" }
        return line
    }

    public var text: String {
        var lines = [summaryLine]
        for step in setup where !step.passed { lines.append("✗ \(step.summary): \(step.text)") }
        for test in tests {
            lines.append(test.line)
            lines += test.detailLines
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
                var body = test.stepLines
                if let log = test.log, !log.isEmpty { body += ["", "The app printed:"] + log }
                lines.append("      <failure message=\"\(escape(test.message))\">\(escape(body.joined(separator: "\n")))</failure>")
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

    public static let summaryFileName = "summary.md"

    /// The run as Markdown, for a CI job summary or a pull request comment: a line with the counts
    /// and a table with every test, the failed step of each failure.
    public var markdown: String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        let (passed, failed, skipped) = counts
        let mark = self.passed ? "✅" : "❌"
        let place = cell(device.name) + (language.map { " in \(cell($0))" } ?? "")
        var lines = ["### \(mark) Mobdev tests: \(cell(project)) on \(place)", ""]
        var counts = ["\(passed) passed"]
        if failed > 0 || passed == 0 { counts.append("\(failed) failed") }
        if skipped > 0 { counts.append("\(skipped) skipped") }
        lines.append(counts.joined(separator: ", ") + String(format: " in %.1f s.", seconds) + (cancelled ? " Cancelled." : ""))
        if let error { lines += ["", "**Could not run:** \(cell(error))"] }
        guard !tests.isEmpty else { return lines.joined(separator: "\n") + "\n" }
        lines += ["", "| | Test | Time | Details |", "|---|---|---|---|"]
        for test in tests {
            let icon = switch test.status {
            case .passed: "✅"
            case .failed: "❌"
            case .skipped: "⏭️"
            }
            let time = test.status == .skipped ? "" : String(format: "%.1f s", test.seconds)
            lines.append("| \(icon) | \(cell(test.name)) | \(time) | \(test.status == .passed ? "" : cell(test.message)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes results.json, junit.xml and summary.md into the output folder.
    public func write() throws {
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.resultsFileName), options: .atomic)
        try Data(junit.utf8).write(to: folder.appendingPathComponent(Self.junitFileName), options: .atomic)
        try Data(markdown.utf8).write(to: folder.appendingPathComponent(Self.summaryFileName), options: .atomic)
    }

    /// The run saved in a folder.
    public static func load(_ folder: URL) throws -> TestRunResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TestRunResult.self, from: try Data(contentsOf: folder.appendingPathComponent(resultsFileName)))
    }
}

/// Runs are kept in the project's output/runs, the newest 20, for the app, `run_tests` and
/// `test_result`. A single test file outside a project, a project folder that cannot be written,
/// and runs from before projects kept their own stay in the app's folder; both places are listed
/// together, so the old runs give way to new ones by themselves. `Mobdev test` writes wherever
/// `--artifacts` says instead.
public enum TestRuns {
    /// Runs of folders without a mobdev.json, and those of projects from before 0.2.51.
    public static var folder: URL { MobdevPaths.home.appendingPathComponent("test-runs", isDirectory: true) }
    public static let kept = 20

    /// A project's runs in the app's folder live under its name and a hash of its folder, so two
    /// projects called "App" stay apart.
    public static func projectFolder(_ project: TestProject) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in project.folder.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        let name = "\(TestProject.slug(project.name))-\(String(hash, radix: 16).prefix(8))"
        return folder.appendingPathComponent(name, isDirectory: true)
    }

    /// The project's own output/runs, for a folder with a mobdev.json.
    static func ownFolder(_ project: TestProject) -> URL? {
        guard TestProject.isProject(project.folder) else { return nil }
        return project.folder.appendingPathComponent(TestProject.outputFolderName, isDirectory: true)
            .appendingPathComponent(ProjectOutput.runs.rawValue, isDirectory: true)
    }

    /// A new folder for a run, named after the time, after removing the oldest runs. Two runs in
    /// the same second, such as on two devices, get folders of their own.
    public static func newRunFolder(for project: TestProject) throws -> URL {
        let files = FileManager.default
        var parent = projectFolder(project)
        if ownFolder(project) != nil, let own = try? TestProject.output(.runs, in: project.folder) { parent = own }
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        for old in runs(for: project).dropFirst(kept - 1) { try? files.removeItem(at: old) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: Date())
        for suffix in 1...1000 {
            let url = parent.appendingPathComponent(suffix == 1 ? stamp : "\(stamp) (\(suffix))", isDirectory: true)
            do {
                // Without intermediate folders, creating fails when another run took the name first.
                try files.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw ToolFailure("Could not make a folder for the run in \(parent.path).")
    }

    /// A project's run folders in both places, newest first.
    public static func runs(for project: TestProject) -> [URL] {
        let parents = [ownFolder(project), projectFolder(project)].compactMap { $0 }
        let all = parents.flatMap { parent in
            ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).filter { !$0.hasPrefix(".") }
                .map { parent.appendingPathComponent($0, isDirectory: true) }
        }
        return all.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// The newest run with results, or the one in the named folder.
    public static func result(for project: TestProject, run: String? = nil) -> TestRunResult? {
        if let run {
            guard !run.contains("/"), !run.hasPrefix(".") else { return nil }
            for folder in runs(for: project) where folder.lastPathComponent == run {
                if let result = try? TestRunResult.load(folder) { return result }
            }
            return nil
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
        // Everything the steps save without a path lands in this project, whatever becomes active
        // meanwhile.
        let own = TestProject.isProject(project.folder) ? ProjectList.normalized(project.folder) : nil
        let result = await ProjectScope.$pinned.withValue(own ?? ProjectScope.pinned) {
            await runTestsInScope(project, options: options, source: source, progress: progress)
        }
        if let own { projects.notifyOutput(own, .runs) }
        return result
    }

    private func runTestsInScope(
        _ project: TestProject, options: TestRunOptions, source: String,
        progress: (@Sendable (TestRunResult.Test) -> Void)?
    ) async -> TestRunResult {
        let device = phone as? any Device
        let kind = device?.kind ?? (phone.status().input == .bluetooth ? DeviceKind.iPhone : .simulator)
        var result = TestRunResult(
            project: project, device: .init(id: device?.id ?? "", name: device?.name ?? "Device", kind: kind.rawValue),
            output: options.output)
        result.language = options.language

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
        var overrides = options.variables
        if let language = options.language, overrides["LANGUAGE"] == nil { overrides["LANGUAGE"] = language }
        let variables = Variables(
            project: project, overrides: overrides, environment: ProcessInfo.processInfo.environment)

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

        var restoreLanguage: (@Sendable () async -> Void)?
        if let language = options.language {
            switch await setLanguage(language, project: project, kind: kind, variables: variables, source: source) {
            case .success(let (step, restore)):
                result.setup.append(step)
                restoreLanguage = restore
            case .failure(let failure):
                result.setup.append(failure.step)
                result.error = "Could not set the language to \(language): \(failure.step.text)"
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
                    failedStep: nil, message: "not for \(TestCase.platformName(kind))", screenshot: nil, video: nil, log: nil)
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
        await restoreLanguage?()
        return finished(result)
    }

    private struct LanguageFailure: Error { let step: TestRunResult.Step }

    /// Sets the run's language as a setup step and returns how to put the old one back. iOS apps
    /// read it at launch, so a running copy is stopped for the tests to launch it again.
    private func setLanguage(
        _ language: String, project: TestProject, kind: DeviceKind, variables: Variables, source: String
    ) async -> Result<(TestRunResult.Step, @Sendable () async -> Void), LanguageFailure> {
        var arguments: [String: JSONValue] = ["language": .string(language)]
        if let bundleID = project.app.bundleID { arguments["bundle_id"] = .string(bundleID) }
        let set = Flow.Step("set_language", arguments)
        let started = Date()
        func step(_ text: String, passed: Bool) -> TestRunResult.Step {
            .init(summary: set.summary, text: text, passed: passed, seconds: Date().timeIntervalSince(started))
        }
        guard let settings = phone.settings else {
            return .failure(LanguageFailure(step: step("This device cannot change its language.", passed: false)))
        }
        let saved: SavedLanguage
        do {
            saved = try await settings.savedLanguage(bundleID: project.app.bundleID)
        } catch {
            return .failure(LanguageFailure(step: step(String(describing: error), passed: false)))
        }
        let output = await self.step(set, variables: variables, source: source)
        guard !output.isError else { return .failure(LanguageFailure(step: step(output.text, passed: false))) }
        if kind != .android, let bundleID = project.app.bundleID {
            _ = await self.step(Flow.Step("stop_app", ["bundle_id": .string(bundleID)]), variables: variables, source: source)
        }
        let bundleID = project.app.bundleID
        return .success((step(output.text, passed: true), { try? await settings.restoreLanguage(saved, bundleID: bundleID) }))
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
            message: "", screenshot: nil, video: nil, log: nil)
        // Every variable first, so a test never half-runs because of a typo in its last step.
        if let (index, error) = Flow.unsetVariable(in: written, variables: variables) {
            outcome.status = .failed
            outcome.failedStep = index + 1
            outcome.message = "step \(index + 1) of \(written.count), \(written[index].summary): \(error)"
            return (outcome, nil)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bundleID = project.app.bundleID
        let logs = phone.apps?.logs
        let statusBefore = bundleID.flatMap { logs?.status(for: $0) }
        // Where the app's output stands now, so a failure shows only what it printed during the test.
        let cursor = bundleID.flatMap { logs?.read(app: $0, after: nil, limit: 1, contains: nil).cursor }
        // The steps as written, filled in as they run: results show ${PASSWORD}, never its value.
        let flow = Flow(name: test.name, steps: written)
        // Checks find the project's baselines and leave their files in the test's folder.
        let checks = CheckContext(root: project.folder, artifacts: folder)
        let result = await CheckContext.$current.withValue(checks) {
            await Flow.recording(phone, to: video ? folder.appendingPathComponent("run.mp4") : nil) {
                await run(flow, variables: variables, source: source)
            }
        }
        let files = checks.files.get()
        if !files.isEmpty { outcome.files = files }
        outcome.seconds = result.seconds
        outcome.steps = result.steps.map { step in
            .init(
                summary: step.step.summary, text: step.text, passed: step.passed, seconds: step.seconds,
                number: step.number, round: step.round, tolerated: step.tolerated ? true : nil)
        }
        outcome.video = result.video?.url.path
        if !result.passed, let failure = result.failure {
            outcome.status = .failed
            let number = failure.result.number
            outcome.failedStep = Int(number.split(separator: ".").first.map(String.init) ?? "") ?? failure.index + 1
            let round = failure.result.round.map { " (\($0))" } ?? ""
            outcome.message =
                "step \(number) of \(written.count), \(failure.result.step.summary)\(round): \(failure.result.text)"
        }
        if let bundleID, let after = logs?.status(for: bundleID), after.hasPrefix("crashed"), after != statusBefore {
            outcome.status = .failed
            let crash = "\(bundleID) \(after)"
            outcome.message = outcome.message.isEmpty ? crash : "\(outcome.message) \(crash)"
        }
        if outcome.status == .failed, let bundleID, let logs {
            // How the app is doing and what it printed: a launch that ended, an error it logged.
            if let status = logs.status(for: bundleID), status != "running", !status.hasPrefix("crashed") {
                outcome.message += " The app \(status)."
            }
            let lines = logs.read(app: bundleID, after: cursor, limit: 2000, contains: nil).lines.map(\.text)
            if !lines.isEmpty { outcome.log = Array(lines.suffix(TestRunResult.keptLogLines)) }
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
