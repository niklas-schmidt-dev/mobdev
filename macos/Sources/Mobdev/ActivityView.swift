import MobdevCore
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.activity.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet", systemImage: "waveform.path.ecg",
                    description: Text("Every action an agent takes on the phone appears here."))
            } else {
                Table(model.activity) {
                    TableColumn("Time") { entry in
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 80, max: 100)
                    TableColumn("Action") { entry in
                        Label {
                            Text(entry.tool)
                        } icon: {
                            Image(systemName: entry.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(entry.failed ? .red : .green)
                        }
                    }
                    .width(min: 110, ideal: 130, max: 180)
                    TableColumn("From") { entry in
                        Text(entry.source == "relay" ? "Remote" : "This Mac")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 80, max: 110)
                    TableColumn("Result") { entry in
                        Text(entry.summary)
                            .foregroundStyle(entry.failed ? .red : .primary)
                            .lineLimit(2)
                            .help(entry.summary)
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .navigationSubtitle(model.activity.isEmpty ? "Agent actions on the phone" : "\(model.activity.count) actions")
        .toolbar {
            ToolbarItem {
                Button("Clear", systemImage: "trash") { model.clearActivity() }
                    .disabled(model.activity.isEmpty)
            }
        }
    }
}
