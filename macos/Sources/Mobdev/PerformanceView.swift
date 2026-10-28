import AppKit
import MobdevCore
import SwiftUI

/// The selected device's performance in its inspector: an app's CPU and memory over a few seconds,
/// the whole device's load, and a trace recorded with Instruments (iPhones, simulators) or
/// Perfetto (Android). Everything runs through the same tools agents use, so it shows in the
/// activity as "You".
struct PerformanceSection: View {
    @Environment(AppModel.self) private var model
    let state: DeviceState

    @State private var apps: [InstalledApp] = []
    @State private var bundleID = ""
    @State private var busy: String?
    @State private var sample: JSONValue?
    @State private var load: JSONValue?
    @State private var trace: JSONValue?
    @State private var failure: String?
    @State private var recording = false

    private var isAndroid: Bool { state.kind == .android }

    var body: some View {
        Section {
            Picker("App", selection: $bundleID) {
                if apps.isEmpty { Text("No Apps").tag("") }
                ForEach(apps, id: \.bundleID) { app in Text(app.title).tag(app.bundleID) }
            }
            .disabled(apps.isEmpty)
            HStack {
                Button("Sample") { Task { await run("performance", ["bundle_id": .string(bundleID), "seconds": 5]) } }
                    .disabled(bundleID.isEmpty || busy != nil)
                    .help("Reads the app's CPU and memory for 5 seconds; it must be running")
                Button("Record Trace…") { recording = true }
                    .disabled(busy != nil)
                Button("Device Load") { Task { await run("device_load", ["count": 5]) } }
                    .disabled(busy != nil)
                    .help("The busiest processes, memory in use and the thermal state right now")
                if let busy {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                }
            }
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let sample { SampleRows(sample: sample) }
            if let load { LoadRows(load: load) }
            if let trace { TraceRows(trace: trace, open: { open($0) }) }
        } header: {
            Text("Performance")
        } footer: {
            Text(footer)
        }
        .task(id: state.id) { await loadApps() }
        .sheet(isPresented: $recording) {
            TraceSheet(isAndroid: isAndroid, appName: apps.first { $0.bundleID == bundleID }?.name) { template, seconds, launch, wholeDevice in
                recording = false
                var arguments: [String: JSONValue] = ["seconds": .number(seconds)]
                if !isAndroid { arguments["template"] = .string(template) }
                if !wholeDevice, !bundleID.isEmpty {
                    arguments["bundle_id"] = .string(bundleID)
                    if launch { arguments["launch"] = true }
                }
                Task { await run("record_trace", arguments) }
            }
        }
    }

    private var footer: String {
        switch state.kind {
        case .iPhone: "Uses Instruments with Developer Mode on the \(state.noun). Instruments needs 10 to 20 seconds more than what it records."
        case .simulator: "A simulator's apps are processes on this Mac, read directly; traces use Instruments."
        case .android: "Reads top, /proc and dumpsys over adb; traces are Perfetto traces for ui.perfetto.dev."
        }
    }

    /// Developer apps first; all apps where there are none, as on a fresh simulator.
    private func loadApps() async {
        for all in [false, true] {
            let output = await model.run("list_apps", on: state.id, ["all": .bool(all)])
            let found = (output.data?["apps"]?.arrayValue ?? output.data?.arrayValue ?? []).compactMap { app -> InstalledApp? in
                guard let id = app["bundle_id"]?.stringValue else { return nil }
                return InstalledApp(
                    bundleID: id, name: app["name"]?.stringValue ?? id, version: app["version"]?.stringValue ?? "",
                    build: app["build"]?.stringValue ?? "", developer: app["developer"]?.boolValue ?? false, location: nil)
            }
            if !found.isEmpty || all {
                apps = found
                if !found.contains(where: { $0.bundleID == bundleID }) { bundleID = found.first?.bundleID ?? "" }
                return
            }
        }
    }

    private func run(_ tool: String, _ arguments: [String: JSONValue]) async {
        busy = switch tool {
        case "performance": "Sampling…"
        case "record_trace": "Recording…"
        default: "Reading…"
        }
        failure = nil
        let output = await model.run(tool, on: state.id, arguments)
        busy = nil
        guard !output.isError, let data = output.data else {
            failure = output.text
            return
        }
        switch tool {
        case "performance": sample = data
        case "record_trace":
            trace = data
            if let path = data["path"]?.stringValue { open(URL(fileURLWithPath: path)) }
        default: load = data
        }
    }

    /// An Instruments trace opens in Instruments; a Perfetto trace is shown in Finder next to
    /// Perfetto's web viewer, which opens files from the disk.
    private func open(_ file: URL) {
        if file.pathExtension == "trace" {
            if let instruments = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Instruments") {
                NSWorkspace.shared.open([file], withApplicationAt: instruments, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(file)
            }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file])
            if let perfetto = URL(string: "https://ui.perfetto.dev") { NSWorkspace.shared.open(perfetto) }
        }
    }
}

/// `performance`'s numbers: CPU average and peak, memory at the start, the end and its peak.
private struct SampleRows: View {
    let sample: JSONValue

    var body: some View {
        let cpu = sample["cpu"], memory = sample["memory_mb"]
        LabeledContent("CPU") {
            Text("\(percent(cpu?["average"])) average, \(percent(cpu?["peak"])) peak").monospacedDigit()
        }
        LabeledContent("Memory") {
            Text("\(megabytes(memory?["start"])) → \(megabytes(memory?["end"])), peak \(megabytes(memory?["peak"]))")
                .monospacedDigit()
        }
        if let frames = sample["frames"], let total = frames["total"]?.doubleValue {
            LabeledContent("Frames") {
                Text("\(Int(total)) rendered, \(percent(frames["janky_percent"])) janky").monospacedDigit()
            }
        }
        if let ended = sample["ended"]?.stringValue {
            Text(ended).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// `device_load`'s numbers: the device's CPU, memory and thermal state, then its busiest processes.
private struct LoadRows: View {
    let load: JSONValue

    var body: some View {
        if let cpu = load["cpu_percent"]?.doubleValue {
            LabeledContent("Device CPU") {
                Text(load["cores"]?.doubleValue.map { "\(Int(cpu / max($0, 1)))% of \(Int($0)) cores" } ?? "\(Int(cpu))% of one core")
                    .monospacedDigit()
            }
        }
        if let used = load["memory_mb"]?["used"]?.doubleValue {
            LabeledContent("Device Memory") {
                Text(load["memory_mb"]?["total"]?.doubleValue.map { "\(gigabytes(used)) of \(gigabytes($0))" } ?? gigabytes(used))
                    .monospacedDigit()
            }
        }
        if let thermal = load["thermal_state"]?.stringValue { LabeledContent("Thermal State", value: thermal) }
        ForEach(Array((load["top_cpu"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, process in
            LabeledContent(process["name"]?.stringValue ?? "?") {
                Text("\(percent(process["cpu"])) · \(megabytes(process["memory_mb"]))").monospacedDigit()
            }
        }
        if let note = load["note"]?.stringValue {
            Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The trace just recorded: where it is, its summary, and buttons to open it again.
private struct TraceRows: View {
    let trace: JSONValue
    let open: (URL) -> Void

    var body: some View {
        if let path = trace["path"]?.stringValue {
            LabeledContent("Trace") {
                Text(URL(fileURLWithPath: path).lastPathComponent).truncationMode(.middle).lineLimit(1)
            }
            ForEach(Array((trace["summary"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, line in
                Text(line.stringValue?.trimmingCharacters(in: .whitespaces) ?? "")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Button("Open") { open(URL(fileURLWithPath: path)) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        }
    }
}

/// Which template to record, for how long, and of what.
private struct TraceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let isAndroid: Bool
    let appName: String?
    let record: (_ template: String, _ seconds: Double, _ launch: Bool, _ wholeDevice: Bool) -> Void

    @State private var templates: [String] = []
    @State private var template = "Time Profiler"
    @State private var seconds = 10.0
    @State private var launch = false
    @State private var wholeDevice = false

    var body: some View {
        Form {
            if isAndroid {
                LabeledContent("Recording", value: "Perfetto")
            } else {
                Picker("Template", selection: $template) {
                    ForEach(templates.isEmpty ? [template] : templates, id: \.self) { Text($0).tag($0) }
                }
            }
            LabeledContent("Duration") {
                Stepper("\(Int(seconds)) s", value: $seconds, in: 1...60, step: 5).monospacedDigit()
            }
            if let appName {
                Toggle("Whole device", isOn: $wholeDevice)
                Toggle("Launch \(appName) for the recording", isOn: $launch)
                    .disabled(wholeDevice || template == "App Launch")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .navigationTitle("Record Trace")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Record") { record(template, seconds, launch || template == "App Launch", wholeDevice || appName == nil) }
                    .disabled(template == "App Launch" && (appName == nil || wholeDevice))
            }
        }
        .task {
            guard !isAndroid else { return }
            templates = (try? await Xctrace().templates()) ?? []
        }
    }
}

private func percent(_ value: JSONValue?) -> String {
    value?.doubleValue.map { String(format: "%.1f%%", $0) } ?? "–"
}

private func megabytes(_ value: JSONValue?) -> String {
    value?.doubleValue.map { String(format: "%.0f MB", $0) } ?? "–"
}

private func gigabytes(_ megabytes: Double) -> String { String(format: "%.1f GB", megabytes / 1024) }
