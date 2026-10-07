import Foundation

/// `Mobdev test <project> [--device <id or name>]… [--simulator <type>]… [--emulator <avd>]… [--language <tag>]…
/// [--artifacts <dir>] [--test <name>]… [--var NAME=value]… [--no-video] [--wait <seconds>]`: runs a project's tests on a booted iOS
/// simulator or Android device without the app, for scripts and CI. iPhones need the running app;
/// there, call `run_tests` through MCP or the HTTP API.
///
/// Prints a line per test and exits 0 when every test passed, 1 when one failed and 2 when the
/// tests could not start. The artifacts directory gets results.json, junit.xml, each test's video
/// and failure screenshot, the activity log and copied crash reports. Ctrl-C stops after the
/// current step and still writes the results.
public enum TestCommand {
    static let usage = """
        Usage: Mobdev test <project> [--device <id or name>]... [--simulator <device type>]... [--emulator <avd>]... [--language <tag>]... [--artifacts <dir>] [--test <name>]... [--var NAME=value]... [--no-video] [--wait <seconds>]

        Runs the tests of a project (a folder with tests/*.json or Maestro tests/*.yaml and
        mobdev.json, or one test file)
        on a booted iOS simulator or Android emulator or phone, without the app.
          --device     the device from list_devices; needed when several are booted. Repeat it
                       to run on several devices at once, each in its own artifacts folder
          --simulator  create, boot and afterwards delete a simulator of this type for the run,
                       e.g. "iPhone 17" or "iPhone 17,com.apple.CoreSimulator.SimRuntime.iOS-26-5";
                       repeatable, and combinable with --device
          --emulator   start this Android Virtual Device read-only for the run and shut it down
                       afterwards, e.g. Pixel_9_Pro; repeat it, even with the same AVD, for several
                       at once. Nothing the run does is saved to the AVD
          --language   run the tests in this language, e.g. de-DE: the simulator's, or the Android
                       app's (needs app.bundle_id in mobdev.json). Repeat it to run every language
                       on each device in turn, in a folder per language. Steps see it as
                       ${LANGUAGE}, and each device gets its old language back afterwards
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
        /// Android Virtual Devices to start read-only for the run.
        var emulators: [String] = []
        /// Languages to run the tests in, one after another on each device.
        var languages: [String] = []

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
            case "--device", "--artifacts", "--wait", "--test", "--var", "--simulator", "--emulator", "--language":
                guard let value = rest.popFirst() else { throw ToolFailure("\(argument) needs a value.") }
                switch argument {
                case "--device":
                    if options.device == nil { options.device = value } else { options.moreDevices.append(value) }
                case "--simulator": options.simulators.append(value)
                case "--emulator":
                    guard AndroidEmulators.isName(value) else {
                        throw ToolFailure("--emulator needs the name of an Android Virtual Device, like Pixel_9_Pro.")
                    }
                    options.emulators.append(value)
                case "--language":
                    guard !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
                        throw ToolFailure("--language needs a language tag such as de-DE.")
                    }
                    if !options.languages.contains(value) { options.languages.append(value) }
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

        if options.deviceQueries.count + options.simulators.count + options.emulators.count > 1
            || !options.simulators.isEmpty || !options.emulators.isEmpty || options.languages.count > 1
        {
            return await runOnSeveral(project, selected: selected, options: options, home: home.url, output: output)
        }

        guard let connection = await CommandSupport.connect(device: options.device, wait: options.wait, output: output)
        else { return 2 }
        defer { connection.emulators.stop(waiting: true) }
        let device = connection.device

        output("Running \(project.name) (\(selected.isEmpty ? project.tests.count : selected.count) tests) on \(device.name) (\(device.id))")
        let runOptions = TestRunOptions(
            output: home.url, tests: selected, variables: options.variables, video: options.video,
            language: options.languages.first)
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
    /// device, with every line prefixed by the device's name. Each device runs the languages one
    /// after another, each into a folder of its own inside the device's. Simulators made for the
    /// run are deleted afterwards, and emulators started for it shut down. The exit code is the
    /// worst of all runs, and summary.md covers them all.
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
        var started: [AndroidEmulators.Started] = []
        defer { for emulator in started { AndroidEmulators.stop(emulator) } }
        for avd in options.emulators {
            do {
                let emulator = try await AndroidEmulators.start(avd)
                output("Started the emulator \(avd) read-only as \(emulator.serial).")
                started.append(emulator)
            } catch {
                output("Could not start the emulator \(avd): \(error)")
                return 2
            }
        }
        let queries = options.deviceQueries + created + started.map(\.serial)
        guard let connection = await CommandSupport.connect(devices: queries, wait: options.wait, output: output) else {
            return 2
        }
        defer { connection.emulators.stop() }
        let languages: [String?] = options.languages.isEmpty ? [nil] : options.languages
        output(
            "Running \(project.name) on \(connection.devices.map(\.name).joined(separator: ", "))"
                + (connection.devices.count > 1 ? " at once" : "")
                + (options.languages.isEmpty ? "" : " in \(options.languages.joined(separator: ", "))"))
        let results = await withTaskGroup(of: [TestRunResult?].self) { group in
            for device in connection.devices {
                // A UDID's start tells simulators apart; emulator serials differ only at the end.
                let shortID = device.id.count <= 16 ? device.id : String(device.id.prefix(8))
                let deviceFolder = home.appendingPathComponent(
                    "\(TestProject.slug(device.name))-\(TestProject.slug(shortID))", isDirectory: true)
                let name = device.name, id = device.id, tools = connection.tools
                group.addTask {
                    var results: [TestRunResult?] = []
                    for language in languages {
                        let folder = language.map { deviceFolder.appendingPathComponent($0, isDirectory: true) } ?? deviceFolder
                        let runOptions = TestRunOptions(
                            output: folder, tests: selected, variables: options.variables, video: options.video,
                            language: language)
                        let label = "[\(name)\(language.map { ", \($0)" } ?? "")]"
                        do {
                            results.append(
                                try await tools.runTests(project, on: id, options: runOptions, source: "cli") { test in
                                    output("\(label) \(test.line)")
                                    for line in test.detailLines { output("\(label) \(line)") }
                                })
                        } catch {
                            output("\(label) \(error)")
                            results.append(nil)
                        }
                        if Task.isCancelled { break }
                    }
                    return results
                }
            }
            var results: [TestRunResult?] = []
            for await batch in group { results += batch }
            return results
        }
        let finished = results.compactMap { $0 }.sorted {
            ($0.device.name, $0.language ?? "") < ($1.device.name, $1.language ?? "")
        }
        var code: Int32 = finished.count < connection.devices.count * languages.count ? 2 : 0
        for result in finished {
            output(result.summaryLine)
            code = max(code, exitCode(result))
        }
        let markdown = finished.map(\.markdown).joined(separator: "\n")
        try? Data(markdown.utf8).write(to: home.appendingPathComponent(TestRunResult.summaryFileName))
        if options.artifacts != nil {
            output(
                "Results: one folder per device\(options.languages.isEmpty ? "" : " and language") in \(home.path), and summary.md")
        }
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

/// Android Virtual Devices that `Mobdev test --emulator` starts for one run. They run read-only,
/// so several copies of one AVD run at once and nothing they do is saved to it.
enum AndroidEmulators {
    struct Started: Sendable {
        let avd: String
        let serial: String
        let process: Process
    }

    /// AVD names are letters, digits, dots, dashes and underscores.
    static func isName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// The SDK's `emulator` next to its `platform-tools/adb`.
    static func emulatorTool(nextTo adb: URL) -> URL {
        adb.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("emulator/emulator")
    }

    /// The first console port from 5554 whose pair (console, adb) is free and that no listed device uses.
    static func freePort(taken serials: Set<String>, isFree: (Int) -> Bool = AndroidEmulators.canBind) -> Int? {
        stride(from: 5554, through: 5682, by: 2).first { port in
            !serials.contains("emulator-\(port)") && isFree(port) && isFree(port + 1)
        }
    }

    static func canBind(_ port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Starts the AVD without a window and waits until Android has finished booting.
    static func start(_ avd: String, timeout: TimeInterval = 600) async throws -> Started {
        guard let adb = ADB.find() else { throw ToolFailure("adb is missing; install the Android SDK, e.g. with Android Studio.") }
        let tool = emulatorTool(nextTo: adb.executable)
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw ToolFailure("The Android emulator is missing at \(tool.path); install it in Android Studio's SDK Manager.")
        }
        let listed = try await adb.runner.run(tool, ["-list-avds"], timeout: 30)
        let avds = listed.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard avds.contains(avd) else {
            throw ToolFailure("There is no AVD named \(avd). AVDs: \(avds.isEmpty ? "none" : avds.joined(separator: ", ")).")
        }
        let devices = try await adb.runner.run(adb.executable, ["devices"], timeout: 30)
        let serials = Set(devices.output.split(whereSeparator: \.isNewline).compactMap { $0.split(separator: "\t").first.map(String.init) })
        guard let port = freePort(taken: serials) else { throw ToolFailure("No free emulator port between 5554 and 5682.") }

        let log = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-emulator-\(port).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = tool
        process.arguments = [
            "-avd", avd, "-read-only", "-no-snapshot-save", "-no-window", "-no-audio", "-no-boot-anim", "-port", "\(port)",
        ]
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let started = Started(avd: avd, serial: "emulator-\(port)", process: process)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard process.isRunning else {
                let tail = (try? String(contentsOf: log, encoding: .utf8))?.split(whereSeparator: \.isNewline).suffix(3)
                    .joined(separator: " ") ?? ""
                throw ToolFailure("It quit while booting. \(tail)")
            }
            if Task.isCancelled { break }
            let booted = try? await adb.run(started.serial, ["shell", "getprop", "sys.boot_completed"], timeout: 10)
            if booted?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return started }
        }
        stop(started)
        throw ToolFailure("It did not finish booting within \(Int(timeout)) s.")
    }

    /// Asks the emulator to quit through adb and ends its process if it has not after 30 s.
    static func stop(_ started: Started) {
        if let adb = ADB.find() {
            let kill = Process()
            kill.executableURL = adb.executable
            kill.arguments = ["-s", started.serial, "emu", "kill"]
            kill.standardOutput = FileHandle.nullDevice
            kill.standardError = FileHandle.nullDevice
            try? kill.run()
            kill.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(30)
        while started.process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        if started.process.isRunning { started.process.terminate() }
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
