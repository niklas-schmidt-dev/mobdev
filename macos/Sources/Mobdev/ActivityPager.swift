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
        let devices = model.hub.devices.filter { device == nil || $0.id == device }
        return devices.flatMap { hardware in
            (hardware.activity.all + (older[hardware.id] ?? [])).map {
                ActivityItem(deviceID: hardware.id, deviceName: hardware.name, entry: $0)
            }
        }
        .sorted { $0.entry.date > $1.entry.date }
    }

    func hasMore(in model: AppModel, device: String?) -> Bool {
        model.hub.devices.contains { (device == nil || $0.id == device) && !exhausted.contains($0.id) }
    }

    /// Reads the next page for each device that still has older entries.
    func loadMore(in model: AppModel, device: String?) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        for hardware in model.hub.devices where (device == nil || hardware.id == device) && !exhausted.contains(hardware.id) {
            let cursor = (older[hardware.id]?.last ?? hardware.activity.all.last)?.date ?? .now
            let log = hardware.activity
            let size = Self.pageSize
            let page = await Task.detached(priority: .userInitiated) { log.older(than: cursor, limit: size) }.value
            if page.count < Self.pageSize { exhausted.insert(hardware.id) }
            older[hardware.id, default: []] += page
        }
    }

    /// Forgets what was read, after a log is cleared.
    func reset() {
        older = [:]
        exhausted = []
    }
}
