import Foundation

/// A run of a native test suite that goes on by itself: xcodebuild and Gradle take minutes,
/// longer than an agent's call or a relay's 90 seconds may wait. Callers wait as long as they
/// like and read how it is doing at any time; the newest state is `snapshot`.
public final class NativeTestRun: Sendable {
    /// The project folder, which runs one suite at a time.
    public let project: URL
    public let output: URL
    /// Who started it, as the activity names callers.
    public let source: String
    private let state: Locked<NativeTestResult>
    private let process = Locked<RunningCommand?>(nil)
    private let stopped = Locked(false)
    private let lastNotice = Locked(Date.distantPast)

    init(project: URL, output: URL, source: String, result: NativeTestResult) {
        self.project = project
        self.output = output
        self.source = source
        state = Locked(result)
    }

    public var snapshot: NativeTestResult { state.get() }
    public var isFinished: Bool { state.get().progress == nil }
    var isStopped: Bool { stopped.get() }

    /// Stops xcodebuild or Gradle; the run ends cancelled with what finished so far.
    public func cancel() {
        stopped.set(true)
        process.get()?.stop()
    }

    func attach(_ running: RunningCommand) {
        process.set(running)
        if stopped.get() { running.stop() }
    }

    /// Changes the state, and tells the app about phases, finished tests and the end at once and
    /// about new lines of output at most twice a second.
    func update(lineOnly: Bool = false, _ change: (inout NativeTestResult) -> Void) {
        state.withLock(change)
        if lineOnly {
            let now = Date()
            let due = lastNotice.withLock { last -> Bool in
                guard now.timeIntervalSince(last) >= 0.5 else { return false }
                last = now
                return true
            }
            guard due else { return }
        }
        NativeTestRuns.changed(project)
    }

    /// Waits until the run ends or `timeout` passes, whichever is first; a cancelled caller stops
    /// waiting at once. The run goes on either way.
    public func wait(timeout: TimeInterval) async -> NativeTestResult {
        let deadline = Date().addingTimeInterval(timeout)
        while !isFinished, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return snapshot
    }
}

/// Native test runs: the ones going on in this process, by project, and the finished ones in the
/// project's output/native-runs, the newest 20. A folder without a mobdev.json keeps its runs in
/// the app's folder. `Mobdev test --native` writes wherever `--artifacts` says instead.
public enum NativeTestRuns {
    private static let active = Locked<[String: NativeTestRun]>([:])
    private static let handler = Locked<(@Sendable (URL) -> Void)?>(nil)
    public static let kept = 20

    /// Called on any thread when a run starts, makes progress or ends, with its project folder.
    public static func onChange(_ handler: @escaping @Sendable (URL) -> Void) { self.handler.set(handler) }

    static func changed(_ project: URL) { handler.get()?(project) }

    static func key(_ folder: URL) -> String { ProjectList.normalized(folder).path }

    /// The run going on for a project, if one is.
    public static func running(for project: URL) -> NativeTestRun? {
        active.withLock { runs in runs[key(project)].flatMap { $0.isFinished ? nil : $0 } }
    }

    /// Registers a run unless the project has one going on already, which is returned instead.
    static func register(_ run: NativeTestRun) -> NativeTestRun? {
        let other = active.withLock { runs -> NativeTestRun? in
            if let existing = runs[key(run.project)], !existing.isFinished { return existing }
            runs[key(run.project)] = run
            return nil
        }
        if other == nil { changed(run.project) }
        return other
    }

    /// Where a project's runs go: its own output/native-runs, else under the app's folder.
    static func parent(for project: TestProject) -> URL {
        if TestProject.isProject(project.folder),
            let own = try? TestProject.output(.nativeRuns, in: project.folder)
        {
            return own
        }
        return TestRuns.projectFolder(project).appendingPathComponent(ProjectOutput.nativeRuns.rawValue, isDirectory: true)
    }

    /// A new folder for a run, named after the time, after removing the oldest runs.
    public static func newRunFolder(for project: TestProject) throws -> URL {
        let files = FileManager.default
        let parent = parent(for: project)
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        for old in runs(for: project).dropFirst(kept - 1) { try? files.removeItem(at: old) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: Date())
        for suffix in 1...1000 {
            let url = parent.appendingPathComponent(suffix == 1 ? stamp : "\(stamp) (\(suffix))", isDirectory: true)
            do {
                try files.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw ToolFailure("Could not make a folder for the run in \(parent.path).")
    }

    /// A project's run folders, newest first.
    public static func runs(for project: TestProject) -> [URL] {
        var parents = [TestRuns.projectFolder(project).appendingPathComponent(ProjectOutput.nativeRuns.rawValue, isDirectory: true)]
        if TestProject.isProject(project.folder) {
            parents.insert(
                project.folder.appendingPathComponent(TestProject.outputFolderName, isDirectory: true)
                    .appendingPathComponent(ProjectOutput.nativeRuns.rawValue, isDirectory: true), at: 0)
        }
        let all = parents.flatMap { parent in
            ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).filter { !$0.hasPrefix(".") }
                .map { parent.appendingPathComponent($0, isDirectory: true) }
        }
        return all.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// The newest finished run, or the one in the named folder.
    public static func result(for project: TestProject, run: String? = nil) -> NativeTestResult? {
        if let run, run.contains("/") || run.hasPrefix(".") { return nil }
        for folder in runs(for: project) where run == nil || folder.lastPathComponent == run {
            if let result = try? NativeTestResult.load(folder) { return result }
        }
        return nil
    }
}

/// Runs a native suite: xcodebuild for iOS on a simulator or an iPhone, Gradle for Android on an
/// emulator or phone or on the Mac, then reads Xcode's result bundle or Gradle's JUnit reports.
/// Every command goes through `commands`, so tests script them.
public struct NativeTestRunner: Sendable {
    let commands: CommandRunning
    /// What the commands see besides this process's environment: ANDROID_HOME and JAVA_HOME
    /// where an app started from Finder has none.
    let environment: [String: String]
    /// A run that takes longer is stopped.
    var timeout: TimeInterval = 2 * 3600

    public init(commands: CommandRunning = ProcessRunner(), environment: [String: String] = NativeTestRunner.toolEnvironment()) {
        self.commands = commands
        self.environment = environment
    }

    /// The runner the tools use; tests put one with scripted commands in its place.
    @TaskLocal static var current = NativeTestRunner()

    static let xcodebuild = URL(fileURLWithPath: "/usr/bin/xcodebuild")
    static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    static let env = URL(fileURLWithPath: "/usr/bin/env")

    /// Variables Gradle needs that an app started from Finder lacks: the Android SDK Mobdev finds
    /// adb in, and Android Studio's own Java.
    public static func toolEnvironment(_ current: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var extra: [String: String] = [:]
        if current["ANDROID_HOME"] == nil, current["ANDROID_SDK_ROOT"] == nil, let adb = ADB.find() {
            extra["ANDROID_HOME"] = adb.executable.deletingLastPathComponent().deletingLastPathComponent().path
        }
        if current["JAVA_HOME"] == nil {
            let studio = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
            if FileManager.default.isExecutableFile(atPath: studio + "/bin/java") { extra["JAVA_HOME"] = studio }
        }
        return extra
    }

    /// The command for a plan: `xcodebuild test` (or `test-without-building`) on the device,
    /// writing its result bundle into the run's folder; or the Gradle wrapper with the task and
    /// ANDROID_SERIAL naming the device. `device` is nil for Gradle unit tests on the Mac.
    func command(_ plan: NativeTestPlan, device: TestRunResult.Device?, output: URL) throws -> (URL, [String]) {
        switch plan.suite {
        case .xcode(let container, let scheme, let testPlan):
            guard let device else { throw ToolFailure("Xcode's tests run on a simulator or an iPhone; pick one.") }
            guard device.kind != DeviceKind.android.rawValue else {
                throw ToolFailure("\(device.name) is an Android device; iOS tests run on a simulator or an iPhone.")
            }
            var arguments = [
                plan.build ? "test" : "test-without-building",
                container.pathExtension == "xcworkspace" ? "-workspace" : "-project", container.path, "-scheme", scheme,
            ]
            if let testPlan { arguments += ["-testPlan", testPlan] }
            arguments += [
                "-destination", "id=\(device.id)",
                "-resultBundlePath", output.appendingPathComponent(NativeTestResult.resultBundleName).path,
            ]
            // On an iPhone, Xcode makes or renews the development profile as when you run from it.
            if device.kind == DeviceKind.iPhone.rawValue { arguments.append("-allowProvisioningUpdates") }
            arguments += plan.only.map { "-only-testing:\($0)" }
            return (Self.xcodebuild, arguments)
        case .gradle(let root, _, _):
            let task = plan.gradleTask ?? NativeTestPlan.defaultGradleTask
            var variables = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            if plan.needsDevice {
                guard let device else { throw ToolFailure("\(task) runs on an Android emulator or phone; pick one.") }
                guard device.kind == DeviceKind.android.rawValue else {
                    throw ToolFailure("\(device.name) is not an Android device; \(task) runs on an emulator or phone.")
                }
                variables.append("ANDROID_SERIAL=\(device.id)")
            }
            var arguments = [root.appendingPathComponent("gradlew").path, "-p", root.path, "--console=plain", task]
            if !plan.only.isEmpty {
                if plan.needsDevice {
                    // The instrumentation runner takes classes and Class#method, comma-separated.
                    arguments.append("-Pandroid.testInstrumentationRunnerArguments.class=\(plan.only.joined(separator: ","))")
                } else {
                    for test in plan.only { arguments += ["--tests", test.replacingOccurrences(of: "#", with: ".")] }
                }
            }
            return (Self.env, variables + arguments)
        }
    }

    /// Runs the plan to the end, updating `run` as it goes, and writes results.json, junit.xml
    /// and summary.md. Never throws: what went wrong is the result's error.
    func execute(_ plan: NativeTestPlan, device: TestRunResult.Device?, run: NativeTestRun) async -> NativeTestResult {
        let output = run.output
        let logURL = URL(fileURLWithPath: run.snapshot.log)
        let started = Date()
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        defer { try? log?.close() }

        let status: Int32
        do {
            let (executable, arguments) = try command(plan, device: device, output: output)
            run.update { $0.command = [executable.path] + arguments }
            status = try await stream(executable, arguments, run: run, plan: plan, log: log)
        } catch {
            return finish(run) { $0.error = String(describing: error) }
        }
        run.update {
            $0.progress?.phase = "Reading results"
        }
        let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        switch plan.suite {
        case .xcode:
            return await readXcode(run: run, status: status, log: logText)
        case .gradle(let root, _, let module):
            return readGradle(run: run, status: status, log: logText, root: root, module: module, since: started)
        }
    }

    /// Starts the command, keeps its output in the log and the run's progress, and waits for its end.
    private func stream(
        _ executable: URL, _ arguments: [String], run: NativeTestRun, plan: NativeTestPlan, log: FileHandle?
    ) async throws -> Int32 {
        let ended = Locked<CheckedContinuation<Int32, Never>?>(nil)
        let status = Locked<Int32?>(nil)
        let finish: @Sendable (Int32) -> Void = { code in
            let continuation = ended.withLock { continuation -> CheckedContinuation<Int32, Never>? in
                status.set(code)
                defer { continuation = nil }
                return continuation
            }
            continuation?.resume(returning: code)
        }
        let platform = plan.platform
        let running = try commands.start(
            executable, arguments,
            onLine: { line in
                log?.write(Data((line + "\n").utf8))
                let event = NativeTestRunner.progressEvent(line, platform: platform)
                run.update(lineOnly: event == nil) { result in
                    guard var progress = result.progress else { return }
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty { progress.lastLine = String(line.prefix(300)) }
                    switch event {
                    case .testing?: progress.phase = "Testing"
                    case .finished(let failed)?:
                        progress.phase = "Testing"
                        progress.finished += 1
                        if failed { progress.failed += 1 }
                    case nil: break
                    }
                    result.progress = progress
                }
            },
            onExit: finish)
        run.attach(running)
        let limit = timeout
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            running.stop()
        }
        defer { watchdog.cancel() }
        return await withCheckedContinuation { continuation in
            let done = ended.withLock { pending -> Int32? in
                if let code = status.get() { return code }
                pending = continuation
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    enum ProgressEvent: Equatable {
        case testing
        case finished(failed: Bool)
    }

    /// What a line of output says about the run: testing started, or a test finished.
    static func progressEvent(_ line: String, platform: NativePlatform) -> ProgressEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        switch platform {
        case .ios:
            // XCTest: Test Case '-[SampleTests.SampleTests testAdd]' passed (0.001 seconds).
            if trimmed.hasPrefix("Test Case '"), let tail = trimmed.range(of: "' ", options: .backwards) {
                let rest = trimmed[tail.upperBound...]
                if rest.hasPrefix("passed") || rest.hasPrefix("skipped") { return .finished(failed: false) }
                if rest.hasPrefix("failed") { return .finished(failed: true) }
                return nil
            }
            // Swift Testing: ✔ Test adding() passed after 0.001 seconds. / ✘ Test x() failed after …
            if trimmed.hasPrefix("✔ Test ") || trimmed.hasPrefix("➜ Test ") || trimmed.hasPrefix("✘ Test "),
                !trimmed.hasPrefix("✘ Test run"), !trimmed.hasPrefix("✔ Test run"), !trimmed.contains("recorded an issue")
            {
                return .finished(failed: trimmed.hasPrefix("✘"))
            }
            if trimmed.hasPrefix("Testing started") || trimmed.hasPrefix("Test Suite 'All tests' started")
                || trimmed.hasPrefix("◇ Test run started")
            {
                return .testing
            }
            return nil
        case .android:
            // > Task :app:connectedDebugAndroidTest, then one line per failed test.
            if trimmed.hasPrefix("> Task "), NativeTestPlan.isInstrumented(trimmed) || trimmed.contains("UnitTest") {
                return .testing
            }
            if trimmed.hasSuffix(" FAILED"), trimmed.contains(" > ") { return .finished(failed: true) }
            return nil
        }
    }

    // MARK: Results

    private func readXcode(run: NativeTestRun, status: Int32, log: String) async -> NativeTestResult {
        let bundle = run.output.appendingPathComponent(NativeTestResult.resultBundleName)
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            return finish(run) { result in
                if !run.isStopped {
                    result.error = UIRunner.summary(log) ?? "xcodebuild ended with status \(status) without results. Its output is in \(result.log)."
                }
            }
        }
        let path = ["--path", bundle.path]
        var tests: [NativeTestResult.Test] = []
        var problem: String?
        do {
            let listed = try await commands.run(Self.xcrun, ["xcresulttool", "get", "test-results", "tests"] + path, timeout: 300)
            if listed.status == 0 {
                tests = try XCResultReader.tests(Data(Self.json(listed.output).utf8))
            } else {
                problem = listed.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            problem = String(describing: error)
        }
        var seconds: Double?
        if let summary = try? await commands.run(Self.xcrun, ["xcresulttool", "get", "test-results", "summary"] + path, timeout: 120),
            summary.status == 0
        {
            seconds = XCResultReader.duration(summary: Data(Self.json(summary.output).utf8))
        }
        var buildErrors: [NativeTestResult.Failure] = []
        if tests.isEmpty, status != 0,
            let built = try? await commands.run(Self.xcrun, ["xcresulttool", "get", "build-results"] + path, timeout: 120),
            built.status == 0
        {
            buildErrors = XCResultReader.buildErrors(Data(Self.json(built.output).utf8))
        }
        // The failures' attachments, such as a UI test's screenshot, next to the results.
        if tests.contains(where: { $0.status == .failed }) {
            let folder = run.output.appendingPathComponent("attachments", isDirectory: true)
            let exported = try? await commands.run(
                Self.xcrun, ["xcresulttool", "export", "attachments"] + path + ["--output-path", folder.path, "--only-failures"],
                timeout: 300)
            if exported?.status == 0, let manifest = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) {
                let files = XCResultReader.attachments(manifest: manifest, folder: folder)
                for index in tests.indices {
                    if let found = files[tests[index].identifier], !found.isEmpty { tests[index].attachments = found }
                }
            }
        }
        return finish(run) { result in
            result.resultBundle = bundle.path
            result.tests = tests
            result.buildErrors = buildErrors
            if let seconds { result.seconds = seconds }
            if run.isStopped { return }
            if !buildErrors.isEmpty {
                result.error = "The build failed: " + buildErrors.prefix(3).map(\.text).joined(separator: " ")
            } else if tests.isEmpty {
                result.error = problem.map { "Could not read the results: \($0)" }
                    ?? UIRunner.summary(log) ?? (status == 0 ? "The scheme ran no tests." : "xcodebuild ended with status \(status). Its output is in \(result.log).")
            } else if status != 0, !tests.contains(where: { $0.status == .failed }) {
                // The tests passed and xcodebuild still failed, such as a test runner that crashed.
                result.error = UIRunner.summary(log) ?? "xcodebuild ended with status \(status). Its output is in \(result.log)."
            }
        }
    }

    /// xcresulttool's JSON without a warning printed before or after it: stdout and stderr come
    /// together.
    static func json(_ output: String) -> String {
        guard let start = output.firstIndex(where: { $0 == "{" || $0 == "[" }),
            let end = output.lastIndex(where: { $0 == "}" || $0 == "]" }), start < end
        else { return output }
        return String(output[start...end])
    }

    private func readGradle(
        run: NativeTestRun, status: Int32, log: String, root: URL, module: String?, since started: Date
    ) -> NativeTestResult {
        let reports = Self.junitReports(root: root, module: module)
        // Gradle leaves the reports of earlier runs; a run reads what it wrote. A unit-test task
        // Gradle found up to date wrote nothing, and its previous results still hold.
        let fresh = reports.filter { $0.modified >= started.addingTimeInterval(-2) }
        var note: String?
        var chosen = fresh
        if fresh.isEmpty, status == 0, !reports.isEmpty, !run.isStopped {
            let newest = reports.map(\.modified).max()!
            chosen = reports.filter { newest.timeIntervalSince($0.modified) < 600 }
            note = "Gradle found the task up to date and ran nothing; these are its results from \(newest.formatted(date: .abbreviated, time: .shortened))."
        }
        var tests: [NativeTestResult.Test] = []
        for report in chosen {
            guard let data = try? Data(contentsOf: report.url), let found = try? JUnitReader.tests(data) else { continue }
            tests += found
        }
        let failures = Self.gradleFailure(log)
        return finish(run) { result in
            result.tests = tests
            result.note = note
            if run.isStopped { return }
            if status != 0, !tests.contains(where: { $0.status == .failed }) {
                result.error = failures ?? "Gradle ended with status \(status). Its output is in \(result.log)."
            } else if tests.isEmpty {
                result.error = "Gradle wrote no test results\(failures.map { ": \($0)" } ?? "."). Its output is in \(result.log)."
            }
        }
    }

    /// The JUnit reports under a Gradle root, or a module's: build/outputs/androidTest-results for
    /// instrumented tests and build/test-results for unit tests, with when each was written.
    static func junitReports(root: URL, module: String?) -> [(url: URL, modified: Date)] {
        let base = module.map { root.appendingPathComponent($0.split(separator: ":").joined(separator: "/"), isDirectory: true) } ?? root
        var reports: [(URL, Date)] = []
        guard
            let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }
        while let url = walker.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                let name = url.lastPathComponent
                if ["node_modules", "src", "intermediates", "generated", "tmp", "kotlin"].contains(name) || walker.level > 8 {
                    walker.skipDescendants()
                }
                continue
            }
            let path = url.path
            guard url.pathExtension == "xml",
                path.contains("/build/outputs/androidTest-results/") || path.contains("/build/test-results/")
            else { continue }
            reports.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return reports
    }

    /// Gradle's "What went wrong" in a few lines.
    static func gradleFailure(_ log: String) -> String? {
        let lines = log.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("* What went wrong:") }) else {
            return lines.first { $0.hasPrefix("FAILURE:") || $0.hasPrefix("ERROR:") }
        }
        var message: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("* ") { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { message.append(trimmed) }
            if message.count == 4 { break }
        }
        return message.isEmpty ? nil : message.joined(separator: " ")
    }

    /// Ends the run: the change, its time, the files; then it no longer counts as going on.
    private func finish(_ run: NativeTestRun, _ change: (inout NativeTestResult) -> Void) -> NativeTestResult {
        var final = run.snapshot
        change(&final)
        final.progress = nil
        final.cancelled = run.isStopped
        if final.seconds == 0 { final.seconds = Date().timeIntervalSince(final.started) }
        do {
            try final.write()
        } catch {
            final.error = final.error ?? "Could not write \(final.output): \(error.localizedDescription)"
        }
        run.update { $0 = final }
        return final
    }
}

// MARK: - Starting runs

extension NativeTestRunner {
    /// Starts a run in the background and returns it at once, or the run the project has going
    /// on already (then `started` is false). `onEnd` runs once it finished, such as releasing the
    /// device.
    public func start(
        _ plan: NativeTestPlan, project: TestProject, device: TestRunResult.Device?, output: URL, source: String,
        onEnd: (@Sendable (NativeTestResult) -> Void)? = nil
    ) -> (run: NativeTestRun, started: Bool) {
        let result = NativeTestResult(project: project, plan: plan, device: device, output: output)
        let run = NativeTestRun(project: project.folder, output: output, source: source, result: result)
        if let other = NativeTestRuns.register(run) {
            try? FileManager.default.removeItem(at: output)
            return (other, false)
        }
        let runner = self
        Task.detached(priority: .utility) {
            let final = await runner.execute(plan, device: device, run: run)
            onEnd?(final)
            NativeTestRuns.changed(run.project)
        }
        return (run, true)
    }
}
