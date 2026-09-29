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

    public init(_ device: HardwareDevice) {
        let status = device.status()
        self.init(
            id: device.id, name: device.name, model: device.info?.productType ?? "",
            modelName: device.info?.modelName ?? "iPhone", osVersion: device.info?.osVersion ?? "",
            deviceClass: device.info?.deviceClass ?? "iPhone", screen: status.screen.isConnected,
            bluetooth: status.bluetooth.isConnected, ready: status.frameSize != nil && status.bluetooth.isConnected)
    }

    public var json: JSONValue {
        (try? JSONValue.parse(JSONEncoder().encode(self))) ?? .null
    }
}

/// Routes tool calls to the device named by the `device` argument.
public final class DeviceTools: ToolCalling {
    private let hub: DeviceHub
    private let settleDelay: TimeInterval
    private let tools = Locked<[String: PhoneTools]>([:])

    public init(hub: DeviceHub, settleDelay: TimeInterval = 0.6) {
        self.hub = hub
        self.settleDelay = settleDelay
    }

    public static let definitions: [ToolDefinition] = {
        let device: JSONValue = [
            "type": "string",
            "description": "Device id or name from list_devices. Needed when more than one iPhone is connected.",
        ]
        let listDevices = ToolDefinition(
            name: "list_devices", title: "List devices",
            description:
                "The iPhones and iPads on this Mac with id, name, model, iOS version and whether each is ready. Pass `device` to the other tools to pick one.",
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
        let query = arguments?["device"]?.stringValue
        if name == "status", query == nil, hub.devices.count != 1 { return overview() }
        do {
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

    private func tools(for device: HardwareDevice) -> PhoneTools {
        tools.withLock { cache in
            if let existing = cache[device.id] { return existing }
            let created = PhoneTools(phone: device, activity: device.activity, settleDelay: settleDelay)
            cache[device.id] = created
            return created
        }
    }

    private func resolve(_ query: String?) throws -> HardwareDevice {
        if let device = hub.device(matching: query) { return device }
        let devices = hub.devices
        let names = devices.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
        if devices.isEmpty {
            throw ToolFailure("No iPhone is connected. Connect an unlocked iPhone with a USB data cable.")
        }
        if let query, !query.isEmpty { throw ToolFailure("No device \"\(query)\". Devices: \(names).") }
        throw ToolFailure("Several devices are connected. Pass `device` with one of: \(names).")
    }

    private func listDevices() -> ToolOutput {
        let summaries = hub.devices.map(DeviceSummary.init)
        guard !summaries.isEmpty else {
            return ToolOutput(text: "No devices. Connect an unlocked iPhone with a USB data cable.", data: .array([]))
        }
        let lines = summaries.map { device in
            let state = device.ready ? "ready" : device.screen ? "screen only, Bluetooth not paired" : "not connected"
            return "\(device.name): \(device.modelName), iOS \(device.osVersion), \(state). id: \(device.id)"
        }
        return ToolOutput(text: lines.joined(separator: "\n"), data: .array(summaries.map(\.json)))
    }

    /// Status without a device when there are none or several.
    private func overview() -> ToolOutput {
        let summaries = hub.devices.map(DeviceSummary.init)
        let ready = summaries.filter(\.ready)
        var lines = [ready.isEmpty ? "Not ready." : "\(ready.count) of \(summaries.count) devices ready."]
        lines += summaries.map { "\($0.name): \($0.ready ? "ready" : $0.screen ? "Bluetooth not paired" : "not connected")" }
        if summaries.count > 1 { lines.append("Pass `device` to act on one of them.") }
        if summaries.isEmpty { lines.append("Connect an unlocked iPhone with a USB data cable.") }
        return ToolOutput(
            text: lines.joined(separator: "\n"),
            data: ["ready": .bool(!ready.isEmpty), "devices": .array(summaries.map(\.json))])
    }
}
