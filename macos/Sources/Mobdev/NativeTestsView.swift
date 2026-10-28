import AppKit
import MobdevCore
import SwiftUI

/// A project's native tests: the app's own XCTest, XCUITest and Swift Testing suite through Xcode,
/// or its Gradle tests, run on the chosen device with the same tool agents use
/// (`run_native_tests`). Shows the suite that runs, the run's progress, and every failure with
/// its file and line; the result bundle opens in Xcode.
struct NativeTestsView: View {
    @Environment(AppModel.self) private var model
    let project: TestProject
    /// The devices that can run tests, and the one chosen (empty for the first).
    let devices: [DeviceState]
    @Binding var deviceID: String
    @State private var selectedTest: String?
    /// What runs on the chosen device, or why nothing can. Finding it walks the repository, so it
    /// is found again only when the project or the device's platform changes.
    @State private var plan: Result<NativeTestPlan, ToolProblem>?

    private var device: DeviceState? { devices.first { $0.id == deviceID } ?? devices.first }
    /// The device's platform; without a device the plan's, found with it as run_native_tests picks.
    private var devicePlatform: NativePlatform? { device.map { NativePlatform($0.kind) } }
    private var platform: NativePlatform {
        if let devicePlatform { return devicePlatform }
        if case .success(let plan)? = plan { return plan.platform }
        return .ios
    }
    private var result: NativeTestResult? { model.nativeResult(project.folder) }
    private var running: Bool { result?.running == true }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            // Fills the pane, header at the top, also without a result below.
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity, alignment: .top)
            if let result, !running, !result.tests.isEmpty || !result.buildErrors.isEmpty {
                NativeTestDetail(test: selected, result: result)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(project.folder.path) \(model.projectRevision(project.folder))") { model.refreshNativeRun(project.folder) }
        .task(id: "\(project.folder.path) \(model.projectRevision(project.folder)) \(devicePlatform?.rawValue ?? "none")") {
            let project = self.project, devicePlatform = self.devicePlatform
            plan = await Task.detached {
                // Without a device, the suite that runs on the Mac when there is one.
                let platform = devicePlatform ?? NativeTestPlan.platformWithoutDevice(project)
                return Result { try NativeTestPlan.resolve(project, platform: platform) }.mapError { ToolProblem(String(describing: $0)) }
            }.value
        }
    }

    private var selected: NativeTestResult.Test? {
        guard let selectedTest else { return result?.tests.first { $0.status == .failed } }
        return result?.tests.first { $0.identifier == selectedTest }
    }

    /// The suite and the newest run, and the device to run on.
    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                switch plan {
                case nil:
                    Text("Finding the suite…").foregroundStyle(.secondary)
                case .success(let plan)?:
                    Text(plan.title.prefix(1).uppercased() + plan.title.dropFirst())
                        .lineLimit(1)
                    Text(plan.needsDevice ? plan.platform.label : "\(plan.platform.label), on this Mac")
                        .font(.callout).foregroundStyle(.secondary)
                case .failure?:
                    Text("No native suite found").foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let result, !running { NativeRunSummary(result: result) }
            RunDevicePicker(devices: devices, deviceID: $deviceID, disabled: running)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var content: some View {
        if let result, result.running, let progress = result.progress {
            NativeProgressView(result: result, progress: progress)
        } else if case .failure(let error)? = plan, result == nil {
            ContentUnavailableView {
                Label("No Native Tests Found", systemImage: "hammer")
            } description: {
                Text(String(describing: error))
                Text(#"Name the suite in mobdev.json: "native_tests": {"ios": {"project": "../App.xcodeproj", "scheme": "App"}, "android": {"gradle_root": "../android"}}"#)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            } actions: {
                Button("Open mobdev.json") { NSWorkspace.shared.open(project.file) }
            }
        } else if let result {
            NativeResultList(result: result, selection: $selectedTest)
        } else {
            ContentUnavailableView {
                Label("Not Run Yet", systemImage: "hammer")
            } description: {
                Text("Run builds the app's tests with \(platform == .android ? "Gradle" : "Xcode") and runs them on \(device?.name ?? "the device"). Agents run the same with run_native_tests.")
            }
        }
    }
}

/// Why no suite was found, as the view shows it.
struct ToolProblem: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The device picker of the Tests views: the devices that can run, or one entry saying there is none.
struct RunDevicePicker: View {
    let devices: [DeviceState]
    @Binding var deviceID: String
    let disabled: Bool

    private struct Option: Identifiable {
        let id: String
        let name: String
    }

    var body: some View {
        let options = devices.isEmpty ? [Option(id: "", name: "No Device Ready")] : devices.map { Option(id: $0.id, name: $0.name) }
        let chosen = devices.first { $0.id == deviceID }?.id ?? devices.first?.id ?? ""
        Picker("Run on", selection: Binding(get: { chosen }, set: { deviceID = $0 })) {
            ForEach(options) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(disabled || devices.isEmpty)
        .help(devices.isEmpty ? "Connect a device or boot a simulator first" : "The device the tests run on")
    }
}

/// "3 passed, 1 failed · iPhone 17 · Today at 14:03", or why the run could not run.
private struct NativeRunSummary: View {
    let result: NativeTestResult

    var body: some View {
        let (passed, failed, skipped) = result.counts
        HStack(spacing: 6) {
            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(result.passed ? .green : .red)
            Text(
                result.error != nil && result.tests.isEmpty
                    ? "Could not run"
                    : [
                        "\(passed) passed", failed > 0 ? "\(failed) failed" : nil, skipped > 0 ? "\(skipped) skipped" : nil,
                        result.cancelled ? "stopped" : nil,
                    ].compactMap { $0 }.joined(separator: ", "))
            Text("·").foregroundStyle(.tertiary)
            Text(result.device?.name ?? "This Mac").foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Text(result.started.relativeText).foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// A run in progress: its phase, how many tests finished, and the newest line of output.
private struct NativeProgressView: View {
    let result: NativeTestResult
    let progress: NativeTestResult.Progress

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(progress.phase == "Testing" && progress.finished > 0
                ? "Testing: \(progress.finished) finished\(progress.failed > 0 ? ", \(progress.failed) failed" : "")"
                : "\(progress.phase)…")
                .font(.headline)
                .monospacedDigit()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Duration.seconds(Int(context.date.timeIntervalSince(result.started))).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(progress.lastLine)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: 560)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The run's tests by suite, failures first within each, and the build's errors above them.
private struct NativeResultList: View {
    let result: NativeTestResult
    @Binding var selection: String?

    private var suites: [(name: String, tests: [NativeTestResult.Test])] {
        var suites: [(name: String, tests: [NativeTestResult.Test])] = []
        for test in result.tests {
            if let index = suites.firstIndex(where: { $0.name == test.suite }) {
                suites[index].tests.append(test)
            } else {
                suites.append((test.suite, [test]))
            }
        }
        return suites.map { ($0.name, $0.tests.sorted { ($0.status == .failed ? 0 : 1) < ($1.status == .failed ? 0 : 1) }) }
    }

    var body: some View {
        List(selection: $selection) {
            if let error = result.error {
                Section {
                    Label {
                        Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                }
            }
            if !result.buildErrors.isEmpty {
                Section("Build Errors") {
                    ForEach(Array(result.buildErrors.enumerated()), id: \.offset) { _, failure in
                        FailureRow(failure: failure)
                    }
                }
            }
            if let note = result.note {
                Section { Text(note).foregroundStyle(.secondary) }
            }
            ForEach(suites, id: \.name) { suite in
                Section(suite.name.isEmpty ? "Tests" : suite.name) {
                    ForEach(suite.tests, id: \.identifier) { test in
                        NativeTestRow(test: test).tag(test.identifier)
                    }
                }
            }
        }
    }
}

private struct NativeTestRow: View {
    let test: NativeTestResult.Test

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.body.weight(.semibold)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(test.name)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(test.status == .failed ? .red : .secondary).lineLimit(1)
                }
            }
            Spacer()
            if test.status != .skipped {
                Text(String(format: "%.2f s", test.seconds)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String? {
        switch test.status {
        case .failed: test.failures.first.map { $0.text.split(separator: "\n").first.map(String.init) ?? "" }
        case .skipped: test.message ?? "Skipped"
        case .passed: nil
        }
    }

    private var symbol: String {
        switch test.status {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        }
    }

    private var tint: Color {
        switch test.status {
        case .passed: .green
        case .failed: .red
        case .skipped: .secondary
        }
    }
}

/// One failure: its place, which opens the file at the line in Xcode, and the message.
private struct FailureRow: View {
    let failure: NativeTestResult.Failure

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let location = failure.location, let file = failure.file {
                Button(location) { NativeFiles.reveal(file, line: failure.line) }
                    .buttonStyle(.link)
                    .help("Open \(file) at this line in Xcode")
            }
            Text(failure.message)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

/// The selected test's failures and attachments, and the run's files.
private struct NativeTestDetail: View {
    let test: NativeTestResult.Test?
    let result: NativeTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(test?.name ?? result.suite).font(.headline).lineLimit(1)
                if let test, test.status != .skipped {
                    Text(String(format: "%.2f s", test.seconds)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if let bundle = result.resultBundle {
                    Button("Open in Xcode") { NSWorkspace.shared.open(URL(fileURLWithPath: bundle)) }
                        .help("Open the result bundle in Xcode, with logs, screenshots and coverage")
                }
                Button("Show Log", systemImage: "doc.text") { NSWorkspace.shared.open(URL(fileURLWithPath: result.log)) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Open everything \(result.platform == .ios ? "xcodebuild" : "Gradle") printed")
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.output)])
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Show results.json, junit.xml and the run's files in Finder")
            }
            if let test {
                if !test.identifier.isEmpty {
                    Text(test.identifier).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if test.status == .failed {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(test.failures.enumerated()), id: \.offset) { _, failure in
                                FailureRow(failure: failure)
                            }
                            if let attachments = test.attachments, !attachments.isEmpty {
                                AttachmentStrip(paths: attachments)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                } else {
                    Text(test.status == .passed ? "Passed." : test.message ?? "Skipped.").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else {
                Text("Select a test to see its failures.").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
    }
}

/// A failure's attachments: pictures as thumbnails, other files by name; a click opens them.
private struct AttachmentStrip: View {
    let paths: [String]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(paths, id: \.self) { path in
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    } label: {
                        if let image = NSImage(contentsOfFile: path), ["png", "jpg", "jpeg", "heic"].contains((path as NSString).pathExtension.lowercased()) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 160)
                                .clipShape(.rect(cornerRadius: 6))
                        } else {
                            Label((path as NSString).lastPathComponent, systemImage: "paperclip")
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open \((path as NSString).lastPathComponent)")
                }
            }
        }
    }
}

/// Opens a test's source in Xcode at the failing line.
enum NativeFiles {
    static func reveal(_ path: String, line: Int?) {
        let xed = URL(fileURLWithPath: "/usr/bin/xed")
        guard let line, FileManager.default.isExecutableFile(atPath: xed.path) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        let process = Process()
        process.executableURL = xed
        process.arguments = ["--line", String(line), path]
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}
