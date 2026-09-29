import CoreBluetooth
import Foundation
import SystemConfiguration

public enum BluetoothState: Sendable, Equatable {
    case starting
    case unauthorized
    case poweredOff
    case unsupported(String)
    case advertising
    case connected(hosts: Int)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .starting: "Starting Bluetooth"
        case .unauthorized: "Bluetooth access not allowed"
        case .poweredOff: "Bluetooth is off"
        case .unsupported(let reason): "Bluetooth unavailable: \(reason)"
        case .advertising: "Waiting for the iPhone to pair"
        case .connected(let hosts): hosts == 1 ? "iPhone paired" : "\(hosts) devices paired"
        case .failed(let message): "Bluetooth failed: \(message)"
        }
    }
}

public enum HIDError: Error, CustomStringConvertible {
    case notConnected

    public var description: String {
        "No iPhone is paired over Bluetooth. On the iPhone open Settings > Bluetooth and tap “\(HIDPeripheral.macName)” under Other Devices."
    }
}

/// The Mac as a Bluetooth LE keyboard and pointer (HID over GATT).
///
/// Classic Bluetooth HID is not an option: `bluetoothd` owns the L2CAP channels. The GATT
/// details below (long-form 0x1812 UUID, encrypted report attributes, Report Reference
/// descriptors, Service Changed for stale caches) follow the notes of sryo/clak and iphone-use.
public final class HIDPeripheral: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate,
    @unchecked Sendable
{
    /// The name iOS lists the Mac under in Settings › Bluetooth. iOS shows the computer name, not the
    /// advertised local name.
    public static var macName: String { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "this Mac" }

    public let localName: String

    private let queue = DispatchQueue(label: "dev.mobdev.bluetooth")
    private let onStateChange: @Sendable (BluetoothState) -> Void
    private let stateBox = Locked<BluetoothState>(.starting)
    private let hostCount = Locked(0)

    // Everything below is only touched on `queue`.
    private var manager: CBPeripheralManager?
    /// Reads the model of each host. Other devices on the same Apple Account, such as an Apple
    /// Watch, also connect to the Mac and subscribe to its keyboard; only iPhones and iPads count.
    private var monitor: CBCentralManager?
    private var hosts: [UUID: Host] = [:]
    private var identifying: [UUID: CBPeripheral] = [:]
    private var servicesToAdd: [CBMutableService] = []
    private var published = false
    private var inputs: [ReportID: CBMutableCharacteristic] = [:]
    private var keyboardOutput: CBMutableCharacteristic?
    private var serviceChanged: CBMutableCharacteristic?
    private var subscriptions: [UUID: Set<ObjectIdentifier>] = [:]
    private var serviceChangedSent = Set<UUID>()
    private var outbox: [(CBMutableCharacteristic, Data, [CBCentral]?)] = []

    private struct Host {
        enum Kind { case identifying, phone, other }
        let central: CBCentral
        var kind = Kind.identifying
        var name: String?
    }

    public init(localName: String = "Mobdev", onStateChange: @escaping @Sendable (BluetoothState) -> Void = { _ in }) {
        self.localName = localName
        self.onStateChange = onStateChange
        super.init()
    }

    public var state: BluetoothState { stateBox.get() }

    public func start() {
        queue.async {
            guard self.manager == nil else { return }
            self.manager = CBPeripheralManager(delegate: self, queue: self.queue)
            self.monitor = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    /// Republishes the GATT database. Helps hosts that cached an old one.
    public func republish() {
        queue.async {
            guard let manager = self.manager, manager.state == .poweredOn else { return }
            manager.stopAdvertising()
            self.publish(manager)
        }
    }

    /// Sends one input report to every subscribed iPhone or iPad.
    public func send(_ id: ReportID, _ bytes: [UInt8]) throws {
        guard hostCount.get() > 0 else { throw HIDError.notConnected }
        queue.async {
            guard let characteristic = self.inputs[id] else { return }
            let phones = self.hosts.values.filter {
                $0.kind == .phone
                    && self.subscriptions[$0.central.identifier]?.contains(ObjectIdentifier(characteristic)) == true
            }
            guard !phones.isEmpty else { return }
            if self.outbox.count > 1024 { self.outbox.removeFirst(self.outbox.count - 1024) }
            self.outbox.append((characteristic, Data(bytes), phones.map(\.central)))
            self.drain()
        }
    }

    // MARK: GATT database

    private static func sig(_ short: String) -> CBUUID {
        CBUUID(string: "0000\(short)-0000-1000-8000-00805F9B34FB")
    }

    private func buildServices() -> [CBMutableService] {
        let changed = CBMutableCharacteristic(
            type: CBUUID(string: "2A05"), properties: [.indicate], value: nil, permissions: [.readable])
        serviceChanged = changed
        let gatt = CBMutableService(type: Self.sig("1801"), primary: true)
        gatt.characteristics = [changed]

        let info = CBMutableCharacteristic(
            type: CBUUID(string: "2A4A"), properties: [.read],
            value: Data([0x11, 0x01, 0x00, 0x02]), permissions: [.readable])
        let reportMap = CBMutableCharacteristic(
            type: CBUUID(string: "2A4B"), properties: [.read],
            value: Data(HIDReportMap.descriptor), permissions: [.readEncryptionRequired])
        let controlPoint = CBMutableCharacteristic(
            type: CBUUID(string: "2A4C"), properties: [.writeWithoutResponse],
            value: nil, permissions: [.writeEncryptionRequired])
        let protocolMode = CBMutableCharacteristic(
            type: CBUUID(string: "2A4E"), properties: [.read, .writeWithoutResponse],
            value: nil, permissions: [.readable, .writeable])

        var characteristics: [CBMutableCharacteristic] = [info, reportMap, controlPoint, protocolMode]
        inputs = [:]
        for id in ReportID.allCases {
            let report = CBMutableCharacteristic(
                type: CBUUID(string: "2A4D"), properties: [.read, .notify],
                value: nil, permissions: [.readEncryptionRequired])
            report.descriptors = [CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([id.rawValue, 1]))]
            inputs[id] = report
            characteristics.append(report)
        }
        let output = CBMutableCharacteristic(
            type: CBUUID(string: "2A4D"), properties: [.read, .write, .writeWithoutResponse],
            value: nil, permissions: [.readEncryptionRequired, .writeEncryptionRequired])
        output.descriptors = [
            CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([ReportID.keyboard.rawValue, 2]))
        ]
        keyboardOutput = output
        characteristics.append(output)

        let hid = CBMutableService(type: Self.sig("1812"), primary: true)
        hid.characteristics = characteristics

        let device = CBMutableService(type: Self.sig("180A"), primary: true)
        device.characteristics = [
            CBMutableCharacteristic(
                type: CBUUID(string: "2A29"), properties: [.read],
                value: Data("Mobdev".utf8), permissions: [.readable]),
            CBMutableCharacteristic(
                type: CBUUID(string: "2A50"), properties: [.read],
                value: Data([0x02, 0xFF, 0xFF, 0x00, 0x01, 0x00, 0x01]), permissions: [.readable]),
        ]

        let battery = CBMutableService(type: Self.sig("180F"), primary: true)
        battery.characteristics = [
            CBMutableCharacteristic(
                type: CBUUID(string: "2A19"), properties: [.read, .notify], value: nil, permissions: [.readable])
        ]

        return [gatt, hid, device, battery]
    }

    private func publish(_ manager: CBPeripheralManager) {
        manager.removeAllServices()
        published = false
        subscriptions = [:]
        hosts = [:]
        serviceChangedSent = []
        outbox = []
        updateHostCount()
        servicesToAdd = buildServices()
        addNextService()
    }

    private func addNextService() {
        guard let manager else { return }
        guard !servicesToAdd.isEmpty else {
            published = true
            advertise()
            return
        }
        manager.add(servicesToAdd.removeFirst())
    }

    private func advertise() {
        guard let manager, published, !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")],
        ])
    }

    // MARK: CBPeripheralManagerDelegate

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Log.info("bluetooth state \(peripheral.state.rawValue)")
        switch peripheral.state {
        case .poweredOn:
            publish(peripheral)
        case .unauthorized:
            setState(.unauthorized)
        case .poweredOff:
            setState(.poweredOff)
        case .unsupported:
            setState(.unsupported("this Mac does not support Bluetooth LE peripherals"))
        default:
            setState(.starting)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            setState(.failed("could not add \(service.uuid): \(error.localizedDescription)"))
            return
        }
        addNextService()
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error, (error as? CBError)?.code != .alreadyAdvertising {
            setState(.failed("advertising failed: \(error.localizedDescription)"))
        } else if hostCount.get() == 0 {
            setState(.advertising)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let value: Data
        switch request.characteristic.uuid {
        case CBUUID(string: "2A4E"): value = Data([0x01])
        case CBUUID(string: "2A19"): value = Data([100])
        case CBUUID(string: "2A4D"): value = Data(count: reportLength(request.characteristic))
        default:
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests where request.characteristic.uuid == CBUUID(string: "2A4C") {
            recoverStaleCacheIfNeeded(request.central)
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic
    ) {
        subscriptions[central.identifier, default: []].insert(ObjectIdentifier(characteristic))
        if hosts[central.identifier] == nil {
            hosts[central.identifier] = Host(central: central)
            identify(central.identifier)
        }
        guard let (id, input) = inputs.first(where: { $0.value === characteristic }) else { return }
        outbox.append((input, Data(count: id.length), [central]))
        drain()
        updateHostCount()
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        subscriptions[central.identifier]?.remove(ObjectIdentifier(characteristic))
        updateHostCount()
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drain()
    }

    // MARK: Identifying hosts

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        for (identifier, host) in hosts where host.kind == .identifying && identifying[identifier] == nil {
            identify(identifier)
        }
    }

    /// Reads the host's model number from its Device Information service over the existing link.
    private func identify(_ identifier: UUID) {
        guard let monitor, monitor.state == .poweredOn else { return }  // Retried once it powers on.
        guard let peripheral = monitor.retrievePeripherals(withIdentifiers: [identifier]).first else {
            classify(identifier, model: nil, name: nil)
            return
        }
        identifying[identifier] = peripheral
        peripheral.delegate = self
        monitor.connect(peripheral)
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, let pending = self.identifying[identifier] else { return }
            self.classify(identifier, model: nil, name: pending.name)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: "180A")])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        classify(peripheral.identifier, model: nil, name: peripheral.name)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "180A") }) else {
            classify(peripheral.identifier, model: nil, name: peripheral.name)
            return
        }
        peripheral.discoverCharacteristics([CBUUID(string: "2A24")], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let model = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "2A24") }) else {
            classify(peripheral.identifier, model: nil, name: peripheral.name)
            return
        }
        peripheral.readValue(for: model)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let model = characteristic.value.flatMap { String(data: $0, encoding: .utf8) }
        classify(peripheral.identifier, model: model, name: peripheral.name)
    }

    /// iPhones and iPads report models like "iPhone17,1". Without a model the name decides, so a
    /// host whose Device Information cannot be read still works unless it calls itself a watch.
    private func classify(_ identifier: UUID, model: String?, name: String?) {
        if let peripheral = identifying.removeValue(forKey: identifier) {
            monitor?.cancelPeripheralConnection(peripheral)
        }
        guard var host = hosts[identifier], host.kind == .identifying else { return }
        let isPhone =
            model.map { $0.hasPrefix("iPhone") || $0.hasPrefix("iPad") }
            ?? !(name ?? "").localizedCaseInsensitiveContains("watch")
        host.kind = isPhone ? .phone : .other
        host.name = name
        hosts[identifier] = host
        Log.info("bluetooth host \(name ?? "unnamed") (\(model ?? "no model")): \(isPhone ? "controlled" : "ignored")")
        updateHostCount()
    }

    // MARK: Helpers

    private func setState(_ state: BluetoothState) {
        let changed = stateBox.withLock { current -> Bool in
            guard current != state else { return false }
            current = state
            return true
        }
        if changed {
            Log.info("bluetooth: \(state.summary)")
            onStateChange(state)
        }
    }

    private func updateHostCount() {
        let inputIDs = Set(inputs.values.map(ObjectIdentifier.init))
        let count = hosts.filter { identifier, host in
            host.kind == .phone && !(subscriptions[identifier] ?? []).isDisjoint(with: inputIDs)
        }.count
        hostCount.set(count)
        if count > 0 {
            setState(.connected(hosts: count))
        } else if published {
            setState(.advertising)
        }
    }

    private func drain() {
        guard let manager else { return }
        while let (characteristic, data, targets) = outbox.first {
            guard manager.updateValue(data, for: characteristic, onSubscribedCentrals: targets) else { return }
            outbox.removeFirst()
        }
    }

    /// A bonded host that trusts a stale GATT cache writes the Control Point but never
    /// subscribes to input reports. Indicating Service Changed makes it rediscover.
    private func recoverStaleCacheIfNeeded(_ central: CBCentral) {
        guard let serviceChanged else { return }
        let subscribed = subscriptions[central.identifier] ?? []
        let hasInput = !subscribed.isDisjoint(with: inputs.values.map(ObjectIdentifier.init))
        guard !hasInput, subscribed.contains(ObjectIdentifier(serviceChanged)),
            !serviceChangedSent.contains(central.identifier)
        else { return }
        serviceChangedSent.insert(central.identifier)
        Log.info("stale GATT cache on \(central.identifier), indicating Service Changed")
        outbox.insert((serviceChanged, Data([0x10, 0x00, 0xFF, 0xFF]), [central]), at: 0)
        drain()
    }

    private func reportLength(_ characteristic: CBCharacteristic) -> Int {
        if characteristic === keyboardOutput { return 1 }
        return inputs.first(where: { $0.value === characteristic })?.key.length ?? 0
    }
}
