import Foundation

/// `Mobdev test <project> [--device <id or name>] [--artifacts <dir>] [--test <name>]…
/// [--var NAME=value]… [--no-video] [--wait <seconds>]`: runs a project's tests on a booted iOS
/// simulator or Android device without the app, for scripts and CI. iPhones need the running app;
/// there, call `run_tests` through MCP or the HTTP API.
///
/// Prints a line per test and exits 0 when every test passed, 1 when one failed and 2 when the
/// tests could not start. The artifacts directory gets results.json, junit.xml, each test's video
/// and failure screenshot, the activity log and copied crash reports. Ctrl-C stops after the
/// current step and still writes the results.
public enum TestCommand {
    static let usage = """
        Usage: Mobdev test <project> [--device <id or name>] [--artifacts <dir>] [--test <name>]... [--var NAME=value]... [--no-video] [--wait <seconds>]

        Runs the tests of a project (a folder with tests/*.json and mobdev.json, or one test file)
        on a booted iOS simulator or Android emulator or phone, without the app.
          --device     the device from list_devices; needed when several are booted
          --artifacts  where to keep results.json, junit.xml, each test's video and failure
                       screenshot, the activity log and crash reports
          --test       run only this test (file name without .json, or its name); repeatable
          --var        a value for ${NAME} in the steps, e.g. --var EMAIL=me@example.com; repeatable.
                       Secrets can also come from the environment.
          --no-video   do not record the tests
          --wait       how long to wait for the device to appear, default 120
        """

    public static func run(_ arguments: [String]) -> Never {
        CommandSupport.run { await execute(arguments, output: CommandSupport.print) }
    }

    struct Options: Equatable {
        var project: String
        var device: String?
        var artifacts: String?
        var tests: [String] = []
        var variables: [String: String] = [:]
        var video = true
        var wait: TimeInterval = 120
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var project: String?
        var options = Options(project: "")
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--no-video": options.video = false
            case "--device", "--artifacts", "--wait", "--test", "--var":
                guard let value = rest.popFirst() else { throw ToolFailure("\(argument) needs a value.") }
                switch argument {
                case "--device": options.device = value
                case "--artifacts": options.artifacts = value
                case "--test": options.tests.append(value)
                case "--var":
                    let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2, Variables.isName(String(parts[0])) else {
                        throw ToolFailure("--var needs NAME=value, like --var EMAIL=me@example.com.")
                    }
                    options.variables[String(parts[0])] = String(parts[1])
                default:
                    guard let seconds = TimeInterval(value), seconds >= 0 else {
                        throw ToolFailure("--wait needs a number of seconds.")
                    }
                    options.wait = seconds
                }
            case "-h", "--help": throw ToolFailure("")
            default:
                guard !argument.hasPrefix("-"), project == nil else { throw ToolFailure("Unexpected \(argument).") }
                project = argument
            }
        }
        guard let project else { throw ToolFailure("Which project? Pass a folder with tests, or a test file.") }
        options.project = project
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
        let home = CommandSupport.home(artifacts: options.artifacts)
        defer { if home.temporary { try? FileManager.default.removeItem(at: home.url) } }

        let project: TestProject
        var selected: [String]
        do {
            let located = try TestProject.locate(
                options.project.hasPrefix("/") || options.project.hasPrefix("~")
                    ? options.project : FileManager.default.currentDirectoryPath + "/" + options.project)
            project = located.project
            selected = located.tests
        } catch {
            output(String(describing: error))
            return 2
        }
        if !options.tests.isEmpty { selected = options.tests }
        guard !project.tests.isEmpty else {
            output("\(project.name) has no tests. Add tests/<name>.json, or let an agent save one with save_test.")
            return 2
        }

        guard let connection = await CommandSupport.connect(device: options.device, wait: options.wait, output: output)
        else { return 2 }
        defer { connection.emulators.stop() }
        let device = connection.device

        output("Running \(project.name) (\(selected.isEmpty ? project.tests.count : selected.count) tests) on \(device.name) (\(device.id))")
        let runOptions = TestRunOptions(output: home.url, tests: selected, variables: options.variables, video: options.video)
        let result: TestRunResult
        do {
            result = try await connection.tools.runTests(project, on: device.id, options: runOptions, source: "cli") { test in
                output(test.line)
                if test.status == .failed, let screenshot = test.screenshot { output("  Screenshot: \(screenshot)") }
                if test.status == .failed, let video = test.video { output("  Video: \(video)") }
            }
        } catch {
            output(String(describing: error))
            return 2
        }
        for step in result.setup where !step.passed { output("✗ \(step.summary): \(step.text)") }
        output(result.summaryLine)
        if options.artifacts != nil {
            output("Results: \(home.url.appendingPathComponent(TestRunResult.resultsFileName).path), \(TestRunResult.junitFileName)")
        }
        if result.error != nil || result.cancelled { return result.error != nil ? 2 : 1 }
        return result.passed ? 0 : 1
    }
}

/// What `Mobdev flow` and `Mobdev test` share: the artifacts directory, the device to run on and
/// a main loop that stops on Ctrl-C.
enum CommandSupport {
    /// One line to standard output.
    static let print: @Sendable (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }

    /// Runs the command's work and exits with its code. The first interrupt cancels the work,
    /// which ends a wait at once and starts no further step; a second one quits at once.
    static func run(_ work: @escaping @Sendable () async -> Int32) -> Never {
        let task = Task { exit(await work()) }
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                if task.isCancelled { exit(130) }
                FileHandle.standardError.write(Data("Stopping…\n".utf8))
                task.cancel()
            }
            source.resume()
            return source
        }
        withExtendedLifetime(signals) { dispatchMain() }
    }

    /// The artifacts directory, created, as `MOBDEV_HOME` too, so the activity log and crash
    /// reports land there instead of in the app's folder; a temporary one without `--artifacts`.
    static func home(artifacts: String?) -> (url: URL, temporary: Bool) {
        let url =
            artifacts.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "mobdev-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        setenv("MOBDEV_HOME", url.path, 1)
        return (url, artifacts == nil)
    }

    /// Waits for the named booted simulator or Android device, or without a name for the only one;
    /// several booted without a name is a mistake to report at once. Nil, after saying why, when
    /// none appears.
    static func connect(device query: String?, wait: TimeInterval, output: @escaping @Sendable (String) -> Void) async
        -> (tools: DeviceTools, device: any Device, emulators: EmulatorHub)?
    {
        let emulators = EmulatorHub(adb: ADB.find()) {}
        let tools = DeviceTools(hub: DeviceHub(keyboardLayout: .us) {}, emulators: emulators, settleDelay: 0.3)
        emulators.start()
        let deadline = Date().addingTimeInterval(wait)
        var device: (any Device)?
        var lastError = ""
        while device == nil {
            do {
                device = try tools.phone(for: query) as? any Device
            } catch {
                lastError = String(describing: error)
                let ambiguous = query == nil && !emulators.devices.isEmpty
                guard Date() < deadline, !ambiguous, !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard let device else {
            emulators.stop()
            output(lastError.isEmpty ? "No booted simulator or Android device." : lastError)
            if let reason = SimulatorKit.unavailableReason { output("Simulators are not available: \(reason)") }
            return nil
        }
        return (tools, device, emulators)
    }
}
