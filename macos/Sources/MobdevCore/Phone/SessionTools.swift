import Foundation

/// Tools for what just happened on a device and for Apple's Shortcuts: `recent_steps` turns the
/// actions that worked into a flow, `run_shortcut` runs a shortcut by name.
extension PhoneTools {
    static let sessionDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "recent_steps", title: "Recent steps",
            description:
                "The newest actions that succeeded on this device (by any agent or in the app), as flow steps: taps, typing, app launches, waits and settings, without the calls that only looked or failed. Once a path through the app works, pass them to save_test or run_flow, after dropping detours. count limits them (default 50, at most 200); clear: true starts over, e.g. right before the path to keep.",
            inputSchema: schema(
                [
                    "count": ["type": "integer", "minimum": 1, "maximum": 200],
                    "clear": ["type": "boolean", "description": "Forget the steps so far"],
                ], screenshot: false),
            readOnly: true),
        ToolDefinition(
            name: "press_button", title: "Press button",
            description:
                "Press a hardware button: volume_up, volume_down, mute and play_pause on iPhones (through the Bluetooth keyboard) and Android; lock (the side button) on simulators and Android. An iPhone is never locked: Mobdev could not enter its passcode.",
            inputSchema: schema(
                ["button": ["type": "string", "enum": ["volume_up", "volume_down", "mute", "play_pause", "lock"]]],
                required: ["button"]),
            readOnly: false),
        ToolDefinition(
            name: "run_shortcut", title: "Run shortcut",
            description:
                "Run a shortcut from Apple's Shortcuts app by its name, e.g. one that turns on Do Not Disturb or sets the brightness. Through a shortcuts:// link on simulators and iPhones in Developer Mode, otherwise through Spotlight. The shortcut must exist on the device. Not on Android.",
            inputSchema: schema(["name": ["type": "string"]], required: ["name"]),
            readOnly: false),
    ]

    func runSessionTool(_ name: String, _ args: Arguments) async throws -> ToolOutput? {
        switch name {
        case "recent_steps":
            if args.bool("clear") == true {
                history.clear()
                return ToolOutput(text: "Forgot the recent steps. New actions are collected from now on.", data: ["steps": []])
            }
            let count = Int(try args.number("count", default: 50, range: 1...200))
            let steps = Array(history.steps.suffix(count))
            guard !steps.isEmpty else {
                return ToolOutput(text: "No actions yet on this device since Mobdev started or the steps were cleared.", data: ["steps": []])
            }
            let flow = Flow(name: "Recent steps", steps: steps)
            let lines = steps.enumerated().map { "\($0.offset + 1). \($0.element.summary)" }
            return ToolOutput(
                text: (lines + ["Pass these steps to save_test (steps) or run_flow."]).joined(separator: "\n"),
                data: ["steps": .array(steps.map(\.json)), "flow": (try? JSONValue.parse(flow.encoded())) ?? .null])
        case "press_button":
            let name = try args.string("button")
            let buttons: [String: ConsumerUsage] = [
                "volume_up": .volumeUp, "volume_down": .volumeDown, "mute": .mute, "play_pause": .playPause, "lock": .power,
            ]
            guard let button = buttons[name] else {
                throw ToolFailure("button must be volume_up, volume_down, mute, play_pause or lock.")
            }
            if button == .power, phone.status().input == .bluetooth {
                throw ToolFailure("Mobdev does not lock an iPhone: it could not enter the passcode to unlock it again.")
            }
            try requireTouch()
            try await phone.press(button)
            return ToolOutput(text: "Pressed \(name.replacingOccurrences(of: "_", with: " ")).")
        case "run_shortcut":
            let shortcut = try args.string("name", maxLength: 100)
            if let apps = phone.apps {
                guard apps.platform != .android else { throw ToolFailure("Android has no Shortcuts app.") }
                var components = URLComponents(string: "shortcuts://run-shortcut")!
                components.queryItems = [URLQueryItem(name: "name", value: shortcut)]
                guard let url = components.url else { throw ToolFailure("\(shortcut) cannot be put into a link.") }
                try await apps.open(url)
                try await pause(1.5)
                return ToolOutput(
                    text:
                        "Asked Shortcuts to run \"\(shortcut)\". When no shortcut has that name, Shortcuts shows an alert saying so; observe shows it.")
            }
            // Without Developer Mode, Spotlight lists shortcuts by name and Return runs the top hit.
            _ = try await run("open_app", Arguments(["name": .string(shortcut)]))
            return ToolOutput(text: "Searched Spotlight for the shortcut \"\(shortcut)\" and ran the top hit.")
        default:
            return nil
        }
    }
}
