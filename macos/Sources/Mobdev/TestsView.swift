import AppKit
import MobdevCore
import SwiftUI

/// A project's tests: tests/*.json (or Maestro .yaml) next to the mobdev.json naming the app. Run
/// them on a device and see each result with its steps, the failure's screenshot and the video.
/// Agents write and run the same tests through list_tests, save_test, run_tests and test_result,
/// and `Mobdev test` runs them in CI.
struct ProjectTestsView: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    @State private var project: TestProject?
    @State private var problem: String?
    @State private var deviceID = ""
    /// The test last selected, by file name, so the window reopens on it.
    @AppStorage("testsSelectedTest") private var storedTest = ""

    private var selectedTest: Binding<String?> {
        Binding(get: { storedTest.isEmpty ? nil : storedTest }, set: { storedTest = $0 ?? "" })
    }

    private var readyDevices: [DeviceState] { model.devices.filter(\.isReady) }
    private var device: DeviceState? { readyDevices.first { $0.id == deviceID } ?? readyDevices.first }
    private var running: Bool { project.map { model.runningTests.contains($0.folder.path) } ?? false }

    var body: some View {
        Group {
            if let project, project.tests.isEmpty {
                ContentUnavailableView {
                    Label("No Tests Yet", systemImage: "checklist")
                } description: {
                    Text(
                        "Each test is a file in tests/: a list of tool calls (.json) or a Maestro flow (.yaml). Let an agent write one with save_test, or record a flow on a device and save it into tests/."
                    )
                } actions: {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.testsFolder]) }
                }
            } else if let project {
                ProjectView(project: project, selectedTest: selectedTest, devices: readyDevices, deviceID: $deviceID)
            } else {
                ContentUnavailableView {
                    Label("Project Not Readable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem ?? "")
                } actions: {
                    Button("Reload") { reload() }
                }
            }
        }
        .toolbar { toolbar }
        .task(id: "\(folder.path) \(model.projectRevision(folder))") { reload() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Reload", systemImage: "arrow.clockwise") { reload() }
                .help("Read the project's files again")
                .disabled(running)
            // The device is chosen in the project's header: the toolbar draws a picker's menu
            // but not its title, so the choice would be invisible here.
            if running {
                Button("Stop", systemImage: "stop.fill") { project.map(model.stopTests) }
                    .help("Stop after the current step")
            } else {
                Button("Run", systemImage: "play.fill") { run() }
                    .disabled(project == nil || project?.tests.isEmpty == true || device == nil)
                    .help(device == nil ? "Connect a device or boot a simulator first" : "Run every test on \(device?.name ?? "the device")")
            }
        }
    }

    private func reload() {
        guard !running else { return }
        do {
            let loaded = try TestProject.load(folder)
            project = loaded
            problem = nil
            model.loadTestResult(for: loaded)
        } catch {
            project = nil
            problem = String(describing: error)
        }
    }

    private func run() {
        guard let project, let device else { return }
        model.runTests(project, on: device.id)
    }
}

/// The project's tests with their newest results, and the selected test's details.
private struct ProjectView: View {
    @Environment(AppModel.self) private var model
    let project: TestProject
    @Binding var selectedTest: String?
    /// The devices ready to run on, and the one chosen (empty for the first).
    let devices: [DeviceState]
    @Binding var deviceID: String

    private var key: String { project.folder.path }
    private var running: Bool { model.runningTests.contains(key) }
    private var live: [TestRunResult.Test] { model.liveTests[key] ?? [] }
    private var last: TestRunResult? { model.testResults[key] }

    /// The newest outcome of a test: from the run in progress, else the saved run.
    private func outcome(_ slug: String) -> TestRunResult.Test? {
        if running { return live.first { $0.slug == slug } }
        return last?.tests.first { $0.slug == slug }
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                if project.tests.isEmpty {
                    ContentUnavailableView {
                        Label("No Tests Yet", systemImage: "doc.badge.plus")
                    } description: {
                        Text("Add tests/<name>.json in \(project.folder.path), or let an agent save one with save_test.")
                    }
                } else {
                    List(project.tests, id: \.slug, selection: $selectedTest) { test in
                        TestRow(test: test, outcome: outcome(test.slug), waiting: running && outcome(test.slug) == nil)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            detail
                .frame(maxWidth: .infinity, minHeight: 180)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.name).font(.title2.weight(.semibold))
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                    Text("Running \(live.count + 1) of \(project.tests.count)").foregroundStyle(.secondary).monospacedDigit()
                } else if let last {
                    RunSummary(result: last)
                }
            }
            HStack(spacing: 10) {
                Text(project.folder.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.file.path.isEmpty ? project.folder : project.file])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Show mobdev.json in Finder")
            }
            HStack(alignment: .firstTextBaseline) {
                if let bundleID = project.app.bundleID {
                    Text("App: \(bundleID)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                devicePicker
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// What the device picker lists: the ready devices, or one entry saying there is none.
    private struct DeviceOption: Identifiable {
        let id: String
        let name: String
    }

    private var devicePicker: some View {
        let options = devices.isEmpty
            ? [DeviceOption(id: "", name: "No Device Ready")] : devices.map { DeviceOption(id: $0.id, name: $0.name) }
        let chosen = devices.first { $0.id == deviceID }?.id ?? devices.first?.id ?? ""
        return Picker("Run on", selection: Binding(get: { chosen }, set: { deviceID = $0 })) {
            ForEach(options) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(running || devices.isEmpty)
        .help(devices.isEmpty ? "Connect a device or boot a simulator first" : "The device the tests run on")
    }

    @ViewBuilder private var detail: some View {
        if let slug = selectedTest, let test = project.tests.first(where: { $0.slug == slug }) {
            TestDetail(test: test, outcome: outcome(slug), result: running ? nil : last)
        } else {
            ContentUnavailableView {
                Label("Select a Test", systemImage: "checklist")
            } description: {
                Text("Its steps and newest result appear here.")
            }
        }
    }
}

/// "2 passed, 1 failed · Today at 14:03".
private struct RunSummary: View {
    let result: TestRunResult

    var body: some View {
        let (passed, failed, skipped) = result.counts
        HStack(spacing: 6) {
            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(result.passed ? .green : .red)
            Text(
                [
                    "\(passed) passed", failed > 0 ? "\(failed) failed" : nil, skipped > 0 ? "\(skipped) skipped" : nil,
                    result.cancelled ? "cancelled" : nil,
                ].compactMap { $0 }.joined(separator: ", "))
            Text("·").foregroundStyle(.tertiary)
            Text(result.device.name).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Text(result.started, format: .relative(presentation: .named)).foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

private struct TestRow: View {
    let test: TestCase
    let outcome: TestRunResult.Test?
    /// Part of the run in progress and not finished yet.
    let waiting: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if waiting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).foregroundStyle(tint).font(.body.weight(.semibold))
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(test.name)
                Text(subtitle).font(.callout).foregroundStyle(outcome?.status == .failed ? .red : .secondary).lineLimit(1)
            }
            Spacer()
            if !test.platforms.isEmpty {
                Text(test.platforms.map { $0 == "ios" ? "iOS" : "Android" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: .capsule)
            }
            if let outcome, outcome.status != .skipped {
                Text(String(format: "%.1f s", outcome.seconds)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        switch outcome?.status {
        case .failed?: outcome?.message ?? "Failed"
        case .skipped?: outcome?.message ?? "Skipped"
        case .passed?: test.description.isEmpty ? "\(test.steps.count) steps" : test.description
        case nil: test.description.isEmpty ? "\(test.steps.count) steps, not run yet" : test.description
        }
    }

    private var symbol: String {
        switch outcome?.status {
        case .passed?: "checkmark.circle.fill"
        case .failed?: "xmark.octagon.fill"
        case .skipped?: "minus.circle"
        case nil: "circle.dashed"
        }
    }

    private var tint: Color {
        switch outcome?.status {
        case .passed?: .green
        case .failed?: .red
        case .skipped?, nil: .secondary
        }
    }
}

/// The selected test: what it does, and how its newest run went, step by step.
private struct TestDetail: View {
    let test: TestCase
    let outcome: TestRunResult.Test?
    /// The saved run the outcome is from, for its folder.
    let result: TestRunResult?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(test.name).font(.headline)
                    Spacer()
                    Button("Show in Finder", systemImage: "doc") { NSWorkspace.shared.activateFileViewerSelecting([test.file]) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Show \(test.file.lastPathComponent) in Finder")
                    if let outcome, outcome.status == .failed, let video = outcome.video,
                        FileManager.default.fileExists(atPath: video)
                    {
                        Button("Show Video", systemImage: "play.rectangle") { FlowVideos.play(URL(fileURLWithPath: video)) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Open the video of this test's run")
                    }
                }
                if !test.description.isEmpty { Text(test.description).foregroundStyle(.secondary) }
                if let outcome, outcome.status == .failed {
                    Text(outcome.message).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    Text(lines)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            }
            if let outcome, let screenshot = outcome.screenshot {
                FailureImage(path: screenshot)
            }
        }
        .padding(16)
    }

    /// The steps as they ran and what the app printed, or the steps as the file lists them before any run.
    private var lines: String {
        guard let outcome, !outcome.steps.isEmpty else {
            return test.steps.enumerated().map { "\($0 + 1). \($1.summary)" }.joined(separator: "\n")
        }
        var lines = outcome.stepLines
        if let log = outcome.log, !log.isEmpty { lines += ["", "The app printed:"] + log }
        return lines.joined(separator: "\n")
    }
}

/// The screen a test failed on, from its PNG; a click opens the file.
private struct FailureImage: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Open the screenshot of the failure")
                .accessibilityLabel("Screenshot of the failure")
            }
        }
        .frame(maxWidth: 220, maxHeight: 360)
        .task(id: path) { image = NSImage(contentsOfFile: path) }
    }
}
