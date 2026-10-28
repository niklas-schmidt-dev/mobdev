import Foundation

/// `Mobdev test <project> --native …`: runs the app's own XCTest or Gradle suite, as
/// `run_native_tests` does, on a booted simulator or Android device without the app, for CI.
///
/// Prints the phases while it builds and tests, then a line per test, and exits 0 when every test
/// passed, 1 when one failed or Ctrl-C stopped it, and 2 when the tests could not run (no suite
/// found, the build failed, no device). `--artifacts` gets results.json, junit.xml, summary.md,
/// the log, Tests.xcresult and failures' attachments.
enum NativeTestCommand {
    static let usage = """
        Usage: Mobdev test <project> --native [--platform ios|android] [--device <id or name>] [--simulator <device type>] [--emulator <avd>] [--artifacts <dir>] [--test <identifier>]... [--scheme <name>] [--test-plan <name>] [--workspace <path>] [--xcode-project <path>] [--no-build] [--gradle-root <path>] [--task <task>] [--module <module>] [--wait <seconds>]

        Runs the app's own test suite: XCTest, XCUITest and Swift Testing with xcodebuild on a
        booted simulator, or Android's instrumented tests with Gradle on an emulator or phone. A
        Gradle unit-test task such as testDebugUnitTest runs on the Mac without a device. The suite
        comes from native_tests in mobdev.json, else the repository's only Xcode workspace or
        project and shared scheme with tests, or its gradlew; the options override both, with
        paths relative to the project folder.
          --platform       ios or android; default the device's
          --device         the booted simulator or Android device; needed when several are booted
          --simulator      create and boot a simulator of this type for the run and delete it
                           afterwards, e.g. "iPhone 17"
          --emulator       start this Android Virtual Device read-only for the run and shut it down
                           afterwards
          --artifacts      where to keep results.json, junit.xml, summary.md, the log, Tests.xcresult
                           and the failures' attachments
          --test           run only this test (repeatable): Target/Class/method for Xcode,
                           com.example.LoginTest or com.example.LoginTest#signIn for Gradle
          --scheme, --test-plan, --workspace, --xcode-project
                           the Xcode suite; --no-build runs test-without-building on the last build
          --gradle-root, --task, --module
                           the Gradle suite; --task defaults to connectedDebugAndroidTest
          --wait           how long to wait for the device to appear, default 120
        """

    struct Options: Equatable {
        var project = ""
        var platform: NativePlatform?
        var device: String?
        var simulator: String?
        var emulator: String?
        var artifacts: String?
        var only: [String] = []
        var overrides = NativeTestPlan.Overrides()
        var build = true
        var wait: TimeInterval = 120
    }

    /// The flow options of `Mobdev test` that mean nothing for a native suite.
    static let flowOnly: Set<String> = ["--var", "--language", "--no-video"]

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var project: String?
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--native": continue
            case "--no-build": options.build = false
            case "-h", "--help": throw ToolFailure("")
            case _ where flowOnly.contains(argument):
                throw ToolFailure("\(argument) is for Mobdev's own tests, not for --native.")
            case "--platform", "--device", "--simulator", "--emulator", "--artifacts", "--test", "--scheme", "--test-plan",
                "--workspace", "--xcode-project", "--gradle-root", "--task", "--module", "--wait":
                guard let value = rest.popFirst(), !value.isEmpty else { throw ToolFailure("\(argument) needs a value.") }
                switch argument {
                case "--platform":
                    guard let platform = NativePlatform(rawValue: value) else { throw ToolFailure("--platform takes ios or android.") }
                    options.platform = platform
                case "--device": options.device = value
                case "--simulator": options.simulator = value
                case "--emulator":
                    guard AndroidEmulators.isName(value) else {
                        throw ToolFailure("--emulator needs the name of an Android Virtual Device, like Pixel_9_Pro.")
                    }
                    options.emulator = value
                case "--artifacts": options.artifacts = value
                case "--test": options.only.append(value)
                case "--scheme": options.overrides.scheme = value
                case "--test-plan": options.overrides.testPlan = value
                case "--workspace": options.overrides.workspace = value
                case "--xcode-project": options.overrides.project = value
                case "--gradle-root": options.overrides.gradleRoot = value
                case "--task": options.overrides.task = value
                case "--module": options.overrides.module = value
                default:
                    guard let seconds = TimeInterval(value), seconds >= 0 else { throw ToolFailure("--wait needs a number of seconds.") }
                    options.wait = seconds
                }
            default:
                guard !argument.hasPrefix("-"), project == nil else { throw ToolFailure("Unexpected \(argument).") }
                project = argument
            }
        }
        guard let project else { throw ToolFailure("Which project? Pass the folder with mobdev.json.") }
        options.project = project
        let devices = [options.device, options.simulator, options.emulator].compactMap { $0 }
        guard devices.count <= 1 else { throw ToolFailure("--native runs on one device: pass one of --device, --simulator and --emulator.") }
        if options.simulator != nil, options.platform == .android { throw ToolFailure("--simulator runs iOS tests, not --platform android.") }
        if options.emulator != nil, options.platform == .ios { throw ToolFailure("--emulator runs Android tests, not --platform ios.") }
        if options.platform == nil {
            if options.simulator != nil { options.platform = .ios }
            if options.emulator != nil { options.platform = .android }
        }
        return options
    }

    static func execute(_ arguments: [String], output: @escaping @Sendable (String) -> Void) async -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            let message = String(describing: error)
            output(message.isEmpty ? usage : "\(message)\n\n\(usage)")
            return 2
        }
        let project: TestProject
        do {
            let path = options.project.hasPrefix("/") || options.project.hasPrefix("~")
                ? options.project : FileManager.default.currentDirectoryPath + "/" + options.project
            project = try TestProject.locate(path).project
        } catch {
            output(String(describing: error))
            return 2
        }

        // A plan known before any device: a Gradle unit-test task needs none.
        var plan: NativeTestPlan?
        if let platform = options.platform {
            do {
                plan = try NativeTestPlan.resolve(
                    project, platform: platform, overrides: options.overrides, only: options.only, build: options.build)
            } catch {
                output(String(describing: error))
                return 2
            }
        }

        let home = CommandSupport.home(artifacts: options.artifacts)
        defer { if home.temporary { try? FileManager.default.removeItem(at: home.url) } }
        var device: TestRunResult.Device?
        var created: String?
        var started: AndroidEmulators.Started?
        defer {
            if let created { Simulators.delete(created) }
            if let started { AndroidEmulators.stop(started) }
        }
        if plan?.needsDevice ?? true {
            var query = options.device
            do {
                if let spec = options.simulator {
                    let udid = try await Simulators.create(spec)
                    output("Created and booted the simulator \"\(spec)\" (\(udid)).")
                    created = udid
                    query = udid
                } else if let avd = options.emulator {
                    let emulator = try await AndroidEmulators.start(avd)
                    output("Started the emulator \(avd) read-only as \(emulator.serial).")
                    started = emulator
                    query = emulator.serial
                }
            } catch {
                output("Could not start the device: \(error)")
                return 2
            }
            guard let connection = await CommandSupport.connect(device: query, wait: options.wait, output: output) else { return 2 }
            let found = connection.device
            connection.emulators.stop()
            device = TestRunResult.Device(id: found.id, name: found.name, kind: found.kind.rawValue)
            if plan == nil {
                do {
                    plan = try NativeTestPlan.resolve(
                        project, platform: NativePlatform(found.kind), overrides: options.overrides, only: options.only,
                        build: options.build)
                } catch {
                    output(String(describing: error))
                    return 2
                }
            }
        }
        guard let plan else { return 2 }
        if !plan.needsDevice { device = nil }

        // xcodebuild refuses to write a result bundle over an earlier one.
        try? FileManager.default.removeItem(at: home.url.appendingPathComponent(NativeTestResult.resultBundleName))
        output("Running \(project.name)'s \(plan.title) \(device.map { "on \($0.name) (\($0.id))" } ?? "on this Mac")")
        let (run, _) = NativeTestRunner().start(plan, project: project, device: device, output: home.url, source: "cli")
        var phase = ""
        while !run.isFinished {
            if Task.isCancelled { run.cancel() }
            if let progress = run.snapshot.progress, progress.phase != phase {
                phase = progress.phase
                output("\(phase)…")
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let result = run.snapshot
        for failure in result.buildErrors { output("✗ \(failure.text)") }
        for test in result.tests {
            output(test.line)
            for line in test.detailLines { output(line) }
        }
        if let note = result.note { output(note) }
        output(result.summaryLine)
        if options.artifacts != nil {
            output("Results: \(home.url.appendingPathComponent(NativeTestResult.resultsFileName).path), \(NativeTestResult.junitFileName), \(URL(fileURLWithPath: result.log).lastPathComponent)\(result.resultBundle == nil ? "" : ", \(NativeTestResult.resultBundleName)")")
        }
        return exitCode(result)
    }

    static func exitCode(_ result: NativeTestResult) -> Int32 {
        if result.error != nil { return 2 }
        return result.passed ? 0 : 1
    }
}
