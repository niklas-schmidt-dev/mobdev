import CoreGraphics
import Foundation

/// A booted iOS Simulator: its screen from the framebuffer, touches, keys and the Home button as
/// HID events, and apps through `devicectl` and `simctl`. Nothing to set up.
public final class SimulatorDevice: Device, @unchecked Sendable {
    public let id: String
    public let activity: ActivityLog
    public let control: DeviceControl
    private let kit: SimulatorKit
    private let simulator: Locked<BootedSimulator>
    private let cachedSize = Locked<(size: (width: Int, height: Int)?, at: Date)>((nil, .distantPast))

    init(_ simulator: BootedSimulator, kit: SimulatorKit) {
        id = simulator.udid
        self.simulator = Locked(simulator)
        self.kit = kit
        activity = ActivityLog(limit: 1000, file: MobdevPaths.activityFile(device: simulator.udid))
        control = DeviceControl(udid: simulator.udid, reportsFolder: MobdevPaths.crashReportsFolder, simulator: true)
    }

    func update(_ simulator: BootedSimulator) { self.simulator.set(simulator) }

    public var kind: DeviceKind { .simulator }
    public var name: String { simulator.get().name }

    public var info: DeviceInfo? {
        let simulator = simulator.get()
        // An unknown model identifier would show as "iPhone"; the device type's name says more.
        return DeviceInfo(
            id: simulator.udid, name: simulator.name,
            productType: simulator.modelIdentifier.isEmpty || DeviceModels.name(for: simulator.modelIdentifier) == nil
                ? simulator.modelName : simulator.modelIdentifier,
            osVersion: simulator.osVersion, buildVersion: "", deviceClass: simulator.deviceClass)
    }

    public var apps: AppBackend? { control }

    // MARK: PhoneBackend

    public func status() -> PhoneStatus {
        let screen: ScreenState =
            screenSize().map { .connected(name: name, width: $0.width, height: $0.height) }
            ?? .failed("The simulator's screen is not available yet")
        return PhoneStatus(
            screen: screen, bluetooth: .unsupported("not needed for simulators"), keyboardLayout: keyboardLayout(),
            input: .direct("Simulator"))
    }

    private let cachedLayout = Locked<(layout: KeyboardLayout, at: Date)>((.us, .distantPast))

    /// The simulator reads key events with the layout of its keyboard, e.g. German for a simulator
    /// set to German, so keys are sent for that layout. Read from its preferences every 10 seconds.
    private func keyboardLayout() -> KeyboardLayout {
        let cached = cachedLayout.get()
        if Date().timeIntervalSince(cached.at) < 10 { return cached.layout }
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(id)/data/Library/Preferences")
        let keyboards =
            (NSDictionary(contentsOf: preferences.appendingPathComponent("com.apple.keyboard.preferences.plist"))?[
                "KeyboardsCurrentAndNext"] as? [String])
            ?? (NSDictionary(contentsOf: preferences.appendingPathComponent(".GlobalPreferences.plist"))?["AppleKeyboards"]
                as? [String])
            ?? []
        let layout = keyboards.first.map(Self.layout(forKeyboard:)) ?? .us
        cachedLayout.set((layout, Date()))
        return layout
    }

    /// "de_DE@sw=QWERTZ-German;hw=Automatic" is German: an automatic hardware layout follows the
    /// software keyboard. An explicit "hw=" wins.
    static func layout(forKeyboard keyboard: String) -> KeyboardLayout {
        let options = keyboard.split(separator: "@", maxSplits: 1).last.map(String.init) ?? ""
        var values: [String: String] = [:]
        for option in options.split(separator: ";") {
            let parts = option.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        let hardware = values["hw"] ?? "Automatic"
        let source = hardware == "Automatic" ? values["sw"] ?? keyboard : hardware
        return source.localizedCaseInsensitiveContains("German") || source.hasPrefix("QWERTZ") ? .german : .us
    }

    /// The framebuffer's size, looked up at most once a second: status is read often.
    private func screenSize() -> (width: Int, height: Int)? {
        let cached = cachedSize.get()
        if Date().timeIntervalSince(cached.at) < 1, let size = cached.size { return size }
        let size = kit.screenSize(id)
        cachedSize.set((size, Date()))
        return size
    }

    public func frame() -> CGImage? { kit.frame(id) }

    /// Waits inside a gesture without throwing: a cancelled call must still lift the finger or
    /// release the key, or iOS keeps it held.
    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }

    public func tap(at point: NormalizedPoint, hold: TimeInterval) async throws {
        try kit.touch(id, .down, at: point)
        await pause(hold)
        try kit.touch(id, .up, at: point)
    }

    public func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {
        // SimulatorKit keeps drags at least 16 ms apart.
        let steps = max(Int(duration / 0.02), 4)
        let interval = max(duration / Double(steps), 0.017)
        try kit.touch(id, .down, at: start)
        var last = start
        do {
            // A cancelled swipe ends where it got to instead of leaving the finger down.
            for step in 1...steps where !Task.isCancelled {
                await pause(interval)
                let t = Double(step) / Double(steps)
                last = NormalizedPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                try kit.touch(id, .drag, at: last)
            }
            await pause(interval)
        } catch {
            try? kit.touch(id, .up, at: last)
            throw error
        }
        try kit.touch(id, .up, at: last)
    }

    /// As a swipe (see `wheelSwipe`).
    public func scroll(at point: NormalizedPoint, ticks: Int) async throws {
        let (start, end) = wheelSwipe(at: point, ticks: ticks)
        try await swipe(from: start, to: end, duration: 0.35)
    }

    public func pan(at point: NormalizedPoint, ticks: Int) async throws {
        let (start, end) = wheelSwipe(at: point, ticks: ticks, sideways: true)
        try await swipe(from: start, to: end, duration: 0.35)
    }

    /// Stops between keys when cancelled, never inside one.
    public func type(_ strokes: [KeyStroke]) async throws {
        for stroke in strokes {
            try Task.checkCancellation()
            try await press(stroke)
        }
    }

    public func press(_ stroke: KeyStroke) async throws {
        // Modifier bits 0–7 are the HID usages 0xE0–0xE7.
        let modifiers = (0..<8).filter { stroke.modifiers & (1 << $0) != 0 }.map { UInt32(0xE0 + $0) }
        var held: [UInt32] = []
        // Whatever went down goes up again, also when sending fails halfway.
        defer { for usage in held.reversed() { try? kit.key(id, usage: usage, down: false) } }
        for usage in modifiers + [UInt32(stroke.usage)] {
            try kit.key(id, usage: usage, down: true)
            held.append(usage)
        }
        await pause(0.012)
        try kit.key(id, usage: UInt32(stroke.usage), down: false)
        held.removeLast()
        for modifier in modifiers.reversed() {
            try kit.key(id, usage: modifier, down: false)
            held.removeLast()
        }
        await pause(0.008)
    }

    public func press(_ button: ConsumerUsage) async throws {
        switch button {
        case .home:
            try kit.button(id, .home, down: true)
            await pause(0.1)
            try kit.button(id, .home, down: false)
        default:
            throw DeveloperError("The simulator has no \(button) button. Use press_key or the tools for apps.")
        }
    }

    /// Opens an app by its name or bundle ID, without Spotlight.
    public func openApp(named name: String) async throws -> String? {
        let app = try await AppMatcher.find(name, in: control.apps(all: true))
        try await control.activate(app.bundleID)
        return "Opened \(app.name) (\(app.bundleID))."
    }

    /// The frontmost app's accessibility elements, read off the cooperative threads since each
    /// element is a round trip to the simulator.
    public func uiTree() async throws -> [UIElement]? {
        let kit = self.kit, id = self.id
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try kit.elements(id) })
            }
        }
    }
}

/// Picks the app a name means: the exact name or bundle ID, then the one whose bundle ID ends in
/// the name ("Settings" is com.android.settings), then the only one whose name starts with or
/// contains it.
enum AppMatcher {
    static func find(_ query: String, in apps: [InstalledApp]) throws -> InstalledApp {
        let needle = query.trimmingCharacters(in: .whitespaces)
        func folded(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let target = folded(needle)
        let compact = target.filter { !$0.isWhitespace }
        if let exact = apps.first(where: { folded($0.name) == target || $0.bundleID.lowercased() == target }) {
            return exact
        }
        func lastComponent(_ app: InstalledApp) -> String { app.bundleID.lowercased().split(separator: ".").last.map(String.init) ?? "" }
        for test in [{ (app: InstalledApp) in lastComponent(app) == compact },
                     { (app: InstalledApp) in folded(app.name).hasPrefix(target) || lastComponent(app).hasPrefix(compact) },
                     { (app: InstalledApp) in folded(app.name).contains(target) || app.bundleID.lowercased().contains(compact) }] {
            let matches = apps.filter(test)
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 {
                throw DeveloperError(
                    "\"\(needle)\" matches several apps: "
                        + matches.prefix(8).map { "\($0.name) (\($0.bundleID))" }.joined(separator: ", ")
                        + ". Pass the full name or the bundle ID.")
            }
        }
        throw DeveloperError("No app named \"\(needle)\". list_apps with all: true lists every app.")
    }
}
