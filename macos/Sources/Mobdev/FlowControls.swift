import AppKit
import MobdevCore
import SwiftUI
import UniformTypeIdentifiers

/// Record and Run Flow… in the activity header. Recording collects what happens on the device,
/// from agents and from you, and saves it as a flow file that run_flow, this button and
/// `Mobdev flow` in CI play back.
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
        let output = await model.run("run_flow", on: id, ["path": .string(file.path)])
        running = false
        result = FlowRun(file: file, text: output.text, passed: !output.isError)
    }
}

struct FlowRun: Identifiable {
    let id = UUID()
    let file: URL
    let text: String
    let passed: Bool
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
                Spacer()
                Button("Run Again") { again() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }
}
