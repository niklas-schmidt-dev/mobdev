import CoreGraphics
import Foundation

/// What the HTTP API, MCP and the relay call: one phone (`PhoneTools`) or every device (`DeviceTools`).
public protocol ToolCalling: Sendable {
    var definitions: [ToolDefinition] { get }
    func call(_ name: String, arguments: JSONValue?, source: String, screenshotByDefault: Bool) async throws
        -> ToolOutput
    /// The phone a request addresses by id or name, for the raw screenshot endpoint.
    func phone(for device: String?) throws -> PhoneBackend
}

extension PhoneTools: ToolCalling {
    public var definitions: [ToolDefinition] { Self.definitions }
    public func phone(for device: String?) throws -> PhoneBackend { phone }
}

/// A device as agents, the relay and the dashboard see it. The JSON matches the relay's
/// `devices` frame and `list_devices`.
public struct DeviceSummary: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var model: String
    public var modelName: String
    public var osVersion: String
    public var deviceClass: String
    public var screen: Bool
    public var bluetooth: Bool
    public var ready: Bool

    public init(
        id: String, name: String, model: String, modelName: String, osVersion: String, deviceClass: String,
        screen: Bool, bluetooth: Bool, ready: Bool
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.modelName = modelName
        self.osVersion = osVersion
        self.deviceClass = deviceClass
        self.screen = screen
        self.bluetooth = bluetooth
        self.ready = ready
    }

    enum CodingKeys: String, CodingKey {
        case id, name, model, screen, bluetooth, ready
        case modelName = "model_name"
        case osVersion = "os_version"
        case deviceClass = "device_class"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName) ?? ""
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion) ?? ""
        deviceClass = try container.decodeIfPresent(String.self, forKey: .deviceClass) ?? "iPhone"
        screen = try container.decodeIfPresent(Bool.self, forKey: .screen) ?? false
        bluetooth = try container.decodeIfPresent(Bool.self, forKey: .bluetooth) ?? false
        ready = try container.decodeIfPresent(Bool.self, forKey: .ready) ?? false
    }

    /// What the device artwork needs, for devices known only from the relay.
    public var info: DeviceInfo {
        DeviceInfo(
            id: id, name: name, productType: model, osVersion: osVersion, buildVersion: "", deviceClass: deviceClass)
    }

    /// `bluetooth` means "input connected": Bluetooth for iPhones, always for simulators and Android.
    /// A simulator's model name says so, since the relays only pass these fields.
    public init(_ device: any Device) {
        let status = device.status()
        let modelName = device.info?.modelName ?? device.kind.label
        self.init(
            id: device.id, name: device.name, model: device.info?.productType ?? "",
            modelName: device.kind == .simulator ? "\(modelName) Simulator" : modelName,
            osVersion: device.info?.osVersion ?? "", deviceClass: device.info?.deviceClass ?? "iPhone",
            screen: status.screen.isConnected, bluetooth: status.inputReady, ready: status.isReady)
    }

    public var json: JSONValue {
        (try? JSONValue.parse(JSONEncoder().encode(self))) ?? .null
    }
}

/// Routes tool calls to the device named by the `device` argument: an iPhone, a booted simulator or
/// an Android device.
public final class DeviceTools: ToolCalling {
    private let hub: DeviceHub
    private let emulators: EmulatorHub?
    private let settleDelay: TimeInterval
    /// Per device, with the object it was made for: a rescan can replace a device under the same id.
    private let tools = Locked<[String: (device: any Device, tools: PhoneTools)]>([:])

    public init(hub: DeviceHub, emulators: EmulatorHub? = nil, settleDelay: TimeInterval = 0.6) {
        self.hub = hub
        self.emulators = emulators
        self.settleDelay = settleDelay
    }

    public static let definitions: [ToolDefinition] = {
        let device: JSONValue = [
            "type": "string",
            "description":
                "Device id or name from list_devices. Needed when several devices are connected; without it Mobdev uses the only one, and on a Mac with an iPhone always the iPhone.",
        ]
        let listDevices = ToolDefinition(
            name: "list_devices", title: "List devices",
            description:
                "The iPhones and iPads on this Mac, booted iOS simulators and Android emulators and phones, with id, name, model, system version and whether each is ready. Pass `device` to the other tools to pick one.",
            inputSchema: ["type": "object", "properties": [:]], readOnly: true)
        return [listDevices]
            + PhoneTools.definitions.map { definition in
                guard case .object(var schema) = definition.inputSchema,
                    case .object(var properties)? = schema["properties"]
                else { return definition }
                properties["device"] = device
                schema["properties"] = .object(properties)
                return ToolDefinition(
                    name: definition.name, title: definition.title, description: definition.description,
                    inputSchema: .object(schema), readOnly: definition.readOnly)
            }
    }()

    public var definitions: [ToolDefinition] { Self.definitions }

    public func call(_ name: String, arguments: JSONValue?, source: String, screenshotByDefault: Bool)
        async throws -> ToolOutput
    {
        guard Self.definitions.contains(where: { $0.name == name }) else { throw UnknownToolError(name: name) }
        if name == "list_devices" { return listDevices() }
        do {
            // Only a missing (or null) `device` means "pick for me". A number, an empty string or
            // anything else is a mistake, and guessing could act on the wrong phone.
            let query: String?
            switch arguments?["device"] {
            case nil, .null?: query = nil
            case .string(let text)?: query = text
            default: throw ToolFailure("device must be a device id or name from list_devices.")
            }
            if name == "status", query == nil, devices(matching: nil).count != 1 { return overview() }
            let device = try resolve(query)
            var remaining = arguments ?? [:]
            if case .object(var object) = remaining {
                object["device"] = nil
                remaining = .object(object)
            }
            return try await tools(for: device).call(
                name, arguments: remaining, source: source, screenshotByDefault: screenshotByDefault)
        } catch let failure as ToolFailure {
            return ToolOutput(text: failure.description, isError: true)
        }
    }

    public func phone(for device: String?) throws -> PhoneBackend { try resolve(device) }

    /// iPhones first, then simulators, then Android devices.
    public var allDevices: [any Device] { hub.devices + (emulators?.devices ?? []) }

    private func tools(for device: any Device) -> PhoneTools {
        let current = Set(allDevices.map(\.id))
        return tools.withLock { cache in
            cache = cache.filter { current.contains($0.key) }  // Forgotten or shut down devices.
            if let existing = cache[device.id], existing.device === device { return existing.tools }
            let created = PhoneTools(phone: device, activity: device.activity, settleDelay: settleDelay)
            cache[device.id] = (device, created)
            return created
        }
    }

    /// Like `DeviceHub.devices(matching:)` across every kind of device. Without a query, a Mac that
    /// knows an iPhone picks among its iPhones only, as before simulators and Android existed: a
    /// locked or unplugged iPhone must not hand an agent's input to a simulator.
    func devices(matching query: String?) -> [any Device] {
        let hardware = hub.devices
        let virtual = emulators?.devices ?? []
        if query == nil, !hardware.isEmpty { return hub.devices(matching: nil) }
        let all: [any Device] = hardware + virtual
        let keys =
            hardware.map {
                DeviceHub.DeviceKey(id: $0.id, captureID: $0.captureID, name: $0.name, connected: $0.capture.state.isConnected)
            } + virtual.map { DeviceHub.DeviceKey(id: $0.id, captureID: $0.id, name: $0.name, connected: true) }
        return DeviceHub.matches(query, in: keys).map { all[$0] }
    }

    private func resolve(_ query: String?) throws -> any Device {
        if let query, query.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ToolFailure("device must be a device id or name from list_devices.")
        }
        let matches = devices(matching: query)
        if matches.count == 1 { return matches[0] }
        let devices = allDevices
        func list(_ devices: [any Device]) -> String {
            devices.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
        }
        if devices.isEmpty {
            throw ToolFailure(
                "No device is connected. Connect an unlocked iPhone with a USB data cable, boot a simulator or start an Android emulator.")
        }
        if let query {
            if matches.count > 1 {
                throw ToolFailure("\"\(query)\" matches several devices: \(list(matches)). Pass the full id.")
            }
            throw ToolFailure("No device \"\(query)\". Devices: \(list(devices)).")
        }
        throw ToolFailure("Several devices are connected. Pass `device` with one of: \(list(devices)).")
    }

    private static func state(_ device: any Device, _ summary: DeviceSummary) -> String {
        if summary.ready { return "ready" }
        let status = device.status()
        if status.screen.isConnected, status.frameSize == nil { return "connected, no picture yet (wake and unlock it)" }
        if device.kind == .iPhone { return summary.screen ? "screen only, Bluetooth not paired" : "not connected" }
        return "screen not available yet"
    }

    private func listDevices() -> ToolOutput {
        let devices = allDevices
        guard !devices.isEmpty else {
            return ToolOutput(
                text:
                    "No devices. Connect an unlocked iPhone with a USB data cable, boot a simulator or start an Android emulator.",
                data: .array([]))
        }
        let summaries = devices.map(DeviceSummary.init)
        let lines = zip(devices, summaries).map { device, summary in
            let system = device.info?.systemName ?? summary.osVersion
            return "\(summary.name): \(summary.modelName), \(system), \(Self.state(device, summary)). id: \(summary.id)"
        }
        return ToolOutput(
            text: lines.joined(separator: "\n"),
            data: .array(zip(devices, summaries).map { device, summary in
                guard case .object(var object) = summary.json else { return summary.json }
                object["kind"] = .string(device.kind.rawValue)
                return .object(object)
            }))
    }

    /// Status without a device when there are none or several.
    private func overview() -> ToolOutput {
        let devices = allDevices
        let summaries = devices.map(DeviceSummary.init)
        let ready = summaries.filter(\.ready)
        var lines = [ready.isEmpty ? "Not ready." : "\(ready.count) of \(summaries.count) devices ready."]
        lines += zip(devices, summaries).map { "\($1.name): \(Self.state($0, $1))" }
        if summaries.count > 1 { lines.append("Pass `device` to act on one of them.") }
        if summaries.isEmpty {
            lines.append("Connect an unlocked iPhone with a USB data cable, boot a simulator or start an Android emulator.")
        }
        return ToolOutput(
            text: lines.joined(separator: "\n"),
            data: ["ready": .bool(!ready.isEmpty), "devices": .array(summaries.map(\.json))])
    }
}

/// Another Mac of the same account and the devices it last reported, from the relay's
/// `GET /v1/account/devices`.
public struct RemoteMac: Sendable, Equatable, Decodable, Identifiable {
    public let name: String
    public let online: Bool
    public let devices: [DeviceSummary]
    public var id: String { name }

    public struct Response: Decodable {
        public let macs: [RemoteMac]
    }
}
