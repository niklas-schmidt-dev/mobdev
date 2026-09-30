import Foundation
import Testing
@testable import MobdevCore

/// Answers devicectl commands from a script, the way the real one writes its --json-output.
final class FakeDevicectl: CommandRunning, @unchecked Sendable {
    /// Whole JSON documents by subcommand, e.g. "device info apps".
    var answers: [String: JSONValue] = [:]
    /// What `device copy from` writes, by source name.
    var files: [String: String] = [:]
    /// What `device process launch --console` prints, and its exit status.
    var console: (lines: [String], status: Int32) = ([], 0)
    /// False keeps the console running, like an app that has not ended yet.
    var consoleExits = true
    let calls = Locked<[[String]]>([])

    static func success(_ result: JSONValue) -> JSONValue {
        ["info": ["outcome": "success", "jsonVersion": 5], "result": result]
    }

    static func failure(_ description: String, reason: String) -> JSONValue {
        [
            "info": ["outcome": "failed"],
            "error": [
                "code": 10002, "domain": "com.apple.dt.CoreDeviceError",
                "userInfo": [
                    "NSLocalizedDescription": ["string": .string(description)],
                    "NSLocalizedFailureReason": ["string": .string(reason)],
                ],
            ],
        ]
    }

    func command(_ arguments: [String]) -> String {
        arguments.prefix { !$0.hasPrefix("-") }.joined(separator: " ")
    }

    func calls(to command: String) -> [[String]] {
        calls.get().filter { self.command($0) == command }
    }

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        calls.withLock { $0.append(arguments) }
        let command = command(arguments)
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        if let path = value(after: "--json-output"), let answer = answers[command] {
            try answer.encoded().write(to: URL(fileURLWithPath: path))
        }
        if command == "device copy from", let source = value(after: "--source"), let text = files[source],
            let destination = value(after: "--destination")
        {
            try Data(text.utf8).write(to: URL(fileURLWithPath: destination))
        }
        return CommandResult(status: answers[command] == nil ? 1 : 0, output: "")
    }

    func start(
        _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningCommand {
        calls.withLock { $0.append(arguments) }
        for line in console.lines { onLine(line) }
        if consoleExits { onExit(console.status) }
        return Stopped()
    }

    func runBinary(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, data: Data) {
        calls.withLock { $0.append(arguments) }
        return (1, Data())
    }

    private struct Stopped: RunningCommand {
        func stop() {}
    }
}

@Suite struct DeveloperToolTests {
    let udid = "00008120-000639440C13C01E"
    let runner = FakeDevicectl()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-tests-\(UUID().uuidString)")

    func tools() -> PhoneTools {
        let control = DeviceControl(
            udid: udid, runner: runner, devicectl: URL(fileURLWithPath: "/usr/bin/true"), reportsFolder: folder)
        return PhoneTools(phone: FakePhone(lines: [], apps: control), activity: ActivityLog(), settleDelay: 0)
    }

    func call(_ tools: PhoneTools, _ name: String, _ arguments: JSONValue = [:]) async throws -> ToolOutput {
        try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
    }

    static let fixtureApp: JSONValue = [
        "bundleIdentifier": "dev.mobdev.fixture", "name": "Mobdev Fixture", "version": "1.2", "bundleVersion": "7",
        "builtByDeveloper": true, "removable": true,
        "url": "file:///private/var/containers/Bundle/Application/25CD989E/MobdevFixture.app/",
    ]
    static let storeApp: JSONValue = [
        "bundleIdentifier": "net.whatsapp.WhatsApp", "name": "WhatsApp", "version": "26.1", "bundleVersion": "1",
        "builtByDeveloper": false, "removable": true,
        "url": "file:///private/var/containers/Bundle/Application/A41A378E/WhatsApp.app/",
    ]

    /// A folder that looks like an app bundle built for the given platform.
    func appBundle(platform: String) throws -> URL {
        let app = folder.appendingPathComponent("Fixture-\(platform).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "dev.mobdev.fixture", "CFBundleSupportedPlatforms": [platform]]
        try info.write(to: app.appendingPathComponent("Info.plist"))
        return app
    }

    @Test func listAppsShowsDeveloperAppsForThisDevice() async throws {
        runner.answers["device info apps"] = FakeDevicectl.success(["apps": [Self.fixtureApp]])
        let output = try await call(tools(), "list_apps")
        #expect(!output.isError)
        #expect(output.text == "Mobdev Fixture 1.2 (7): dev.mobdev.fixture")
        #expect(output.data?.arrayValue?.first?["developer"] == true)
        let arguments = try #require(runner.calls(to: "device info apps").first)
        #expect(arguments.contains(udid))
        #expect(!arguments.contains("--include-all-apps"))
    }

    @Test func installChecksThePathBeforeDevicectl() async throws {
        let tools = tools()
        let simulatorBuild = try appBundle(platform: "iPhoneSimulator")
        let simulator = try await call(tools, "install_app", ["path": .string(simulatorBuild.path)])
        #expect(simulator.isError)
        #expect(simulator.text.contains("built for the Simulator"))
        let relative = try await call(tools, "install_app", ["path": "build/My.app"])
        #expect(relative.text.contains("absolute"))
        let missing = try await call(tools, "install_app", ["path": "/nonexistent/My.app"])
        #expect(missing.text.contains("does not exist"))
        let wrongKind = try await call(tools, "install_app", ["path": "/etc/hosts"])
        #expect(wrongKind.text.contains(".app bundle or an .ipa"))
        #expect(runner.calls.get().isEmpty)
    }

    @Test func installReportsWhatWasInstalledWithoutAScreenshot() async throws {
        let build = try appBundle(platform: "iPhoneOS")
        runner.answers["device install app"] = FakeDevicectl.success([
            "installedApplications": [["bundleID": "dev.mobdev.fixture"]]
        ])
        runner.answers["device info apps"] = FakeDevicectl.success(["apps": [Self.fixtureApp]])
        let output = try await tools().call(
            "install_app", arguments: ["path": .string(build.path)], source: "test", screenshotByDefault: true)
        #expect(output.text == "Installed Mobdev Fixture 1.2 (7) as dev.mobdev.fixture. Start it with launch_app.")
        #expect(output.image == nil)
        let arguments = try #require(runner.calls(to: "device install app").first)
        // The path comes after "--", so a path starting with "-" is never read as an option.
        #expect(Array(arguments.suffix(2)) == ["--", build.path])
    }

    @Test func uninstallRefusesAppsNotInstalledForDevelopment() async throws {
        runner.answers["device info apps"] = FakeDevicectl.success(["apps": [Self.storeApp]])
        let output = try await call(tools(), "uninstall_app", ["bundle_id": "net.whatsapp.WhatsApp"])
        #expect(output.isError)
        #expect(output.text.contains("never App Store or system apps"))
        #expect(runner.calls(to: "device uninstall app").isEmpty)
    }

    @Test func uninstallRemovesADeveloperApp() async throws {
        runner.answers["device info apps"] = FakeDevicectl.success(["apps": [Self.fixtureApp]])
        runner.answers["device uninstall app"] = FakeDevicectl.success([:])
        let output = try await call(tools(), "uninstall_app", ["bundle_id": "dev.mobdev.fixture"])
        #expect(output.text == "Removed Mobdev Fixture 1.2 (7) (dev.mobdev.fixture) and its data.")
        #expect(runner.calls(to: "device uninstall app").first?.suffix(2) == ["--", "dev.mobdev.fixture"])
    }

    @Test func launchCapturesOutputAndHowTheAppEnded() async throws {
        runner.console = (
            [
                "Launched application with dev.mobdev.fixture bundle identifier.",
                "Waiting for the application to terminate…",
                "fixture: first",
                "2026-09-29 22:51:01.827538+0200 MobdevFixture[72519:139909429] [app] fixture: os_log line",
                "fixture: second",
                "App terminated due to signal 5.",
            ], 1
        )
        let tools = tools()
        let launched = try await call(
            tools, "launch_app",
            ["bundle_id": "dev.mobdev.fixture", "arguments": ["-flag", "two"], "environment": ["MODE": "test"]])
        #expect(launched.text == "Launched dev.mobdev.fixture. Its output is captured; read it with logs.")

        let arguments = try #require(runner.calls(to: "device process launch").first)
        #expect(arguments.contains("--console"))
        #expect(arguments.contains("--terminate-existing"))
        #expect(Array(arguments.suffix(4)) == ["--", "dev.mobdev.fixture", "-flag", "two"])
        let environment = try #require(arguments.firstIndex(of: "--environment-variables").map { arguments[$0 + 1] })
        let parsed = try JSONValue.parse(Data(environment.utf8))
        #expect(parsed["OS_ACTIVITY_DT_MODE"] == "YES")
        #expect(parsed["MODE"] == "test")

        let logs = try await call(tools, "logs", ["bundle_id": "dev.mobdev.fixture"])
        #expect(logs.text.contains("dev.mobdev.fixture: crashed: signal 5 (SIGTRAP). Call crash_reports"))
        #expect(logs.text.contains("fixture: first\n"))
        #expect(!logs.text.contains("Launched application"))
        #expect(!logs.text.contains("Waiting for"))
        #expect(logs.data?["cursor"] == 3)

        let newer = try await call(tools, "logs", ["after": 2])
        #expect(newer.data?["lines"]?.arrayValue?.count == 1)
        #expect(newer.text.contains("fixture: second"))
        let filtered = try await call(tools, "logs", ["contains": "OS_LOG"])
        #expect(filtered.data?["lines"]?.arrayValue?.count == 1)
    }

    @Test func logsPageForwardWithoutSkippingLines() async throws {
        runner.console = (["Launched application with dev.mobdev.fixture bundle identifier."] + (1...5).map { "line \($0)" }, 0)
        runner.consoleExits = false
        let tools = tools()
        _ = try await call(tools, "launch_app", ["bundle_id": "dev.mobdev.fixture"])
        let first = try await call(tools, "logs", ["after": 0, "lines": 2])
        #expect(first.data?["lines"]?.arrayValue?.map { $0["text"] } == ["line 1", "line 2"])
        #expect(first.data?["more"] == true)
        #expect(first.data?["cursor"] == 2)
        let second = try await call(tools, "logs", ["after": 2, "lines": 2])
        #expect(second.data?["lines"]?.arrayValue?.map { $0["text"] } == ["line 3", "line 4"])
        let tail = try await call(tools, "logs", ["lines": 2])
        #expect(tail.data?["lines"]?.arrayValue?.map { $0["text"] } == ["line 4", "line 5"])
        #expect(tail.data?["cursor"] == 5)
        // A cursor from before Mobdev restarted starts over instead of hiding every line.
        let stale = try await call(tools, "logs", ["after": 900])
        #expect(stale.data?["lines"]?.arrayValue?.count == 5)
        let huge = try await call(tools, "logs", ["after": 9_223_372_036_854_775_807])
        #expect(huge.isError)
    }

    @Test func relaunchWithoutRestartKeepsTheCapture() async throws {
        runner.console = (["Launched application with dev.mobdev.fixture bundle identifier.", "hello"], 0)
        runner.consoleExits = false
        runner.answers["device process launch"] = FakeDevicectl.success(["process": ["processIdentifier": 42]])
        let tools = tools()
        _ = try await call(tools, "launch_app", ["bundle_id": "dev.mobdev.fixture"])
        let again = try await call(tools, "launch_app", ["bundle_id": "dev.mobdev.fixture", "restart": false])
        #expect(again.text.contains("already running with its output captured"))
        let launches = runner.calls(to: "device process launch")
        #expect(launches.count == 2)
        #expect(launches[0].contains("--console"))
        #expect(!launches[1].contains("--console"))
        let logs = try await call(tools, "logs", ["bundle_id": "dev.mobdev.fixture"])
        #expect(logs.text.contains("dev.mobdev.fixture: running"))
    }

    @Test func aConsoleThatEndsWithoutAnEndingSaysSo() async throws {
        runner.console = (["Launched application with dev.mobdev.fixture bundle identifier.", "hello"], 1)
        let tools = tools()
        _ = try await call(tools, "launch_app", ["bundle_id": "dev.mobdev.fixture"])
        let logs = try await call(tools, "logs", ["bundle_id": "dev.mobdev.fixture"])
        #expect(logs.text.contains("output capture ended (devicectl exited with status 1)"))
    }

    @Test func launchFailureSaysWhatIsWrong() async throws {
        runner.console = (
            [
                "ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002 (0x2712))",
                "       NSLocalizedFailureReason = The requested application com.example.missing is not installed.",
                "       BundleIdentifier = com.example.missing",
                "       NSLocalizedRecoverySuggestion = Provide a valid bundle identifier.",
            ], 1
        )
        runner.answers["list devices"] = FakeDevicectl.success([
            "devices": [["hardwareProperties": ["udid": .string(udid)], "deviceProperties": ["developerModeStatus": "disabled"]]]
        ])
        let output = try await call(tools(), "launch_app", ["bundle_id": "com.example.missing"])
        #expect(output.isError)
        #expect(
            output.text.hasPrefix(
                "The application failed to launch. The requested application com.example.missing is not installed. Provide a valid bundle identifier."
            ))
        #expect(output.text.contains("Developer Mode is off"))
    }

    @Test func devicectlErrorsBecomeReadableMessages() async throws {
        runner.answers["device process openURL"] = FakeDevicectl.failure(
            "The device is locked.", reason: "Unlock the device and try again.")
        runner.answers["list devices"] = FakeDevicectl.success(["devices": []])
        let output = try await call(tools(), "open_url", ["url": "myapp://settings"])
        #expect(output.isError)
        #expect(output.text.hasPrefix("The device is locked. Unlock the device and try again."))
        #expect(output.text.contains("Xcode does not know this device yet"))
        let badURL = try await call(tools(), "open_url", ["url": "not a url"])
        #expect(badURL.text.contains("scheme"))
    }

    @Test func stopTerminatesTheAppsProcessOnly() async throws {
        runner.answers["device info apps"] = FakeDevicectl.success(["apps": [Self.fixtureApp]])
        runner.answers["device info processes"] = FakeDevicectl.success([
            "runningProcesses": [
                ["processIdentifier": 1, "executable": "file:///sbin/launchd"],
                [
                    "processIdentifier": 812,
                    "executable": "file:///private/var/containers/Bundle/Application/25CD989E/MobdevFixture.app/MobdevFixture",
                ],
                [
                    "processIdentifier": 813,
                    "executable":
                        "file:///private/var/containers/Bundle/Application/25CD989E/MobdevFixture.app/PlugIns/Widget.appex/Widget",
                ],
                ["processIdentifier": 900, "executable": "file:///private/var/containers/Bundle/Application/A41A378E/WhatsApp.app/WhatsApp"],
            ]
        ])
        runner.answers["device process terminate"] = FakeDevicectl.success([:])
        let tools = tools()
        let output = try await call(tools, "stop_app", ["bundle_id": "dev.mobdev.fixture"])
        #expect(output.text == "Stopped dev.mobdev.fixture.")
        let terminated = runner.calls(to: "device process terminate").compactMap { arguments in
            arguments.firstIndex(of: "--pid").map { arguments[$0 + 1] }
        }
        #expect(terminated == ["812"])

        runner.answers["device info processes"] = FakeDevicectl.success(["runningProcesses": []])
        let again = try await call(tools, "stop_app", ["bundle_id": "dev.mobdev.fixture"])
        #expect(again.text == "dev.mobdev.fixture was not running.")
    }

    static let crashFiles: JSONValue = FakeDevicectl.success([
        "files": [
            [
                "name": "MobdevFixture-2026-09-29-225309.ips", "relativePath": "MobdevFixture-2026-09-29-225309.ips",
                "metadata": ["lastModDate": "2026-09-29T20:53:09.000Z", "size": 30210],
                "resources": ["isDirectory": false],
            ],
            [
                "name": "WhatsApp-2026-09-29-173246.ips", "relativePath": "WhatsApp-2026-09-29-173246.ips",
                "metadata": ["lastModDate": "2026-09-29T15:32:50.000Z", "size": 55751],
                "resources": ["isDirectory": false],
            ],
            [
                "name": "MobdevFixture.cpu_resource-2026-09-29-230000.ips",
                "relativePath": "MobdevFixture.cpu_resource-2026-09-29-230000.ips",
                "metadata": ["lastModDate": "2026-09-29T21:00:00.000Z", "size": 100],
                "resources": ["isDirectory": false],
            ],
            ["name": "Assistant", "relativePath": "Assistant", "resources": ["isDirectory": true]],
        ]
    ])

    static let crashReport = """
        {"app_name":"MobdevFixture","timestamp":"2026-09-29 22:53:09.00 +0200","app_version":"1.2","build_version":"7","bundleID":"dev.mobdev.fixture","bug_type":"309","os_version":"iPhone OS 27.0 (24A437)","name":"MobdevFixture"}
        {"procName":"MobdevFixture","exception":{"codes":"0x1, 0x100046270","type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"termination":{"code":5,"namespace":"SIGNAL","indicator":"Trace/BPT trap: 5"},"asi":{"libswiftCore.dylib":["Fatal error: Index out of range"]},"faultingThread":0,"threads":[{"triggered":true,"frames":[{"imageOffset":8816,"symbol":"closure #2 in FixtureApp.init()","symbolLocation":124,"imageIndex":0},{"imageOffset":114616,"imageIndex":1}]}],"usedImages":[{"name":"MobdevFixture","base":4295245824},{"name":"libdispatch.dylib","base":8158027776}]}
        """

    @Test func crashReportsListCrashesNewestFirstAndFilterByApp() async throws {
        runner.answers["device info files"] = Self.crashFiles
        runner.answers["device info apps"] = FakeDevicectl.success(["apps": [Self.fixtureApp]])
        let tools = tools()
        let all = try await call(tools, "crash_reports")
        #expect(all.data?.arrayValue?.map { $0["name"] } == [
            "MobdevFixture-2026-09-29-225309.ips", "WhatsApp-2026-09-29-173246.ips",
        ])
        let byBundle = try await call(tools, "crash_reports", ["app": "dev.mobdev.fixture"])
        #expect(byBundle.data?.arrayValue?.map { $0["process"] } == ["MobdevFixture"])
        let none = try await call(tools, "crash_reports", ["app": "Settings"])
        #expect(none.text == "No crash reports for Settings.")
    }

    @Test func readingACrashReportSummarizesAndKeepsTheFile() async throws {
        runner.answers["device info files"] = Self.crashFiles
        runner.answers["device copy from"] = FakeDevicectl.success([:])
        runner.files["MobdevFixture-2026-09-29-225309.ips"] = Self.crashReport
        let output = try await call(tools(), "crash_reports", ["name": "MobdevFixture-2026-09-29-225309.ips"])
        #expect(!output.isError)
        #expect(output.text.contains("MobdevFixture 1.2 (7), dev.mobdev.fixture"))
        #expect(output.text.contains("Exception: EXC_BREAKPOINT (SIGTRAP)"))
        #expect(output.text.contains("Fatal error: Index out of range"))
        #expect(output.text.contains("0  MobdevFixture  0x0000000100046270  closure #2 in FixtureApp.init() + 124"))
        #expect(
            output.text.contains(
                "1  libdispatch.dylib  0x00000001e6435fb8  (libdispatch.dylib + 114616, loaded at 0x1e641a000)"))
        let file = try #require(output.data?["file"]?.stringValue)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(file.hasPrefix(folder.path))

        let unknown = try await call(tools(), "crash_reports", ["name": "../../etc/passwd"])
        #expect(unknown.isError)
        #expect(runner.calls(to: "device copy from").count == 1)
    }

    @Test func systemReportsGetATitleAndTheirReason() throws {
        let text = """
            {"bug_type":"301","timestamp":"2026-09-30 02:43:39.00 +0200","os_version":"iPhone OS 27.0 (24A437)"}
            {"eventReason":"Memory pressure","largestProcess":"WhatsApp","processes":[]}
            """
        let report = try #require(CrashReport.parse(text))
        #expect(report.summary.hasPrefix("System report (bug type 301)\n2026-09-30 02:43:39.00 +0200, iPhone OS 27.0"))
        #expect(report.summary.contains("Memory pressure\nLargest process: WhatsApp"))
    }

    func simulatorTools(reports: URL? = nil) -> PhoneTools {
        let control = DeviceControl(
            udid: udid, runner: runner, devicectl: URL(fileURLWithPath: "/usr/bin/true"), reportsFolder: folder,
            simulator: true, localReports: reports ?? folder)
        return PhoneTools(phone: FakePhone(lines: [], apps: control), activity: ActivityLog(), settleDelay: 0)
    }

    @Test func simulatorsTakeSimulatorBuildsOnly() async throws {
        let tools = simulatorTools()
        let deviceBuild = try appBundle(platform: "iPhoneOS")
        let refused = try await call(tools, "install_app", ["path": .string(deviceBuild.path)])
        #expect(refused.text.contains("built for devices"))
        let ipa = try await call(tools, "install_app", ["path": "/tmp/App.ipa"])
        #expect(ipa.text.contains("built for the simulator"))
        runner.answers["device install app"] = FakeDevicectl.success([
            "installedApplications": [["bundleID": "dev.mobdev.fixture"]]
        ])
        let simulatorBuild = try appBundle(platform: "iPhoneSimulator")
        let installed = try await call(tools, "install_app", ["path": .string(simulatorBuild.path)])
        #expect(installed.text.hasPrefix("Installed"))
    }

    @Test func simulatorsStopAppsWithSimctl() async throws {
        runner.answers["device info apps"] = FakeDevicectl.success(["apps": [Self.fixtureApp]])
        runner.answers["simctl terminate \(udid) dev.mobdev.fixture"] = FakeDevicectl.success([:])
        let tools = simulatorTools()
        let stopped = try await call(tools, "stop_app", ["bundle_id": "dev.mobdev.fixture"])
        #expect(stopped.text == "Stopped dev.mobdev.fixture.")
        #expect(runner.calls(to: "device info processes").isEmpty)
    }

    @Test func simulatorCrashReportsComeFromTheMac() async throws {
        let reports = folder.appendingPathComponent("DiagnosticReports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let mine = Self.crashReport
            .replacingOccurrences(of: "\"bug_type\":\"309\"", with: "\"bug_type\":\"309\",\"platform\":7")
            .replacingOccurrences(of: "\"procName\":\"MobdevFixture\"", with: "\"procName\":\"MobdevFixture\",\"procPath\":\"/Devices/\(udid)/data/MobdevFixture\"")
        try Data(mine.utf8).write(to: reports.appendingPathComponent("MobdevFixture-2026-09-30-184951.ips"))
        let otherSimulator = mine.replacingOccurrences(of: udid, with: "AAAAAAAA-0000-0000-0000-000000000000")
        try Data(otherSimulator.utf8).write(to: reports.appendingPathComponent("MobdevFixture-2026-09-30-100000.ips"))
        let macApp = Self.crashReport.replacingOccurrences(of: "\"bug_type\":\"309\"", with: "\"bug_type\":\"309\",\"platform\":1")
        try Data(macApp.utf8).write(to: reports.appendingPathComponent("Safari-2026-09-30-100000.ips"))

        let tools = simulatorTools(reports: reports)
        let list = try await call(tools, "crash_reports")
        #expect(list.data?.arrayValue?.map { $0["name"] } == ["MobdevFixture-2026-09-30-184951.ips"])
        let report = try await call(tools, "crash_reports", ["name": "MobdevFixture-2026-09-30-184951.ips"])
        #expect(report.text.contains("Exception: EXC_BREAKPOINT (SIGTRAP)"))
        #expect(runner.calls.get().isEmpty)
    }

    @Test func crashFileNamesGiveTheProcess() {
        #expect(CrashReportFile.process(fromName: "WhatsApp-2026-09-29-173246.ips") == "WhatsApp")
        #expect(CrashReportFile.process(fromName: "Raycast Keyboard-2026-09-29-173246.ips") == "Raycast Keyboard")
        #expect(
            CrashReportFile.process(fromName: "ProxiedDevice-1a2b/WatchApp-2026-09-29-173246.ips") == "WatchApp")
        #expect(CrashReportFile.process(fromName: "UIKit-runloop-MyApp-2026-09-29-173246.ips") == "UIKit-runloop-MyApp")
        #expect(CrashReportFile.process(fromName: "Spotify.diskwrites_resource-2026-09-28-003322.ips") == nil)
        #expect(CrashReportFile.process(fromName: "notes.plist") == nil)
    }

    @Test func toolsExplainWhenADeviceHasNoDeveloperAccess() async throws {
        let tools = PhoneTools(phone: FakePhone(lines: []), activity: ActivityLog(), settleDelay: 0)
        let output = try await tools.call("list_apps", arguments: nil, source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("Reconnect the cable"))
    }

    @Test func everyDeviceToolListsTheDeveloperTools() {
        let names = Set(DeviceTools.definitions.map(\.name))
        for tool in ["list_apps", "install_app", "uninstall_app", "launch_app", "stop_app", "open_url", "logs", "crash_reports"] {
            #expect(names.contains(tool))
        }
    }
}
