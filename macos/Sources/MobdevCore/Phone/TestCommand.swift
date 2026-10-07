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
        Usage: Mobdev test <project> [--device <id or name>]... [--simulator <device type>]... [--artifacts <dir>] [--test <name>]... [--var NAME=value]... [--no-video] [--wait <seconds>]

        Runs the tests of a project (a folder with tests/*.json or Maestro tests/*.yaml and
        mobdev.json, or one test file)
        on a booted iOS simulator or Android emulator or phone, without the app.
          --device     the device from list_devices; needed when several are booted. Repeat it
                       to run on several devices at once, each in its own artifacts folder
          --simulator  create, boot and afterwards delete a simulator of this type for the run,
                       e.g. "iPhone 17" or "iPhone 17,com.apple.CoreSimulator.SimRuntime.iOS-26-5";
                       repeatable, and combinable with --device
          --artifacts  where to keep results.json, junit.xml, each test's video and failure
                       screenshot, the activity log and crash reports
          --test       run only this test (file name without .json or .yaml, or its name); repeatable
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
        /// Devices after the first `--device`.
        var moreDevices: [String] = []
        /// Simulators to create for the run, as "<device type>" or "<device type>,<runtime>".
        var simulators: [String] = []

        /// Every device query, the first `--device` first.
        var deviceQueries: [String] { (device.map { [$0] } ?? []) + moreDevices }
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var project: String?
        var options = Options(project: "")
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--no-video": options.video = false
            case "--device", "--artifacts", "--wait", "--test", "--var", "--simulator":
                guard let value = rest.popFirst() else { throw ToolFailure("\(argument) needs a value.") }
                switch argument {
                case "--device":
                    if options.device == nil { options.device = value } else { options.moreDevices.append(value) }
                case "--simulator": options.simulators.append(value)
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

        if options.deviceQueries.count + options.simulators.count > 1 || !options.simulators.isEmpty {
            return await runOnSeveral(project, selected: selected, options: options, home: home.url, output: output)
        }

        guard let connection = await CommandSupport.connect(device: options.device, wait: options.wait, output: output)
        else { return 2 }
        defer { connection.emulators.stop(waiting: true) }
        let device = connection.device

        output("Running \(project.name) (\(selected.isEmpty ? project.tests.count : selected.count) tests) on \(device.name) (\(device.id))")
        let runOptions = TestRunOptions(output: home.url, tests: selected, variables: options.variables, video: options.video)
        let result: TestRunResult
        do {
            result = try await connection.tools.runTests(project, on: device.id, options: runOptions, source: "cli") { test in
                output(test.line)
                for line in test.detailLines { output(line) }
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
        return exitCode(result)
    }

    static func exitCode(_ result: TestRunResult) -> Int32 {
        if result.error != nil || result.cancelled { return result.error != nil ? 2 : 1 }
        return result.passed ? 0 : 1
    }

    /// Runs the project on several devices at once, each into a folder of its own named after the
    /// device, with every line prefixed by the device's name. Simulators made for the run are
    /// deleted afterwards. The exit code is the worst of all runs, and summary.md covers them all.
    static func runOnSeveral(
        _ project: TestProject, selected: [String], options: Options, home: URL,
        output: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        var created: [String] = []
        defer { for udid in created { Simulators.delete(udid) } }
        for spec in options.simulators {
            do {
                let udid = try await Simulators.create(spec)
                output("Created and booted the simulator \"\(spec)\" (\(udid)).")
                created.append(udid)
            } catch {
                output("Could not make the simulator \"\(spec)\": \(error)")
                return 2
            }
        }
        let queries = options.deviceQueries + created
        guard let connection = await CommandSupport.connect(devices: queries, wait: options.wait, output: output) else {
            return 2
        }
        defer { connection.emulators.stop() }
        output("Running \(project.name) on \(connection.devices.map(\.name).joined(separator: ", ")) at once")
        let results = await withTaskGroup(of: TestRunResult?.self) { group in
            for device in connection.devices {
                let folder = home.appendingPathComponent(
                    "\(TestProject.slug(device.name))-\(device.id.prefix(8))", isDirectory: true)
                let runOptions = TestRunOptions(output: folder, tests: selected, variables: options.variables, video: options.video)
                let name = device.name, id = device.id, tools = connection.tools
                group.addTask {
                    do {
                        return try await tools.runTests(project, on: id, options: runOptions, source: "cli") { test in
                            output("[\(name)] \(test.line)")
                            for line in test.detailLines { output("[\(name)] \(line)") }
                        }
                    } catch {
                        output("[\(name)] \(error)")
                        return nil
                    }
                }
            }
            var results: [TestRunResult] = []
            for await result in group { if let result { results.append(result) } }
            return results
        }
        var code: Int32 = results.count < connection.devices.count ? 2 : 0
        for result in results.sorted(by: { $0.device.name < $1.device.name }) {
            output(result.summaryLine)
            code = max(code, exitCode(result))
        }
        let markdown = results.sorted { $0.device.name < $1.device.name }.map(\.markdown).joined(separator: "\n")
        try? Data(markdown.utf8).write(to: home.appendingPathComponent(TestRunResult.summaryFileName))
        if options.artifacts != nil { output("Results: one folder per device in \(home.path), and summary.md") }
        return code
    }
}

/// Simulators that `Mobdev test --simulator` makes for one run and deletes afterwards.
enum Simulators {
    /// "iPhone 17" or "iPhone 17,<runtime identifier>": creates, boots and waits until booted.
    static func create(_ spec: String) async throws -> String {
        let parts = spec.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let runner = ProcessRunner()
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        let made = try await runner.run(xcrun, ["simctl", "create", "Mobdev \(parts[0])"] + parts, timeout: 60)
        // simctl also prints which runtime it picked, so the UDID is the line that is one.
        guard let udid = createdUDID(made.output) else {
            throw ToolFailure(made.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard made.status == 0 else {
            delete(udid)
            throw ToolFailure(made.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let booted = try await runner.run(xcrun, ["simctl", "bootstatus", udid, "-b"], timeout: 600)
        guard booted.status == 0 else {
            delete(udid)
            throw ToolFailure("It did not boot: \(booted.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return udid
    }

    /// The UDID in what `simctl create` printed, e.g. after "No runtime specified, using …".
    static func createdUDID(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { UUID(uuidString: $0) != nil }
    }

    /// Shuts the simulator down and deletes it, waiting until it is gone.
    static func delete(_ udid: String) {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        for arguments in [["simctl", "shutdown", udid], ["simctl", "delete", udid]] {
            let process = Process()
            process.executableURL = xcrun
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
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

    /// Waits until every named booted simulator or Android device shows up. Nil, after saying
    /// which are missing, when one does not.
    static func connect(devices queries: [String], wait: TimeInterval, output: @escaping @Sendable (String) -> Void) async
        -> (tools: DeviceTools, devices: [any Device], emulators: EmulatorHub)?
    {
        let emulators = EmulatorHub(adb: ADB.find()) {}
        let tools = DeviceTools(hub: DeviceHub(keyboardLayout: .us) {}, emulators: emulators, settleDelay: 0.3)
        emulators.start()
        let deadline = Date().addingTimeInterval(wait)
        var problems: [String] = []
        while true {
            problems = []
            var found: [any Device] = []
            for query in queries {
                do {
                    if let device = try tools.phone(for: query) as? any Device, !found.contains(where: { $0.id == device.id }) {
                        found.append(device)
                    }
                } catch {
                    problems.append(String(describing: error))
                }
            }
            if problems.isEmpty { return (tools, found, emulators) }
            guard Date() < deadline, !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        emulators.stop()
        for problem in problems { output(problem) }
        if let reason = SimulatorKit.unavailableReason { output("Simulators are not available: \(reason)") }
        return nil
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
