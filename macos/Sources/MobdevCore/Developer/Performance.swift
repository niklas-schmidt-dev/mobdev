import Darwin
import Foundation

/// One reading of an app's process while it is sampled.
public struct UsagePoint: Sendable, Equatable {
    /// Seconds since sampling started.
    public var time: Double
    /// Percent of one core since the previous reading; above 100 when several cores work. Nil for the first.
    public var cpu: Double?
    public var memoryMB: Double

    public init(time: Double, cpu: Double?, memoryMB: Double) {
        self.time = time
        self.cpu = cpu
        self.memoryMB = memoryMB
    }
}

/// How smoothly an app drew while it was sampled, from Android's `dumpsys gfxinfo`.
public struct FrameStats: Sendable, Equatable {
    public var total: Int
    public var janky: Int
    public var jankyPercent: Double
    /// Frame times in milliseconds; nil when the device did not report them.
    public var p50: Double?
    public var p90: Double?
    public var p95: Double?
    public var p99: Double?

    public init(total: Int, janky: Int, jankyPercent: Double, p50: Double?, p90: Double?, p95: Double?, p99: Double?) {
        self.total = total
        self.janky = janky
        self.jankyPercent = jankyPercent
        self.p50 = p50
        self.p90 = p90
        self.p95 = p95
        self.p99 = p99
    }
}

/// What `performance` measured: readings about once a second and, where the device has them, frames.
public struct PerformanceSample: Sendable, Equatable {
    public var pid: Int
    public var points: [UsagePoint]
    /// CPU time the app used over the whole sample, as a percent of one core.
    public var averageCPU: Double
    /// What memoryMB is, e.g. "physical footprint" (what Xcode shows) or "resident (RSS)".
    public var memoryKind: String
    public var frames: FrameStats?
    /// Android's proportional set size at the end, the memory Android Studio shows.
    public var pssMB: Double?
    /// Set when the app stopped before the sample was over.
    public var ended: String?

    public init(
        pid: Int, points: [UsagePoint], averageCPU: Double, memoryKind: String, frames: FrameStats? = nil,
        pssMB: Double? = nil, ended: String? = nil
    ) {
        self.pid = pid
        self.points = points
        self.averageCPU = averageCPU
        self.memoryKind = memoryKind
        self.frames = frames
        self.pssMB = pssMB
        self.ended = ended
    }

    public var peakCPU: Double { points.compactMap(\.cpu).max() ?? averageCPU }
    public var peakMemoryMB: Double { points.map(\.memoryMB).max() ?? 0 }
}

/// One cold launch as the system timed it.
public struct LaunchTiming: Sendable, Equatable {
    public var milliseconds: Double
    /// Android's LaunchState line, e.g. "COLD".
    public var state: String?

    public init(milliseconds: Double, state: String? = nil) {
        self.milliseconds = milliseconds
        self.state = state
    }
}

/// The whole device at one moment: its busiest processes, its memory and how warm it is.
public struct DeviceLoad: Sendable, Equatable {
    public struct Process: Sendable, Equatable {
        public var name: String
        public var pid: Int
        /// Percent of one core over the last interval.
        public var cpuPercent: Double
        public var memoryMB: Double

        public init(name: String, pid: Int, cpuPercent: Double, memoryMB: Double) {
            self.name = name
            self.pid = pid
            self.cpuPercent = cpuPercent
            self.memoryMB = memoryMB
        }
    }

    public var processes: [Process]
    /// Every core's load together, as a percent of one core; nil when the device does not say.
    public var cpuPercent: Double?
    /// How many cores the percent is out of, where known.
    public var cores: Int?
    public var memoryUsedMB: Double?
    public var memoryTotalMB: Double?
    /// e.g. "Nominal", or Android's "none (0)".
    public var thermalState: String?
    /// Temperatures the device reports, e.g. "CPU 41.0 °C".
    public var temperatures: [String]
    /// What each process's memory is, e.g. "physical footprint" or "resident (RSS)".
    public var memoryKind: String
    /// How long the readings took to collect.
    public var seconds: Double
    /// How it was measured, in a few words for the tool's answer.
    public var source: String
    /// What the numbers do not cover, e.g. that a simulator shares the Mac's memory.
    public var note: String?

    public init(
        processes: [Process], cpuPercent: Double? = nil, cores: Int? = nil, memoryUsedMB: Double? = nil,
        memoryTotalMB: Double? = nil, thermalState: String? = nil, temperatures: [String] = [], memoryKind: String,
        seconds: Double, source: String, note: String? = nil
    ) {
        self.processes = processes
        self.cpuPercent = cpuPercent
        self.cores = cores
        self.memoryUsedMB = memoryUsedMB
        self.memoryTotalMB = memoryTotalMB
        self.thermalState = thermalState
        self.temperatures = temperatures
        self.memoryKind = memoryKind
        self.seconds = seconds
        self.source = source
        self.note = note
    }

    public func top(byCPU count: Int) -> [Process] {
        Array(processes.sorted { ($0.cpuPercent, $0.memoryMB) > ($1.cpuPercent, $1.memoryMB) }.prefix(count))
    }

    public func top(byMemory count: Int) -> [Process] {
        Array(processes.sorted { ($0.memoryMB, $0.cpuPercent) > ($1.memoryMB, $1.cpuPercent) }.prefix(count))
    }
}

/// What to record with `record_trace`.
public struct TraceRequest: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// A running app.
        case attach(bundleID: String)
        /// Starts the app under the recording.
        case launch(bundleID: String)
        case allProcesses
    }

    /// An Instruments template; ignored on Android, which records a Perfetto trace.
    public var template: String
    public var target: Target
    public var seconds: TimeInterval
    /// Where the trace goes: a .trace bundle, or a .perfetto-trace file on Android.
    public var output: URL

    public init(template: String, target: Target, seconds: TimeInterval, output: URL) {
        self.template = template
        self.target = target
        self.seconds = seconds
        self.output = output
    }
}

/// A recorded trace and what could be read from it cheaply.
public struct TraceRecording: Sendable, Equatable {
    public var file: URL
    /// "Time Profiler", or "Perfetto".
    public var template: String
    /// e.g. "Settings (pid 66546)", "all processes".
    public var target: String
    public var seconds: Double?
    /// A few lines, such as the heaviest functions; empty when nothing cheap could be read.
    public var summary: [String]
    /// How to look at it, e.g. "Open it in Instruments".
    public var howToOpen: String

    public init(file: URL, template: String, target: String, seconds: Double?, summary: [String], howToOpen: String) {
        self.file = file
        self.template = template
        self.target = target
        self.seconds = seconds
        self.summary = summary
        self.howToOpen = howToOpen
    }
}

/// How apps and the device perform: an app's CPU and memory over a few seconds, how long a cold
/// launch takes, the whole device's load, and traces to open in Instruments or Perfetto.
/// Simulators sample the app's process on this Mac and time launches with iOS's own first-frame
/// signpost (`DeviceControl`); iPhones record Instruments' Activity Monitor template with
/// `xctrace` (`DeviceControl` too); Android reads /proc, `dumpsys` and `am start -W` over adb and
/// records Perfetto (`AndroidApps`).
public protocol AppPerformance: Sendable {
    /// Samples a running app about once a second for `seconds`.
    func sample(_ bundleID: String, seconds: TimeInterval) async throws -> PerformanceSample
    /// Stops the app, starts it again and returns how long it took to its first frame.
    func coldLaunch(_ bundleID: String) async throws -> LaunchTiming
    /// How `coldLaunch` measures, in a few words for the tool's answer.
    var launchMethod: String { get }
    /// Whether `measure_launch` uses `coldLaunch` unless told otherwise; false times the screen.
    var timesLaunches: Bool { get }
    /// The whole device right now: every process's CPU and memory, the memory in use, the thermal state.
    func deviceLoad() async throws -> DeviceLoad
    /// Records a trace into `request.output`.
    func recordTrace(_ request: TraceRequest) async throws -> TraceRecording
}

extension AppPerformance {
    public var timesLaunches: Bool { true }

    public func deviceLoad() async throws -> DeviceLoad {
        throw DeveloperError("This device cannot report its load.")
    }

    public func recordTrace(_ request: TraceRequest) async throws -> TraceRecording {
        throw DeveloperError("This device cannot record traces.")
    }
}

/// Readings at a steady interval until `seconds` passed or `read` returns nil because the process
/// ended. `read` returns the process's total CPU time in seconds and its memory in MB.
struct UsageSampler {
    var seconds: TimeInterval
    var interval: TimeInterval
    var read: () async -> (cpuSeconds: Double, memoryMB: Double)?
    var pause: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    var now: () -> Date = Date.init

    /// Every reading and the average CPU over the readings, or nil when even the first read failed.
    func run() async throws -> (points: [UsagePoint], averageCPU: Double, ended: Bool)? {
        let start = now()
        guard let first = await read() else { return nil }
        var points = [UsagePoint(time: 0, cpu: nil, memoryMB: first.memoryMB)]
        var previous = (time: 0.0, cpu: first.cpuSeconds)
        var ended = false
        while previous.time < seconds - 0.001 {
            let next = min(previous.time + interval, seconds)
            try await pause(max(next - now().timeIntervalSince(start), 0))
            guard let reading = await read() else {
                ended = true
                break
            }
            let time = now().timeIntervalSince(start)
            let elapsed = max(time - previous.time, 0.001)
            let cpu = max(reading.cpuSeconds - previous.cpu, 0) / elapsed * 100
            points.append(UsagePoint(time: time, cpu: cpu, memoryMB: reading.memoryMB))
            previous = (time, reading.cpuSeconds)
        }
        let total = previous.time > 0 ? max(previous.cpu - first.cpuSeconds, 0) / previous.time * 100 : 0
        return (points, total, ended)
    }

    /// Once a second, or twice for short samples, so even one second gives a peak.
    static func interval(for seconds: TimeInterval) -> TimeInterval { seconds < 5 ? 0.5 : 1 }
}

// MARK: - Simulators and iPhones

/// A simulator's app is a process on this Mac, so it is sampled like one: `proc_pid_rusage` gives its
/// CPU time and physical footprint, the memory Xcode's gauge shows. The pid comes from the
/// simulator's own launchd, so an app of the same name in another simulator is never measured.
/// An iPhone's app is recorded with Instruments' Activity Monitor template through `xctrace`,
/// attached to the pid devicectl names, which reports the same two numbers about once a second.
extension DeviceControl: AppPerformance {
    public var launchMethod: String { "iOS's first-frame signpost, the time Xcode reports as launch time" }

    /// iPhones time the screen: see `coldLaunch`.
    public var timesLaunches: Bool { isSimulator }

    private func requireSimulator(_ what: String) throws {
        guard isSimulator else {
            throw DeveloperError(
                "\(what) works on simulators and Android. On an iPhone, measure_launch times the screen (method screen), or record the App Launch template with record_trace and open it in Instruments.")
        }
    }

    public func sample(_ bundleID: String, seconds: TimeInterval) async throws -> PerformanceSample {
        if !isSimulator { return try await sampleWithInstruments(bundleID, seconds: seconds) }
        let pid = try await runningPid(of: bundleID)
        let sampler = UsageSampler(seconds: seconds, interval: UsageSampler.interval(for: seconds)) {
            Self.usage(of: pid).map { ($0.cpuSeconds, $0.footprintMB) }
        }
        guard let result = try await sampler.run() else {
            throw DeveloperError("\(bundleID) ended before Mobdev could read it. Start it with launch_app.")
        }
        return PerformanceSample(
            pid: Int(pid), points: result.points, averageCPU: result.averageCPU, memoryKind: "physical footprint",
            ended: result.ended ? "\(bundleID) ended after \(String(format: "%.1f", result.points.last?.time ?? 0)) s." : nil)
    }

    /// The pid of the app's process, which runs on this Mac, from `launchctl list` inside the
    /// simulator. Its path must lie in this simulator's folder, or in the runtime for Apple's apps.
    func runningPid(of bundleID: String) async throws -> pid_t {
        let list = try await simctl(["spawn", udid, "launchctl", "list"])
        guard let pid = Self.pid(of: bundleID, inLaunchctlList: list) else {
            throw DeveloperError("\(bundleID) is not running on this simulator. Start it with launch_app first.")
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            throw DeveloperError("\(bundleID) ended before Mobdev could read it. Start it with launch_app.")
        }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        if path.contains("/CoreSimulator/Devices/"), !path.contains("/CoreSimulator/Devices/\(udid)/") {
            throw DeveloperError("The simulator named a process of another simulator for \(bundleID): \(path)")
        }
        return pid
    }

    /// Records the Activity Monitor template attached to the app for `seconds` and reads its
    /// per-process table. Instruments takes several seconds to start and to save around that.
    private func sampleWithInstruments(_ bundleID: String, seconds: TimeInterval) async throws -> PerformanceSample {
        let (app, pid) = try await runningApp(bundleID)
        let trace = Self.temporaryTrace()
        defer { try? FileManager.default.removeItem(at: trace) }
        let xctrace = Xctrace(runner: runner)
        try await recordAttached(xctrace, template: "Activity Monitor", app: app, pid: pid, seconds: seconds, output: trace)
        let rows = try await xctrace.export(trace, schema: "activity-monitor-process-live").flatMap(ActivityMonitor.processRows)
        guard var sample = ActivityMonitor.sample(rows, pid: pid) else {
            throw DeveloperError("Instruments recorded no readings of \(bundleID) (pid \(pid)). Is it still running?")
        }
        if let last = sample.points.last, last.time < seconds - 3 {
            sample.ended = "Instruments read \(bundleID) for \(String(format: "%.1f", last.time)) s of \(Int(seconds)); it may have ended."
        }
        return sample
    }

    /// The app and the pid of its process on an iPhone, from devicectl.
    func runningApp(_ bundleID: String) async throws -> (app: InstalledApp, pid: Int) {
        guard let app = try await app(bundleID) else { throw DeveloperError("\(bundleID) is not installed.") }
        guard let pid = try await runningPids(of: app).first else {
            throw DeveloperError("\(bundleID) is not running. Start it with launch_app first.")
        }
        return (app, pid)
    }

    /// Attaches by pid. xctrace sometimes does not find a process on a simulator, the same app's
    /// pid one minute and not the next (iOS 27, 2026-10-28), so it tries again after a pause, then
    /// by the app's executable name.
    private func recordAttached(
        _ xctrace: Xctrace, template: String, app: InstalledApp, pid: Int, seconds: TimeInterval, output: URL
    ) async throws {
        let targets = [String(pid), String(pid)] + (Self.executableName(app).map { [$0] } ?? [])
        for (index, target) in targets.enumerated() {
            do {
                try await xctrace.record(template: template, device: udid, target: .attach(target), seconds: seconds, output: output)
                return
            } catch let error as DeveloperError where error.description.contains("Cannot find process") {
                guard index < targets.count - 1 else {
                    throw DeveloperError(
                        "Instruments did not find \(app.bundleID) (pid \(pid)) on the device: \(error.description) Try again in a few seconds, or record every process (no bundle_id).")
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// "…/My.app/" → "My", the name of the app's process; nil when the location is unknown.
    static func executableName(_ app: InstalledApp) -> String? {
        guard let location = app.location else { return nil }
        let path = location.hasPrefix("file://") ? URL(string: location)?.path ?? location : location
        if let executable = NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("Info.plist"))?["CFBundleExecutable"] as? String {
            return executable
        }
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : nil
    }

    static func temporaryTrace() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-\(UUID().uuidString).trace")
    }

    /// Lines like "41077\t0\tUIKitApplication:com.apple.Preferences[e5a5][rb-legacy]"; "-" stands
    /// for an app that is not running.
    static func pid(of bundleID: String, inLaunchctlList text: String) -> pid_t? {
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[2].hasPrefix("UIKitApplication:\(bundleID)["), let pid = pid_t(fields[0]), pid > 0
            else { continue }
            return pid
        }
        return nil
    }

    /// CPU time in seconds and physical footprint in MB of a process on this Mac, nil once it ended.
    static func usage(of pid: pid_t) -> (cpuSeconds: Double, footprintMB: Double)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // The times are in Mach ticks, not nanoseconds, on Apple silicon.
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        return (ticks * machTickNanoseconds / 1e9, Double(info.ri_phys_footprint) / 1_048_576)
    }

    static let machTickNanoseconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)
    }()

    /// Streams the simulator's `ApplicationFirstFramePresentation` signposts while the app starts:
    /// SpringBoard begins one when it gets the launch request and the app ends it when its first
    /// frame is on screen. That interval is the launch time Xcode's Organizer and MetricKit report.
    public func coldLaunch(_ bundleID: String) async throws -> LaunchTiming {
        try requireSimulator("Timing a launch from the system")
        let apps = Self.simctlApps(from: try await simctl(["listapps", udid]))
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else {
            throw DeveloperError("\(bundleID) is not installed on this simulator.")
        }
        let executable = app.location.flatMap { location -> String? in
            let path = location.hasPrefix("file://") ? URL(string: location)?.path ?? location : location
            return NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("Info.plist"))?["CFBundleExecutable"]
                as? String
        }
        _ = try? await runner.run(Self.xcrun, ["simctl", "terminate", udid, bundleID], timeout: 20)
        try await Task.sleep(nanoseconds: 1_000_000_000)  // Until SpringBoard has taken the app down.

        let watch = SignpostWatch(executable: executable)
        let stream = try runner.start(
            Self.xcrun,
            [
                "simctl", "spawn", udid, "log", "stream", "--signpost", "--style", "ndjson", "--timeout", "60s",
                "--predicate", "signpostName == \"ApplicationFirstFramePresentation\"",
            ], onLine: watch.receive, onExit: { _ in watch.finish() })
        defer { stream.stop() }
        // The stream says "Filtering the log data…" once it listens; a launch before that is missed.
        guard await watch.wait(timeout: 15, for: \.listening) else {
            throw DeveloperError("The simulator's log stream did not start within 15 seconds.")
        }
        try await simctl(["launch", udid, bundleID])
        guard await watch.wait(timeout: 45, for: { $0.duration != nil }) else {
            throw DeveloperError(
                watch.state.get().begin == nil
                    ? "iOS did not report the launch of \(bundleID) within 45 seconds."
                    : "\(bundleID) showed no first frame within 45 seconds.")
        }
        return LaunchTiming(milliseconds: (watch.state.get().duration ?? 0) * 1000)
    }
}

// MARK: - Device load and traces on simulators and iPhones

extension DeviceControl {
    /// How long `deviceLoad` reads: two readings a second apart on a simulator, a recording this
    /// long on an iPhone.
    static let loadSeconds: TimeInterval = 3

    public func deviceLoad() async throws -> DeviceLoad {
        isSimulator ? try await simulatorLoad() : try await instrumentsLoad()
    }

    /// The simulator's processes are processes on this Mac: those its launchd lists, read twice a
    /// second apart. Memory and the thermal state are the Mac's, which the simulator shares.
    private func simulatorLoad() async throws -> DeviceLoad {
        let pids = Self.pids(inLaunchctlList: try await simctl(["spawn", udid, "launchctl", "list"]))
        let ownPids = pids.filter { pid in Self.path(of: pid).map(isSimulatorProcess) ?? false }
        var first: [pid_t: (cpuSeconds: Double, footprintMB: Double)] = [:]
        for pid in ownPids { first[pid] = Self.usage(of: pid) }
        let started = Date()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let elapsed = max(Date().timeIntervalSince(started), 0.1)
        let processes = ownPids.compactMap { pid -> DeviceLoad.Process? in
            guard let before = first[pid], let after = Self.usage(of: pid), let path = Self.path(of: pid) else { return nil }
            return DeviceLoad.Process(
                name: (path as NSString).lastPathComponent, pid: Int(pid),
                cpuPercent: max(after.cpuSeconds - before.cpuSeconds, 0) / elapsed * 100, memoryMB: after.footprintMB)
        }
        return DeviceLoad(
            processes: processes, cpuPercent: processes.map(\.cpuPercent).reduce(0, +),
            cores: ProcessInfo.processInfo.activeProcessorCount,
            memoryUsedMB: processes.map(\.memoryMB).reduce(0, +),
            memoryTotalMB: Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576,
            thermalState: Self.thermalName(ProcessInfo.processInfo.thermalState), memoryKind: "physical footprint",
            seconds: elapsed, source: "the simulator's processes on this Mac (proc_pid_rusage, 1 s apart)",
            note: "A simulator runs on this Mac: CPU is out of the Mac's cores, memory used is what the simulator's processes take together out of the Mac's memory, and the thermal state is the Mac's.")
    }

    /// A process of this simulator: its runtime's system or an app in this simulator's folder.
    private func isSimulatorProcess(_ path: String) -> Bool {
        path.contains(".simruntime/") || path.contains("/CoreSimulator/Devices/\(udid)/")
            || (path.contains("/CoreSimulator/") && !path.contains("/CoreSimulator/Devices/"))
    }

    /// Every pid of a `launchctl list`; "-" stands for a job that is not running.
    static func pids(inLaunchctlList text: String) -> [pid_t] {
        text.split(separator: "\n").compactMap { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).first.flatMap { pid_t($0) }.flatMap { $0 > 0 ? $0 : nil }
        }
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    /// A short Activity Monitor recording of every process on the iPhone.
    private func instrumentsLoad() async throws -> DeviceLoad {
        let trace = Self.temporaryTrace()
        defer { try? FileManager.default.removeItem(at: trace) }
        let xctrace = Xctrace(runner: runner)
        try await xctrace.record(
            template: "Activity Monitor", device: udid, target: .allProcesses, seconds: Self.loadSeconds, output: trace)
        let contents = try? await xctrace.contents(trace)
        let processes = try await xctrace.export(trace, schema: "activity-monitor-process-live").first
        let system = try? await xctrace.export(trace, schema: "activity-monitor-system").first
        let thermal = try? await xctrace.export(trace, schema: "device-thermal-state-intervals").first
        return ActivityMonitor.deviceLoad(
            processes: processes, system: system ?? nil, thermal: thermal ?? nil, memoryBytes: contents?.memoryBytes,
            seconds: contents?.duration ?? Self.loadSeconds)
    }

    /// Records an Instruments template with xctrace, attached to an app, launching it, or for
    /// every process, and reads a summary from the trace where that is cheap.
    public func recordTrace(_ request: TraceRequest) async throws -> TraceRecording {
        let xctrace = Xctrace(runner: runner)
        let template = try await xctrace.template(named: request.template)
        if isSimulator, template == "Activity Monitor" {
            throw DeveloperError(
                "Instruments' Activity Monitor needs an iPhone or this Mac: a simulator has no activity monitoring service. Use performance or device_load, which read the simulator's processes on this Mac.")
        }
        try FileManager.default.createDirectory(at: request.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pid: Int?
        let target: String
        switch request.target {
        case .allProcesses:
            target = "all processes"
            try await xctrace.record(
                template: template, device: udid, target: .allProcesses, seconds: request.seconds, output: request.output)
        case .attach(let bundleID):
            if isSimulator {
                guard let app = try await app(bundleID) else { throw DeveloperError("\(bundleID) is not installed.") }
                let found = Int(try await runningPid(of: bundleID))
                pid = found
                try await recordAttached(xctrace, template: template, app: app, pid: found, seconds: request.seconds, output: request.output)
            } else {
                let (app, found) = try await runningApp(bundleID)
                pid = found
                try await recordAttached(xctrace, template: template, app: app, pid: found, seconds: request.seconds, output: request.output)
            }
            target = "\(bundleID) (pid \(pid ?? 0))"
        case .launch(let bundleID):
            // xctrace starts the app by its bundle ID, on simulators too (checked on iOS 27).
            guard let app = try await app(bundleID) else { throw DeveloperError("\(bundleID) is not installed.") }
            _ = try? await stop(bundleID)
            target = "\(bundleID), launched for the recording"
            try await xctrace.record(
                template: template, device: udid, target: .launch(app.bundleID), seconds: request.seconds,
                output: request.output)
        }
        let contents = try? await xctrace.contents(request.output)
        let summary = await TraceSummary.read(request.output, template: template, contents: contents, pid: pid, xctrace: xctrace)
        return TraceRecording(
            file: request.output, template: template, target: target, seconds: contents?.duration, summary: summary,
            howToOpen: "Open it in Instruments (open \(Shell.quoted(request.output.path)))")
    }
}

/// Follows `log stream --style ndjson` for one launch: the first begin of the first-frame signpost,
/// then the end with the same signpost ID from the app's process.
final class SignpostWatch: Sendable {
    struct State {
        var listening = false
        var finished = false
        var begin: (id: Double, ticks: Double)?
        /// Seconds from the launch request to the first frame.
        var duration: Double?
    }

    let executable: String?
    let state = Locked(State())

    init(executable: String?) { self.executable = executable }

    func receive(_ line: String) {
        if line.hasPrefix("Filtering the log data") {
            state.withLock { $0.listening = true }
            return
        }
        guard line.hasPrefix("{"), let event = try? JSONValue.parse(Data(line.utf8)),
            event["signpostName"]?.stringValue == "ApplicationFirstFramePresentation",
            let id = event["signpostID"]?.doubleValue, let ticks = event["machTimestamp"]?.doubleValue
        else { return }
        let path = event["processImagePath"]?.stringValue ?? ""
        state.withLock { state in
            switch event["signpostType"]?.stringValue {
            case "begin" where state.begin == nil:
                // The message ends with the request's own time, a few milliseconds before the event;
                // anything else there is ignored.
                let requested = (event["eventMessage"]?.stringValue ?? "").split(separator: " ").last
                    .flatMap { Double($0) }
                    .flatMap { $0 <= ticks && (ticks - $0) * DeviceControl.machTickNanoseconds < 5e9 ? $0 : nil }
                state.begin = (id, requested ?? ticks)
            case "end":
                guard let begin = state.begin, begin.id == id, state.duration == nil else { return }
                if let executable, !path.hasSuffix("/" + executable) { return }
                state.duration = max(ticks - begin.ticks, 0) * DeviceControl.machTickNanoseconds / 1e9
            default:
                break
            }
        }
    }

    func finish() { state.withLock { $0.finished = true } }

    /// True once `condition` holds, false after `timeout` or when the stream ended first.
    func wait(timeout: TimeInterval, for condition: @escaping (State) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = state.get()
            if condition(current) { return true }
            if current.finished { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition(state.get())
    }
}

// MARK: - Simulator devices

extension SimulatorDevice {
    public var performance: AppPerformance? { control }

    /// UIKit in a simulator turns this Darwin notification into a shake motion event for the
    /// frontmost app, which React Native and Expo answer with their developer menu. Checked with
    /// Expo Go on iOS 27 (2026-10-07).
    public func developerMenu() async throws -> String? {
        try await control.simctl(["spawn", id, "notifyutil", "-p", "com.apple.UIKit.SimulatorShake"])
        return "Shook the simulator"
    }
}
