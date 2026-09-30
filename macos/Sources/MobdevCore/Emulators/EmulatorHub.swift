import Foundation

/// Finds booted iOS simulators and Android devices and keeps one `Device` for each while it is
/// there. Simulators come from CoreSimulator in this process; Android devices from a running adb
/// server, which Mobdev never starts itself.
public final class EmulatorHub: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.mobdev.emulators")
    private let list = Locked<[any Device]>([])
    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var readingDetails: Set<String> = []
    private var adbMisses = 0
    private let adb: ADB?

    public init(adb: ADB? = ADB.find(), onChange: @escaping @Sendable () -> Void) {
        self.adb = adb
        self.onChange = onChange
    }

    /// A fixed list, for tests.
    init(devices: [any Device]) {
        adb = nil
        onChange = {}
        list.set(devices)
    }

    /// Simulators first, then Android, each by name.
    public var devices: [any Device] {
        list.get().sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .simulator }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public var isRunning: Bool { queue.sync { timer != nil } }

    /// Looks every 3 seconds.
    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 3, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.scan() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Stops looking and forgets the devices.
    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            let devices = self.list.get()
            guard !devices.isEmpty else { return }
            self.list.set([])
            devices.forEach(Self.close)
            self.onChange()
        }
    }

    /// Ends what a device that went away still runs: logcat processes, simulator HID clients.
    private static func close(_ device: any Device) {
        (device as? AndroidDevice)?.close()
        if device.kind == .simulator { SimulatorKit.shared?.forget(device.id) }
    }

    private func scan() {
        var devices = list.get()
        var changed = false

        let booted = SimulatorKit.shared?.bootedSimulators() ?? []
        for simulator in booted {
            if let existing = devices.first(where: { $0.id == simulator.udid }) as? SimulatorDevice {
                if existing.info?.name != simulator.name {
                    existing.update(simulator)
                    changed = true
                }
            } else if let kit = SimulatorKit.shared {
                devices.append(SimulatorDevice(simulator, kit: kit))
                Log.info("simulator \(simulator.name) (\(simulator.udid)) booted")
                changed = true
            }
        }
        var gone = devices.filter { device in device.kind == .simulator && !booted.contains { $0.udid == device.id } }

        // Nil means the adb server did not answer this time (restarting, busy): keep the Android
        // devices and the logs of their apps, unless it stays silent for three rounds.
        let android = adb.flatMap { _ in ADB.devices() }
        adbMisses = android == nil ? adbMisses + 1 : 0
        if let listed = android ?? (adbMisses >= 3 ? [] : nil) {
            gone += devices.filter { device in device.kind == .android && !listed.contains { $0.serial == device.id } }
        }
        if !gone.isEmpty {
            devices.removeAll { device in gone.contains { $0 === device } }
            gone.forEach(Self.close)
            changed = true
        }
        if let adb, let android {
            for listed in android where !devices.contains(where: { $0.id == listed.serial }) && !readingDetails.contains(listed.serial) {
                // Reading name and version takes a moment; the device is listed once they are known.
                readingDetails.insert(listed.serial)
                Task {
                    let details = await AndroidDevice.details(serial: listed.serial, listed: listed.properties, adb: adb)
                    self.queue.async {
                        self.readingDetails.remove(listed.serial)
                        var current = self.list.get()
                        // Stopped meanwhile, or listed already.
                        guard self.timer != nil, !current.contains(where: { $0.id == listed.serial }) else { return }
                        current.append(AndroidDevice(serial: listed.serial, details: details, adb: adb))
                        self.list.set(current)
                        Log.info("android device \(details.name) (\(listed.serial)) connected")
                        self.onChange()
                    }
                }
            }
        }

        if changed {
            list.set(devices)
            onChange()
        }
    }
}
