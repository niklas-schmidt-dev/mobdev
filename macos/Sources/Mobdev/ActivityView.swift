import MobdevCore
import SwiftUI

/// Every agent action across all devices, newest first and grouped by day, with each entry's
/// device. Filter by device or search tools, summaries and device names.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var device: String?
    @State private var query = ""
    @State private var pager = ActivityPager()

    private var items: [ActivityItem] {
        _ = model.activity  // Refresh when new actions come in.
        return pager.items(in: model, device: device).filter { item in
            query.isEmpty || item.entry.summary.localizedCaseInsensitiveContains(query)
                || ToolIcon.title(for: item.entry.tool).localizedCaseInsensitiveContains(query)
                || item.deviceName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let items = self.items
        VStack(spacing: 0) {
            if !model.activity.isEmpty {
                // In the content, not the toolbar: a toolbar menu shows neither title nor selection.
                HStack {
                    Picker("Device", selection: $device) {
                        Text("All Devices").tag(String?.none)
                        Divider()
                        ForEach(model.devices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer()
                    Text(items.count == 1 ? "1 action" : "\(items.count)\(pager.hasMore(in: model, device: device) ? "+" : "") actions")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                Divider()
            }
            if model.activity.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet", systemImage: "waveform.path.ecg",
                    description: Text("Every action an agent takes on any of your devices appears here."))
            } else if items.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(ActivityDay.group(items, date: \.entry.date)) { day in
                        Section(day.title) {
                            ForEach(day.items) { item in
                                ActivityRow(entry: item.entry, deviceName: item.deviceName)
                            }
                        }
                    }
                    if pager.hasMore(in: model, device: device) {
                        LoadMoreRow(page: pager.pagesLoaded) { await pager.loadMore(in: model, device: device) }
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .navigationSubtitle(subtitle)
        .searchable(text: $query, placement: .toolbar, prompt: "Search activity")
        .toolbar {
            ToolbarItem {
                Button("Clear", systemImage: "trash") {
                    model.clearActivity(device: device)
                    pager.reset()
                }
                    .disabled(items.isEmpty)
                    .help(device == nil ? "Clear the activity of every device" : "Clear this device's activity")
            }
        }
    }

    private var subtitle: String {
        device.flatMap { id in model.devices.first { $0.id == id }?.name } ?? "All devices"
    }
}

/// Activity grouped by calendar day, newest first, titled "Today", "Yesterday" or the date.
struct ActivityDay<Item: Identifiable>: Identifiable {
    let id: Date
    let title: String
    let items: [Item]

    static func group(_ items: [Item], date: (Item) -> Date) -> [ActivityDay] {
        let calendar = Calendar.current
        var days: [ActivityDay] = []
        var current: (day: Date, items: [Item])?
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if current?.day != day {
                if let current { days.append(ActivityDay(id: current.day, title: title(for: current.day, calendar: calendar), items: current.items)) }
                current = (day, [])
            }
            current?.items.append(item)
        }
        if let current { days.append(ActivityDay(id: current.day, title: title(for: current.day, calendar: calendar), items: current.items)) }
        return days
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// The last row of an activity list: loads the next page as soon as it scrolls into view, and
/// again after each page while it stays in view. It keeps its identity: a row whose `.id` changed
/// with every new entry made AppKit warn "reentrant operation in its NSTableView delegate. This
/// warning will become an assert in the future" for each one.
struct LoadMoreRow: View {
    /// Pages loaded so far; a new value loads the next.
    let page: Int
    let load: () async -> Void

    var body: some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.small)
            Text("Loading older activity…").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
        .task(id: page) { await load() }
    }
}
