import AVFoundation
import CoreBluetooth
import Foundation

/// One iPhone or iPad: its screen over USB, its own Bluetooth input once matched, and its own
/// activity log that keeps growing across launches.
public final class HardwareDevice: PhoneBackend, @unchecked Sendable {
    /// The UDID when it was known when the device was first seen, else the capture ID. Never changes.
    public let id: String
    /// The screen capture device's unique ID.
    public let captureID: String
    public let capture: ScreenCapture
    public let activity: ActivityLog
    private let peripheral: HIDPeripheral
    private let layout: Locked<KeyboardLayout>
    private let state: Locked<(info: DeviceInfo?, captureName: String, host: UUID?, input: HIDInput?)>
    private let control = Locked<DeviceControl?>(nil)

    init(
        id: String, captureID: String, captureName: String, info: DeviceInfo?, host: UUID?,
        peripheral: HIDPeripheral, layout: Locked<KeyboardLayout>, onChange: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.captureID = captureID
        self.peripheral = peripheral
        self.layout = layout
        capture = ScreenCapture(onlyDeviceID: captureID) { _ in onChange() }
        activity = ActivityLog(limit: 1000, file: MobdevPaths.activityFile(device: id))
        state = Locked((info, captureName, host, host.map { HIDInput(sink: HostSink(peripheral: peripheral, host: $0)) }))
    }

    public var info: DeviceInfo? { state.get().info }
    public var name: String { state.get().info?.name ?? state.get().captureName }
    /// The Bluetooth host this device's input goes to, once matched.
    public var host: UUID? { state.get().host }
    /// Input for the live mirror; nil until a Bluetooth host is matched.
    public var input: HIDInput? { state.get().input }
    /// Plugged in, whether or not its screen can be captured (a locked iPhone has none).
    public var isOnUSB: Bool { onUSB.get() }
    let onUSB = Locked(false)

    var summary: KnownDevice { KnownDevice(id: id, captureID: captureID, name: name, info: info, host: host) }

    func update(info: DeviceInfo) { state.withLock { $0.info = info } }

    func assign(host: UUID?) {
        state.withLock { current in
            guard current.host != host else { return }
            current.host = host
            current.input = host.map { HIDInput(sink: HostSink(peripheral: peripheral, host: $0)) }
        }
    }

    // MARK: PhoneBackend

    public func status() -> PhoneStatus {
        PhoneStatus(screen: capture.state, bluetooth: bluetooth, keyboardLayout: layout.get())
    }

    /// Connected once this device's host is; otherwise what Bluetooth as a whole is doing.
    public var bluetooth: BluetoothState {
        if let host, peripheral.connectedHosts.contains(where: { $0.id == host }) { return .connected(hosts: 1) }
        if case .connected = peripheral.state { return .advertising }
        return peripheral.state
    }

    public func frame() -> CGImage? { capture.frame() }

    private func requireInput() throws -> HIDInput {
        guard let input, case .connected = bluetooth else { throw HIDError.notConnected }
        return input
    }

    public func tap(at point: NormalizedPoint, hold: TimeInterval) async throws {
        try await requireInput().tap(at: point, hold: hold)
    }

    public func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {
        try await requireInput().swipe(from: start, to: end, duration: duration)
    }

    public func scroll(at point: NormalizedPoint, ticks: Int) async throws {
        try await requireInput().scroll(at: point, ticks: ticks)
    }

    public func type(_ strokes: [KeyStroke]) async throws {
        try await requireInput().type(strokes)
    }

    public func press(_ stroke: KeyStroke) async throws {
        try await requireInput().press(stroke)
    }

    public func press(_ button: ConsumerUsage) async throws {
        try await requireInput().consumer(button)
    }

    public func move(to point: NormalizedPoint) async throws {
        try await requireInput().move(to: point)
    }

    /// Developer tools through Xcode's devicectl, once the device's UDID is known. The same instance
    /// stays for the UDID so captured app output survives between calls.
    public var apps: AppBackend? {
        guard let udid = info?.id else { return nil }
        return control.withLock { control in
            if let control, control.udid == udid { return control }
            let created = DeviceControl(udid: udid, reportsFolder: MobdevPaths.crashReportsFolder)
            control = created
            return created
        }
    }
}

/// A device remembered in devices.json.
struct KnownDevice: Codable, Equatable {
    var id: String
    var captureID: String
    var name: String
    var info: DeviceInfo?
    var host: UUID?
}

/// Finds iPhones and iPads on USB, reads what they are, remembers them, and gives each the
/// Bluetooth host that belongs to it, so several phones can be driven from one Mac.
public final class DeviceHub: @unchecked Sendable {
    public let peripheral: HIDPeripheral
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.mobdev.devices")
    private let layout: Locked<KeyboardLayout>
    private let deviceList = Locked<[HardwareDevice]>([])
    private let screensStarted = Locked(false)
    // Only touched on `queue`.
    private var observers: [NSObjectProtocol] = []
    private var loadedKnown = false

    public init(keyboardLayout: KeyboardLayout, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        layout = Locked(keyboardLayout)
        let hostsChanged = ChangeHandler()
        peripheral = HIDPeripheral(localName: MobdevPaths.appName) { _ in hostsChanged.fire() }
        hostsChanged.set { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.assignHosts()
                self.onChange()
            }
        }
    }

    // MARK: Permissions

    /// Whether macOS has asked for camera access yet. The iPhone screen counts as a camera, so
    /// starting the capture before that shows the prompt.
    public static var screenAccessDetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) != .notDetermined
    }

    /// Whether macOS has asked for Bluetooth access yet. Starting Bluetooth before that shows the prompt.
    public static var bluetoothAccessDetermined: Bool { CBManager.authorization != .notDetermined }

    /// Camera access for screen capture, as a screen state for the UI.
    public var screenAccess: ScreenState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: screensStarted.get() ? .searching : .starting
        case .notDetermined: .starting
        default: .cameraDenied
        }
    }

    // MARK: Devices

    /// Every device seen, connected ones first, then by name.
    public var devices: [HardwareDevice] {
        deviceList.get().sorted { lhs, rhs in
            let left = lhs.capture.state.isConnected, right = rhs.capture.state.isConnected
            if left != right { return left }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// The device a request means: by id, name (case-insensitive) or an id prefix of at least six
    /// characters. Without a query, the only device, or the only one with a screen.
    public func device(matching query: String?) -> HardwareDevice? {
        let list = devices
        guard let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            if list.count == 1 { return list[0] }
            let connected = list.filter { $0.capture.state.isConnected }
            return connected.count == 1 ? connected[0] : nil
        }
        return list.first { $0.id == query || $0.captureID == query }
            ?? list.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
            ?? (query.count >= 6 ? list.first { $0.id.lowercased().hasPrefix(query.lowercased()) } : nil)
    }

    public var keyboardLayout: KeyboardLayout {
        get { layout.get() }
        set { layout.set(newValue) }
    }

    /// Starts screen capture for every iPhone; the first time, macOS asks for camera access.
    public func startScreens() {
        guard !screensStarted.withLock({ let was = $0; $0 = true; return was }) else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in self?.queue.async { self?.startWatching() } }
        default:
            queue.async { self.startWatching() }
        }
    }

    /// Starts the Bluetooth keyboard and pointer; the first time, macOS asks for Bluetooth access.
    public func startBluetooth() {
        peripheral.start()
    }

    /// Looks for new devices and rereads what the connected ones are.
    public func rescan() {
        queue.async { self.scan() }
    }

    private func startWatching() {
        loadKnownDevices()
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    // The device needs a moment before lockdownd answers.
                    self?.queue.asyncAfter(deadline: .now() + 1) { self?.scan() }
                })
        }
        scan()
        // A device can take a few seconds to appear after the screen-capture switch flips.
        queue.asyncAfter(deadline: .now() + 2) { self.scan() }
        onChange()
    }

    private func scan() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            onChange()
            return
        }
        let captures = ScreenCapture.devices()
        let infos = USBDevices.read()
        var list = deviceList.get()
        var changed = false
        for capture in captures {
            let info = Self.info(for: capture, in: infos)
            if let existing = list.first(where: { $0.captureID == capture.id }) {
                if let info, existing.info != info {
                    existing.update(info: info)
                    changed = true
                }
                continue
            }
            // A device listed from USB alone (locked, or seen before) gets its screen now.
            if let info, let index = list.firstIndex(where: { $0.id == info.id }) {
                let old = list[index]
                old.capture.stop()
                list[index] = makeDevice(
                    id: old.id, captureID: capture.id, captureName: capture.name, info: info, host: old.host)
                Log.info("device \(info.name) now captured as \(capture.id)")
                changed = true
                continue
            }
            let device = makeDevice(
                id: info?.id ?? capture.id, captureID: capture.id, captureName: capture.name, info: info, host: nil)
            Log.info("device \(device.name) (\(info?.modelName ?? "unknown model")), capture \(capture.id)")
            list.append(device)
            changed = true
        }
        for device in list {
            let present = infos.contains { $0.id == device.id || $0.id == device.info?.id }
                || captures.contains { $0.id == device.captureID }
            if device.onUSB.get() != present {
                device.onUSB.set(present)
                changed = true
            }
        }
        // On USB but without a picture, usually because it is locked: list it, waiting for its screen.
        for info in infos where !list.contains(where: { $0.id == info.id || $0.info?.id == info.id }) {
            let device = makeDevice(id: info.id, captureID: info.id, captureName: info.name, info: info, host: nil)
            device.onUSB.set(true)
            list.append(device)
            Log.info("device \(info.name) on USB without a screen yet")
            changed = true
        }
        deviceList.set(list)
        assignHosts()
        if changed { saveKnownDevices() }
        onChange()
    }

    private func makeDevice(id: String, captureID: String, captureName: String, info: DeviceInfo?, host: UUID?)
        -> HardwareDevice
    {
        let device = HardwareDevice(
            id: id, captureID: captureID, captureName: captureName, info: info, host: host, peripheral: peripheral,
            layout: layout, onChange: onChange)
        device.capture.start()
        return device
    }

    /// The capture device's UDID is its unique ID on current macOS; the name is the fallback.
    private static func info(for capture: CaptureDeviceInfo, in infos: [DeviceInfo]) -> DeviceInfo? {
        func normalized(_ id: String) -> String { id.uppercased().filter { $0.isLetter || $0.isNumber } }
        return infos.first { normalized($0.id) == normalized(capture.id) }
            ?? infos.first { $0.name == capture.name }
    }

    // MARK: Bluetooth hosts

    /// Gives each connected Bluetooth host to a device: its remembered one, then the device with
    /// the same name, then the only device of the same model, then the only device left.
    private func assignHosts() {
        let hosts = peripheral.connectedHosts
        let devices = deviceList.get()
        var free = hosts.filter { host in !devices.contains { $0.host == host.id } }
        var waiting = devices.filter { device in device.host == nil || !hosts.contains { $0.id == device.host } }
            .filter { $0.capture.state.isConnected || $0.host == nil }
        guard !free.isEmpty, !waiting.isEmpty else { return }

        func take(_ host: BluetoothHost, _ device: HardwareDevice) {
            device.assign(host: host.id)
            free.removeAll { $0.id == host.id }
            waiting.removeAll { $0 === device }
            Log.info("bluetooth host \(host.name ?? "unnamed") drives \(device.name)")
        }
        for host in free {
            if let name = host.name, let device = waiting.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                take(host, device)
            }
        }
        for host in free {
            guard let model = host.model else { continue }
            let sameModel = waiting.filter { $0.info?.productType == model }
            if sameModel.count == 1 { take(host, sameModel[0]) }
        }
        if free.count == 1, waiting.count == 1 { take(free[0], waiting[0]) }
        saveKnownDevices()
    }

    // MARK: Remembering devices

    private func loadKnownDevices() {
        guard !loadedKnown else { return }
        loadedKnown = true
        guard let data = try? Data(contentsOf: MobdevPaths.devicesFile),
            let known = try? JSONDecoder().decode([KnownDevice].self, from: data)
        else { return }
        let list = known.map {
            makeDevice(id: $0.id, captureID: $0.captureID, captureName: $0.name, info: $0.info, host: $0.host)
        }
        deviceList.set(list)
    }

    private func saveKnownDevices() {
        let known = deviceList.get().map(\.summary)
        guard let data = try? JSONEncoder().encode(known) else { return }
        try? MobdevPaths.ensureHome()
        try? data.write(to: MobdevPaths.devicesFile, options: .atomic)
    }

    /// Forgets a device that is not connected, including its activity log.
    public func forget(_ id: String) {
        queue.async {
            var list = self.deviceList.get()
            guard let index = list.firstIndex(where: { $0.id == id }), !list[index].capture.state.isConnected else {
                return
            }
            list.remove(at: index)
            self.deviceList.set(list)
            try? FileManager.default.removeItem(at: MobdevPaths.activityFile(device: id))
            self.saveKnownDevices()
            self.onChange()
        }
    }
}

/// Lets a callback created before `self` exists reach it.
private final class ChangeHandler: Sendable {
    private let handler = Locked<(@Sendable () -> Void)?>(nil)
    func set(_ handler: @escaping @Sendable () -> Void) { self.handler.set(handler) }
    func fire() { handler.get()?() }
}
