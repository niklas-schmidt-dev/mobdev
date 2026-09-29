import MobdevCore
import SwiftUI

/// Every agent action across all devices, newest first, with each entry's device. Filter by device
/// or search tools, summaries and device names.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var device: String?
    @State private var query = ""

    private var items: [ActivityItem] {
        model.activity.filter { item in
            (device == nil || item.deviceID == device)
                && (query.isEmpty || item.entry.summary.localizedCaseInsensitiveContains(query)
                    || ToolIcon.title(for: item.entry.tool).localizedCaseInsensitiveContains(query)
                    || item.deviceName.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        let items = self.items
        Group {
            if model.activity.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet", systemImage: "waveform.path.ecg",
                    description: Text("Every action an agent takes on any of your devices appears here."))
            } else if items.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(items) { item in
                    ActivityRow(entry: item.entry, deviceName: item.deviceName)
                }
            }
        }
        .navigationTitle("Activity")
        .navigationSubtitle(subtitle(items.count))
        .searchable(text: $query, placement: .toolbar, prompt: "Search activity")
        .toolbar {
            ToolbarItem {
                // Text items, so the toolbar shows which device is picked, not just an icon.
                Picker("Device", selection: $device) {
                    Text("All Devices").tag(String?.none)
                    Divider()
                    ForEach(model.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Show one device's activity")
            }
            ToolbarItem {
                Button("Clear", systemImage: "trash") { model.clearActivity(device: device) }
                    .disabled(items.isEmpty)
                    .help(device == nil ? "Clear the activity of every device" : "Clear this device's activity")
            }
        }
    }

    private func subtitle(_ count: Int) -> String {
        let scope = device.flatMap { id in model.devices.first { $0.id == id }?.name } ?? "all devices"
        return model.activity.isEmpty ? "All devices" : "\(count) actions on \(scope)"
    }
}
