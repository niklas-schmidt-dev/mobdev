import Foundation
import Testing
@testable import MobdevCore

/// Answers like Xcode's tools for an iPhone: devicectl writes its JSON to --json-output, `xctrace
/// record` saves a trace (or fails as told), `xctrace export` writes the table the xpath asks for
/// to --output. Records every call.
final class InstrumentsRunner: CommandRunning, @unchecked Sendable {
    let calls = Locked<[[String]]>([])
    /// devicectl results by command, e.g. "device info apps".
    var devicectl: [String: JSONValue] = [:]
    /// Export XML by schema, and "toc" for the table of contents.
    var exports: [String: String] = [:]
    var templates = ["Activity Monitor", "Allocations", "App Launch", "Leaks", "Time Profiler"]
    var recordFailure: String?
    /// Printed instead of recording, as it is, by this many recordings.
    var missingProcess: (output: String, times: Int)?

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        calls.withLock { $0.append(arguments) }
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        if let json = value(after: "--json-output") {
            let command = arguments.prefix(3).joined(separator: " ")
            let reply: JSONValue = ["info": ["outcome": "success"], "result": devicectl[command] ?? [:]]
            try Data(reply.compactString.utf8).write(to: URL(fileURLWithPath: json))
            return CommandResult(status: 0, output: "")
        }
        switch Array(arguments.prefix(2)) {
        case ["xctrace", "list"]:
            return CommandResult(status: 0, output: "== Standard Templates ==\n" + templates.joined(separator: "\n") + "\n")
        case ["xctrace", "record"]:
            guard let output = value(after: "--output") else { return CommandResult(status: 1, output: "no output") }
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            if let missing = missingProcess, missing.times > 0 {
                missingProcess = (missing.output, missing.times - 1)
                return CommandResult(status: 1, output: missing.output)
            }
            if let recordFailure {
                return CommandResult(status: 1, output: "Run issues were detected (trace is still ready to be viewed):\n* [Error] \(recordFailure)\n\nRecording failed with errors. Saving output file...")
            }
            return CommandResult(status: 0, output: "Recording completed. Saving output file...")
        case ["xctrace", "export"]:
            guard let output = value(after: "--output") else { return CommandResult(status: 1, output: "no output") }
            let key = arguments.contains("--toc")
                ? "toc" : value(after: "--xpath")?.components(separatedBy: "@schema=\"").last?.components(separatedBy: "\"").first ?? ""
            guard let xml = exports[key] else { return CommandResult(status: 1, output: "Error: no such table") }
            try Data(xml.utf8).write(to: URL(fileURLWithPath: output))
            return CommandResult(status: 0, output: "Finished export to the file: \(output)")
        default:
            return CommandResult(status: 0, output: "")
        }
    }

    func start(
        _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningCommand { ScriptedRunner.Stopper() }

    func runBinary(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, data: Data) {
        (0, Data())
    }

    var records: [[String]] { calls.get().filter { $0.starts(with: ["xctrace", "record"]) } }

    /// A table of contents naming these tables, for a device with 6 GB.
    static func toc(_ schemas: [String], template: String) -> String {
        """
        <?xml version="1.0"?>
        <trace-toc><run number="1"><info><target>
        <device platform="iOS" model="iPhone" memory-size="6442450944" name="Test iPhone" os-version="27.0.1" uuid="PHONE-1"/>
        </target><summary><duration>5.2</duration><template-name>\(template)</template-name></summary></info>
        <processes/><data>\(schemas.map { "<table schema=\"\($0)\"/>" }.joined())</data></run></trace-toc>
        """
    }
}

@Suite struct InstrumentsTests {
    static let app: JSONValue = [
        "bundleIdentifier": "com.example.Busy", "name": "Busy", "builtByDeveloper": true,
        "url": "file:///private/var/containers/Bundle/Application/ABC/Busy.app/",
    ]

    /// An iPhone with Busy installed and running as pid 40731, the pid of the fixtures.
    func iPhone(_ runner: InstrumentsRunner) -> DeviceControl {
        runner.devicectl["device info apps"] = ["apps": [Self.app]]
        runner.devicectl["device info processes"] = [
            "runningProcesses": [
                ["executable": "file:///private/var/containers/Bundle/Application/ABC/Busy.app/PlugIns/Widget.appex/Widget", "processIdentifier": 40800],
                ["executable": "file:///private/var/containers/Bundle/Application/ABC/Busy.app/Busy", "processIdentifier": 40731],
            ]
        ]
        return DeviceControl(
            udid: "PHONE-1", runner: runner, devicectl: URL(fileURLWithPath: "/usr/bin/true"),
            reportsFolder: FileManager.default.temporaryDirectory)
    }

    @Test func exportTablesResolveReferencesAndKeepEmptyCellsEmpty() throws {
        let table = try #require(XctraceTable.parse(Data(XctraceFixtures.attachedProcess.utf8)).first)
        #expect(table.schema == "activity-monitor-process-live")
        #expect(table.columns.prefix(8) == ["start", "process", "responsible-process", "duration", "pid", "uid", "cpu-percent", "cpu-total"])
        #expect(table.rows.count == 3)
        let first = table.rows[0], last = table.rows[2]
        #expect(table.value(first, "cpu-percent") == nil)
        #expect(table.value(last, "cpu-percent")?.fmt == "93.9%")
        // The later rows name the process and its footprint only by reference.
        #expect(table.value(last, "process")?.fmt == "yes (40731)")
        #expect(table.value(last, "process")?.child("pid")?.number == 40731)
        #expect(table.value(last, "memory-physical-footprint")?.number == 1_163_504)
        #expect(table.value(last, "uid")?.fmt == "mobile")
        #expect(XctraceTable.parse(Data("not xml".utf8)).isEmpty)
    }

    @Test func activityMonitorRowsBecomeASampleOfOneProcess() throws {
        let table = try #require(XctraceTable.parse(Data(XctraceFixtures.attachedProcess.utf8)).first)
        let sample = try #require(ActivityMonitor.sample(ActivityMonitor.processRows(table), pid: 40731))
        #expect(sample.points.count == 3)
        #expect(sample.points.map(\.time) == [0, 1.487355791, 2.965329833])
        #expect(sample.points.map(\.cpu) == [nil, 98.739436265, 93.876559213])
        // CPU time 3.073 s → 6.013 s over 2.965 s.
        #expect(abs(sample.averageCPU - (6.013172999 - 3.072740291) / 2.965329833 * 100) < 0.0001)
        #expect(abs(sample.peakCPU - 98.739436265) < 0.0001)
        #expect(abs(sample.peakMemoryMB - 1_163_504 / 1_048_576) < 0.0001)
        #expect(sample.memoryKind == "physical footprint")
        #expect(ActivityMonitor.sample(ActivityMonitor.processRows(table), pid: 1) == nil)
        #expect(ActivityMonitor.processName("Settings (66546)") == "Settings")
        #expect(ActivityMonitor.processName("kernel_task") == "kernel_task")
    }

    @Test func activityMonitorOfAllProcessesGivesTheDevicesLoad() throws {
        let processes = XctraceTable.parse(Data(XctraceFixtures.allProcesses.utf8)).first
        let system = XctraceTable.parse(Data(XctraceFixtures.system.utf8)).first
        let thermal = XctraceTable.parse(Data(XctraceFixtures.thermal.utf8)).first
        let load = ActivityMonitor.deviceLoad(
            processes: processes, system: system, thermal: thermal, memoryBytes: 38_654_705_664, seconds: 5.8)
        #expect(load.processes.count == 7)
        #expect(load.top(byCPU: 2).map(\.name) == ["kernel", "WindowServer"])
        #expect(abs(load.top(byCPU: 1)[0].cpuPercent - 229.154304945) < 0.0001)
        #expect(load.top(byMemory: 2).map(\.name) == ["kernel", "WindowServer"])
        #expect(load.thermalState == "Nominal")
        #expect(abs((load.memoryUsedMB ?? 0) - 34_555_854_848 / 1_048_576) < 0.001)
        #expect(load.memoryTotalMB == 36_864)
        #expect(load.cpuPercent == 1400)
        let text = PhoneTools.describe(load, count: 2)
        #expect(text.contains("Thermal state: Nominal"))
        #expect(text.contains("kernel (pid 0): 229.2% CPU, 2725.2 MB"))
    }

    @Test func timeProfilesNameTheHeaviestFunctionsOfTheProcess() throws {
        let table = try #require(XctraceTable.parse(Data(XctraceFixtures.timeProfile.utf8)).first)
        let lines = TraceSummary.heaviest(table, pid: 29397)
        #expect(lines.first == "Heaviest functions (self time, 3 ms of samples):")
        #expect(lines.dropFirst().first == "  66.7% __open_nocancel (libsystem_kernel.dylib)")
        #expect(lines.dropFirst(2).first == "  33.3% __open (libsystem_kernel.dylib)")
        #expect(TraceSummary.heaviest(table, pid: nil).first == "Heaviest functions (self time, 4 ms of samples):")
        #expect(TraceSummary.heaviest(table, pid: 1).isEmpty)
    }

    @Test func templatesComeFromXctracesListWhateverTheirCase() async throws {
        let runner = InstrumentsRunner()
        let xctrace = Xctrace(runner: runner)
        #expect(try await xctrace.template(named: "time profiler") == "Time Profiler")
        await #expect(throws: DeveloperError.self) { try await xctrace.template(named: "Stopwatch") }
        #expect(Xctrace.templates(fromList: "== Standard Templates ==\nLeaks\n\n== Custom Templates ==\nMine\n") == ["Leaks", "Mine"])
    }

    @Test func anIPhoneAppIsSampledWithActivityMonitorAttachedToItsPid() async throws {
        let runner = InstrumentsRunner()
        runner.exports["activity-monitor-process-live"] = XctraceFixtures.attachedProcess
        let control = iPhone(runner)
        let sample = try await control.sample("com.example.Busy", seconds: 3)
        #expect(sample.pid == 40731)
        #expect(sample.points.count == 3)
        #expect(sample.ended == nil)
        let record = try #require(runner.records.first)
        #expect(record.starts(with: ["xctrace", "record", "--no-prompt", "--template", "Activity Monitor", "--device", "PHONE-1", "--time-limit", "3s"]))
        #expect(record.suffix(2) == ["--attach", "40731"])
        // The trace was only a means: it is gone again.
        let output = try #require(record.firstIndex(of: "--output").map { record[$0 + 1] })
        #expect(!FileManager.default.fileExists(atPath: output))
        #expect(!control.timesLaunches)
    }

    @Test func aFailedRecordingSaysWhatInstrumentsReported() async throws {
        let runner = InstrumentsRunner()
        runner.recordFailure = "Activity monitoring service not available on this device."
        let control = iPhone(runner)
        do {
            _ = try await control.sample("com.example.Busy", seconds: 2)
            Issue.record("Expected a failure")
        } catch {
            #expect(String(describing: error) == "xctrace could not record Activity Monitor: Activity monitoring service not available on this device.")
        }
        let output = try #require(runner.records.first.flatMap { record in record.firstIndex(of: "--output").map { record[$0 + 1] } })
        #expect(!FileManager.default.fileExists(atPath: output))
    }

    @Test func aProcessXctraceDidNotFindIsTriedAgain() async throws {
        let runner = InstrumentsRunner()
        runner.exports["activity-monitor-process-live"] = XctraceFixtures.attachedProcess
        runner.missingProcess = ("Cannot find process for provided pid: 40731", 1)
        let sample = try await iPhone(runner).sample("com.example.Busy", seconds: 3)
        #expect(sample.points.count == 3)
        #expect(runner.records.map { $0.suffix(2) } == [["--attach", "40731"], ["--attach", "40731"]])
    }

    @Test func anIPhonesLoadComesFromActivityMonitorOfEveryProcess() async throws {
        let runner = InstrumentsRunner()
        runner.exports = [
            "toc": InstrumentsRunner.toc(
                ["activity-monitor-process-live", "activity-monitor-system", "device-thermal-state-intervals"],
                template: "Activity Monitor"),
            "activity-monitor-process-live": XctraceFixtures.allProcesses, "activity-monitor-system": XctraceFixtures.system,
            "device-thermal-state-intervals": XctraceFixtures.thermal,
        ]
        let load = try await iPhone(runner).deviceLoad()
        #expect(runner.records.first?.contains("--all-processes") == true)
        #expect(load.memoryTotalMB == 6144)
        #expect(load.thermalState == "Nominal")
        #expect(load.seconds == 5.2)
        #expect(load.top(byCPU: 1).first?.name == "kernel")
    }

    @Test func tracesAttachLaunchOrRecordEverythingAndSummarizeCheaply() async throws {
        let runner = InstrumentsRunner()
        runner.exports = [
            "toc": InstrumentsRunner.toc(["time-profile", "potential-hangs"], template: "Time Profiler"),
            "time-profile": XctraceFixtures.timeProfile.replacingOccurrences(of: "29397", with: "40731"),
            "potential-hangs": """
                <?xml version="1.0"?>
                <trace-query-result><node><schema name="potential-hangs"><col><mnemonic>start</mnemonic></col></schema>
                <row><start-time>1</start-time></row></node></trace-query-result>
                """,
        ]
        let control = iPhone(runner)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-traces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("busy.trace")
        let attached = try await control.recordTrace(
            TraceRequest(template: "time profiler", target: .attach(bundleID: "com.example.Busy"), seconds: 4, output: output))
        #expect(attached.template == "Time Profiler")
        #expect(attached.target == "com.example.Busy (pid 40731)")
        #expect(attached.seconds == 5.2)
        #expect(attached.summary.first == "Heaviest functions (self time, 3 ms of samples):")
        #expect(attached.summary.last == "1 potential hang")
        #expect(runner.records.last?.suffix(2) == ["--attach", "40731"])

        _ = try await control.recordTrace(
            TraceRequest(template: "App Launch", target: .launch(bundleID: "com.example.Busy"), seconds: 5, output: output))
        #expect(runner.records.last?.suffix(3) == ["--launch", "--", "com.example.Busy"])
        _ = try await control.recordTrace(TraceRequest(template: "Leaks", target: .allProcesses, seconds: 5, output: output))
        #expect(runner.records.last?.last == "--all-processes")
        await #expect(throws: DeveloperError.self) {
            try await control.recordTrace(TraceRequest(template: "Stopwatch", target: .allProcesses, seconds: 5, output: output))
        }
    }

    @Test func simulatorsHaveNoActivityMonitorToRecord() async throws {
        let control = DeviceControl(
            udid: "SIM-1", runner: InstrumentsRunner(), reportsFolder: FileManager.default.temporaryDirectory, simulator: true,
            simctl: true)
        do {
            _ = try await control.recordTrace(
                TraceRequest(template: "Activity Monitor", target: .allProcesses, seconds: 2, output: URL(fileURLWithPath: "/tmp/x.trace")))
            Issue.record("Expected a failure")
        } catch {
            #expect(String(describing: error).contains("Use performance or device_load"))
        }
        #expect(control.timesLaunches)
    }

    @Test func launchctlListsGiveEveryRunningPid() {
        let list = "PID\tStatus\tLabel\n-\t0\tcom.apple.idle\n41077\t0\tUIKitApplication:com.apple.Preferences[e5a5]\n123\t0\tcom.apple.backboardd\n"
        #expect(DeviceControl.pids(inLaunchctlList: list) == [41077, 123])
    }
}

/// Android: the device's load from top, /proc/meminfo and the thermal service, and Perfetto.
@Suite struct AndroidLoadTests {
    /// What the load script prints, written from toybox top's batch output and the formats of
    /// /proc/meminfo and `dumpsys thermalservice` on Android 14 to 16, not recorded from a device.
    static let output = """
        TOP
        Tasks: 512 total,   1 running, 511 sleeping,   0 stopped,   0 zombie
          Mem:  3912316K total,  3618236K used,   294080K free,     4520K buffers
         Swap:  2934232K total,   302848K used,  2631384K free,  1638224K cached
        400%cpu  60%user   0%nice  40%sys 300%idle   0%iow   0%irq   0%sirq   0%host
          PID [%CPU]   RES NAME
         1234  90.0  210M system_server
        Tasks: 512 total,   1 running, 511 sleeping,   0 stopped,   0 zombie
          Mem:  3912316K total,  3618236K used,   294080K free,     4520K buffers
         Swap:  2934232K total,   302848K used,  2631384K free,  1638224K cached
        400%cpu  48%user   0%nice  22%sys 330%idle   0%iow   0%irq   0%sirq   0%host
          PID [%CPU]   RES NAME
         4242  35.0  1.1G com.example.app
         1234  20.0  210M system_server
          612   9.5  2048 surfaceflinger
          890   0.0  512K kworker/u8:2 events
        MEMINFO
        MemTotal:        3912316 kB
        MemFree:          294080 kB
        MemAvailable:    1956158 kB
        THERMAL
        IsStatusOverride: false
        ThermalEventListeners:
        \tcallbacks: 1
        Thermal Status: 1
        Cached temperatures:
        \tTemperature{mValue=44.0, mType=0, mName=cpu0, mStatus=0}
        HAL Ready: true
        Current temperatures from HAL:
        \tTemperature{mValue=41.5, mType=0, mName=CPU, mStatus=0}
        \tTemperature{mValue=33.0, mType=3, mName=SKIN, mStatus=0}
        Current cooling devices from HAL:
        \tCoolingDevice{mValue=0, mType=2, mName=cpu}
        """

    @Test func topMeminfoAndTheThermalServiceGiveTheLoad() {
        let load = AndroidApps.parseLoad(Self.output)
        // The second frame: its percentages cover the second between them.
        #expect(load.processes.map(\.pid) == [4242, 1234, 612, 890])
        #expect(load.top(byCPU: 1).first?.name == "com.example.app")
        #expect(load.processes.last?.name == "kworker/u8:2 events")
        #expect(load.top(byMemory: 1).first?.memoryMB == 1.1 * 1024)
        #expect(load.processes.first { $0.pid == 612 }?.memoryMB == 2)
        #expect(load.cpuPercent == 70)
        #expect(load.cores == 4)
        #expect(abs((load.memoryTotalMB ?? 0) - 3_912_316 / 1024) < 0.001)
        #expect(abs((load.memoryUsedMB ?? 0) - (3_912_316 - 1_956_158) / 1024) < 0.001)
        #expect(load.thermalState == "light (1)")
        #expect(load.temperatures == ["CPU 41.5 °C", "SKIN 33.0 °C"])
        #expect(load.memoryKind == "resident (RSS)")
    }

    @Test func perfettoRecordsTheAppsSectionsAndIsPulledToTheMac() async throws {
        let calls = Locked<[[String]]>([])
        let runner = HandlerRunner { arguments in
            calls.withLock { $0.append(arguments) }
            if arguments.dropFirst(2).first == "pull" {
                try Data(repeating: 1, count: 2048).write(to: URL(fileURLWithPath: arguments[4]))
            }
            return CommandResult(status: 0, output: "")
        }
        let apps = AndroidApps(serial: "emulator-5554", adb: ADB(executable: URL(fileURLWithPath: "/bin/adb"), runner: runner), reportsFolder: FileManager.default.temporaryDirectory)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-perfetto-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("trace.perfetto-trace")
        let recording = try await apps.recordTrace(
            TraceRequest(template: "Perfetto", target: .attach(bundleID: "com.example.app"), seconds: 7.5, output: output))
        let shell = try #require(calls.get().first { $0.contains("shell") }?.last)
        #expect(shell.hasPrefix("perfetto -o /data/misc/perfetto-traces/mobdev-"))
        #expect(shell.hasSuffix(".perfetto-trace -t 8s -b 64mb -a com.example.app sched freq idle am wm gfx view binder_driver hal dalvik input res"))
        let remote = shell.split(separator: " ")[2]
        #expect(calls.get().contains(["-s", "emulator-5554", "pull", String(remote), output.path]))
        #expect(calls.get().last == ["-s", "emulator-5554", "shell", "rm -f \(remote)"])
        #expect(recording.target == "com.example.app")
        #expect(recording.howToOpen.contains("ui.perfetto.dev"))
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(AndroidApps.perfettoCommand(remote: "/r", seconds: 3, package: nil, background: true)
            == "perfetto --background -o /r -t 3s -b 64mb sched freq idle am wm gfx view binder_driver hal dalvik input res")
    }
}

/// record_trace and device_load as agents call them, on a fake device.
@Suite struct ProfilingToolTests {
    func call(_ tools: PhoneTools, _ name: String, _ arguments: JSONValue) async throws -> ToolOutput {
        try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
    }

    @Test func tracesGoIntoTheProjectsOutputUnlessAPathIsGiven() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-trace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try TestProject.create(at: folder.appendingPathComponent("mobdev"), name: "App", bundleID: "dev.mobdev.fixture")
        let projectFolder = ProjectList.normalized(project.folder)
        let notified = Locked<[ProjectOutput?]>([])
        let list = ProjectList(known: [projectFolder], active: projectFolder)
        list.onOutput { _, kind in notified.withLock { $0.append(kind) } }
        let performance = FakePerformance()
        let tools = PhoneTools(phone: DevLoopPhone(performance: performance), activity: ActivityLog(), settleDelay: 0, projects: list)

        let output = try await call(tools, "record_trace", ["bundle_id": "com.example.app", "seconds": 4])
        #expect(!output.isError, "\(output.text)")
        let request = try #require(performance.traces.get().first)
        #expect(request.template == "Time Profiler")
        #expect(request.target == .attach(bundleID: "com.example.app"))
        #expect(request.seconds == 4)
        #expect(request.output.deletingLastPathComponent().path == projectFolder.appendingPathComponent("output/traces").path)
        #expect(request.output.lastPathComponent.hasPrefix("time-profiler-"))
        #expect(request.output.pathExtension == "trace")
        #expect(output.text.contains("1 potential hang"))
        #expect(output.data?["path"]?.stringValue == request.output.path)
        #expect(notified.get() == [.traces])

        let path = folder.appendingPathComponent("launch.trace")
        let launch = try await call(tools, "record_trace", ["template": "App Launch", "bundle_id": "com.example.app", "path": .string(path.path)])
        #expect(!launch.isError, "\(launch.text)")
        #expect(performance.traces.get().last?.target == .launch(bundleID: "com.example.app"))
        #expect(performance.traces.get().last?.output == path)

        let everything = try await call(tools, "record_trace", ["template": "Leaks"])
        #expect(!everything.isError)
        #expect(performance.traces.get().last?.target == .allProcesses)

        #expect(try await call(tools, "record_trace", ["template": "App Launch"]).text.contains("pass bundle_id"))
        #expect(try await call(tools, "record_trace", ["launch": true]).text.contains("launch needs bundle_id"))
        #expect(try await call(tools, "record_trace", ["seconds": 61]).isError)
        #expect(try await call(tools, "record_trace", ["path": "relative.trace"]).text.contains("absolute"))
        #expect(try await call(tools, "record_trace", ["path": .string(folder.appendingPathComponent("x.mp4").path)]).text.contains(".trace"))
        #expect(performance.traces.get().count == 3)
    }

    @Test func androidRecordsPerfettoTraces() async throws {
        let performance = FakePerformance()
        let phone = DevLoopPhone(performance: performance, timedApps: TimedApps(platform: .android))
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0, projects: ProjectList())
        let output = try await call(tools, "record_trace", ["template": "Time Profiler", "seconds": 2])
        #expect(!output.isError, "\(output.text)")
        let request = try #require(performance.traces.get().first)
        #expect(request.template == "Perfetto")
        #expect(request.output.pathExtension == "perfetto-trace")
        try? FileManager.default.removeItem(at: request.output)
    }

    @Test func deviceLoadListsTheBusiestAndLargestProcesses() async throws {
        let performance = FakePerformance()
        performance.load = DeviceLoad(
            processes: [
                .init(name: "SpringBoard", pid: 40, cpuPercent: 12, memoryMB: 180),
                .init(name: "MyApp", pid: 900, cpuPercent: 85.5, memoryMB: 420),
                .init(name: "backboardd", pid: 41, cpuPercent: 3, memoryMB: 30),
            ], cpuPercent: 120, cores: 6, memoryUsedMB: 4000, memoryTotalMB: 8000, thermalState: "Fair",
            memoryKind: "physical footprint", seconds: 3, source: "a fake")
        let tools = PhoneTools(phone: DevLoopPhone(performance: performance), activity: ActivityLog(), settleDelay: 0)
        let output = try await call(tools, "device_load", ["count": 2])
        #expect(!output.isError)
        #expect(output.text.contains("CPU: 120.0% of one core (6 cores, 20.0% of all)"))
        #expect(output.text.contains("Memory: 4000.0 MB used of 8000.0 MB (50.0%)"))
        #expect(output.text.contains("Thermal state: Fair"))
        #expect(output.text.contains("Busiest by CPU:\n  MyApp (pid 900): 85.5% CPU, 420.0 MB\n  SpringBoard (pid 40): 12.0% CPU, 180.0 MB\n"))
        #expect(output.data?["top_memory"]?.arrayValue?.count == 2)
        #expect(output.data?["thermal_state"] == "Fair")
        let none = try await call(
            PhoneTools(phone: DevLoopPhone(performance: nil, input: .bluetooth), activity: ActivityLog(), settleDelay: 0), "device_load", [:])
        #expect(none.isError)
        #expect(none.text.contains("connect it with a cable"))
    }

    @Test func iPhonesTimeTheScreenUnlessToldOtherwise() async throws {
        let performance = FakePerformance()
        performance.timesLaunches = false
        let tools = PhoneTools(phone: DevLoopPhone(performance: performance), activity: ActivityLog(), settleDelay: 0)
        let system = try await call(tools, "measure_launch", ["bundle_id": "com.example.app", "method": "system"])
        #expect(system.isError)
        #expect(system.text.contains("template App Launch"))
        // Without a method it times the screen, which this fake device cannot launch apps for.
        let screen = try await call(tools, "measure_launch", ["bundle_id": "com.example.app"])
        #expect(screen.text.contains("Launching apps is not available"))
        #expect(performance.calls.get().isEmpty)
    }
}

/// Answers every command with a closure, for commands with side effects such as `adb pull`.
struct HandlerRunner: CommandRunning {
    let handler: @Sendable ([String]) throws -> CommandResult

    init(_ handler: @escaping @Sendable ([String]) throws -> CommandResult) { self.handler = handler }

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try handler(arguments)
    }

    func start(
        _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningCommand { ScriptedRunner.Stopper() }

    func runBinary(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, data: Data) {
        (0, Data())
    }
}

/// Exports of real recordings with `xctrace export --xpath`, Xcode 27 (2026-10-28), cut down to a few
/// rows and the columns Mobdev reads. Activity Monitor was recorded on this Mac, whose tables are
/// the ones an iPhone records (simulators have no activity monitoring service); Time Profiler on an
/// iOS 27 simulator. The attached recording keeps Instruments' `id`/`ref` sharing as exported.
enum XctraceFixtures {
    /// Activity Monitor attached to one busy process (pid 40731), every column.
    static let attachedProcess = #"""
        <?xml version="1.0"?>
        <trace-query-result>
        <node xpath='//trace-toc[1]/run[1]/data[1]/table[9]'><schema name="activity-monitor-process-live" documentation="Tracks the most accurate totals of process activity at a given interval in time."><col><mnemonic>start</mnemonic><name>Start Time</name><engineering-type>start-time</engineering-type></col><col><mnemonic>process</mnemonic><name>Process Name</name><engineering-type>process</engineering-type></col><col><mnemonic>responsible-process</mnemonic><name>Responsible Process</name><engineering-type>process</engineering-type></col><col><mnemonic>duration</mnemonic><name>Duration</name><engineering-type>duration</engineering-type></col><col><mnemonic>pid</mnemonic><name>Process ID</name><engineering-type>pid</engineering-type></col><col><mnemonic>uid</mnemonic><name>User Name</name><engineering-type>process-uid</engineering-type></col><col><mnemonic>cpu-percent</mnemonic><name>% CPU</name><engineering-type>system-cpu-percent</engineering-type></col><col><mnemonic>cpu-total</mnemonic><name>CPU Time</name><engineering-type>duration-on-core</engineering-type></col><col><mnemonic>thread-count</mnemonic><name># Threads</name><engineering-type>event-count</engineering-type></col><col><mnemonic>mach-port-count</mnemonic><name># Ports</name><engineering-type>event-count</engineering-type></col><col><mnemonic>memory-physical-footprint</mnemonic><name>Memory</name><engineering-type>size-in-bytes</engineering-type></col><col><mnemonic>memory-real</mnemonic><name>Real Mem</name><engineering-type>size-in-bytes</engineering-type></col><col><mnemonic>memory-real-private</mnemonic><name>Real Private Mem</name><engineering-type>size-in-bytes</engineering-type></col><col><mnemonic>memory-real-shared</mnemonic><name>Real Shared Mem</name><engineering-type>size-in-bytes</engineering-type></col><col><mnemonic>arch-kind</mnemonic><name>Kind</name><engineering-type>cpu-arch-name</engineering-type></col><col><mnemonic>sudden-termination</mnemonic><name>Sudden Termination</name><engineering-type>boolean</engineering-type></col><col><mnemonic>sandbox</mnemonic><name>Sandbox</name><engineering-type>boolean</engineering-type></col><col><mnemonic>restricted</mnemonic><name>Restricted</name><engineering-type>boolean</engineering-type></col><col><mnemonic>idle-wakeups</mnemonic><name>Idle Wake Ups</name><engineering-type>event-count</engineering-type></col><col><mnemonic>app-nap</mnemonic><name>App Nap</name><engineering-type>boolean</engineering-type></col><col><mnemonic>memory-purgeable</mnemonic><name>Purgeable Mem</name><engineering-type>size-in-bytes</engineering-type></col><col><mnemonic>memory-compressed</mnemonic><name>Compressed Mem</name><engineering-type>size-in-bytes</engineering-type></col><col><mnemonic>disk-bytes-written</mnemonic><name>Disk Writes</name><engineering-type>disk-size-in-bytes</engineering-type></col><col><mnemonic>disk-bytes-read</mnemonic><name>Disk Reads</name><engineering-type>disk-size-in-bytes</engineering-type></col><col><mnemonic>disk-bytes-written-per-second</mnemonic><name>Data Written/sec</name><engineering-type>size-in-bytes-per-second</engineering-type></col><col><mnemonic>disk-bytes-read-per-second</mnemonic><name>Data Read/sec</name><engineering-type>size-in-bytes-per-second</engineering-type></col><col><mnemonic>preventing-sleep</mnemonic><name>Preventing Sleep</name><engineering-type>boolean</engineering-type></col></schema><row><start-time id="1" fmt="00:00.000.000">0</start-time><process id="2" fmt="yes (40731)"><pid id="3" fmt="40731">40731</pid><device-session id="4" fmt="TODO">TODO</device-session></process><process id="5" fmt="T3 Code (Nightly) (84233)"><pid id="6" fmt="84233">84233</pid><device-session ref="4"/></process><duration id="7" fmt="1.49 s">1487355791</duration><pid ref="3"/><process-uid id="8" fmt="mobile">501</process-uid><sentinel/><duration-on-core id="9" fmt="3.07 s">3072740291</duration-on-core><event-count id="10" fmt="1">1</event-count><event-count id="11" fmt="11">11</event-count><size-in-bytes id="12" fmt="1,11 MiB">1163504</size-in-bytes><size-in-bytes id="13" fmt="1,11 MiB">1163264</size-in-bytes><size-in-bytes id="14" fmt="688,00 KiB">704512</size-in-bytes><size-in-bytes id="15" fmt="752,00 KiB">770048</size-in-bytes><cpu-arch-name id="16" fmt="arm64">arm64</cpu-arch-name><boolean id="17" fmt="No">0</boolean><boolean ref="17"/><boolean id="18" fmt="Yes">1</boolean><event-count id="19" fmt="0">0</event-count><boolean ref="17"/><size-in-bytes id="20" fmt="0 Bytes">0</size-in-bytes><size-in-bytes ref="20"/><disk-size-in-bytes id="21" fmt="0 Bytes">0</disk-size-in-bytes><disk-size-in-bytes id="22" fmt="96,00 KiB">98304</disk-size-in-bytes><size-in-bytes-per-second id="23" fmt="0 Bytes">0</size-in-bytes-per-second><size-in-bytes-per-second ref="23"/><boolean ref="17"/></row>
        <row><start-time id="24" fmt="00:01.487.355">1487355791</start-time><process ref="2"/><process ref="5"/><duration id="25" fmt="1.48 s">1477974042</duration><pid ref="3"/><process-uid ref="8"/><system-cpu-percent id="26" fmt="98.7%">98.739436265</system-cpu-percent><duration-on-core id="27" fmt="4.52 s">4523981916</duration-on-core><event-count ref="10"/><event-count ref="11"/><size-in-bytes ref="12"/><size-in-bytes ref="13"/><size-in-bytes ref="14"/><size-in-bytes id="28" fmt="720,00 KiB">737280</size-in-bytes><cpu-arch-name ref="16"/><boolean ref="17"/><boolean ref="17"/><boolean ref="18"/><event-count ref="19"/><boolean ref="17"/><size-in-bytes ref="20"/><size-in-bytes ref="20"/><disk-size-in-bytes ref="21"/><disk-size-in-bytes ref="22"/><size-in-bytes-per-second ref="23"/><size-in-bytes-per-second ref="23"/><boolean ref="17"/></row>
        <row><start-time id="29" fmt="00:02.965.329">2965329833</start-time><process ref="2"/><process ref="5"/><duration id="30" fmt="3.05 s">3047223143</duration><pid ref="3"/><process-uid ref="8"/><system-cpu-percent id="31" fmt="93.9%">93.876559213</system-cpu-percent><duration-on-core id="32" fmt="6.01 s">6013172999</duration-on-core><event-count ref="10"/><event-count ref="11"/><size-in-bytes ref="12"/><size-in-bytes ref="13"/><size-in-bytes ref="14"/><size-in-bytes ref="28"/><cpu-arch-name ref="16"/><boolean ref="17"/><boolean ref="17"/><boolean ref="18"/><event-count ref="19"/><boolean ref="17"/><size-in-bytes ref="20"/><size-in-bytes ref="20"/><disk-size-in-bytes ref="21"/><disk-size-in-bytes ref="22"/><size-in-bytes-per-second ref="23"/><size-in-bytes-per-second ref="23"/><boolean ref="17"/></row>
        </node></trace-query-result>
        """#

    /// Activity Monitor of all processes: two readings of seven of them.
    static let allProcesses = #"""
        <?xml version="1.0"?>
        <trace-query-result><node xpath="//trace-toc[1]/run[1]/data[1]/table[9]"><schema name="activity-monitor-process-live"><col><mnemonic>start</mnemonic></col><col><mnemonic>process</mnemonic></col><col><mnemonic>pid</mnemonic></col><col><mnemonic>cpu-percent</mnemonic></col><col><mnemonic>cpu-total</mnemonic></col><col><mnemonic>memory-physical-footprint</mnemonic></col></schema><row><start-time fmt="00:00.000.000">0</start-time><process fmt="kernel (0)"><pid fmt="0">0</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="0">0</pid><sentinel /><duration-on-core fmt="15981.91 min">958914613074291</duration-on-core><size-in-bytes fmt="2,66 GiB">2857549824</size-in-bytes></row><row><start-time fmt="00:00.000.000">0</start-time><process fmt="SpringBoard (73688)"><pid fmt="73688">73688</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="73688">73688</pid><sentinel /><duration-on-core fmt="4.20 min">252161510707</duration-on-core><size-in-bytes fmt="96,22 MiB">100895504</size-in-bytes></row><row><start-time fmt="00:00.000.000">0</start-time><process fmt="mds_stores (19784)"><pid fmt="19784">19784</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="19784">19784</pid><sentinel /><duration-on-core fmt="7.12 min">427342139207</duration-on-core><size-in-bytes fmt="14,53 MiB">15238056</size-in-bytes></row><row><start-time fmt="00:00.000.000">0</start-time><process fmt="mds_stores (416)"><pid fmt="416">416</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="416">416</pid><sentinel /><duration-on-core fmt="1069.06 min">64143565451624</duration-on-core><size-in-bytes fmt="239,01 MiB">250616480</size-in-bytes></row><row><start-time fmt="00:00.000.000">0</start-time><process fmt="SpringBoard (58990)"><pid fmt="58990">58990</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="58990">58990</pid><sentinel /><duration-on-core fmt="5.25 min">314710963291</duration-on-core><size-in-bytes fmt="81,32 MiB">85265144</size-in-bytes></row><row><start-time fmt="00:00.000.000">0</start-time><process fmt="mds_stores (17588)"><pid fmt="17588">17588</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="17588">17588</pid><sentinel /><duration-on-core fmt="123.91 min">7434669172249</duration-on-core><size-in-bytes fmt="404,80 MiB">424465328</size-in-bytes></row><row><start-time fmt="00:00.000.000">0</start-time><process fmt="WindowServer (79935)"><pid fmt="79935">79935</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="79935">79935</pid><sentinel /><duration-on-core fmt="3579.91 min">214794337554625</duration-on-core><size-in-bytes fmt="1,75 GiB">1882147000</size-in-bytes></row><row><start-time fmt="00:02.269.441">2269441041</start-time><process fmt="kernel (0)"><pid fmt="0">0</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="0">0</pid><system-cpu-percent fmt="229.2%">229.154304945</system-cpu-percent><duration-on-core fmt="15981.99 min">958919583417416</duration-on-core><size-in-bytes fmt="2,66 GiB">2857598976</size-in-bytes></row><row><start-time fmt="00:02.269.441">2269441041</start-time><process fmt="SpringBoard (73688)"><pid fmt="73688">73688</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="73688">73688</pid><system-cpu-percent fmt="0.1%">0.065575746</system-cpu-percent><duration-on-core fmt="4.20 min">252162933041</duration-on-core><size-in-bytes fmt="96,24 MiB">100911888</size-in-bytes></row><row><start-time fmt="00:02.269.441">2269441041</start-time><process fmt="mds_stores (19784)"><pid fmt="19784">19784</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="19784">19784</pid><system-cpu-percent fmt="0.0%">0.000000000</system-cpu-percent><duration-on-core fmt="7.12 min">427342139207</duration-on-core><size-in-bytes fmt="14,53 MiB">15238056</size-in-bytes></row><row><start-time fmt="00:02.269.441">2269441041</start-time><process fmt="mds_stores (416)"><pid fmt="416">416</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="416">416</pid><system-cpu-percent fmt="0.7%">0.668604892</system-cpu-percent><duration-on-core fmt="1069.06 min">64143579953624</duration-on-core><size-in-bytes fmt="239,76 MiB">251402912</size-in-bytes></row><row><start-time fmt="00:02.269.441">2269441041</start-time><process fmt="SpringBoard (58990)"><pid fmt="58990">58990</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="58990">58990</pid><system-cpu-percent fmt="0.0%">0.049554447</system-cpu-percent><duration-on-core fmt="5.25 min">314712038124</duration-on-core><size-in-bytes fmt="81,33 MiB">85281528</size-in-bytes></row><row><start-time fmt="00:02.269.441">2269441041</start-time><process fmt="mds_stores (17588)"><pid fmt="17588">17588</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="17588">17588</pid><system-cpu-percent fmt="1.3%">1.340663782</system-cpu-percent><duration-on-core fmt="123.91 min">7434698251166</duration-on-core><size-in-bytes fmt="406,85 MiB">426611680</size-in-bytes></row><row><start-time fmt="00:02.269.441">2269441041</start-time><process fmt="WindowServer (79935)"><pid fmt="79935">79935</pid><device-session fmt="TODO">TODO</device-session></process><pid fmt="79935">79935</pid><system-cpu-percent fmt="30.6%">30.649833102</system-cpu-percent><duration-on-core fmt="3579.92 min">214795002347666</duration-on-core><size-in-bytes fmt="1,75 GiB">1882163384</size-in-bytes></row></node></trace-query-result>
        """#

    /// The device's memory and load, the last two readings.
    static let system = #"""
        <?xml version="1.0"?>
        <trace-query-result><node xpath="//trace-toc[1]/run[1]/data[1]/table[14]"><schema name="activity-monitor-system"><col><mnemonic>start</mnemonic></col><col><mnemonic>duration</mnemonic></col><col><mnemonic>cpu-total-load</mnemonic></col><col><mnemonic>memory-physical-used</mnemonic></col></schema><row><start-time fmt="00:03.125.413">3125413625</start-time><duration fmt="1.07 s">1066724916</duration><cpu-percent-loads fmt="1400.0%">1400.000000000</cpu-percent-loads><size-in-bytes fmt="32,10 GiB">34462105600</size-in-bytes></row><row><start-time fmt="00:04.192.138">4192138541</start-time><duration fmt="1.28 s">1278802459</duration><cpu-percent-loads fmt="1400.0%">1400.000000000</cpu-percent-loads><size-in-bytes fmt="32,18 GiB">34555854848</size-in-bytes></row></node></trace-query-result>
        """#

    /// The thermal state over the recording.
    static let thermal = #"""
        <?xml version="1.0"?>
        <trace-query-result><node xpath="//trace-toc[1]/run[1]/data[1]/table[4]"><schema name="device-thermal-state-intervals"><col><mnemonic>start</mnemonic></col><col><mnemonic>duration</mnemonic></col><col><mnemonic>thermal-state</mnemonic></col></schema><row><start-time fmt="00:00.000.000">0</start-time><duration fmt="5.77 s">5766766786</duration><thermal-state fmt="Nominal">Nominal</thermal-state></row></node></trace-query-result>
        """#

    /// Time Profiler: three samples of lsd (pid 29397), one of another process, two frames each.
    static let timeProfile = #"""
        <?xml version="1.0"?>
        <trace-query-result><node xpath="//trace-toc[1]/run[1]/data[1]/table[25]"><schema name="time-profile"><col><mnemonic>time</mnemonic></col><col><mnemonic>thread</mnemonic></col><col><mnemonic>process</mnemonic></col><col><mnemonic>core</mnemonic></col><col><mnemonic>thread-state</mnemonic></col><col><mnemonic>weight</mnemonic></col><col><mnemonic>stack</mnemonic></col></schema><row><sample-time fmt="00:00.992.496">992496166</sample-time><thread fmt="lsd (0xf3cc696) (lsd, pid: 29397)"><tid fmt="0xf3cc696">255641238</tid><process fmt="lsd (29397)"><pid fmt="29397">29397</pid><device-session fmt="TODO">TODO</device-session></process></thread><process fmt="lsd (29397)"><pid fmt="29397">29397</pid><device-session fmt="TODO">TODO</device-session></process><core fmt="CPU 4 ((null) Core)">4</core><thread-state fmt="Running">Running</thread-state><weight fmt="1.00 ms">1000000</weight><tagged-backtrace><frame name="__open" addr="0x102f75575"><binary name="libsystem_kernel.dylib" arch="arm64" /></frame><frame name="open" addr="0x102f7f987"><binary name="libsystem_kernel.dylib" arch="arm64" /></frame></tagged-backtrace></row><row><sample-time fmt="00:01.014.497">1014497500</sample-time><thread fmt="lsd (0xf3cc928) (lsd, pid: 29397)"><tid fmt="0xf3cc928">255641896</tid><process fmt="lsd (29397)"><pid fmt="29397">29397</pid><device-session fmt="TODO">TODO</device-session></process></thread><process fmt="lsd (29397)"><pid fmt="29397">29397</pid><device-session fmt="TODO">TODO</device-session></process><core fmt="CPU 10 ((null) Core)">10</core><thread-state fmt="Running">Running</thread-state><weight fmt="1.00 ms">1000000</weight><tagged-backtrace><frame name="__open_nocancel" addr="0x102f756e1"><binary name="libsystem_kernel.dylib" arch="arm64" /></frame><frame name="open$NOCANCEL" addr="0x102f886e7"><binary name="libsystem_kernel.dylib" arch="arm64" /></frame></tagged-backtrace></row><row><sample-time fmt="00:01.015.498">1015498916</sample-time><thread fmt="lsd (0xf3cc69a) (lsd, pid: 29397)"><tid fmt="0xf3cc69a">255641242</tid><process fmt="lsd (29397)"><pid fmt="29397">29397</pid><device-session fmt="TODO">TODO</device-session></process></thread><process fmt="lsd (29397)"><pid fmt="29397">29397</pid><device-session fmt="TODO">TODO</device-session></process><core fmt="CPU 1 ((null) Core)">1</core><thread-state fmt="Running">Running</thread-state><weight fmt="1.00 ms">1000000</weight><tagged-backtrace><frame name="__open_nocancel" addr="0x102f756e1"><binary name="libsystem_kernel.dylib" arch="arm64" /></frame><frame name="open$NOCANCEL" addr="0x102f886e7"><binary name="libsystem_kernel.dylib" arch="arm64" /></frame></tagged-backtrace></row><row><sample-time fmt="00:00.387.495">387495666</sample-time><thread fmt="Main Thread (0xf3cc61d) (akd, pid: 29678)"><tid fmt="0xf3cc61d">255641117</tid><process fmt="akd (29678)"><pid fmt="29678">29678</pid><device-session fmt="TODO">TODO</device-session></process></thread><process fmt="akd (29678)"><pid fmt="29678">29678</pid><device-session fmt="TODO">TODO</device-session></process><core fmt="CPU 5 ((null) Core)">5</core><thread-state fmt="Running">Running</thread-state><weight fmt="1.00 ms">1000000</weight><tagged-backtrace><frame name="mach_o::Header::SegmentInfo mach_o::Header::parse_segment_command&lt;true&gt;(mach_o::Header::LoadCommandInfo const&amp;, unsigned short, void (mach_o::Header::SegmentInfo const&amp;, mach_o::Header::SectionInfo const&amp;) block_pointer, mach_o::Error*) const" addr="0x1005b1581"><binary name="dyld_sim" arch="arm64" /></frame><frame name="invocation function for block in mach_o::Header::forEachSegment(void (mach_o::Header::SegmentInfo const&amp;, bool&amp;) block_pointer) const" addr="0x1005b5cdb"><binary name="dyld_sim" arch="arm64" /></frame></tagged-backtrace></row></node></trace-query-result>
        """#
}
