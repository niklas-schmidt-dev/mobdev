import Foundation

/// Tools that set a device's state directly: location, permissions, push notifications, appearance,
/// language, the status bar, biometrics, an app's data, the clipboard and the orientation. They run
/// through `PhoneBackend.settings`: simctl and devicectl for simulators and iPhones, adb for Android.
extension PhoneTools {
    static let settingsDefinitions: [ToolDefinition] = {
        let bundleID: JSONValue = [
            "type": "string", "description": "Bundle ID, e.g. com.example.MyApp, or the package name on Android",
        ]
        let coordinate: JSONValue = [
            "type": "object",
            "properties": ["latitude": ["type": "number"], "longitude": ["type": "number"]],
            "required": ["latitude", "longitude"],
        ]
        return [
            ToolDefinition(
                name: "set_location", title: "Set location",
                description:
                    "Simulate where the device is: latitude and longitude, or a route of waypoints it follows at speed meters per second, or clear: true to stop. Simulators and Android emulators; iPhones with Developer Mode and Xcode 27.",
                inputSchema: schema(
                    [
                        "latitude": ["type": "number", "description": "Decimal degrees, e.g. 52.52"],
                        "longitude": ["type": "number", "description": "Decimal degrees, e.g. 13.405"],
                        "route": ["type": "array", "items": coordinate, "description": "Two or more waypoints"],
                        "speed": ["type": "number", "description": "Meters per second along the route, default 10"],
                        "clear": ["type": "boolean", "description": "Stop simulating a location"],
                    ], screenshot: false),
                readOnly: false),
            ToolDefinition(
                name: "set_permission", title: "Set permission",
                description:
                    "Grant, revoke or reset an app's permission without the system prompt, so a test starts from a known state. Permissions: "
                    + DeviceSettingsNames.permissions.joined(separator: ", ")
                    + ". Simulators have no camera or notifications switch; Android takes these names or a full android.permission name. Simulators and Android only. Changing a permission may stop the app.",
                inputSchema: schema(
                    [
                        "bundle_id": bundleID,
                        "permission": ["type": "string", "description": "e.g. location, photos, camera, notifications"],
                        "state": [
                            "type": "string", "enum": .array(PermissionState.allCases.map { .string($0.rawValue) }),
                            "description": "grant (default), revoke, or reset so the app asks again",
                        ],
                    ], required: ["bundle_id", "permission"], screenshot: false),
                readOnly: false),
            ToolDefinition(
                name: "send_push", title: "Send push notification",
                description:
                    "Deliver a push notification to an app on a simulator as if it came from Apple's servers: title and body, or a full APNs payload. On Android it posts a notification with the title and body from the shell, which the app does not receive as a message. Real iPhones get pushes only through your own APNs key.",
                inputSchema: schema(
                    [
                        "bundle_id": bundleID,
                        "title": ["type": "string"],
                        "body": ["type": "string"],
                        "badge": ["type": "integer", "minimum": 0],
                        "data": [
                            "type": "object",
                            "description": "Custom keys next to aps, e.g. {\"deeplink\": \"myapp://inbox\"}",
                        ],
                        "payload": [
                            "type": "object",
                            "description": "A complete APNs payload with an aps object; replaces title, body, badge and data",
                        ],
                    ], required: ["bundle_id"]),
                readOnly: false),
            ToolDefinition(
                name: "set_appearance", title: "Set appearance",
                description:
                    "Switch dark mode, the text size (Dynamic Type), Increase Contrast and Reduce Motion, to check how an app looks in each. Simulators and Android; iPhones with Developer Mode and Xcode 27. Reduce Motion on a simulator needs Xcode 27.",
                inputSchema: schema([
                    "dark": ["type": "boolean"],
                    "text_size": [
                        "type": "string", "enum": .array(Appearance.textSizes.map(JSONValue.string)),
                        "description": "large is the default",
                    ],
                    "increase_contrast": ["type": "boolean"],
                    "reduce_motion": ["type": "boolean"],
                ]),
                readOnly: false),
            ToolDefinition(
                name: "set_language", title: "Set language",
                description:
                    "Change the language and region, e.g. de-DE or ja-JP. On a simulator for the whole device: relaunch the app with launch_app to see it. On Android for one app (pass bundle_id; Android 13 and later). For one launch of an iOS app, launch_app with arguments [\"-AppleLanguages\", \"(de)\", \"-AppleLocale\", \"de_DE\"] also works.",
                inputSchema: schema(
                    ["language": ["type": "string", "description": "A language tag such as de-DE"], "bundle_id": bundleID],
                    required: ["language"], screenshot: false),
                readOnly: false),
            ToolDefinition(
                name: "set_status_bar", title: "Set status bar",
                description:
                    "Override what the status bar shows, for clean screenshots: preset screenshot (9:41, full battery and bars) or single values; preset clear removes every override. Simulators and Android (demo mode); iPhones with Developer Mode and Xcode 27.",
                inputSchema: schema([
                    "preset": ["type": "string", "enum": ["screenshot", "clear"]],
                    "time": ["type": "string", "description": "e.g. 9:41"],
                    "battery_level": ["type": "integer", "minimum": 0, "maximum": 100],
                    "battery_state": ["type": "string", "enum": ["charging", "charged", "discharging"]],
                    "wifi_bars": ["type": "integer", "minimum": 0, "maximum": 3],
                    "cellular_bars": ["type": "integer", "minimum": 0, "maximum": 4],
                    "network": ["type": "string", "enum": ["wifi", "lte", "5g", "hide"]],
                ]),
                readOnly: false),
            ToolDefinition(
                name: "biometrics", title: "Face ID and fingerprints",
                description:
                    "Answer a Face ID, Touch ID or fingerprint prompt: match or fail. enroll and unenroll turn Face ID on or off on a simulator. Simulators (Xcode 27 or Simulator's own switches before) and Android emulators with a fingerprint enrolled in Settings.",
                inputSchema: schema(
                    [
                        "action": [
                            "type": "string", "enum": .array(BiometricAction.allCases.map { .string($0.rawValue) }),
                        ]
                    ], required: ["action"]),
                readOnly: false),
            ToolDefinition(
                name: "reset_app", title: "Reset app",
                description:
                    "Delete an app's data so it starts as if just installed, without reinstalling it. keychain also empties the simulator's keychain (all apps). Simulators and Android; on an iPhone use uninstall_app and install_app.",
                inputSchema: schema(
                    [
                        "bundle_id": bundleID,
                        "keychain": ["type": "boolean", "description": "Also reset the keychain, default false"],
                    ], required: ["bundle_id"], screenshot: false),
                readOnly: false),
            ToolDefinition(
                name: "clipboard", title: "Clipboard",
                description:
                    "Read the device's clipboard, or set it with text, e.g. to paste a long value or check what an app copied. Simulators, Android, and iPhones with Developer Mode and Xcode 27.",
                inputSchema: schema(["text": ["type": "string", "description": "Set the clipboard to this"]], screenshot: false),
                readOnly: false),
            ToolDefinition(
                name: "set_orientation", title: "Set orientation",
                description:
                    "Turn the device: portrait, landscape_left, landscape_right or portrait_upside_down. The app must support it. Coordinates follow the new screenshot. Simulators and iPhones need Xcode 27; Android any version.",
                inputSchema: schema(
                    [
                        "orientation": [
                            "type": "string", "enum": .array(Orientation.allCases.map { .string($0.rawValue) }),
                        ]
                    ], required: ["orientation"]),
                readOnly: false),
        ]
    }()

    func runSettingsTool(_ name: String, _ args: Arguments) async throws -> ToolOutput? {
        switch name {
        case "set_location":
            let settings = try requireSettings()
            if args.bool("clear") == true {
                try await settings.clearLocation()
                return ToolOutput(text: "Stopped simulating a location.")
            }
            if args.has("route") {
                let waypoints = try coordinates(args.value["route"])
                let speed = try args.number("speed", default: 10, range: 0.1...1000)
                try await settings.followRoute(waypoints, speed: speed)
                return ToolOutput(
                    text: "Following a route of \(waypoints.count) waypoints at \(format(speed)) m/s. clear: true stops it.")
            }
            let coordinate = try self.coordinate(args.value)
            try await settings.setLocation(coordinate)
            return ToolOutput(text: "The device is now at \(coordinate.latitude), \(coordinate.longitude).")
        case "set_permission":
            let bundleID = try args.string("bundle_id")
            let permission = try args.string("permission", maxLength: 100)
            let stateName = args.has("state") ? try args.string("state") : "grant"
            guard let state = PermissionState(rawValue: stateName) else {
                throw ToolFailure("state must be grant, revoke or reset.")
            }
            try await requireSettings().setPermission(permission, state, bundleID: bundleID)
            let done = switch state {
            case .grant: "Granted \(permission) to"
            case .revoke: "Revoked \(permission) from"
            case .reset: "Reset \(permission) for"
            }
            return ToolOutput(text: "\(done) \(bundleID).")
        case "send_push":
            let bundleID = try args.string("bundle_id")
            let payload = try pushPayload(args)
            let text = try await requireSettings().sendPush(payload, to: bundleID)
            return ToolOutput(text: text)
        case "set_appearance":
            let appearance = try self.appearance(args)
            try await requireSettings().setAppearance(appearance)
            var changed: [String] = []
            if let dark = appearance.dark { changed.append(dark ? "dark mode" : "light mode") }
            if let size = appearance.textSize { changed.append("text size \(size)") }
            if let contrast = appearance.increaseContrast { changed.append("Increase Contrast \(contrast ? "on" : "off")") }
            if let motion = appearance.reduceMotion { changed.append("Reduce Motion \(motion ? "on" : "off")") }
            return ToolOutput(text: "Set " + changed.joined(separator: ", ") + ".")
        case "set_language":
            let language = try args.string("language", maxLength: 35)
            guard language.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                throw ToolFailure("language must be a language tag such as de-DE or ja-JP.")
            }
            let bundleID = args.has("bundle_id") ? try args.string("bundle_id") : nil
            return ToolOutput(text: try await requireSettings().setLanguage(language, bundleID: bundleID))
        case "set_status_bar":
            let override = try statusBar(args)
            try await requireSettings().setStatusBar(override)
            return ToolOutput(text: override == nil ? "Cleared the status bar overrides." : "Set the status bar.")
        case "biometrics":
            guard let action = BiometricAction(rawValue: try args.string("action")) else {
                throw ToolFailure("action must be match, fail, enroll or unenroll.")
            }
            try await requireSettings().biometrics(action)
            let text = switch action {
            case .match: "Presented a matching face or finger."
            case .fail: "Presented a face or finger that does not match."
            case .enroll: "Turned Face ID on."
            case .unenroll: "Turned Face ID off."
            }
            return ToolOutput(text: text)
        case "reset_app":
            let bundleID = try args.string("bundle_id")
            let text = try await requireSettings().resetApp(bundleID, keychain: args.bool("keychain") ?? false)
            return ToolOutput(text: text)
        case "clipboard":
            let settings = try requireSettings()
            if args.has("text") {
                let text = try args.string("text", maxLength: 100_000)
                try await settings.setClipboard(text)
                return ToolOutput(text: "Copied \(text.count) characters to the device's clipboard.")
            }
            let text = try await settings.clipboard()
            return ToolOutput(text: text.isEmpty ? "The clipboard is empty." : text, data: ["text": .string(text)])
        case "set_orientation":
            guard let orientation = Orientation(rawValue: try args.string("orientation")) else {
                throw ToolFailure("orientation must be portrait, landscape_left, landscape_right or portrait_upside_down.")
            }
            try await requireSettings().setOrientation(orientation)
            try await pause(1.0)  // The rotation animation.
            return ToolOutput(text: "Turned the device to \(orientation.rawValue).")
        default:
            return nil
        }
    }

    private func requireSettings() throws -> DeviceSettings {
        guard let settings = phone.settings else {
            throw ToolFailure(
                "Device settings are not available for this device yet: Mobdev has not read its identity over USB. Reconnect the cable and unlock the iPhone.")
        }
        return settings
    }

    private func coordinate(_ value: JSONValue) throws -> Coordinate {
        let args = Arguments(value)
        let latitude = try args.number("latitude", default: .nan, range: -90...90)
        let longitude = try args.number("longitude", default: .nan, range: -180...180)
        guard !latitude.isNaN, !longitude.isNaN else {
            throw ToolFailure("Pass latitude and longitude, a route, or clear: true.")
        }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    /// Waypoints as objects with latitude and longitude, or as [latitude, longitude] pairs.
    private func coordinates(_ value: JSONValue?) throws -> [Coordinate] {
        guard let items = value?.arrayValue, items.count >= 2, items.count <= 1000 else {
            throw ToolFailure("route must be an array of 2 to 1000 waypoints, each {\"latitude\": …, \"longitude\": …}.")
        }
        return try items.map { item in
            if let pair = item.arrayValue, pair.count == 2, let latitude = pair[0].doubleValue,
                let longitude = pair[1].doubleValue
            {
                return try coordinate(["latitude": .number(latitude), "longitude": .number(longitude)])
            }
            return try coordinate(item)
        }
    }

    /// An APNs payload from title, body, badge and data, or the one given whole.
    private func pushPayload(_ args: Arguments) throws -> JSONValue {
        if args.has("payload") {
            guard let payload = args.value["payload"]?.objectValue, payload["aps"]?.objectValue != nil else {
                throw ToolFailure("payload must be an object with an aps object, e.g. {\"aps\": {\"alert\": \"Hi\"}}.")
            }
            return try sized(.object(payload))
        }
        var alert: [String: JSONValue] = [:]
        if args.has("title") { alert["title"] = .string(try args.string("title")) }
        if args.has("body") { alert["body"] = .string(try args.string("body")) }
        var aps: [String: JSONValue] = [:]
        if !alert.isEmpty {
            aps["alert"] = .object(alert)
            aps["sound"] = "default"
        }
        if args.has("badge") { aps["badge"] = .number(try args.number("badge", default: 0, range: 0...99_999).rounded()) }
        guard !aps.isEmpty else { throw ToolFailure("Pass title, body or badge, or a whole payload.") }
        var payload: [String: JSONValue] = [:]
        if args.has("data") {
            guard let data = args.value["data"]?.objectValue else { throw ToolFailure("data must be an object.") }
            payload = data
        }
        payload["aps"] = .object(aps)
        return try sized(.object(payload))
    }

    /// APNs takes at most 4 KB.
    private func sized(_ payload: JSONValue) throws -> JSONValue {
        let size = payload.encoded().count
        guard size <= 4096 else { throw ToolFailure("The payload has \(size) bytes; a push takes at most 4096.") }
        return payload
    }

    private func appearance(_ args: Arguments) throws -> Appearance {
        var appearance = Appearance(
            dark: args.bool("dark"), increaseContrast: args.bool("increase_contrast"), reduceMotion: args.bool("reduce_motion"))
        if args.has("text_size") {
            let size = try args.string("text_size")
            guard Appearance.textSizes.contains(size) else {
                throw ToolFailure("text_size must be one of " + Appearance.textSizes.joined(separator: ", ") + ".")
            }
            appearance.textSize = size
        }
        guard !appearance.isEmpty else {
            throw ToolFailure("Pass dark, text_size, increase_contrast or reduce_motion.")
        }
        return appearance
    }

    /// Nil for preset clear.
    private func statusBar(_ args: Arguments) throws -> StatusBarOverride? {
        let preset = args.has("preset") ? try args.string("preset") : nil
        if preset == "clear" { return nil }
        guard preset == nil || preset == "screenshot" else { throw ToolFailure("preset must be screenshot or clear.") }
        var override = preset == "screenshot" ? StatusBarOverride.screenshot : StatusBarOverride()
        if args.has("time") { override.time = try args.string("time", maxLength: 40) }
        if args.has("battery_level") { override.batteryLevel = Int(try args.number("battery_level", default: 100, range: 0...100)) }
        if args.has("battery_state") {
            let state = try args.string("battery_state")
            guard ["charging", "charged", "discharging"].contains(state) else {
                throw ToolFailure("battery_state must be charging, charged or discharging.")
            }
            override.batteryState = state
        }
        if args.has("wifi_bars") { override.wifiBars = Int(try args.number("wifi_bars", default: 3, range: 0...3)) }
        if args.has("cellular_bars") { override.cellularBars = Int(try args.number("cellular_bars", default: 4, range: 0...4)) }
        if args.has("network") {
            let network = try args.string("network")
            guard ["wifi", "lte", "5g", "hide"].contains(network) else { throw ToolFailure("network must be wifi, lte, 5g or hide.") }
            override.network = network
        }
        guard override != StatusBarOverride() else {
            throw ToolFailure("Pass preset (screenshot or clear) or values such as time and battery_level.")
        }
        return override
    }
}
