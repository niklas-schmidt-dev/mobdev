import CoreGraphics
import Foundation

/// Tools for the loop of building an app: how it performs (CPU, memory, frames, launch time, with
/// optional budgets that fail the call, so tests can hold an app to them) and the conveniences of
/// React Native and Expo development builds (reload, developer menu). Performance runs through
/// `PhoneBackend.performance`; reloads through Metro on this Mac (`Metro`).
extension PhoneTools {
    static let devLoopDefinitions: [ToolDefinition] = {
        let bundleID: JSONValue = [
            "type": "string", "description": "Bundle ID, e.g. com.example.MyApp, or the package name on Android",
        ]
        let port: JSONValue = [
            "type": "integer", "minimum": 1, "maximum": 65535,
            "description": "Port of Metro on this Mac, default 8081",
        ]
        return [
            ToolDefinition(
                name: "performance", title: "App performance",
                description:
                    "Sample a running app for seconds (default 5, at most 60): average and peak CPU as a percent of one core (above 100 when several cores work), memory at the start, the end and its peak, and on Android its frames (rendered, janky share, 50th to 99th percentile frame times). Budgets make the call fail when the app goes over: max_cpu (average), max_memory_mb (peak) and max_janky_percent, so a test can use it as a check. Simulators and Android; on an iPhone it says how to record with Instruments.",
                inputSchema: schema(
                    [
                        "bundle_id": bundleID,
                        "seconds": ["type": "number", "minimum": 1, "maximum": 60, "description": "Default 5"],
                        "max_cpu": ["type": "number", "minimum": 0, "description": "Fail above this average CPU percent"],
                        "max_memory_mb": ["type": "number", "minimum": 0, "description": "Fail above this peak memory"],
                        "max_janky_percent": [
                            "type": "number", "minimum": 0, "maximum": 100,
                            "description": "Fail above this share of janky frames (Android)",
                        ],
                    ], required: ["bundle_id"], screenshot: false),
                readOnly: true),
            ToolDefinition(
                name: "measure_launch", title: "Measure launch",
                description:
                    "Time an app's cold launch over runs (default 3, at most 10): stop it, start it, measure until its first frame; returns min, median and max in milliseconds and the method. Android uses am start -W, simulators iOS's first-frame signpost (the launch time Xcode reports). method screen instead times from the launch animation until the screen stays still for stable seconds, which includes what the app loads after its first frame; iPhones always use it. A launch or splash screen that stays up longer than stable ends it early: raise stable then. max_ms fails the call when the median is slower. The app keeps running without its output captured; launch_app captures it.",
                inputSchema: schema(
                    [
                        "bundle_id": bundleID,
                        "runs": ["type": "integer", "minimum": 1, "maximum": 10, "description": "Default 3"],
                        "method": [
                            "type": "string", "enum": ["system", "screen"],
                            "description": "system (default where the device has it) or screen",
                        ],
                        "max_ms": ["type": "number", "minimum": 0, "description": "Fail when the median is slower"],
                        "stable": [
                            "type": "number", "minimum": 0.3, "maximum": 10,
                            "description": "method screen: seconds without change that end a launch, default 2",
                        ],
                    ], required: ["bundle_id"]),
                readOnly: false),
            ToolDefinition(
                name: "dev_menu", title: "Developer menu",
                description:
                    "Open the developer menu of a React Native or Expo app in development (Expo Go, a development build or a debug build): shakes a simulator, presses the Menu key on Android. On an iPhone it asks Metro on this Mac to open it in every app connected to it.",
                inputSchema: schema(["port": port]), readOnly: false),
            ToolDefinition(
                name: "reload_app", title: "Reload app",
                description:
                    "Reload a React Native or Expo app's JavaScript, as pressing r in Metro's terminal does: Metro on this Mac tells every app connected to it to reload. When Metro has no connected app, Mobdev opens the developer menu and taps Reload instead. Flutter: press r in the terminal that runs flutter run.",
                inputSchema: schema(["port": port]), readOnly: false),
        ]
    }()

    func runDevLoopTool(_ name: String, _ args: Arguments) async throws -> ToolOutput? {
        switch name {
        case "performance": return try await performance(args)
        case "measure_launch": return try await measureLaunch(args)
        case "dev_menu": return try await developerMenu(port: try metroPort(args))
        case "reload_app": return try await reload(port: try metroPort(args))
        default: return nil
        }
    }

    // MARK: Performance

    private func requirePerformance() throws -> AppPerformance {
        guard let performance = phone.performance else {
            if phone.status().input == .bluetooth {
                throw ToolFailure(
                    "Mobdev cannot read an iPhone app's CPU and memory without Instruments. Record it on this Mac with xcrun xctrace record --template 'Activity Monitor' --device <udid from list_devices> --attach <app name> --time-limit 10s and open the trace in Instruments, or measure on a simulator.")
            }
            throw ToolFailure("This device cannot report an app's performance.")
        }
        return performance
    }

    private func performance(_ args: Arguments) async throws -> ToolOutput {
        let bundleID = try args.string("bundle_id")
        let seconds = try args.number("seconds", default: 5, range: 1...60)
        let maxCPU = args.has("max_cpu") ? try args.number("max_cpu", default: 0, range: 0...10_000) : nil
        let maxMemory = args.has("max_memory_mb") ? try args.number("max_memory_mb", default: 0, range: 0...1_000_000) : nil
        let maxJanky = args.has("max_janky_percent") ? try args.number("max_janky_percent", default: 0, range: 0...100) : nil
        let sample = try await requirePerformance().sample(bundleID, seconds: seconds)
        let text = Self.describe(sample, bundleID: bundleID)
        var over: [String] = []
        if let maxCPU, sample.averageCPU > maxCPU {
            over.append("average CPU \(Self.percentage(sample.averageCPU)) is above max_cpu \(format(maxCPU))%")
        }
        if let maxMemory, sample.peakMemoryMB > maxMemory {
            over.append("peak memory \(Self.megabytes(sample.peakMemoryMB)) is above max_memory_mb \(format(maxMemory))")
        }
        if let maxJanky {
            if let frames = sample.frames {
                if frames.jankyPercent > maxJanky {
                    over.append("\(Self.percentage(frames.jankyPercent)) of frames were janky, above max_janky_percent \(format(maxJanky))")
                }
            } else {
                over.append("max_janky_percent needs frame stats, which only Android reports")
            }
        }
        if !over.isEmpty {
            throw ToolFailure("Over budget: " + over.joined(separator: "; ") + ".\n" + text)
        }
        return ToolOutput(text: text, data: Self.json(sample, bundleID: bundleID, seconds: seconds))
    }

    static func percentage(_ value: Double) -> String { String(format: "%.1f%%", value) }
    static func megabytes(_ value: Double) -> String { String(format: "%.1f MB", value) }

    static func describe(_ sample: PerformanceSample, bundleID: String) -> String {
        let span = sample.points.last?.time ?? 0
        let first = sample.points.first?.memoryMB ?? 0
        let last = sample.points.last?.memoryMB ?? 0
        var lines = [
            "\(bundleID) (pid \(sample.pid)) over \(String(format: "%.1f", span)) s, \(sample.points.count) readings:",
            "CPU: average \(percentage(sample.averageCPU)), peak \(percentage(sample.peakCPU)) of one core",
            "Memory (\(sample.memoryKind)): \(megabytes(first)) at the start, \(megabytes(last)) at the end, peak \(megabytes(sample.peakMemoryMB))",
        ]
        if let pss = sample.pssMB { lines.append("PSS at the end: \(megabytes(pss))") }
        if let frames = sample.frames {
            var line = "Frames: \(frames.total) rendered, \(frames.janky) janky (\(percentage(frames.jankyPercent)))"
            let percentiles = [("50th", frames.p50), ("90th", frames.p90), ("95th", frames.p95), ("99th", frames.p99)]
                .compactMap { name, value in value.map { "\(name) \(String(format: "%.0f", $0)) ms" } }
            if !percentiles.isEmpty { line += "; frame times " + percentiles.joined(separator: ", ") }
            lines.append(line)
        } else if sample.memoryKind == "physical footprint" {
            lines.append("Frames: simulators do not report frame times; use Android or Instruments for them.")
        }
        if let ended = sample.ended { lines.append(ended) }
        return lines.joined(separator: "\n")
    }

    static func json(_ sample: PerformanceSample, bundleID: String, seconds: Double) -> JSONValue {
        func number(_ value: Double?) -> JSONValue { value.map { .number(($0 * 10).rounded() / 10) } ?? .null }
        var frames: JSONValue = .null
        if let stats = sample.frames {
            frames = [
                "total": .number(Double(stats.total)), "janky": .number(Double(stats.janky)),
                "janky_percent": number(stats.jankyPercent), "p50_ms": number(stats.p50), "p90_ms": number(stats.p90),
                "p95_ms": number(stats.p95), "p99_ms": number(stats.p99),
            ]
        }
        return [
            "bundle_id": .string(bundleID), "pid": .number(Double(sample.pid)), "seconds": number(seconds),
            "cpu": ["average": number(sample.averageCPU), "peak": number(sample.peakCPU)],
            "memory_mb": [
                "kind": .string(sample.memoryKind), "start": number(sample.points.first?.memoryMB),
                "end": number(sample.points.last?.memoryMB), "peak": number(sample.peakMemoryMB),
            ],
            "pss_mb": number(sample.pssMB),
            "frames": frames,
            "samples": .array(
                sample.points.map { ["t": number($0.time), "cpu": number($0.cpu), "memory_mb": number($0.memoryMB)] }),
            "ended": sample.ended.map(JSONValue.string) ?? .null,
        ]
    }

    // MARK: Launch time

    private func measureLaunch(_ args: Arguments) async throws -> ToolOutput {
        let bundleID = try args.string("bundle_id")
        let runs = Int(try args.number("runs", default: 3, range: 1...10))
        let maxMS = args.has("max_ms") ? try args.number("max_ms", default: 0, range: 0...600_000) : nil
        let stable = try args.number("stable", default: 2, range: 0.3...10)
        let performance = phone.performance
        let method = args.has("method") ? try args.string("method") : performance == nil ? "screen" : "system"
        guard method == "system" || method == "screen" else { throw ToolFailure("method must be system or screen.") }
        if method == "system", performance == nil {
            throw ToolFailure("This device has no launch timing of its own that Mobdev can read. Pass method screen to time the screen instead.")
        }
        let how: String
        var times: [Double] = []
        var state: String?
        if method == "system", let performance {
            how = performance.launchMethod
            for _ in 0..<runs {
                let timing = try await performance.coldLaunch(bundleID)
                times.append(timing.milliseconds)
                state = timing.state ?? state
            }
        } else {
            how = "the screen, from the launch animation until it stayed still for \(format(stable)) s"
            guard let apps = phone.apps else {
                throw ToolFailure("Launching apps is not available for this device yet: Mobdev has not read its identity over USB.")
            }
            try requireTouch()
            for _ in 0..<runs { times.append(try await screenLaunch(bundleID, apps: apps, stable: stable)) }
        }
        let sorted = times.sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        func ms(_ value: Double) -> String { "\(Int(value.rounded())) ms" }
        let text =
            "Cold launch of \(bundleID), \(runs) run\(runs == 1 ? "" : "s"): min \(ms(sorted[0])), median \(ms(median)), max \(ms(sorted[sorted.count - 1]))"
            + (runs > 1 ? " (\(times.map { String(Int($0.rounded())) }.joined(separator: ", ")) ms)" : "")
            + (state.map { ", launch state \($0)" } ?? "") + ".\nMeasured with \(how)."
        if let maxMS, median > maxMS {
            throw ToolFailure("Over budget: the median launch took \(ms(median)), more than max_ms \(format(maxMS)).\n" + text)
        }
        func number(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }
        return ToolOutput(
            text: text,
            data: [
                "bundle_id": .string(bundleID), "method": .string(method), "how": .string(how),
                "runs_ms": .array(times.map(number)), "min_ms": number(sorted[0]), "median_ms": number(median),
                "max_ms": number(sorted[sorted.count - 1]), "launch_state": state.map(JSONValue.string) ?? .null,
            ])
    }

    /// How long one launch timed on the screen may take.
    static let launchTimeout: TimeInterval = 30

    /// One launch timed on the screen: stops the app, waits for a still screen, starts the app and
    /// watches the frames. The time runs from the first frame that differs, the launch animation,
    /// to the last change before the screen stayed still for `stable` seconds, so how long
    /// devicectl or simctl take to pass the request on does not count. A launch screen shown for
    /// longer than that ends the measurement early.
    func screenLaunch(_ bundleID: String, apps: AppBackend, stable: TimeInterval) async throws -> Double {
        _ = try? await apps.stop(bundleID)
        _ = try? await waitForIdle(timeout: 5, stable: 0.5)
        guard let reference = phone.frame().flatMap(FrameSignature.init) else {
            throw ToolFailure("The screen is not available, so the launch cannot be timed on it.")
        }
        // The launch runs next to the watching; a failed one ends the watch at once.
        let failure = Locked<String?>(nil)
        let launch = Task {
            do { try await apps.activate(bundleID) } catch { failure.set(String(describing: error)) }
        }
        defer { launch.cancel() }
        let started = Date()
        var previous = reference
        var firstChange: Date?
        var lastChange: Date?
        while true {
            if let frame = phone.frame().flatMap(FrameSignature.init) {
                let now = Date()
                if frame.changed(from: previous) >= 0.002 {
                    if firstChange == nil { firstChange = now }
                    lastChange = now
                    previous = frame
                }
            }
            if let failure = failure.get() { throw ToolFailure("Could not launch \(bundleID): \(failure)") }
            if let firstChange, let lastChange, Date().timeIntervalSince(lastChange) >= stable {
                await launch.value
                if let failure = failure.get() { throw ToolFailure("Could not launch \(bundleID): \(failure)") }
                return lastChange.timeIntervalSince(firstChange) * 1000
            }
            if Date().timeIntervalSince(started) > Self.launchTimeout {
                throw ToolFailure(
                    firstChange == nil
                        ? "The screen did not change within \(Int(Self.launchTimeout)) s of launching \(bundleID)."
                        : "The screen kept changing for \(Int(Self.launchTimeout)) s after launching \(bundleID), e.g. an animation that never stops. Use method system where the device has it.")
            }
            try await pause(0.03)
        }
    }

    // MARK: React Native and Expo

    private func metroPort(_ args: Arguments) throws -> Int {
        Int(try args.number("port", default: 8081, range: 1...65535))
    }

    private func developerMenu(port: Int) async throws -> ToolOutput {
        if let done = try await phone.developerMenu() {
            return ToolOutput(text: "\(done) to open the app's developer menu. A release build has none.")
        }
        let peers = try await Metro(port: port).send("devMenu")
        guard !peers.isEmpty else {
            throw ToolFailure(
                "Mobdev cannot shake an iPhone, and no app is connected to Metro on port \(port) to ask instead. Start the app from Metro, shake the iPhone, or use AssistiveTouch › Device › Shake.")
        }
        return ToolOutput(text: "Asked Metro on port \(port) to open the developer menu in \(Self.describe(peers)).")
    }

    private func reload(port: Int) async throws -> ToolOutput {
        var problem: String
        do {
            let peers = try await Metro(port: port).send("reload")
            if !peers.isEmpty {
                try await pause(1.5)  // The bundle loads again before the screenshot.
                return ToolOutput(
                    text: "Metro on port \(port) told \(Self.describe(peers)) to reload.",
                    data: ["via": "metro", "apps": .array(peers.map { .string($0.query) })])
            }
            problem = "Metro runs on port \(port) but no app is connected to it"
        } catch {
            problem = String(describing: error)
        }
        if !problem.hasSuffix(".") { problem += "." }
        guard let opened = try await phone.developerMenu() else {
            throw ToolFailure("\(problem) Mobdev cannot open the developer menu of an iPhone app instead: shake the iPhone and tap Reload.")
        }
        try await pause(1.5)
        if let reload = try await reloadItem() {
            try requireTouch()
            try await phone.tap(at: reload, hold: 0.08)
            return ToolOutput(
                text: "\(problem) \(opened) to open the developer menu and tapped Reload.",
                data: ["via": "developer menu"])
        }
        throw ToolFailure(
            "\(problem) \(opened) to open the developer menu, but it shows no Reload: is this a React Native development build?")
    }

    /// Where the developer menu's Reload is: from the UI tree where there is one, else from text recognition.
    private func reloadItem() async throws -> NormalizedPoint? {
        if let tree = try? await phone.uiTree() {
            let matches = ElementQuery(id: nil, text: "Reload").matches(in: tree)
            let exact = matches.filter { ElementQuery.folded($0.label) == "reload" }
            return (exact.first(where: \.tappable) ?? exact.first ?? matches.first)?.center
        }
        let (frame, _) = try currentFrame()
        let found = try await screenText("Reload", in: frame).matches
        return (found.first(where: \.exact) ?? found.first)?.center
    }

    /// "2 connected apps (role=ios, role=android)", each kind of query once.
    static func describe(_ peers: [Metro.Peer]) -> String {
        var queries: [String] = []
        for query in peers.map(\.query) where !query.isEmpty && !queries.contains(query) { queries.append(query) }
        return "\(peers.count) connected app\(peers.count == 1 ? "" : "s")"
            + (queries.isEmpty ? "" : " (\(queries.joined(separator: ", ")))")
    }
}
