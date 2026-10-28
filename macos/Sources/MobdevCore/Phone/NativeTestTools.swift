import CoreGraphics
import Foundation

/// `run_native_tests`: the app's own test suites on this device, XCTest and Swift Testing through
/// Xcode, instrumented and unit tests through Gradle. A run goes on in the background, holding the
/// device, and `native_test_result` reads it, so no caller has to wait the minutes it takes.
extension PhoneTools {
    static let nativeTestDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "run_native_tests", title: "Run native tests",
            description:
                "Run the app's own test suite on this device: XCTest, XCUITest and Swift Testing with xcodebuild on a simulator or iPhone, or Android instrumented tests with Gradle (connectedDebugAndroidTest) on an emulator or phone; a Gradle unit-test task such as testDebugUnitTest runs on the Mac. The suite comes from native_tests in the project's mobdev.json, else the repository's only Xcode workspace or project and shared scheme with tests, or its gradlew; arguments override both. Results go to the project's output/native-runs: every failure with its message and file:line, failures' attachments, results.json, junit.xml and the .xcresult. Builds take minutes: the run goes on in the background and holds the device; the call waits up to wait seconds (default until the end, through a relay at most 75) and otherwise returns while it runs. Then call native_test_result.",
            inputSchema: schema(
                [
                    "project": ProjectTools.projectArgument(),
                    "platform": [
                        "type": "string", "enum": ["ios", "android"],
                        "description": "Which suite: ios or android. Default the device's platform",
                    ],
                    "only": [
                        "type": "array", "items": ["type": "string"],
                        "description":
                            "Run only these tests. iOS: Target, Target/Class or Target/Class/method as -only-testing takes them (Swift Testing functions with their parentheses, like AppTests/adding()). Android: a class or Class#method, e.g. com.example.LoginTest#signIn",
                    ],
                    "workspace": ["type": "string", "description": "iOS: the .xcworkspace, relative to the project folder or absolute"],
                    "xcode_project": ["type": "string", "description": "iOS: the .xcodeproj, instead of a workspace"],
                    "scheme": ["type": "string", "description": "iOS: the scheme whose tests run"],
                    "test_plan": ["type": "string", "description": "iOS: a test plan of the scheme"],
                    "build": [
                        "type": "boolean",
                        "description": "iOS: false runs test-without-building on the last build. Default true",
                    ],
                    "gradle_root": ["type": "string", "description": "Android: the folder with gradlew, relative to the project folder or absolute"],
                    "task": [
                        "type": "string",
                        "description": "Android: the Gradle task, default connectedDebugAndroidTest; testDebugUnitTest runs unit tests on the Mac",
                    ],
                    "module": ["type": "string", "description": "Android: the Gradle module, e.g. app"],
                    "wait": [
                        "type": "number",
                        "description": "Seconds to wait for the end before returning while it runs; 0 returns at once. Default until the end (through a relay at most 75)",
                    ],
                ], screenshot: false),
            readOnly: false)
    ]

    /// How long a call through a relay waits, which gives up on the Mac after 90 seconds.
    static let relayWait: TimeInterval = 75

    func runNativeTestsTool(_ args: Arguments, source: String) async throws -> ToolOutput {
        let (project, _) = try ProjectTools.locate(args, projects: projects)
        let device = phone as? any Device
        let kind = device?.kind ?? (phone.status().input.isIPhone ? DeviceKind.iPhone : .simulator)
        func text(_ key: String) throws -> String? { args.has(key) ? try args.string(key) : nil }
        let overrides = NativeTestPlan.Overrides(
            workspace: try text("workspace"), project: try text("xcode_project"), scheme: try text("scheme"),
            testPlan: try text("test_plan"), gradleRoot: try text("gradle_root"), task: try text("task"), module: try text("module"))
        var platform = NativePlatform(kind)
        if args.has("platform") {
            guard let named = NativePlatform(rawValue: try args.string("platform")) else {
                throw ToolFailure("platform must be ios or android.")
            }
            platform = named
        } else if phone is ThisMac {
            platform = NativeTestPlan.platformWithoutDevice(project, overrides: overrides)
        }
        let plan = try NativeTestPlan.resolve(
            project, platform: platform, overrides: overrides, only: try args.stringArray("only"), build: args.bool("build") ?? true)
        var wait = try args.number("wait", default: 2 * 3600, range: 0...(2 * 3600))
        if source == "relay" { wait = min(wait, Self.relayWait) }

        if let running = NativeTestRuns.running(for: project.folder) {
            return nativeOutput(running.snapshot, prefix: "\(project.name) already has native tests running, started by \(running.source).")
        }
        var target: TestRunResult.Device?
        if plan.needsDevice {
            guard let device else {
                throw ToolFailure(
                    "No device to run \(plan.title) on: boot a simulator or connect a device. A Gradle unit-test task such as testDebugUnitTest runs on the Mac without one.")
            }
            target = TestRunResult.Device(id: device.id, name: device.name, kind: device.kind.rawValue)
        }
        // Xcode installs the app and drives it, so nothing else may tap meanwhile. Unit tests on
        // the Mac leave the device alone.
        let hold = plan.needsDevice ? try takeHold("a native test run", source: source) : nil
        // Mobdev Runner is an XCTest session too, and an iPhone runs one at a time: it waits for the
        // run, which holds the device anyway.
        let pausedRunner = plan.needsDevice && platform == .ios ? (phone as? HardwareDevice)?.info?.id : nil
        if let pausedRunner { UIRunners.shared.pause(pausedRunner) }
        let output: URL
        do {
            output = try NativeTestRuns.newRunFolder(for: project)
        } catch {
            if let hold { releaseHold(hold) }
            if let pausedRunner { UIRunners.shared.resume(pausedRunner) }
            throw error
        }
        // 0 while the call waits; 1 once it returned with the run going on, so the end is logged.
        let delivery = Locked(0)
        let activity = self.activity
        let projects = self.projects
        let own = TestProject.isProject(project.folder) ? ProjectList.normalized(project.folder) : nil
        let (run, started) = NativeTestRunner.current.start(
            plan, project: project, device: target, output: output, source: source
        ) { [weak self] final in
            if let hold { self?.releaseHold(hold) }
            if let pausedRunner { UIRunners.shared.resume(pausedRunner) }
            if delivery.get() == 1 {
                activity.record(source: source, tool: "run_native_tests", summary: final.summaryLine, failed: !final.passed)
            }
            if let own { projects.notifyOutput(own, .nativeRuns) }
        }
        guard started else {
            if let hold { releaseHold(hold) }
            if let pausedRunner { UIRunners.shared.resume(pausedRunner) }
            return nativeOutput(run.snapshot, prefix: "\(project.name) already has native tests running, started by \(run.source).")
        }
        let result = await run.wait(timeout: wait)
        delivery.withLock { $0 = result.running ? 1 : 2 }
        if result.running {
            return nativeOutput(
                result,
                prefix:
                    "Started native tests of \(project.name): \(plan.title)\(target.map { " on \($0.name)" } ?? " on this Mac"). They go on in the background\(plan.needsDevice ? " and hold the device" : ""); call native_test_result for how they are doing and, once done, every result."
            )
        }
        return nativeOutput(result)
    }

    func nativeOutput(_ result: NativeTestResult, prefix: String? = nil) -> ToolOutput {
        ToolOutput(
            text: [prefix, result.text].compactMap { $0 }.joined(separator: "\n"), data: result.json,
            isError: !result.running && !result.passed)
    }

    /// Takes the device's hold for a run that outlives the call, until `releaseHold`. Throws
    /// "Busy" while another caller's run holds it.
    func takeHold(_ what: String, source: String) throws -> UUID {
        let mine = DeviceHold(what: what, source: source)
        let other = hold.withLock { held -> DeviceHold? in
            if let held { return held }
            held = mine
            return nil
        }
        if let other { throw ToolFailure(other.busy) }
        return mine.id
    }

    func releaseHold(_ id: UUID) {
        hold.withLock { held in if held?.id == id { held = nil } }
    }
}

/// No device: a Gradle unit-test task runs on the Mac when none is connected, and `run_native_tests`
/// goes through this in its place.
struct ThisMac: PhoneBackend {
    private func none() -> ToolFailure { ToolFailure("No device is connected.") }
    func status() -> PhoneStatus {
        PhoneStatus(screen: .searching, bluetooth: .unsupported("no device"), keyboardLayout: .us, input: .direct("this Mac"))
    }
    func frame() -> CGImage? { nil }
    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws { throw none() }
    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws { throw none() }
    func scroll(at point: NormalizedPoint, ticks: Int) async throws { throw none() }
    func pan(at point: NormalizedPoint, ticks: Int) async throws { throw none() }
    func type(_ strokes: [KeyStroke]) async throws { throw none() }
    func press(_ stroke: KeyStroke) async throws { throw none() }
    func press(_ button: ConsumerUsage) async throws { throw none() }
}

extension ProjectTools {
    static let nativeTestDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "native_test_result", title: "Native test result",
            description:
                "How a project's native test run (run_native_tests or the app) is doing while it runs, else the results of its newest run (or the run named by run): counts, every failed test with its message, file:line and attachments, the result bundle and the log. Call it again while it runs.",
            inputSchema: PhoneTools.schema(
                [
                    "project": projectArgument(),
                    "run": ["type": "string", "description": "A run folder's name, e.g. 2026-10-07 14.03.22; default the newest"],
                ], screenshot: false),
            readOnly: true)
    ]

    static func nativeTestResult(_ args: Arguments, projects: ProjectList) throws -> ToolOutput {
        let (project, _) = try locate(args, projects: projects)
        let named = args.has("run") ? try args.string("run") : nil
        if named == nil, let running = NativeTestRuns.running(for: project.folder) {
            let snapshot = running.snapshot
            return ToolOutput(
                text: snapshot.text + "\nStill running; call native_test_result again for the results.", data: snapshot.json)
        }
        guard let result = NativeTestRuns.result(for: project, run: named) else {
            let runs = NativeTestRuns.runs(for: project).map(\.lastPathComponent)
            if let named {
                throw ToolFailure(
                    "No native run \"\(named)\" for \(project.name). Runs: \(runs.isEmpty ? "none" : runs.joined(separator: ", ")).")
            }
            throw ToolFailure("No native test results yet for \(project.name). Run them with run_native_tests.")
        }
        return ToolOutput(text: result.text, data: result.json)
    }

    /// What `list_tests` says about the native suites: what mobdev.json names, and the newest run.
    static func nativeLines(_ project: TestProject) -> [String] {
        var lines: [String] = []
        if let ios = project.nativeTests?.ios {
            let parts = [ios.workspace ?? ios.project, ios.scheme.map { "scheme \($0)" }, ios.testPlan.map { "test plan \($0)" }]
            lines.append("Native iOS tests: " + parts.compactMap { $0 }.joined(separator: ", "))
        }
        if let android = project.nativeTests?.android {
            let parts = [
                android.gradleRoot, android.module.map { "module \($0)" }, "task \(android.task ?? NativeTestPlan.defaultGradleTask)",
            ]
            lines.append("Native Android tests: " + parts.compactMap { $0 }.joined(separator: ", "))
        }
        if let running = NativeTestRuns.running(for: project.folder) {
            lines.append("Native tests running: \(running.snapshot.summaryLine)")
        } else if let last = NativeTestRuns.result(for: project) {
            lines.append("Newest native run: \(last.summaryLine) Call native_test_result for details.")
        }
        return lines
    }
}
