import Foundation

/// The platforms of an app's own test suites: XCTest and Swift Testing through Xcode, and
/// Android's instrumented and unit tests through Gradle.
public enum NativePlatform: String, Sendable, Codable, CaseIterable {
    case ios, android

    public var label: String { self == .ios ? "iOS" : "Android" }

    /// The platform a device's tests are for.
    public init(_ kind: DeviceKind) { self = kind == .android ? .android : .ios }
}

/// `native_tests` in mobdev.json: where the app's own test suites are and how to run them, so
/// `run_native_tests` and `Mobdev test --native` need no arguments. Every key is optional, paths
/// are relative to the project folder like `app.builds`, and what is left out is found in the
/// repository when there is exactly one candidate:
///
///     "native_tests": {
///       "ios": {"workspace": "../ios/App.xcworkspace", "scheme": "App", "test_plan": "UnitTests"},
///       "android": {"gradle_root": "../android", "module": "app", "task": "connectedDebugAndroidTest"}
///     }
///
/// `ios` takes `workspace` or `project` (an .xcodeproj), `scheme` and `test_plan`. `android` takes
/// `gradle_root` (the folder with gradlew), `task` (default connectedDebugAndroidTest; a unit-test
/// task such as testDebugUnitTest runs on the Mac without a device) and `module`, which qualifies
/// the task (`:app:connectedDebugAndroidTest`) and limits where results are read.
public struct NativeTestConfig: Sendable, Equatable {
    public struct IOS: Sendable, Equatable {
        public var workspace: String?
        public var project: String?
        public var scheme: String?
        public var testPlan: String?

        public init(workspace: String? = nil, project: String? = nil, scheme: String? = nil, testPlan: String? = nil) {
            self.workspace = workspace
            self.project = project
            self.scheme = scheme
            self.testPlan = testPlan
        }

        static let keys: Set<String> = ["workspace", "project", "scheme", "test_plan"]
    }

    public struct Android: Sendable, Equatable {
        public var gradleRoot: String?
        public var task: String?
        public var module: String?

        public init(gradleRoot: String? = nil, task: String? = nil, module: String? = nil) {
            self.gradleRoot = gradleRoot
            self.task = task
            self.module = module
        }

        static let keys: Set<String> = ["gradle_root", "task", "module"]
    }

    public var ios: IOS?
    public var android: Android?

    public init(ios: IOS? = nil, android: Android? = nil) {
        self.ios = ios
        self.android = android
    }

    static let key = "native_tests"

    static func parse(_ value: JSONValue) throws -> NativeTestConfig {
        guard let object = value.objectValue else { throw ToolFailure("\(key) must be an object with ios and android.") }
        if let unknown = object.keys.sorted().first(where: { !["ios", "android"].contains($0) }) {
            throw ToolFailure("\(key) has an unknown key \"\(unknown)\". Keys: android, ios.")
        }
        func fields(_ name: String, keys: Set<String>) throws -> [String: String]? {
            guard let value = object[name], !value.isNull else { return nil }
            guard let fields = value.objectValue else { throw ToolFailure("\(key).\(name) must be an object.") }
            var strings: [String: String] = [:]
            for (field, value) in fields {
                guard keys.contains(field) else {
                    throw ToolFailure(
                        "\(key).\(name) has an unknown key \"\(field)\". Keys: \(keys.sorted().joined(separator: ", ")).")
                }
                if value.isNull { continue }
                guard let string = value.stringValue, !string.isEmpty else {
                    throw ToolFailure("\(key).\(name).\(field) must be a non-empty string.")
                }
                strings[field] = string
            }
            return strings
        }
        var config = NativeTestConfig()
        if let ios = try fields("ios", keys: IOS.keys) {
            if ios["workspace"] != nil, ios["project"] != nil {
                throw ToolFailure("\(key).ios takes workspace or project, not both.")
            }
            config.ios = IOS(workspace: ios["workspace"], project: ios["project"], scheme: ios["scheme"], testPlan: ios["test_plan"])
        }
        if let android = try fields("android", keys: Android.keys) {
            config.android = Android(gradleRoot: android["gradle_root"], task: android["task"], module: android["module"])
        }
        return config
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = [:]
        if let ios {
            var fields: [String: JSONValue] = [:]
            if let workspace = ios.workspace { fields["workspace"] = .string(workspace) }
            if let project = ios.project { fields["project"] = .string(project) }
            if let scheme = ios.scheme { fields["scheme"] = .string(scheme) }
            if let testPlan = ios.testPlan { fields["test_plan"] = .string(testPlan) }
            object["ios"] = .object(fields)
        }
        if let android {
            var fields: [String: JSONValue] = [:]
            if let root = android.gradleRoot { fields["gradle_root"] = .string(root) }
            if let task = android.task { fields["task"] = .string(task) }
            if let module = android.module { fields["module"] = .string(module) }
            object["android"] = .object(fields)
        }
        return .object(object)
    }
}

/// One native test suite, resolved to what runs: an Xcode workspace or project with its scheme,
/// or a Gradle root with its task.
public struct NativeTestPlan: Sendable, Equatable {
    public enum Suite: Sendable, Equatable {
        case xcode(container: URL, scheme: String, testPlan: String?)
        case gradle(root: URL, task: String, module: String?)
    }

    public var suite: Suite
    /// Tests to run, all when empty: `Target/Class/method` for Xcode (`-only-testing:`), a class
    /// or `Class#method` for Gradle.
    public var only: [String]
    /// False runs Xcode's `test-without-building` on the last build.
    public var build: Bool

    public init(suite: Suite, only: [String] = [], build: Bool = true) {
        self.suite = suite
        self.only = only
        self.build = build
    }

    public var platform: NativePlatform {
        if case .gradle = suite { return .android }
        return .ios
    }

    /// The Gradle task with its module, such as `:app:connectedDebugAndroidTest`.
    var gradleTask: String? {
        guard case .gradle(_, let task, let module) = suite else { return nil }
        guard let module, !task.hasPrefix(":") else { return task }
        let path = module.split(separator: "/").joined(separator: ":")
        return ":\(path.hasPrefix(":") ? String(path.dropFirst()) : path):\(task)"
    }

    /// Whether the suite runs on a device: Xcode always (a simulator at least), Gradle for
    /// instrumented tasks only. A unit-test task such as testDebugUnitTest runs on the Mac.
    public var needsDevice: Bool {
        guard let task = gradleTask else { return true }
        return Self.isInstrumented(task)
    }

    static func isInstrumented(_ task: String) -> Bool {
        let name = task.split(separator: ":").last.map(String.init) ?? task
        return name.hasPrefix("connected") || name.hasPrefix("device") || name.contains("AndroidTest")
    }

    /// "scheme Sample of Sample.xcodeproj, test plan Unit", "Gradle :app:connectedDebugAndroidTest".
    public var title: String {
        switch suite {
        case .xcode(let container, let scheme, let testPlan):
            return "scheme \(scheme) of \(container.lastPathComponent)" + (testPlan.map { ", test plan \($0)" } ?? "")
        case .gradle:
            return "Gradle \(gradleTask ?? "")"
        }
    }

    /// Arguments of the tool that override mobdev.json.
    public struct Overrides: Sendable, Equatable {
        public var workspace: String?
        public var project: String?
        public var scheme: String?
        public var testPlan: String?
        public var gradleRoot: String?
        public var task: String?
        public var module: String?

        public init(
            workspace: String? = nil, project: String? = nil, scheme: String? = nil, testPlan: String? = nil,
            gradleRoot: String? = nil, task: String? = nil, module: String? = nil
        ) {
            self.workspace = workspace
            self.project = project
            self.scheme = scheme
            self.testPlan = testPlan
            self.gradleRoot = gradleRoot
            self.task = task
            self.module = module
        }
    }

    public static let defaultGradleTask = "connectedDebugAndroidTest"

    /// The suite for a platform: the arguments over the project's `native_tests` over what the
    /// repository holds. Relative paths are relative to the project folder.
    public static func resolve(
        _ project: TestProject, platform: NativePlatform, overrides: Overrides = Overrides(), only: [String] = [],
        build: Bool = true
    ) throws -> NativeTestPlan {
        let base = URL(fileURLWithPath: project.folder.path, isDirectory: true)
        // Plain absolute file URLs, without a trailing slash, so equal suites compare equal.
        func path(_ value: String) -> URL {
            URL(fileURLWithPath: URL(fileURLWithPath: (value as NSString).expandingTildeInPath, relativeTo: base).standardizedFileURL.path)
        }
        let files = FileManager.default
        switch platform {
        case .ios:
            let config = project.nativeTests?.ios ?? .init()
            // An argument for one kind of container replaces the file's other kind too.
            let named = overrides.workspace ?? overrides.project
                ?? (overrides.workspace == nil && overrides.project == nil ? config.workspace ?? config.project : nil)
            let container: URL
            if let named {
                container = path(named)
                guard ["xcworkspace", "xcodeproj"].contains(container.pathExtension) else {
                    throw ToolFailure("\(named) is neither an .xcworkspace nor an .xcodeproj.")
                }
                guard files.fileExists(atPath: container.path) else {
                    throw ToolFailure("\(container.path) does not exist. Set native_tests.ios in \(TestProject.fileName) to the app's workspace or project, relative to \(base.path).")
                }
            } else {
                container = try NativeTestDiscovery.xcodeContainer(in: ProjectIcons.repository(of: base))
            }
            let scheme = try overrides.scheme ?? config.scheme ?? NativeTestDiscovery.scheme(in: container)
            return NativeTestPlan(
                suite: .xcode(container: container, scheme: scheme, testPlan: overrides.testPlan ?? config.testPlan), only: only,
                build: build)
        case .android:
            let config = project.nativeTests?.android ?? .init()
            let root: URL
            if let named = overrides.gradleRoot ?? config.gradleRoot {
                root = path(named)
            } else {
                root = try NativeTestDiscovery.gradleRoot(in: ProjectIcons.repository(of: base))
            }
            guard files.isExecutableFile(atPath: root.appendingPathComponent("gradlew").path) else {
                throw ToolFailure("\(root.path) has no gradlew. Set native_tests.android.gradle_root in \(TestProject.fileName) to the folder with the Gradle wrapper, relative to \(base.path).")
            }
            let task = overrides.task ?? config.task ?? defaultGradleTask
            guard !task.isEmpty, !task.hasPrefix("-"), !task.contains(where: \.isWhitespace) else {
                throw ToolFailure("task must be one Gradle task, like connectedDebugAndroidTest or testDebugUnitTest.")
            }
            let module = overrides.module ?? config.module
            if let module, module.isEmpty || module.contains(where: \.isWhitespace) {
                throw ToolFailure("module must be a Gradle module such as app.")
            }
            return NativeTestPlan(suite: .gradle(root: root, task: task, module: module), only: only, build: build)
        }
    }
}

/// Finds an app's test suites in its repository from the files alone, without running Xcode or
/// Gradle: the one workspace (else project), its one scheme with tests, the one Gradle wrapper.
enum NativeTestDiscovery {
    /// The workspace nearest the top, else the project; several at the same depth are a choice
    /// for the user. CocoaPods' own project does not count.
    static func xcodeContainer(in repository: URL) throws -> URL {
        var workspaces: [URL] = []
        var projects: [URL] = []
        ProjectIcons.walk(repository) { url, isFolder in
            guard isFolder else { return }
            switch url.pathExtension {
            case "xcworkspace": workspaces.append(url)
            case "xcodeproj" where url.lastPathComponent != "Pods.xcodeproj": projects.append(url)
            default: break
            }
        }
        let rootDepth = repository.pathComponents.count
        for candidates in [workspaces, projects] where !candidates.isEmpty {
            let shallowest = candidates.map(\.pathComponents.count).min()!
            let top = candidates.filter { $0.pathComponents.count == shallowest }.sorted { $0.path < $1.path }
            if top.count == 1 { return URL(fileURLWithPath: top[0].standardizedFileURL.path) }
            let names = top.map { $0.pathComponents.dropFirst(rootDepth).joined(separator: "/") }
            throw ToolFailure(
                "\(repository.path) has several: \(names.joined(separator: ", ")). Name one as workspace or project (native_tests.ios in \(TestProject.fileName), or the tool's argument).")
        }
        throw ToolFailure(
            "No Xcode workspace or project in \(repository.path). Set native_tests.ios.workspace or project in \(TestProject.fileName).")
    }

    /// The shared schemes of a project, or of the projects a workspace holds, with whether each
    /// tests something.
    static func schemes(in container: URL) -> [(name: String, tests: Bool)] {
        var folders = [container.appendingPathComponent("xcshareddata/xcschemes")]
        if container.pathExtension == "xcworkspace",
            let text = try? String(contentsOf: container.appendingPathComponent("contents.xcworkspacedata"), encoding: .utf8)
        {
            // <FileRef location = "group:App.xcodeproj">, relative to the workspace's folder.
            for match in text.matches(of: /location\s*=\s*"(?:group|container):([^"]+\.xcodeproj)"/) {
                let project = container.deletingLastPathComponent().appendingPathComponent(String(match.1))
                guard project.lastPathComponent != "Pods.xcodeproj" else { continue }
                folders.append(project.appendingPathComponent("xcshareddata/xcschemes"))
            }
        }
        var schemes: [(name: String, tests: Bool)] = []
        for folder in folders {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".xcscheme") }
            for name in names.sorted() {
                let text = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
                let scheme = String(name.dropLast(".xcscheme".count))
                if !schemes.contains(where: { $0.name == scheme }) {
                    schemes.append((scheme, text.contains("<TestableReference") || text.contains("<TestPlanReference")))
                }
            }
        }
        return schemes
    }

    /// The only shared scheme with tests, else the only shared scheme.
    static func scheme(in container: URL) throws -> String {
        let schemes = schemes(in: container)
        let testing = schemes.filter(\.tests)
        if testing.count == 1 { return testing[0].name }
        if testing.isEmpty, schemes.count == 1 { return schemes[0].name }
        if schemes.isEmpty {
            throw ToolFailure(
                "\(container.lastPathComponent) has no shared scheme. Name the scheme (native_tests.ios.scheme in \(TestProject.fileName), or the tool's scheme), or share it in Xcode's Manage Schemes.")
        }
        let names = (testing.isEmpty ? schemes : testing).map(\.name).joined(separator: ", ")
        throw ToolFailure(
            "\(container.lastPathComponent) has several schemes\(testing.isEmpty ? "" : " with tests"): \(names). Name one as scheme (native_tests.ios.scheme in \(TestProject.fileName), or the tool's argument).")
    }

    /// The folder with gradlew nearest the repository's top: its root, or a folder such as android/.
    static func gradleRoot(in repository: URL) throws -> URL {
        if FileManager.default.isExecutableFile(atPath: repository.appendingPathComponent("gradlew").path) { return repository }
        var found: [URL] = []
        ProjectIcons.walk(repository) { url, isFolder in
            if !isFolder, url.lastPathComponent == "gradlew", url.pathComponents.count - repository.pathComponents.count <= 3 {
                found.append(url.deletingLastPathComponent())
            }
        }
        guard let shallowest = found.map(\.pathComponents.count).min() else {
            throw ToolFailure("No Gradle wrapper (gradlew) in \(repository.path). Set native_tests.android.gradle_root in \(TestProject.fileName).")
        }
        let top = found.filter { $0.pathComponents.count == shallowest }.sorted { $0.path < $1.path }
        guard top.count == 1 else {
            throw ToolFailure(
                "\(repository.path) has several Gradle wrappers: \(top.map(\.path).joined(separator: ", ")). Name one as gradle_root.")
        }
        return URL(fileURLWithPath: top[0].standardizedFileURL.path)
    }
}

// MARK: - Results

/// One run of a native test suite, as `results.json` in its folder keeps it, and as a run in
/// progress shows it.
public struct NativeTestResult: Sendable, Codable, Equatable {
    public typealias Status = TestRunResult.Status

    /// What failed and where: an assertion with the test's file and line, or a compiler error.
    public struct Failure: Sendable, Codable, Equatable {
        public var message: String
        public var file: String?
        public var line: Int?

        public init(message: String, file: String? = nil, line: Int? = nil) {
            self.message = message
            self.file = file
            self.line = line
        }

        /// "SampleTests.swift:10", or nil without a file.
        public var location: String? {
            guard let file else { return nil }
            let name = (file as NSString).lastPathComponent
            return line.map { "\(name):\($0)" } ?? name
        }

        /// "SampleTests.swift:10: XCTAssertEqual failed: …".
        public var text: String { location.map { "\($0): \(message)" } ?? message }
    }

    public struct Test: Sendable, Codable, Equatable {
        public var name: String
        /// The test's class or suite, and its bundle: "SampleTests/SampleTests", "com.example.LoginTest".
        public var suite: String
        /// What selects it again: `-only-testing:` for Xcode ("SampleTests/SampleTests/testAdd"),
        /// "Class#method" for Gradle.
        public var identifier: String
        public var status: Status
        public var seconds: Double
        public var failures: [Failure]
        /// Why it was skipped.
        public var message: String?
        /// Files the test attached when it failed, such as a UI test's screenshot.
        public var attachments: [String]?

        public init(
            name: String, suite: String, identifier: String, status: Status, seconds: Double, failures: [Failure] = [],
            message: String? = nil, attachments: [String]? = nil
        ) {
            self.name = name
            self.suite = suite
            self.identifier = identifier
            self.status = status
            self.seconds = seconds
            self.failures = failures
            self.message = message
            self.attachments = attachments
        }

        /// "✓ testAdd (0.1 s)", "✗ testAddFails (1.4 s): SampleTests.swift:10: XCTAssertEqual …".
        public var line: String {
            let time = String(format: "%.1f s", seconds)
            switch status {
            case .passed: return "✓ \(suite) \(name) (\(time))"
            case .failed:
                let first = failures.first.map { ": " + ($0.text.split(separator: "\n").first.map(String.init) ?? "") } ?? ""
                return "✗ \(suite) \(name) (\(time))\(first)"
            case .skipped: return "– \(suite) \(name)\(message.map { ": \($0)" } ?? "")"
            }
        }

        /// Every failure in full and the attachments, indented under the test's line.
        public var detailLines: [String] {
            guard status == .failed else { return [] }
            var lines = failures.dropFirst().map { "  \($0.text)" }
            if let first = failures.first, first.text.contains("\n") {
                lines.insert(contentsOf: first.text.split(separator: "\n").dropFirst().map { "    \($0)" }, at: 0)
            }
            for file in attachments ?? [] { lines.append("  Attachment: \(file)") }
            return lines
        }
    }

    /// How a run in progress is doing; nil once it ended.
    public struct Progress: Sendable, Codable, Equatable {
        /// "Building", "Testing" or "Reading results".
        public var phase: String
        /// Tests that finished so far, by the output's count.
        public var finished: Int
        public var failed: Int
        /// The newest line of output.
        public var lastLine: String

        public init(phase: String = "Building", finished: Int = 0, failed: Int = 0, lastLine: String = "") {
            self.phase = phase
            self.finished = finished
            self.failed = failed
            self.lastLine = lastLine
        }
    }

    public static let resultsFileName = "results.json"
    public static let junitFileName = "junit.xml"
    public static let summaryFileName = "summary.md"
    /// The result bundle of an Xcode run, in the run's folder.
    public static let resultBundleName = "Tests.xcresult"

    public var project: String
    /// The project folder.
    public var folder: String
    public var platform: NativePlatform
    /// What ran, as `NativeTestPlan.title` says it.
    public var suite: String
    /// The command that ran, to run it again in a terminal.
    public var command: [String]
    /// Nil for unit tests that ran on the Mac.
    public var device: TestRunResult.Device?
    public var started: Date
    public var seconds: Double
    /// Why the tests did not run, or not all of them: the build failed, the device was missing.
    public var error: String?
    /// The compiler's errors when the build failed.
    public var buildErrors: [Failure]
    public var cancelled: Bool
    public var tests: [Test]
    /// Something to know about the results, such as Gradle finding its task up to date.
    public var note: String?
    /// The run's folder.
    public var output: String
    /// The .xcresult of an Xcode run, which Xcode opens.
    public var resultBundle: String?
    /// Everything xcodebuild or Gradle printed.
    public var log: String
    public var progress: Progress?

    public init(
        project: TestProject, plan: NativeTestPlan, device: TestRunResult.Device?, output: URL, command: [String] = []
    ) {
        self.project = project.name
        folder = project.folder.path
        platform = plan.platform
        suite = plan.title
        self.command = command
        self.device = device
        started = Date()
        seconds = 0
        buildErrors = []
        cancelled = false
        tests = []
        self.output = output.path
        log = output.appendingPathComponent(plan.platform == .ios ? "xcodebuild.log" : "gradle.log").path
        progress = Progress()
    }

    public var running: Bool { progress != nil }

    public var counts: (passed: Int, failed: Int, skipped: Int) {
        (
            tests.filter { $0.status == .passed }.count, tests.filter { $0.status == .failed }.count,
            tests.filter { $0.status == .skipped }.count
        )
    }

    /// Every test passed, something ran, nothing stopped the run.
    public var passed: Bool {
        error == nil && !cancelled && !running && !tests.isEmpty && tests.allSatisfy { $0.status != .failed }
    }

    /// "Native tests \"My App\" (scheme App of App.xcodeproj) on iPhone 17: 12 passed, 1 failed in 84.2 s."
    public var summaryLine: String {
        let place = device.map { " on \($0.name)" } ?? " on this Mac"
        var line = "Native tests \"\(project)\" (\(suite))\(place): "
        if let progress {
            let elapsed = Date().timeIntervalSince(started)
            line += "running for \(Int(elapsed)) s, \(progress.phase.lowercased())"
            if progress.finished > 0 { line += ", \(progress.finished) tests finished, \(progress.failed) failed" }
            return line + "."
        }
        let (passed, failed, skipped) = counts
        var parts = ["\(passed) passed"]
        if failed > 0 || passed == 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        line += parts.joined(separator: ", ") + String(format: " in %.1f s.", seconds)
        if cancelled { line += " Cancelled." }
        if let error { line += " \(error)" }
        return line
    }

    public var text: String {
        var lines = [summaryLine]
        if let progress, !progress.lastLine.isEmpty { lines.append("Last output: \(progress.lastLine)") }
        for failure in buildErrors.prefix(20) { lines.append("✗ \(failure.text)") }
        if buildErrors.count > 20 { lines.append("… and \(buildErrors.count - 20) more errors") }
        // A run in progress lists only what failed; a finished one every failure and the count of the rest.
        for test in tests where test.status == .failed {
            lines.append(test.line)
            lines += test.detailLines
        }
        if !running, tests.contains(where: { $0.status != .failed }) {
            let (passed, _, skipped) = counts
            lines.append("\(passed) passed\(skipped > 0 ? ", \(skipped) skipped" : ""): see results.json for each.")
        }
        if let note { lines.append(note) }
        if let resultBundle { lines.append("Result bundle: \(resultBundle)") }
        lines.append("Log: \(log)")
        if !running { lines.append("Results: \(output)/\(Self.resultsFileName)") }
        return lines.joined(separator: "\n")
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public var json: JSONValue {
        var value = (try? JSONValue.parse(try Self.encoder.encode(self))) ?? .null
        if case .object(var object) = value {
            object["running"] = .bool(running)
            object["passed"] = .bool(passed)
            let (passed, failed, skipped) = counts
            object["counts"] = ["passed": .number(Double(passed)), "failed": .number(Double(failed)), "skipped": .number(Double(skipped))]
            value = .object(object)
        }
        return value
    }

    /// The run as a JUnit report: a suite per test class, a case per test. A build that failed or
    /// a run that could not start is a case of its own with an error.
    public var junit: String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func time(_ seconds: Double) -> String { String(format: "%.3f", seconds) }
        let (_, failed, skipped) = counts
        let errors = error == nil ? 0 : 1
        var suites: [(name: String, tests: [Test])] = []
        for test in tests {
            if let index = suites.firstIndex(where: { $0.name == test.suite }) {
                suites[index].tests.append(test)
            } else {
                suites.append((test.suite, [test]))
            }
        }
        let timestamp = ISO8601DateFormatter().string(from: started)
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<testsuites name=\"\(escape("\(project) \(suite)"))\" tests=\"\(tests.count + errors)\" failures=\"\(failed)\" errors=\"\(errors)\" skipped=\"\(skipped)\" time=\"\(time(seconds))\">",
        ]
        if let error {
            lines.append("  <testsuite name=\"Setup\" tests=\"1\" failures=\"0\" errors=\"1\" skipped=\"0\" time=\"0.000\" timestamp=\"\(timestamp)\">")
            lines.append("    <testcase name=\"Setup\" classname=\"\(escape(suite))\" time=\"0.000\">")
            lines.append("      <error message=\"\(escape(error))\">\(escape(buildErrors.map(\.text).joined(separator: "\n")))</error>")
            lines.append("    </testcase>")
            lines.append("  </testsuite>")
        }
        for (name, cases) in suites {
            let caseFailures = cases.filter { $0.status == .failed }.count
            let caseSkipped = cases.filter { $0.status == .skipped }.count
            let caseTime = cases.map(\.seconds).reduce(0, +)
            lines.append(
                "  <testsuite name=\"\(escape(name))\" tests=\"\(cases.count)\" failures=\"\(caseFailures)\" errors=\"0\" skipped=\"\(caseSkipped)\" time=\"\(time(caseTime))\" timestamp=\"\(timestamp)\">")
            for test in cases {
                let file = test.failures.first?.file.map { " file=\"\(escape($0))\"" } ?? ""
                let line = test.failures.first?.line.map { " line=\"\($0)\"" } ?? ""
                lines.append(
                    "    <testcase name=\"\(escape(test.name))\" classname=\"\(escape(name))\" time=\"\(time(test.seconds))\"\(file)\(line)>")
                switch test.status {
                case .failed:
                    let message = test.failures.first?.message.split(separator: "\n").first.map(String.init) ?? "Failed"
                    var body = test.failures.map(\.text)
                    body += (test.attachments ?? []).map { "Attachment: \($0)" }
                    lines.append("      <failure message=\"\(escape(message))\">\(escape(body.joined(separator: "\n")))</failure>")
                case .skipped:
                    lines.append("      <skipped message=\"\(escape(test.message ?? ""))\"/>")
                case .passed:
                    break
                }
                lines.append("    </testcase>")
            }
            lines.append("  </testsuite>")
        }
        lines.append("</testsuites>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The run as Markdown for a CI job summary: the counts, then every failure with its place.
    public var markdown: String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        let (passed, failed, skipped) = counts
        let place = device.map { " on \(cell($0.name))" } ?? ""
        var lines = ["### \(self.passed ? "✅" : "❌") Native tests: \(cell(project)), \(cell(suite))\(place)", ""]
        var parts = ["\(passed) passed"]
        if failed > 0 || passed == 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        lines.append(parts.joined(separator: ", ") + String(format: " in %.1f s.", seconds) + (cancelled ? " Cancelled." : ""))
        if let error { lines += ["", "**Could not run:** \(cell(error))"] }
        for failure in buildErrors.prefix(20) { lines.append("- \(cell(failure.text))") }
        let failures = tests.filter { $0.status == .failed }
        if !failures.isEmpty {
            lines += ["", "| Test | Where | Message |", "|---|---|---|"]
            for test in failures {
                let first = test.failures.first
                lines.append(
                    "| \(cell("\(test.suite) \(test.name)")) | \(cell(first?.location ?? "")) | \(cell(first?.message ?? "")) |")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes results.json, junit.xml and summary.md into the run's folder.
    public func write() throws {
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: folder.appendingPathComponent(Self.resultsFileName), options: .atomic)
        try Data(junit.utf8).write(to: folder.appendingPathComponent(Self.junitFileName), options: .atomic)
        try Data(markdown.utf8).write(to: folder.appendingPathComponent(Self.summaryFileName), options: .atomic)
    }

    public static func load(_ folder: URL) throws -> NativeTestResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(NativeTestResult.self, from: Data(contentsOf: folder.appendingPathComponent(resultsFileName)))
    }
}

// MARK: - Reading Xcode's results

/// Reads what `xcrun xcresulttool get test-results tests` and `get build-results` print, and the
/// manifest of `export attachments`.
enum XCResultReader {
    /// Every test case of the tree, with its failures' messages and places. Xcode's own result of
    /// a case covers its runs on several devices, configurations and repetitions.
    static func tests(_ data: Data) throws -> [NativeTestResult.Test] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolFailure("xcresulttool printed no test results.")
        }
        var tests: [NativeTestResult.Test] = []
        func visit(_ node: [String: Any], path: [String]) {
            let type = node["nodeType"] as? String ?? ""
            let name = node["name"] as? String ?? ""
            let children = node["children"] as? [[String: Any]] ?? []
            if type == "Test Case" {
                tests.append(testCase(node, name: name, children: children, path: path))
                return
            }
            // Bundles and suites name the test; plans, devices and configurations do not.
            let named = ["Unit test bundle", "UI test bundle", "Test Suite"].contains(type)
            for child in children { visit(child, path: named ? path + [name] : path) }
        }
        for node in root["testNodes"] as? [[String: Any]] ?? [] { visit(node, path: []) }
        return tests
    }

    private static func testCase(_ node: [String: Any], name: String, children: [[String: Any]], path: [String])
        -> NativeTestResult.Test
    {
        var failures: [NativeTestResult.Failure] = []
        var skipMessage: String?
        func collect(_ nodes: [[String: Any]]) {
            for child in nodes {
                let type = child["nodeType"] as? String ?? ""
                let text = child["name"] as? String ?? ""
                if type == "Failure Message" {
                    let location = child["sourceLocation"] as? [String: Any]
                    let failure = NativeTestResult.Failure(
                        message: text, file: location?["filePath"] as? String, line: location?["lineNumber"] as? Int)
                    if !failures.contains(failure) { failures.append(failure) }
                } else if type == "Skip Message" {
                    skipMessage = skipMessage ?? text
                }
                collect(child["children"] as? [[String: Any]] ?? [])
            }
        }
        collect(children)
        let status: NativeTestResult.Status
        switch node["result"] as? String {
        case "Passed", "Expected Failure": status = .passed
        case "Skipped": status = .skipped
        case "Failed": status = .failed
        default:
            status = .failed
            if failures.isEmpty { failures.append(.init(message: "The test did not finish.")) }
        }
        if status == .failed, failures.isEmpty { failures.append(.init(message: "Failed")) }
        let only = onlyTesting(
            url: node["nodeIdentifierURL"] as? String, identifier: node["nodeIdentifier"] as? String ?? name, bundle: path.first)
        return NativeTestResult.Test(
            name: name, suite: path.joined(separator: "/"), identifier: only, status: status,
            seconds: node["durationInSeconds"] as? Double ?? 0, failures: status == .failed ? failures : [],
            message: status == .skipped ? skipMessage : nil)
    }

    /// What `-only-testing:` takes for a test: the path of its identifier URL without the project,
    /// `SampleTests/SampleTests/testAdd` for XCTest and `SampleTests/adding()` for Swift Testing.
    /// Without a URL, the bundle and the identifier, an XCTest method without its parentheses.
    static func onlyTesting(url: String?, identifier: String, bundle: String?) -> String {
        if let url, let parsed = URL(string: url), parsed.scheme == "test" {
            let parts = parsed.path.split(separator: "/").dropFirst().map { $0.removingPercentEncoding ?? String($0) }
            if !parts.isEmpty { return parts.joined(separator: "/") }
        }
        var only = ([bundle].compactMap { $0 } + [identifier]).joined(separator: "/")
        if identifier.contains("/"), only.hasSuffix("()") { only.removeLast(2) }
        return only
    }

    /// The compiler's errors in `get build-results`, with file and line from each source URL.
    static func buildErrors(_ data: Data) -> [NativeTestResult.Failure] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var failures: [NativeTestResult.Failure] = []
        for error in root["errors"] as? [[String: Any]] ?? [] {
            guard let message = error["message"] as? String else { continue }
            // Says only that the build failed; the other errors say why.
            if message.hasPrefix("Testing cancelled because the build failed") { continue }
            var file: String?
            var line: Int?
            if let source = error["sourceURL"] as? String, let url = URL(string: source), url.isFileURL {
                file = url.path
                // StartingLineNumber counts from 0.
                let fragment = url.fragment ?? ""
                if let match = fragment.firstMatch(of: /StartingLineNumber=(\d+)/), let number = Int(match.1) { line = number + 1 }
            }
            let failure = NativeTestResult.Failure(message: message, file: file, line: line)
            if !failures.contains(failure) { failures.append(failure) }
        }
        return failures
    }

    /// The identifier URL of each test case by its `-only-testing:` identifier: what
    /// `export attachments --test-id` takes.
    static func identifierURLs(_ data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var urls: [String: String] = [:]
        func visit(_ node: [String: Any], bundle: String?) {
            let type = node["nodeType"] as? String ?? ""
            let name = node["name"] as? String ?? ""
            if type == "Test Case" {
                if let url = node["nodeIdentifierURL"] as? String {
                    urls[onlyTesting(url: url, identifier: node["nodeIdentifier"] as? String ?? name, bundle: bundle)] = url
                }
                return
            }
            let isBundle = type == "Unit test bundle" || type == "UI test bundle"
            for child in node["children"] as? [[String: Any]] ?? [] { visit(child, bundle: isBundle ? name : bundle) }
        }
        for node in root["testNodes"] as? [[String: Any]] ?? [] { visit(node, bundle: nil) }
        return urls
    }

    /// The files `export attachments` wrote into `folder` for one test, renamed from their UUIDs
    /// to the names Xcode suggests ("Screen Recording … .mp4", "Debug description for …txt"), as
    /// absolute paths. Xcode 27 marks a failing UI test's recording, hierarchy and descriptions as
    /// not associated with the failure, so a failed test's attachments are all of its own.
    static func readableAttachments(manifest data: Data, folder: URL) -> [String] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let files = FileManager.default
        var paths: [String] = []
        for entry in entries {
            for attachment in entry["attachments"] as? [[String: Any]] ?? [] {
                guard let exported = attachment["exportedFileName"] as? String, !exported.contains("/") else { continue }
                let source = folder.appendingPathComponent(exported)
                var name = (attachment["suggestedHumanReadableName"] as? String ?? "")
                    .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if name.hasPrefix(".") { name = String(name.drop { $0 == "." }) }
                name = String(name.prefix(120))
                let ext = (exported as NSString).pathExtension
                if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() { name += ".\(ext)" }
                var target = folder.appendingPathComponent(name.isEmpty ? exported : name)
                var copy = 2
                while target != source, files.fileExists(atPath: target.path) {
                    target = folder.appendingPathComponent("\(copy) \(name)")
                    copy += 1
                }
                if target != source, (try? files.moveItem(at: source, to: target)) != nil {
                    paths.append(target.path)
                } else if files.fileExists(atPath: source.path) {
                    paths.append(source.path)
                }
            }
        }
        return paths
    }

    /// The start and end of the run in `get test-results summary`, for its duration.
    static func duration(summary data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let start = root["startTime"] as? Double, let finish = root["finishTime"] as? Double, finish >= start
        else { return nil }
        return finish - start
    }
}

// MARK: - Reading JUnit reports

/// Reads the JUnit XML that Gradle writes for Android's instrumented tests
/// (build/outputs/androidTest-results) and unit tests (build/test-results).
final class JUnitReader: NSObject, XMLParserDelegate {
    private var tests: [NativeTestResult.Test] = []
    private var current: NativeTestResult.Test?
    private var text = ""
    private var inFailure = false
    private var failureMessage: String?

    /// The test cases of one report, which may hold one suite or several.
    static func tests(_ data: Data) throws -> [NativeTestResult.Test] {
        let reader = JUnitReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else {
            throw ToolFailure("Not a JUnit report: \(parser.parserError.map { $0.localizedDescription } ?? "unreadable XML").")
        }
        return reader.tests
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        switch name {
        case "testcase":
            let method = attributes["name"] ?? ""
            let className = attributes["classname"] ?? ""
            current = NativeTestResult.Test(
                name: method, suite: className, identifier: className.isEmpty ? method : "\(className)#\(method)",
                status: .passed, seconds: Double(attributes["time"] ?? "") ?? 0)
        case "failure", "error":
            guard current != nil else { return }
            current?.status = .failed
            inFailure = true
            failureMessage = attributes["message"]
            text = ""
        case "skipped":
            guard current != nil else { return }
            current?.status = .skipped
            current?.message = attributes["message"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inFailure { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        if inFailure { text += String(decoding: block, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "failure", "error":
            guard var test = current else { return }
            inFailure = false
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
            let message = (failureMessage?.isEmpty == false ? failureMessage! : firstLine)
            let place = Self.place(in: body, className: test.suite)
            // The message, then the stack trace, which says where; the trace often starts with it.
            let full = body.isEmpty ? message : body.hasPrefix(message) ? body : "\(message)\n\(body)"
            test.failures.append(.init(message: full.isEmpty ? "Failed" : full, file: place?.file, line: place?.line))
            current = test
        case "testcase":
            if let test = current { tests.append(test) }
            current = nil
        default:
            break
        }
    }

    /// The test's own frame in a stack trace, `at com.example.LoginTest.signIn(LoginTest.kt:42)`:
    /// the first frame of its class, else the first frame with a line.
    static func place(in trace: String, className: String) -> (file: String, line: Int)? {
        var first: (file: String, line: Int)?
        for match in trace.matches(of: /at ([\w$.]+)\(([\w$]+\.(?:kt|java|scala|groovy)):(\d+)\)/) {
            guard let line = Int(match.3) else { continue }
            let frame = (String(match.2), line)
            let owner = String(match.1).split(separator: ".").dropLast().joined(separator: ".")
            if !className.isEmpty, owner == className || owner.hasPrefix(className + "$") { return frame }
            first = first ?? frame
        }
        return first
    }
}
