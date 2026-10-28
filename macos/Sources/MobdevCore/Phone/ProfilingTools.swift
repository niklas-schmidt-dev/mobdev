import Foundation

/// Tools that look at a device the way Instruments and Android Studio do: `record_trace` records an
/// Instruments template with `xctrace` on iPhones and simulators, or a Perfetto trace on Android,
/// into the project's output/traces, and `device_load` shows the whole device's load right now.
/// Both run through `PhoneBackend.performance`.
extension PhoneTools {
    /// The longest trace: Instruments adds 10 to 20 seconds to start and save, which with 60
    /// seconds still fits the relays' 90 seconds per call.
    static let longestTrace: TimeInterval = 60

    static let profilingDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "record_trace", title: "Record trace",
            description:
                "Record a trace for seconds (default 10, at most 60) on the Mac that runs Mobdev, to open in Instruments or Perfetto. iPhones (Developer Mode) and simulators record an Instruments template with xctrace: Time Profiler (default), Allocations, Leaks, Network, Animation Hitches, SwiftUI, Power Profiler, App Launch, Activity Monitor (iPhones), or any other xctrace list templates names. With bundle_id it attaches to the running app, with launch it starts the app for the recording (App Launch always does); without bundle_id it records every process, which is slow for Time Profiler. Android records a Perfetto trace (scheduling, frequencies, graphics, input, activity manager; the app's own trace sections with bundle_id), opened at ui.perfetto.dev. Saved to the project's output/traces (see list_projects), else Mobdev's traces folder, unless path names a file. Returns the path and, where cheap, a summary such as the heaviest functions, hangs, hitches or leaks. Instruments takes 10 to 20 s more than seconds, which still fits a relay's 90 s.",
            inputSchema: schema(
                [
                    "template": [
                        "type": "string",
                        "description": "Instruments template, default Time Profiler; ignored on Android",
                    ],
                    "seconds": ["type": "number", "minimum": 1, "maximum": 60, "description": "Default 10"],
                    "bundle_id": [
                        "type": "string",
                        "description": "The app to record, e.g. com.example.MyApp or an Android package; omit for every process",
                    ],
                    "launch": [
                        "type": "boolean",
                        "description": "Start the app for the recording instead of attaching to it (needs bundle_id)",
                    ],
                    "path": [
                        "type": "string",
                        "description":
                            "An absolute path ending in .trace (Android: .perfetto-trace) in an existing folder. A file there is replaced.",
                    ],
                ], screenshot: false),
            readOnly: false),
        ToolDefinition(
            name: "device_load", title: "Device load",
            description:
                "The whole device's load right now: the busiest processes by CPU (percent of one core) and by memory, memory used and total, and the thermal state where the device has one. iPhones record a 3-second Activity Monitor trace with Instruments (Developer Mode; about 15 s in all); simulators read their processes on this Mac, whose memory and thermal state they share; Android reads top, /proc/meminfo and dumpsys thermalservice.",
            inputSchema: schema(
                ["count": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Processes in each list, default 10"]],
                screenshot: false),
            readOnly: true),
    ]

    func runProfilingTool(_ name: String, _ args: Arguments) async throws -> ToolOutput? {
        switch name {
        case "record_trace": return try await recordTrace(args)
        case "device_load": return try await deviceLoad(args)
        default: return nil
        }
    }

    private func requireProfiling(_ what: String) throws -> AppPerformance {
        guard let performance = phone.performance else {
            if phone.status().input == .bluetooth {
                throw ToolFailure(
                    "\(what) needs Instruments, which reaches an iPhone once Mobdev has read its identity over USB: connect it with a cable and unlock it.")
            }
            throw ToolFailure("This device cannot \(what.lowercased()).")
        }
        return performance
    }

    // MARK: record_trace

    private func recordTrace(_ args: Arguments) async throws -> ToolOutput {
        let android = phone.apps?.platform == .android
        var template = args.has("template") ? try args.string("template", maxLength: 200) : "Time Profiler"
        let seconds = try args.number("seconds", default: 10, range: 1...Self.longestTrace)
        let bundleID = args.has("bundle_id") ? try args.string("bundle_id") : nil
        var launch = args.bool("launch") == true
        if android {
            template = "Perfetto"
        } else if template.caseInsensitiveCompare("App Launch") == .orderedSame {
            // App Launch follows a launch from its start; xctrace refuses it for a running app.
            guard bundleID != nil else { throw ToolFailure("App Launch records an app's launch: pass bundle_id.") }
            launch = true
        }
        if launch, bundleID == nil { throw ToolFailure("launch needs bundle_id: the app to start for the recording.") }
        let performance = try requireProfiling("Recording a trace")
        let fileExtension = android ? "perfetto-trace" : "trace"
        let project = args.has("path") ? nil : projects.current()
        let output = try args.has("path")
            ? Self.tracePath(try args.string("path"), fileExtension: fileExtension)
            : Self.newTraceURL(template: template, fileExtension: fileExtension, in: project)
        if FileManager.default.fileExists(atPath: output.path) { try? FileManager.default.removeItem(at: output) }
        let target: TraceRequest.Target =
            bundleID.map { launch ? .launch(bundleID: $0) : .attach(bundleID: $0) } ?? .allProcesses
        let recording = try await performance.recordTrace(
            TraceRequest(template: template, target: target, seconds: seconds, output: output))
        if let project { projects.notifyOutput(project, .traces) }
        var lines = [
            "Recorded \(recording.template) of \(recording.target)"
                + (recording.seconds.map { String(format: " for %.1f s", $0) } ?? "") + " to \(recording.file.path)."
        ]
        lines += recording.summary
        lines.append(recording.howToOpen + ".")
        return ToolOutput(
            text: lines.joined(separator: "\n"),
            data: [
                "path": .string(recording.file.path), "template": .string(recording.template),
                "target": .string(recording.target), "seconds": recording.seconds.map { .number(($0 * 10).rounded() / 10) } ?? .null,
                "summary": .array(recording.summary.map(JSONValue.string)), "open": .string(recording.howToOpen),
            ])
    }

    /// An absolute path given by the agent, with the trace's extension.
    static func tracePath(_ path: String, fileExtension: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ToolFailure("path must be absolute, e.g. /tmp/launch.\(fileExtension).") }
        guard expanded.hasSuffix("." + fileExtension) else { throw ToolFailure("path must end in .\(fileExtension).") }
        var isFolder: ObjCBool = false
        let folder = (expanded as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            throw ToolFailure("The folder \(folder) does not exist.")
        }
        return URL(fileURLWithPath: expanded)
    }

    /// time-profiler-2026-10-28-153012.trace in the project's output/traces, else in Mobdev's folder.
    static func newTraceURL(template: String, fileExtension: String, in project: URL? = nil) throws -> URL {
        let folder =
            try project.map { try TestProject.output(.traces, in: $0) }
            ?? MobdevPaths.home.appendingPathComponent("traces", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let slug = template.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stem = "\(slug.isEmpty ? "trace" : slug)-\(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent("\(stem).\(fileExtension)")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem)-\(index).\(fileExtension)")
            index += 1
        }
        return url
    }

    // MARK: device_load

    private func deviceLoad(_ args: Arguments) async throws -> ToolOutput {
        let count = Int(try args.number("count", default: 10, range: 1...50))
        let load = try await requireProfiling("Reading the device's load").deviceLoad()
        return ToolOutput(text: Self.describe(load, count: count), data: Self.json(load, count: count))
    }

    static func describe(_ load: DeviceLoad, count: Int) -> String {
        func process(_ process: DeviceLoad.Process) -> String {
            String(format: "%@ (pid %d): %.1f%% CPU, %@", process.name, process.pid, process.cpuPercent, megabytes(process.memoryMB))
        }
        var lines = ["Device load from \(load.source):"]
        if let cpu = load.cpuPercent {
            lines.append(
                "CPU: \(percentage(cpu)) of one core" + (load.cores.map { " (\($0) cores, \(percentage(cpu / Double(max($0, 1)))) of all)" } ?? ""))
        }
        if let used = load.memoryUsedMB {
            lines.append(
                "Memory: \(megabytes(used)) used" + (load.memoryTotalMB.map { " of \(megabytes($0)) (\(percentage(used / max($0, 1) * 100)))" } ?? ""))
        } else if let total = load.memoryTotalMB {
            lines.append("Memory: \(megabytes(total)) in all")
        }
        if let thermal = load.thermalState { lines.append("Thermal state: \(thermal)") }
        if !load.temperatures.isEmpty { lines.append("Temperatures: " + load.temperatures.joined(separator: ", ")) }
        lines.append("Busiest by CPU:")
        lines += load.top(byCPU: count).map { "  " + process($0) }
        lines.append("Largest by memory (\(load.memoryKind)):")
        lines += load.top(byMemory: count).map { "  " + process($0) }
        if let note = load.note { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    static func json(_ load: DeviceLoad, count: Int) -> JSONValue {
        func number(_ value: Double?) -> JSONValue { value.map { .number(($0 * 10).rounded() / 10) } ?? .null }
        func processes(_ list: [DeviceLoad.Process]) -> JSONValue {
            .array(list.map {
                ["name": .string($0.name), "pid": .number(Double($0.pid)), "cpu": number($0.cpuPercent), "memory_mb": number($0.memoryMB)]
            })
        }
        return [
            "source": .string(load.source), "seconds": number(load.seconds), "cpu_percent": number(load.cpuPercent),
            "cores": load.cores.map { .number(Double($0)) } ?? .null,
            "memory_mb": ["used": number(load.memoryUsedMB), "total": number(load.memoryTotalMB), "kind": .string(load.memoryKind)],
            "thermal_state": load.thermalState.map(JSONValue.string) ?? .null,
            "temperatures": .array(load.temperatures.map(JSONValue.string)),
            "processes": .number(Double(load.processes.count)),
            "top_cpu": processes(load.top(byCPU: count)), "top_memory": processes(load.top(byMemory: count)),
            "note": load.note.map(JSONValue.string) ?? .null,
        ]
    }
}
