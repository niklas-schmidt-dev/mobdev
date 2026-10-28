import Foundation

/// Tools for the simulators and Android Virtual Devices on this Mac, running or not: listing,
/// booting, shutting down, and creating and deleting simulators. They need no device, like the
/// project tools.
enum VirtualDeviceTools {
    static let names: Set<String> = [
        "list_virtual_devices", "boot_device", "shutdown_device", "create_simulator", "delete_simulator",
    ]

    static func isTool(_ name: String) -> Bool { names.contains(name) }

    static let definitions: [ToolDefinition] = {
        let id: JSONValue = [
            "type": "string",
            "description":
                "A simulator's UDID or an AVD's name from list_virtual_devices, a running emulator's serial, or a name only one of them has",
        ]
        return [
            ToolDefinition(
                name: "list_virtual_devices", title: "List simulators and emulators",
                description:
                    "Every iOS simulator and Android Virtual Device on this Mac, running or not: id, name, model, system, state, whether Mobdev made it and, while it runs, the device id the other tools take. Start one with boot_device.",
                inputSchema: ["type": "object", "properties": [:]], readOnly: true),
            ToolDefinition(
                name: "boot_device", title: "Boot simulator or emulator",
                description:
                    "Start a simulator or an Android Virtual Device and wait until it has booted (a minute or two for Android, up to 10 minutes). It then appears in list_devices for the other tools. An AVD starts as Android Studio starts it and keeps what happens on it. Mobdev shows the screen itself; window: true also opens Simulator or the emulator's window.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": id,
                        "window": ["type": "boolean", "description": "Also open Simulator or the emulator's window, default false"],
                    ],
                    "required": ["id"],
                ], readOnly: false),
            ToolDefinition(
                name: "shutdown_device", title: "Shut down simulator or emulator",
                description:
                    "Shut a simulator down or quit an Android emulator. Refused while a flow, test run or crawl holds it. Real phones are not shut down.",
                inputSchema: ["type": "object", "properties": ["id": id], "required": ["id"]], readOnly: false),
            ToolDefinition(
                name: "create_simulator", title: "Create simulator",
                description:
                    "Create an iOS simulator of a type, e.g. \"iPhone 17 Pro\" or \"iPad Air 11-inch (M3)\", on an iOS version (default the newest that runs it), and boot it unless boot is false. Unknown types and versions fail with the ones this Mac has. Mobdev remembers that it made it, so delete_simulator may delete it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "device_type": ["type": "string", "description": "The simulator type, by name or identifier"],
                        "runtime": [
                            "type": "string",
                            "description": "The iOS version, e.g. \"27.0\", \"27\" (the newest 27.x) or \"iOS 26.5\"; default the newest",
                        ],
                        "name": ["type": "string", "description": "Its name, default the type's"],
                        "boot": ["type": "boolean", "description": "Boot it right away, default true"],
                    ],
                    "required": ["device_type"],
                ], readOnly: false),
            ToolDefinition(
                name: "delete_simulator", title: "Delete simulator",
                description:
                    "Delete a simulator that create_simulator made, with its apps and data, shutting it down first. Simulators Mobdev did not make are refused.",
                inputSchema: ["type": "object", "properties": ["id": id], "required": ["id"]], readOnly: false),
        ]
    }()
}

extension DeviceTools {
    /// How long a call through a relay waits for a boot; the relay gives up after 90 seconds.
    static let relayBootWait: TimeInterval = 75

    func callVirtualDeviceTool(_ name: String, _ args: Arguments, source: String) async throws -> ToolOutput {
        switch name {
        case "list_virtual_devices":
            let list = await virtualDevices.list()
            return Self.listOutput(list)
        case "boot_device":
            let device = try await virtualDevices.device(try args.string("id"))
            if device.state == .booted { return output("\(device.name) is running already", device) }
            guard let booted = try await boot(device, window: args.bool("window") ?? false, source: source) else {
                return output("\(device.name) is still booting; list_virtual_devices shows when it runs", device)
            }
            return output("\(booted.name) has booted", booted, note: await waitUntilListed(booted))
        case "shutdown_device":
            let device = try await virtualDevices.device(try args.string("id"))
            guard device.state != .shutdown else { return output("\(device.name) is shut down already", device) }
            // A flow, test run or crawl on it would fail halfway.
            if let id = device.deviceID, let running = allDevices.first(where: { $0.id == id }) {
                try tools(for: running).checkNotHeld()
            }
            return output("\(device.name) is shut down", try await virtualDevices.shutdown(device))
        case "create_simulator":
            let created = try await virtualDevices.createSimulator(
                type: try args.string("device_type"), runtime: args.has("runtime") ? try args.string("runtime") : nil,
                name: args.has("name") ? try args.string("name") : nil)
            guard args.bool("boot") ?? true else { return output("Created \(created.name)", created) }
            guard let booted = try await boot(created, window: false, source: source) else {
                return output("Created \(created.name); it is still booting, list_virtual_devices shows when it runs", created)
            }
            return output("Created \(created.name) and booted it", booted, note: await waitUntilListed(booted))
        case "delete_simulator":
            let device = try await virtualDevices.device(try args.string("id"))
            if let id = device.deviceID, let running = allDevices.first(where: { $0.id == id }) {
                try tools(for: running).checkNotHeld()
            }
            try await virtualDevices.deleteSimulator(device)
            return ToolOutput(text: "Deleted \(device.name) (\(device.id)).", data: ["deleted": .string(device.id)])
        default:
            throw UnknownToolError(name: name)
        }
    }

    /// Boots in a task of its own, so a caller that stops waiting does not end the boot. Through a
    /// relay the answer comes after `relayBootWait` at most: nil while it still boots.
    private func boot(_ device: VirtualDevice, window: Bool, source: String) async throws -> VirtualDevice? {
        let devices = virtualDevices
        let outcome = Locked<Result<VirtualDevice, Error>?>(nil)
        Task.detached {
            do {
                outcome.set(.success(try await devices.boot(device, window: window)))
            } catch {
                outcome.set(.failure(error))
            }
        }
        let deadline = Date().addingTimeInterval(source == "relay" ? Self.relayBootWait : 24 * 3600)
        while outcome.get() == nil, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return try outcome.get()?.get()
    }

    private func output(_ sentence: String, _ device: VirtualDevice, note: String = "") -> ToolOutput {
        let id = device.deviceID.map { " Its device id: \($0)." } ?? ""
        return ToolOutput(text: "\(sentence) (\(device.model), \(device.system)).\(id)\(note)", data: device.json)
    }

    /// Waits a moment until the device list shows a device that booted, so the next tool finds it.
    /// A sentence for the answer when it does not.
    private func waitUntilListed(_ device: VirtualDevice) async -> String {
        guard let id = device.deviceID else { return "" }
        // `Mobdev boot_device --local` ends with its process; nothing to wait for.
        guard let emulators else { return "" }
        guard emulators.isRunning else {
            return " Mobdev does not show simulators and Android devices now (Settings › Show simulators and Android devices), so the other tools do not see it."
        }
        for _ in 0..<40 {
            if allDevices.contains(where: { $0.id == id }) { return "" }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return " It appears in list_devices in a few seconds."
    }

    static func listOutput(_ list: VirtualDeviceList) -> ToolOutput {
        var lines = list.devices.map { device in
            let model = device.model == device.name ? "" : "\(device.model), "
            var line = "\(device.name): \(model)\(device.system), \(device.state.rawValue). id: \(device.id)"
            if let id = device.deviceID, id != device.id { line += ", device: \(id)" }
            if device.createdByMobdev { line += " (made by Mobdev)" }
            return line
        }
        if list.devices.isEmpty { lines.append("No simulators or Android Virtual Devices on this Mac.") }
        lines += list.problems
        return ToolOutput(
            text: lines.joined(separator: "\n"),
            data: ["devices": .array(list.devices.map(\.json)), "problems": .array(list.problems.map(JSONValue.string))])
    }
}
