import CoreGraphics
import Foundation
import Network
import Testing
@testable import MobdevCore

/// Answers commands by the first rule whose text appears in the joined arguments, records every
/// call, and plays scripted lines into started commands, some only once a run matches a trigger.
final class ScriptedRunner: CommandRunning, @unchecked Sendable {
    let calls = Locked<[String]>([])
    var rules: [(match: String, output: String)] = []
    /// Lines a started command prints at once.
    var startLines: [String] = []
    /// Lines the started command prints when a later `run` contains `trigger`.
    var triggered: (trigger: String, lines: [String])?
    private let streams = Locked<[@Sendable (String) -> Void]>([])

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let joined = arguments.joined(separator: " ")
        calls.withLock { $0.append(joined) }
        if let triggered, joined.contains(triggered.trigger) {
            for stream in streams.get() { for line in triggered.lines { stream(line) } }
        }
        let output = rules.first { joined.contains($0.match) }?.output ?? ""
        return CommandResult(status: 0, output: output)
    }

    func start(
        _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningCommand {
        calls.withLock { $0.append(arguments.joined(separator: " ")) }
        streams.withLock { $0.append(onLine) }
        for line in startLines { onLine(line) }
        return Stopper()
    }

    func runBinary(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, data: Data) {
        (0, Data())
    }

    struct Stopper: RunningCommand {
        func stop() {}
    }
}

/// Canned performance numbers, recording what was asked.
final class FakePerformance: AppPerformance, @unchecked Sendable {
    var sampleResult = PerformanceSample(pid: 1, points: [], averageCPU: 0, memoryKind: "physical footprint")
    var launches: [Double] = []
    let calls = Locked<[String]>([])
    var launchMethod: String { "a fake clock" }

    func sample(_ bundleID: String, seconds: TimeInterval) async throws -> PerformanceSample {
        calls.withLock { $0.append("sample \(bundleID) \(seconds)") }
        return sampleResult
    }

    func coldLaunch(_ bundleID: String) async throws -> LaunchTiming {
        let index = calls.withLock { calls -> Int in
            calls.append("launch \(bundleID)")
            return calls.count - 1
        }
        return LaunchTiming(milliseconds: launches[index % launches.count], state: "COLD")
    }
}

/// Notes when the app is activated, so `DevLoopPhone`'s screen can play a launch from then on.
final class TimedApps: AppBackend, @unchecked Sendable {
    let logs = AppLogs()
    let platform = AppPlatform.iPhone
    let activated = Locked<Date?>(nil)
    /// When set, activating fails with it, as for an app that is not installed.
    var failure: String?

    func activate(_ bundleID: String) async throws {
        if let failure { throw DeveloperError(failure) }
        activated.set(Date())
    }
    func apps(all: Bool) async throws -> [InstalledApp] { [] }
    func app(_ bundleID: String) async throws -> InstalledApp? { nil }
    func install(at path: URL) async throws -> InstalledApp { throw DeveloperError("no") }
    func uninstall(_ bundleID: String) async throws -> InstalledApp { throw DeveloperError("no") }
    func launch(_ bundleID: String, arguments: [String], environment: [String: String], restart: Bool) async throws
        -> LaunchOutcome
    { .launched }
    func stop(_ bundleID: String) async throws -> Bool {
        activated.set(nil)
        return true
    }
    func open(_ url: URL) async throws {}
    func crashReports() async throws -> [CrashReportFile] { [] }
    func crashReport(named name: String) async throws -> (report: CrashReport?, file: URL) { throw DeveloperError("no") }
}

/// A FakePhone with performance, a developer menu and a screen that can follow `TimedApps`.
final class DevLoopPhone: PhoneBackend, @unchecked Sendable {
    let base: FakePhone
    let performanceBackend: AppPerformance?
    let menu: String?
    let menus = Locked(0)
    let timedApps: TimedApps?
    let tree: [UIElement]?
    let input: InputRoute

    init(
        performance: AppPerformance? = nil, menu: String? = "Shook the simulator", timedApps: TimedApps? = nil,
        tree: [UIElement]? = nil, input: InputRoute = .direct("Simulator")
    ) {
        base = FakePhone(lines: [])
        performanceBackend = performance
        self.menu = menu
        self.timedApps = timedApps
        self.tree = tree
        self.input = input
    }

    static func solid(_ gray: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 120, height: 260, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 260))
        return context.makeImage()!
    }

    static let home = solid(1), animation1 = solid(0.7), animation2 = solid(0.4), app = solid(0)

    func status() -> PhoneStatus {
        var status = base.status()
        status.input = input
        return status
    }

    /// Home until activated, then 0.2 s each of two animation frames, then the app.
    func frame() -> CGImage? {
        guard let timedApps else { return base.frame() }
        guard let activated = timedApps.activated.get() else { return Self.home }
        let elapsed = Date().timeIntervalSince(activated)
        return elapsed < 0.2 ? Self.animation1 : elapsed < 0.4 ? Self.animation2 : Self.app
    }

    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws { try await base.tap(at: point, hold: hold) }
    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {}
    func scroll(at point: NormalizedPoint, ticks: Int) async throws {}
    func pan(at point: NormalizedPoint, ticks: Int) async throws {}
    func type(_ strokes: [KeyStroke]) async throws {}
    func press(_ stroke: KeyStroke) async throws {}
    func press(_ button: ConsumerUsage) async throws {}
    func uiTree() async throws -> [UIElement]? { tree }
    var apps: AppBackend? { timedApps }
    var performance: AppPerformance? { performanceBackend }

    func developerMenu() async throws -> String? {
        guard let menu else { return nil }
        menus.withLock { $0 += 1 }
        return menu
    }
}

/// A Metro message socket on a free port: answers getpeers with `peers` and records every message.
final class FakeMetro: @unchecked Sendable {
    let listener: NWListener
    let peers: [String: String]
    let received = Locked<[String]>([])
    private let queue = DispatchQueue(label: "fake-metro")

    init(peers: [String: String]) throws {
        self.peers = peers
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    deinit { listener.cancel() }

    var port: Int { Int(listener.port?.rawValue ?? 0) }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let text = String(data: data, encoding: .utf8) {
                self.received.withLock { $0.append(text) }
                if let json = try? JSONValue.parse(Data(text.utf8)), json["method"]?.stringValue == "getpeers",
                    let id = json["id"]
                {
                    let reply: JSONValue = ["version": 2, "id": id, "result": .object(self.peers.mapValues(JSONValue.string))]
                    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                    let context = NWConnection.ContentContext(identifier: "reply", metadata: [metadata])
                    connection.send(
                        content: Data(reply.compactString.utf8), contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
                }
            }
            self.receive(on: connection)
        }
    }
}

/// A port nothing listens on, from a listener that was closed again.
func closedPort() throws -> Int {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    defer { close(socket) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) } }
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
    }
    return Int(UInt16(bigEndian: address.sin_port))
}

@Suite struct PerformanceParsingTests {
    @Test func findsAnAppsPidInTheSimulatorsLaunchctlList() {
        let list = """
            PID\tStatus\tLabel
            -\t0\tUIKitApplication:com.example.idle[1a2b][rb-legacy]
            41077\t0\tUIKitApplication:com.apple.Preferences[e5a5][rb-legacy]
            35500\t0\tUIKitApplication:com.apple.Spotlight[4892][rb-legacy]
            90210\t0\tUIKitApplication:com.apple.PreferencesExtra[77aa][rb-legacy]
            """
        #expect(DeviceControl.pid(of: "com.apple.Preferences", inLaunchctlList: list) == 41077)
        #expect(DeviceControl.pid(of: "com.example.idle", inLaunchctlList: list) == nil)
        #expect(DeviceControl.pid(of: "com.apple", inLaunchctlList: list) == nil)
    }

    @Test func samplerAveragesCPUOverTheWholeSampleAndStopsWhenTheAppEnds() async throws {
        // A fake clock: each pause moves it on; the app uses half a core, then a whole one.
        let clock = Locked(0.0)
        let readings = Locked<[(Double, Double)?]>([(10, 50), (10.25, 52), (10.75, 60), nil])
        var sampler = UsageSampler(seconds: 3, interval: 0.5) {
            readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }
        let start = Date(timeIntervalSince1970: 0)
        sampler.now = { start.addingTimeInterval(clock.get()) }
        sampler.pause = { seconds in clock.withLock { $0 += seconds } }
        let result = try #require(try await sampler.run())
        #expect(result.ended)
        #expect(result.points.map(\.time) == [0, 0.5, 1.0])
        #expect(result.points.map(\.cpu) == [nil, 50, 100])
        #expect(result.points.map(\.memoryMB) == [50, 52, 60])
        #expect(abs(result.averageCPU - 75) < 0.001)
    }

    /// From `log stream --signpost --style ndjson` on an iOS 27 simulator, shortened to the fields
    /// Mobdev reads: SpringBoard's begin twice, the app's end with the same ID.
    static let signposts = [
        #"Filtering the log data using "signpostName == "ApplicationFirstFramePresentation"""#,
        #"{"signpostID":174407751,"signpostType":"begin","signpostName":"ApplicationFirstFramePresentation","processImagePath":"\/Library\/Developer\/CoreSimulator\/Volumes\/iOS_24A434\/Library\/Developer\/CoreSimulator\/Profiles\/Runtimes\/iOS 27.0.simruntime\/Contents\/Resources\/RuntimeRoot\/System\/Library\/CoreServices\/SpringBoard.app\/SpringBoard","machTimestamp":14247269846707,"eventMessage":"IsForeground=1 AppVersion=8(1.3) 14247269798071"}"#,
        #"{"signpostID":174407751,"signpostType":"begin","signpostName":"ApplicationFirstFramePresentation","processImagePath":"\/SpringBoard.app\/SpringBoard","machTimestamp":14247271027008,"eventMessage":"IsForeground=1 AppVersion=8(1.3) 14247269798071"}"#,
        #"{"signpostID":99,"signpostType":"end","signpostName":"ApplicationFirstFramePresentation","processImagePath":"\/Users\/me\/Library\/Developer\/CoreSimulator\/Devices\/0B94\/data\/Containers\/Bundle\/Application\/9381\/Other.app\/Other","machTimestamp":14247300000000,"eventMessage":"LaunchInfo=480"}"#,
        #"{"signpostID":174407751,"signpostType":"end","signpostName":"ApplicationFirstFramePresentation","processImagePath":"\/Users\/me\/Library\/Developer\/CoreSimulator\/Devices\/0B94\/data\/Containers\/Bundle\/Application\/9381\/PerfFixture.app\/PerfFixture","machTimestamp":14247323654054,"eventMessage":"LaunchInfo=480 enableTelemetry=YES"}"#,
    ]

    @Test func firstFrameSignpostsGiveTheLaunchTimeFromTheRequest() {
        let watch = SignpostWatch(executable: "PerfFixture")
        for line in Self.signposts { watch.receive(line) }
        let state = watch.state.get()
        #expect(state.listening)
        // From the request time in the begin's message to the end: 53,855,983 ticks.
        let expected = 53_855_983 * DeviceControl.machTickNanoseconds / 1e9
        #expect(abs((state.duration ?? 0) - expected) < 0.000_001)
    }

    @Test func coldLaunchOnASimulatorStreamsSignpostsAroundTheLaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-perf-\(UUID().uuidString)")
        let app = folder.appendingPathComponent("PerfFixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try (["CFBundleExecutable": "PerfFixture"] as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        let runner = ScriptedRunner()
        runner.rules = [
            ("listapps", "{ \"dev.mobdev.perffixture\" = { ApplicationType = User; CFBundleIdentifier = \"dev.mobdev.perffixture\"; Path = \"\(app.path)\"; }; }")
        ]
        runner.startLines = [Self.signposts[0]]
        runner.triggered = ("simctl launch", Array(Self.signposts.dropFirst()))
        let control = DeviceControl(
            udid: "SIM-1", runner: runner, reportsFolder: folder, simulator: true, simctl: true, localReports: folder)
        let timing = try await control.coldLaunch("dev.mobdev.perffixture")
        #expect(abs(timing.milliseconds - 53_855_983 * DeviceControl.machTickNanoseconds / 1e6) < 0.001)
        let calls = runner.calls.get()
        #expect(calls.contains("simctl terminate SIM-1 dev.mobdev.perffixture"))
        #expect(calls.contains { $0.hasPrefix("simctl spawn SIM-1 log stream --signpost --style ndjson") })
        #expect(calls.last == "simctl launch SIM-1 dev.mobdev.perffixture")
    }

    @Test func iPhonesSayHowToMeasureWithInstruments() async throws {
        let control = DeviceControl(udid: "PHONE", runner: ScriptedRunner(), reportsFolder: FileManager.default.temporaryDirectory)
        await #expect(throws: DeveloperError.self) { try await control.sample("com.example", seconds: 1) }
        do {
            _ = try await control.sample("com.example", seconds: 1)
        } catch {
            #expect(String(describing: error).contains("xctrace record --template 'Activity Monitor'"))
        }
    }

    /// What the sample script prints on Android: written from the formats of /proc and dumpsys on
    /// Android 14 to 16, not recorded from a device.
    static let androidSample = """
        TCK 100
        S 1000.00 | 4242 (com.example.app) S 312 312 0 0 -1 1077952832 20000 0 0 0 150 50 0 0 10 -10 30 0 9000 | VmRSS:\t  204800 kB
        S 1001.00 | 4242 (com.example.app) S 312 312 0 0 -1 1077952832 20000 0 0 0 190 60 0 0 10 -10 30 0 9000 | VmRSS:\t  209920 kB
        S 1002.00 | 4242 (com.example.app) R 312 312 0 0 -1 1077952832 20000 0 0 0 290 60 0 0 10 -10 30 0 9000 | VmRSS:\t  215040 kB
        GFXINFO
        Applications Graphics Acceleration Info:
        Uptime: 1002345 Realtime: 1002345

        ** Graphics info for pid 4242 [com.example.app] **

        Stats since: 1000123456789ns
        Total frames rendered: 120
        Janky frames: 12 (10.00%)
        Janky frames (legacy): 20 (16.67%)
        50th percentile: 8ms
        90th percentile: 17ms
        95th percentile: 24ms
        99th percentile: 49ms
        Number Missed Vsync: 2
        HISTOGRAM: 5ms=10 6ms=20 7ms=30
        50th gpu percentile: 3ms
        MEMINFO
                   TOTAL PSS:    98304            TOTAL RSS:   215040       TOTAL SWAP PSS:       12
        """

    @Test func androidSampleParsesCPUMemoryFramesAndPSS() throws {
        let sample = try #require(AndroidApps.parseSample(Self.androidSample, pid: 4242))
        #expect(sample.points.map(\.time) == [0, 1, 2])
        // 50 ticks in the first second, 100 in the second, at 100 ticks a second.
        #expect(sample.points.map(\.cpu) == [nil, 50, 100])
        #expect(sample.points.map(\.memoryMB) == [200, 205, 210])
        #expect(sample.averageCPU == 75)
        #expect(sample.peakCPU == 100)
        #expect(sample.pssMB == 96)
        #expect(sample.ended == nil)
        #expect(
            sample.frames == FrameStats(total: 120, janky: 12, jankyPercent: 10, p50: 8, p90: 17, p95: 24, p99: 49))
    }

    @Test func androidStatNamesWithSpacesAndEndedApps() throws {
        #expect(AndroidApps.cpuTicks(fromStat: "77 (my app (x)) S 1 1 0 0 -1 0 0 0 0 0 7 3 0 0") == 10)
        #expect(AndroidApps.cpuTicks(fromStat: "garbage") == nil)
        let ended = try #require(AndroidApps.parseSample("TCK 100\nS 5.00 | 1 (a) S 0 0 0 0 0 0 0 0 0 0 1 1 | VmRSS: 1024 kB\nGONE\nGFXINFO\nNo process found for: a\nMEMINFO\n", pid: 1))
        #expect(ended.ended != nil)
        #expect(ended.frames == nil)
        #expect(ended.points.count == 1)
        #expect(AndroidApps.parseSample("TCK 100\nGONE\n", pid: 1) == nil)
        // Older meminfo has a TOTAL row instead of the summary.
        #expect(AndroidApps.pss("        TOTAL    51200    40000     1000") == 50)
    }

    @Test func amStartReportsTotalTimeAndState() {
        let output = """
            Starting: Intent { act=android.intent.action.MAIN cat=[android.intent.category.LAUNCHER] cmp=com.example.app/.MainActivity }
            Status: ok
            LaunchState: COLD
            Activity: com.example.app/.MainActivity
            TotalTime: 523
            WaitTime: 530
            Complete
            """
        #expect(AndroidApps.launchTiming(output) == LaunchTiming(milliseconds: 523, state: "COLD"))
        #expect(AndroidApps.launchTiming("Status: ok\nWaitTime: 610\nComplete") == LaunchTiming(milliseconds: 610))
        #expect(AndroidApps.launchTiming("Error: Activity not started, unable to resolve Intent") == nil)
    }

    @Test func androidColdLaunchForceStopsAndStartsTheLauncherActivity() async throws {
        let runner = ScriptedRunner()
        runner.rules = [
            ("resolve-activity", "priority=0 preferredOrder=0\ncom.example.app/.MainActivity\n"),
            ("am start -W", "Status: ok\nLaunchState: COLD\nTotalTime: 412\nComplete\n"),
        ]
        let apps = AndroidApps(
            serial: "emulator-5590", adb: ADB(executable: URL(fileURLWithPath: "/adb"), runner: runner),
            reportsFolder: FileManager.default.temporaryDirectory)
        #expect(try await apps.coldLaunch("com.example.app") == LaunchTiming(milliseconds: 412, state: "COLD"))
        let calls = runner.calls.get()
        #expect(calls.contains("-s emulator-5590 shell am force-stop com.example.app"))
        #expect(calls.last == "-s emulator-5590 shell am start -W -n 'com.example.app/.MainActivity'")
        await #expect(throws: DeveloperError.self) { try await apps.coldLaunch("not a package") }
    }

    @Test func androidSampleRunsOneScriptOnTheDevice() async throws {
        let runner = ScriptedRunner()
        runner.rules = [("pidof com.example.app", "4242\n"), ("getconf CLK_TCK", Self.androidSample)]
        let apps = AndroidApps(
            serial: "emulator-5590", adb: ADB(executable: URL(fileURLWithPath: "/adb"), runner: runner),
            reportsFolder: FileManager.default.temporaryDirectory)
        let sample = try await apps.sample("com.example.app", seconds: 2)
        #expect(sample.averageCPU == 75)
        let script = try #require(runner.calls.get().last)
        #expect(script.contains("dumpsys gfxinfo com.example.app reset"))
        #expect(script.contains("/proc/4242/stat"))
        // Two seconds at half-second readings: four pauses, five readings.
        #expect(script.contains("while [ $i -le 4 ]"))
        #expect(script.contains("sleep 0.5"))
    }
}

@Suite struct DevLoopToolTests {
    func call(_ tools: PhoneTools, _ name: String, _ arguments: JSONValue) async throws -> ToolOutput {
        try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
    }

    func tools(_ phone: PhoneBackend) -> PhoneTools { PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0) }

    static let sample = PerformanceSample(
        pid: 77,
        points: [
            UsagePoint(time: 0, cpu: nil, memoryMB: 100), UsagePoint(time: 1, cpu: 30, memoryMB: 140),
            UsagePoint(time: 2, cpu: 10, memoryMB: 120),
        ], averageCPU: 20, memoryKind: "physical footprint")

    @Test func performanceReportsAndHoldsTheAppToBudgets() async throws {
        let performance = FakePerformance()
        performance.sampleResult = Self.sample
        let tools = tools(DevLoopPhone(performance: performance))
        let output = try await call(tools, "performance", ["bundle_id": "com.example.app", "seconds": 2])
        #expect(!output.isError)
        #expect(output.text.contains("CPU: average 20.0%, peak 30.0% of one core"))
        #expect(output.text.contains("100.0 MB at the start, 120.0 MB at the end, peak 140.0 MB"))
        #expect(output.data?["memory_mb"]?["peak"] == 140)
        #expect(output.data?["cpu"]?["average"] == 20)
        #expect(performance.calls.get() == ["sample com.example.app 2.0"])

        let within = try await call(
            tools, "performance", ["bundle_id": "com.example.app", "max_cpu": 25, "max_memory_mb": 150])
        #expect(!within.isError)
        let over = try await call(tools, "performance", ["bundle_id": "com.example.app", "max_cpu": 15, "max_memory_mb": 130])
        #expect(over.isError)
        #expect(over.text.hasPrefix("Over budget: average CPU 20.0% is above max_cpu 15%; peak memory 140.0 MB is above max_memory_mb 130."))
        #expect(over.text.contains("CPU: average 20.0%"))
        let frames = try await call(tools, "performance", ["bundle_id": "com.example.app", "max_janky_percent": 5])
        #expect(frames.isError)
        #expect(frames.text.contains("only Android reports"))
        #expect(try await call(tools, "performance", ["bundle_id": "com.example.app", "seconds": 61]).isError)
    }

    @Test func performanceOnAnIPhoneSaysHowToRecordWithInstruments() async throws {
        let output = try await call(
            tools(DevLoopPhone(performance: nil, menu: nil, input: .bluetooth)), "performance", ["bundle_id": "com.example.app"])
        #expect(output.isError)
        #expect(output.text.contains("xctrace record"))
    }

    @Test func measureLaunchGivesMinMedianMaxAndFailsOverBudget() async throws {
        let performance = FakePerformance()
        performance.launches = [480, 400, 520]
        let tools = tools(DevLoopPhone(performance: performance))
        let output = try await call(tools, "measure_launch", ["bundle_id": "com.example.app"])
        #expect(!output.isError)
        #expect(output.text.hasPrefix("Cold launch of com.example.app, 3 runs: min 400 ms, median 480 ms, max 520 ms (480, 400, 520 ms), launch state COLD."))
        #expect(output.text.contains("Measured with a fake clock."))
        #expect(output.data?["median_ms"] == 480)
        #expect(output.data?["method"] == "system")

        // The next two runs take 480 and 400 ms.
        let over = try await call(tools, "measure_launch", ["bundle_id": "com.example.app", "runs": 2, "max_ms": 430])
        #expect(over.isError)
        #expect(over.text.hasPrefix("Over budget: the median launch took 440 ms, more than max_ms 430."))
        let screenWithoutApps = try await call(tools, "measure_launch", ["bundle_id": "com.example.app", "method": "screen"])
        #expect(screenWithoutApps.isError)
        #expect(try await call(tools, "measure_launch", ["bundle_id": "com.example.app", "method": "stopwatch"]).isError)
    }

    @Test func measureLaunchTimesTheScreenWhereTheDeviceHasNoTiming() async throws {
        let apps = TimedApps()
        let tools = tools(DevLoopPhone(performance: nil, menu: nil, timedApps: apps, input: .direct("Simulator")))
        let output = try await call(tools, "measure_launch", ["bundle_id": "com.example.app", "runs": 1, "stable": 0.6])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.hasSuffix("Measured with the screen, from the launch animation until it stayed still for 0.6 s."))
        let median = try #require(output.data?["median_ms"]?.doubleValue)
        // The animation runs 0.4 s after the launch; polling adds up to a frame each side.
        #expect(median > 300 && median < 600, "\(median)")
        #expect(output.data?["method"] == "screen")
        let system = try await call(tools, "measure_launch", ["bundle_id": "com.example.app", "method": "system"])
        #expect(system.isError)
        #expect(system.text.contains("method screen"))
    }

    @Test func aLaunchThatFailsEndsTheScreenTimingAtOnce() async throws {
        let apps = TimedApps()
        apps.failure = "com.example.gone is not installed."
        let tools = tools(DevLoopPhone(performance: nil, menu: nil, timedApps: apps))
        let started = Date()
        let output = try await call(tools, "measure_launch", ["bundle_id": "com.example.gone", "runs": 1])
        #expect(output.isError)
        #expect(output.text == "Could not launch com.example.gone: com.example.gone is not installed.")
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func blockedAppsCannotBeLaunchedForTiming() throws {
        #expect(throws: ToolFailure.self) {
            try AppBlocklist.check("measure_launch", Arguments(["bundle_id": "de.sparkasse.app"]), list: ["Sparkasse"])
        }
    }

    @Test func devMenuShakesOrPressesMenuWhereTheDeviceCan() async throws {
        let phone = DevLoopPhone(menu: "Shook the simulator")
        let output = try await call(tools(phone), "dev_menu", [:])
        #expect(output.text == "Shook the simulator to open the app's developer menu. A release build has none.")
        #expect(phone.menus.get() == 1)
    }

    @Test func devMenuOnAnIPhoneAsksMetro() async throws {
        let metro = try FakeMetro(peers: ["client-1": "role=ios"])
        let phone = DevLoopPhone(menu: nil, input: .bluetooth)
        let output = try await call(tools(phone), "dev_menu", ["port": .number(Double(metro.port))])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text == "Asked Metro on port \(metro.port) to open the developer menu in 1 connected app (role=ios).")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(metro.received.get().contains(#"{"method":"devMenu","version":2}"#))

        let nobody = try await call(tools(phone), "dev_menu", ["port": .number(Double(try closedPort()))])
        #expect(nobody.isError)
        #expect(nobody.text.contains("Metro is not running on port"))
    }

    @Test func reloadGoesThroughMetroToConnectedApps() async throws {
        let metro = try FakeMetro(peers: ["a": "role=ios", "b": "role=android"])
        let phone = DevLoopPhone()
        let output = try await call(tools(phone), "reload_app", ["port": .number(Double(metro.port))])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text == "Metro on port \(metro.port) told 2 connected apps (role=ios, role=android) to reload.")
        #expect(phone.menus.get() == 0)
        let messages = metro.received.get()
        #expect(messages.count == 2)
        let request = try JSONValue.parse(Data(messages[0].utf8))
        #expect(request["method"] == "getpeers")
        #expect(request["target"] == "server")
        #expect(request["version"] == 2)
        #expect(messages[1] == #"{"method":"reload","version":2}"#)
    }

    @Test func reloadFallsBackToTheDeveloperMenusReload() async throws {
        let metro = try FakeMetro(peers: [:])
        let reload = UIElement(
            role: "Button", label: "Reload", identifier: "", value: "", frame: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.05),
            enabled: true, tappable: true)
        let phone = DevLoopPhone(menu: "Shook the simulator", tree: [reload])
        let output = try await call(tools(phone), "reload_app", ["port": .number(Double(metro.port))])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text == "Metro runs on port \(metro.port) but no app is connected to it. Shook the simulator to open the developer menu and tapped Reload.")
        #expect(phone.menus.get() == 1)
        #expect(phone.base.events.get() == [.tap(reload.center, 0.08)])
        #expect(!metro.received.get().contains { $0.contains("reload") })

        let iPhone = try await call(
            tools(DevLoopPhone(menu: nil, input: .bluetooth)), "reload_app", ["port": .number(Double(try closedPort()))])
        #expect(iPhone.isError)
        #expect(iPhone.text.contains("shake the iPhone and tap Reload"))
    }
}
