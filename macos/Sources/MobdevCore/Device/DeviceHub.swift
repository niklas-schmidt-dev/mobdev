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
    private let pointer = Locked<PointerBehavior?>(nil)
    /// The last look at the iPhone's USB interfaces, at most every two seconds.
    private let usb = Locked<(checked: Date, state: USBScreenState?)>((.distantPast, nil))
    private let onChange: @Sendable () -> Void

    init(
        id: String, captureID: String, captureName: String, info: DeviceInfo?, host: UUID?,
        peripheral: HIDPeripheral, layout: Locked<KeyboardLayout>, onChange: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.captureID = captureID
        self.peripheral = peripheral
        self.layout = layout
        self.onChange = onChange
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
            // Another host may be another phone with other settings.
            pointer.set(nil)
        }
    }

    // MARK: PhoneBackend

    public func status() -> PhoneStatus {
        PhoneStatus(screen: screenState, bluetooth: bluetooth, keyboardLayout: layout.get(), pointer: pointer.get())
    }

    /// The capture's state, except that "no picture" from a locked iPhone says so. A locked iPhone
    /// keeps its USB screen interface and sends nothing; a stuck capture helper leaves the iPhone
    /// without that interface (seen 2026-09-30), and only then does restarting the helper help.
    var screenState: ScreenState {
        let state = capture.state
        guard case .noPicture(let name) = state, let udid = info?.id else { return state }
        let probe = usb.withLock { last -> USBScreenState? in
            if Date().timeIntervalSince(last.checked) > 2 { last = (Date(), USBProbe.screenState(udid: udid)) }
            return last.state
        }
        return Self.screenState(state, name: name, usb: probe)
    }

    static func screenState(_ state: ScreenState, name: String, usb: USBScreenState?) -> ScreenState {
        usb?.hasScreenInterface == true ? .locked(name: name) : state
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

    /// Parks the pointer far from `point`, then moves it there and compares the screen before and
    /// after. Nothing is clicked. Takes about a second.
    public func checkPointer(at point: NormalizedPoint) async throws -> PointerBehavior? {
        let input = try requireInput()
        try await input.move(to: PointerCheck.parking(for: point))
        // iOS draws the pointer, and fades a snap outline in, within a few frames.
        try await Task.sleep(for: .milliseconds(400))
        guard let parked = frame() else { return nil }
        try await Task.sleep(for: .milliseconds(150))
        guard let before = frame(), PointerCheck.isStill(parked, before, around: point) else { return nil }
        try await input.move(to: point)
        try await Task.sleep(for: .milliseconds(400))
        guard let after = frame(), var behavior = PointerCheck.classify(before: before, after: after, at: point)
        else { return nil }
        if behavior == .snaps {
            // More than a dot changed, which an item lighting up under the pointer also does.
            let nudge = PointerCheck.nudge(for: point)
            try await input.move(to: nudge)
            try await Task.sleep(for: .milliseconds(400))
            guard let nudged = frame(), let confirmed = PointerCheck.confirm(aimed: after, nudged: nudged, from: point, to: nudge)
            else { return nil }
            behavior = confirmed
        }
        Log.info("pointer check on \(name): \(behavior.rawValue)")
        if pointer.withLock({ let changed = $0 != behavior; $0 = behavior; return changed }) { onChange() }
        return behavior
    }

    /// Whether the pointer of Bluetooth `host` appears on this device's screen when it moves to the
    /// middle, without clicking. Nil when the screen does not tell: no picture, or it changed by
    /// itself. A host that is another iPhone changes nothing here; AssistiveTouch off neither.
    func showsPointer(of host: UUID) async -> Bool? {
        let input = HIDInput(sink: HostSink(peripheral: peripheral, host: host))
        let point = NormalizedPoint(x: 0.5, y: 0.5)
        do {
            try await input.move(to: PointerCheck.parking(for: point))
            try await Task.sleep(for: .milliseconds(400))
            guard let parked = frame() else { return nil }
            try await Task.sleep(for: .milliseconds(150))
            guard let before = frame(), PointerCheck.isStill(parked, before, around: point) else { return nil }
            try await input.move(to: point)
            try await Task.sleep(for: .milliseconds(400))
            guard let after = frame() else { return nil }
            return PointerCheck.classify(before: before, after: after, at: point).map { $0 != .hidden }
        } catch {
            return nil
        }
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
    /// When hosts were last told apart by their pointers, and whether that is running.
    private let identifying = Locked<(running: Bool, last: Date)>((false, .distantPast))

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

    /// The device a request means, or nil when none or several match (see `devices(matching:)`).
    public func device(matching query: String?) -> HardwareDevice? {
        let matches = devices(matching: query)
        return matches.count == 1 ? matches[0] : nil
    }

    /// The devices a request could mean: an exact id, else every device with that name
    /// (case-insensitive), else every id starting with a prefix of at least six characters. Without
    /// a query, the only device, else the ones with a screen.
    public func devices(matching query: String?) -> [HardwareDevice] {
        let list = devices
        let keys = list.map { DeviceKey(id: $0.id, captureID: $0.captureID, name: $0.name, connected: $0.capture.state.isConnected) }
        return Self.matches(query, in: keys).map { list[$0] }
    }

    struct DeviceKey {
        var id: String
        var captureID: String
        var name: String
        var connected: Bool
    }

    static func matches(_ query: String?, in keys: [DeviceKey]) -> [Int] {
        let all = Array(keys.indices)
        guard let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return keys.count == 1 ? all : all.filter { keys[$0].connected }
        }
        let exact = all.filter { keys[$0].id == query || keys[$0].captureID == query }
        if !exact.isEmpty { return exact }
        let named = all.filter { keys[$0].name.caseInsensitiveCompare(query) == .orderedSame }
        if !named.isEmpty { return named }
        guard query.count >= 6 else { return [] }
        return all.filter { keys[$0].id.lowercased().hasPrefix(query.lowercased()) }
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

    /// Starts every iPhone's capture again, after macOS's screen capture helper was restarted.
    public func restartScreens() {
        for device in devices { device.capture.restart() }
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
        watchForScreens()
        onChange()
    }

    /// An iPhone that was locked when it was plugged in is listed from USB alone, and the running app
    /// is not always told when its screen appears. While one waits, look for a screen no device
    /// owns yet, and scan (which also asks lockdownd) only once there is one.
    private func watchForScreens() {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let list = deviceList.get()
            if list.contains(where: { $0.onUSB.get() && !$0.capture.state.isConnected }),
                ScreenCapture.devices().contains(where: { capture in !list.contains { $0.captureID == capture.id } })
            {
                scan()
            }
            watchForScreens()
        }
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

    /// Gives each connected Bluetooth host that belongs to no device to a device without one: the
    /// device with the same name, then the only device of the same model, then the only device left.
    /// A device keeps its host once it has one. While that host is away, the device's input waits for
    /// it rather than going to another host that connects: names and models are only what a host
    /// says about itself, so switching needs the user's word (`useHost(_:for:)`).
    private func assignHosts() {
        let hosts = peripheral.connectedHosts
        let devices = deviceList.get()
        var free = hosts.filter { host in !devices.contains { $0.host == host.id } }
        var waiting = devices.filter { $0.host == nil }
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
        if !free.isEmpty, !waiting.isEmpty { identifyByPointer(free: free, waiting: waiting) }
    }

    /// Names and models do not always tell which iPhone a host is: iOS sometimes calls itself just
    /// "iPhone", and two of the same model look alike. Then each free host moves its pointer, and
    /// the waiting device whose screen shows it gets that host. Nothing is clicked. It needs
    /// AssistiveTouch, runs at most every 20 s, and only for devices that show a picture.
    private func identifyByPointer(free: [BluetoothHost], waiting: [HardwareDevice]) {
        let devices = waiting.filter { $0.status().frameSize != nil }
        guard !devices.isEmpty else { return }
        let start = identifying.withLock { state -> Bool in
            guard !state.running, Date().timeIntervalSince(state.last) > 20 else { return false }
            state = (true, Date())
            return true
        }
        guard start else { return }
        Task {
            defer { identifying.withLock { $0.running = false } }
            for device in devices {
                var results: [UUID: Bool?] = [:]
                for host in free { results[host.id] = await device.showsPointer(of: host.id) }
                guard let owner = Self.owner(from: results) else { continue }
                queue.async {
                    let list = self.deviceList.get()
                    guard device.host == nil, list.contains(where: { $0 === device }), !list.contains(where: { $0.host == owner }),
                        self.peripheral.connectedHosts.contains(where: { $0.id == owner })
                    else { return }
                    device.assign(host: owner)
                    Log.info("bluetooth host \(owner) drives \(device.name): its pointer appeared on that screen")
                    self.saveKnownDevices()
                    self.onChange()
                }
            }
        }
    }

    /// The one host whose pointer appeared, when every other one clearly did not.
    static func owner(from results: [UUID: Bool?]) -> UUID? {
        let shown = results.filter { $0.value == true }.map(\.key)
        guard shown.count == 1, results.values.allSatisfy({ $0 != nil }) else { return nil }
        return shown[0]
    }

    /// For a device whose own Bluetooth host is away: the one connected host that belongs to no
    /// device, which may be the same iPhone paired again. Nil when there is none or several.
    public func replacementHost(for id: String) -> BluetoothHost? {
        let hosts = peripheral.connectedHosts
        let devices = deviceList.get()
        guard let device = devices.first(where: { $0.id == id }), let current = device.host,
            !hosts.contains(where: { $0.id == current })
        else { return nil }
        let free = hosts.filter { host in !devices.contains { $0.host == host.id } }
        return free.count == 1 ? free[0] : nil
    }

    /// Sends a device's input to another connected Bluetooth host from now on, once the user has
    /// confirmed that it is this iPhone (see `replacementHost(for:)`).
    public func useHost(_ host: UUID, for id: String) {
        queue.async {
            let devices = self.deviceList.get()
            guard let device = devices.first(where: { $0.id == id }),
                self.peripheral.connectedHosts.contains(where: { $0.id == host }),
                !devices.contains(where: { $0.host == host })
            else { return }
            device.assign(host: host)
            Log.info("bluetooth host \(host) now drives \(device.name), as confirmed")
            self.saveKnownDevices()
            self.onChange()
        }
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
