import MobdevCore
import Observation

/// Continuous loading for activity lists: each device keeps its newest entries in memory, and
/// older ones are read from its log file, a page at a time, when a list scrolls to its end.
@MainActor
@Observable
final class ActivityPager {
    nonisolated static let pageSize = 200

    /// Older entries read from disk, newest first, by device id.
    private var older: [String: [ActivityLog.Entry]] = [:]
    private var exhausted = Set<String>()
    private(set) var isLoading = false

    /// Everything loaded for the device, or for all devices, newest first.
    func items(in model: AppModel, device: String?) -> [ActivityItem] {
        let devices = model.allDevices.filter { device == nil || $0.id == device }
        return devices.flatMap { item in
            (item.activity.all + (older[item.id] ?? [])).map {
                ActivityItem(deviceID: item.id, deviceName: item.name, entry: $0)
            }
        }
        .sorted { $0.entry.date > $1.entry.date }
    }

    func hasMore(in model: AppModel, device: String?) -> Bool {
        model.allDevices.contains { (device == nil || $0.id == device) && !exhausted.contains($0.id) }
    }

    /// Reads the next page for each device that still has older entries.
    func loadMore(in model: AppModel, device: String?) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        for item in model.allDevices where (device == nil || item.id == device) && !exhausted.contains(item.id) {
            let cursor = (older[item.id]?.last ?? item.activity.all.last)?.date ?? .now
            let log = item.activity
            let size = Self.pageSize
            let page = await Task.detached(priority: .userInitiated) { log.older(than: cursor, limit: size) }.value
            if page.count < Self.pageSize { exhausted.insert(item.id) }
            older[item.id, default: []] += page
        }
    }

    /// Forgets what was read, after a log is cleared.
    func reset() {
        older = [:]
        exhausted = []
    }
}
