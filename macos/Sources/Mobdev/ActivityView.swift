import MobdevCore
import SwiftUI

/// Every agent action across all devices, newest first.
struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.activity.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet", systemImage: "waveform.path.ecg",
                    description: Text("Every action an agent takes on any of your devices appears here."))
            } else {
                List(model.activity) { item in
                    ActivityRow(entry: item.entry, deviceName: model.devices.count > 1 ? item.deviceName : nil)
                }
            }
        }
        .navigationTitle("Activity")
        .navigationSubtitle(model.activity.isEmpty ? "All devices" : "\(model.activity.count) recent actions on all devices")
        .toolbar {
            ToolbarItem {
                Button("Clear", systemImage: "trash") { model.clearActivity() }
                    .disabled(model.activity.isEmpty)
                    .help("Clear the activity of every device")
            }
        }
    }
}
