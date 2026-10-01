import AppKit
import MobdevCore
import SwiftUI
import UniformTypeIdentifiers

/// Record and Run Flow… in the activity header. Recording collects what happens on the device,
/// from agents and from you, and saves it as a flow file that run_flow, this button and
/// `Mobdev flow` in CI play back. Each Run Flow… keeps a video of the run (see `FlowVideos`).
struct FlowButtons: View {
    @Environment(AppModel.self) private var model
    let id: String
    @State private var running = false
    @State private var result: FlowRun?

    var body: some View {
        HStack(spacing: 2) {
            Button("Record Flow", systemImage: "record.circle") { model.startRecording(id) }
                .disabled(model.recording.contains(id) || running)
                .help("Record what happens on this device as a flow you can replay")
            if running {
                ProgressView().controlSize(.small).frame(width: 22)
            } else {
                Button("Run Flow…", systemImage: "play.circle") { chooseAndRun() }
                    .disabled(model.recording.contains(id))
                    .help("Replay a flow file on this device")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .sheet(item: $result) { run in
            FlowResultSheet(run: run) {
                result = nil
                Task { await self.run(run.file) }
            }
        }
    }

    private func chooseAndRun() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a flow to replay on this device."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await run(url) }
    }

    private func run(_ file: URL) async {
        running = true
        var arguments: [String: JSONValue] = ["path": .string(file.path)]
        let video = FlowVideos.newFile(for: file)
        if let video { arguments["video"] = .string(video.path) }
        let output = await model.run("run_flow", on: id, arguments)
        running = false
        result = FlowRun(
            file: file, text: output.text, passed: !output.isError,
            video: video.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
    }
}

struct FlowRun: Identifiable {
    let id = UUID()
    let file: URL
    let text: String
    let passed: Bool
    /// The run's video, when it could be recorded.
    let video: URL?
}

/// Videos of the runs started with Run Flow…, in the app's folder. The newest 20 are kept.
enum FlowVideos {
    static var folder: URL { MobdevPaths.home.appendingPathComponent("flow-videos", isDirectory: true) }
    static let kept = 20

    /// A new file named after the flow and the time, like "sign-in 2026-10-01 at 14.03.22.mp4",
    /// after removing older videos. Nil when the folder cannot be created.
    static func newFile(for flow: URL) -> URL? {
        let files = FileManager.default
        guard (try? files.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let videos = ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "mp4" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (old, _) in videos.dropFirst(kept - 1) { try? files.removeItem(at: old) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "\(flow.deletingPathExtension().lastPathComponent) \(formatter.string(from: Date())).mp4"
        return folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
    }

    static func play(_ video: URL) {
        if let player = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.QuickTimePlayerX") {
            NSWorkspace.shared.open([video], withApplicationAt: player, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(video)
        }
    }
}

/// Shown while recording, under the activity header.
struct RecordingBar: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let count = model.recordedStepCount(id)
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Recording").fontWeight(.medium)
                Text(count == 1 ? "1 step" : "\(count) steps").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Discard") { _ = model.stopRecording(id) }
                    .help("Stop recording without saving")
                Button("Save…") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(count == 0)
                    .help("Stop recording and save the flow")
            }
            .controlSize(.small)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.red.opacity(0.1), in: .rect(cornerRadius: 10))
        }
        .accessibilityElement(children: .contain)
    }

    /// Recording goes on when the save panel is cancelled, so nothing is lost by accident.
    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(model.state(id)?.name ?? "Device") flow.json"
        panel.message = "Save the recorded steps. Replay them with Run Flow…, run_flow or Mobdev flow."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let flow = Flow(name: url.deletingPathExtension().lastPathComponent, steps: model.stopRecording(id))
        do {
            try flow.encoded().write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

private struct FlowResultSheet: View {
    let run: FlowRun
    let again: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                run.passed ? "Flow passed" : "Flow failed",
                systemImage: run.passed ? "checkmark.circle.fill" : "xmark.octagon.fill"
            )
            .font(.title3.weight(.semibold))
            .foregroundStyle(run.passed ? .green : .red)
            Text(run.file.lastPathComponent).foregroundStyle(.secondary)
            ScrollView {
                Text(run.text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([run.file]) }
                    .help("Show the flow file in the Finder")
                if let video = run.video {
                    Menu("Show Video") {
                        Button("Play in QuickTime Player") { FlowVideos.play(video) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([video]) }
                    } primaryAction: {
                        FlowVideos.play(video)
                    }
                    .fixedSize()
                    .help("Watch a recording of this run")
                }
                Spacer()
                Button("Run Again") { again() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }
}
