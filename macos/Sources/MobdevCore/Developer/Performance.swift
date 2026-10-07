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

/// How an app performs: its CPU and memory over a few seconds, and how long a cold launch takes.
/// Simulators sample the app's process on this Mac and time launches with iOS's own first-frame
/// signpost (`DeviceControl`); Android reads /proc, `dumpsys` and `am start -W` over adb
/// (`AndroidApps`). iPhones have neither without Instruments, so `PhoneBackend.performance` is nil
/// there and `measure_launch` times the screen instead.
public protocol AppPerformance: Sendable {
    /// Samples a running app about once a second for `seconds`.
    func sample(_ bundleID: String, seconds: TimeInterval) async throws -> PerformanceSample
    /// Stops the app, starts it again and returns how long it took to its first frame.
    func coldLaunch(_ bundleID: String) async throws -> LaunchTiming
    /// How `coldLaunch` measures, in a few words for the tool's answer.
    var launchMethod: String { get }
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

// MARK: - Simulators

/// A simulator's app is a process on this Mac, so it is sampled like one: `proc_pid_rusage` gives its
/// CPU time and physical footprint, the memory Xcode's gauge shows. The pid comes from the
/// simulator's own launchd, so an app of the same name in another simulator is never measured.
extension DeviceControl: AppPerformance {
    public var launchMethod: String { "iOS's first-frame signpost, the time Xcode reports as launch time" }

    private func requireSimulator(_ what: String) throws {
        guard isSimulator else {
            throw DeveloperError(
                "\(what) works on simulators and Android. On an iPhone, record with Instruments: xcrun xctrace record --template 'Activity Monitor' --device <udid> --attach <app name> --time-limit 10s, and open the trace in Instruments.")
        }
    }

    public func sample(_ bundleID: String, seconds: TimeInterval) async throws -> PerformanceSample {
        try requireSimulator("Sampling an app's CPU and memory")
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
