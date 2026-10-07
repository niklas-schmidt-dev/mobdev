import Foundation

/// A place on Earth in decimal degrees.
public struct Coordinate: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// "52.52,13.405", the form simctl and devicectl take. Swift prints a dot whatever the locale.
    var pair: String { "\(latitude),\(longitude)" }
}

public enum PermissionState: String, Sendable, CaseIterable {
    /// Allowed without asking.
    case grant
    /// Denied.
    case revoke
    /// Not decided: the app asks again.
    case reset
}

/// How the device looks. Nil fields stay as they are.
public struct Appearance: Sendable, Equatable {
    public var dark: Bool?
    /// One of `textSizes`, e.g. "large" (the default) or "accessibility-medium".
    public var textSize: String?
    public var increaseContrast: Bool?
    public var reduceMotion: Bool?

    public init(dark: Bool? = nil, textSize: String? = nil, increaseContrast: Bool? = nil, reduceMotion: Bool? = nil) {
        self.dark = dark
        self.textSize = textSize
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
    }

    public var isEmpty: Bool { dark == nil && textSize == nil && increaseContrast == nil && reduceMotion == nil }

    /// Dynamic Type sizes, smallest first, as simctl and devicectl name them.
    public static let textSizes = [
        "extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
        "accessibility-medium", "accessibility-large", "accessibility-extra-large",
        "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large",
    ]
}

/// What the status bar shows, for screenshots. Nil fields keep the real value.
public struct StatusBarOverride: Sendable, Equatable {
    public var time: String?
    public var batteryLevel: Int?
    /// "charging", "charged" or "discharging".
    public var batteryState: String?
    /// 0–3.
    public var wifiBars: Int?
    /// 0–4.
    public var cellularBars: Int?
    /// "wifi", "lte", "5g" or "hide".
    public var network: String?

    public init(
        time: String? = nil, batteryLevel: Int? = nil, batteryState: String? = nil, wifiBars: Int? = nil,
        cellularBars: Int? = nil, network: String? = nil
    ) {
        self.time = time
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.wifiBars = wifiBars
        self.cellularBars = cellularBars
        self.network = network
    }

    /// Apple's screenshot look: 9:41, full battery, full bars.
    public static let screenshot = StatusBarOverride(
        time: "9:41", batteryLevel: 100, batteryState: "charged", wifiBars: 3, cellularBars: 4, network: "wifi")
}

public enum BiometricAction: String, Sendable, CaseIterable {
    /// A face or finger the device knows.
    case match
    /// One it does not.
    case fail
    /// Turns Face ID or Touch ID on, so apps can use it.
    case enroll
    /// Turns it off again.
    case unenroll
}

public enum Orientation: String, Sendable, CaseIterable {
    case portrait
    case portraitUpsideDown = "portrait_upside_down"
    case landscapeLeft = "landscape_left"
    case landscapeRight = "landscape_right"

    /// devicectl's name.
    var devicectl: String {
        switch self {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        }
    }
}

/// Device state that tests and agents set directly instead of tapping through Settings: location,
/// permissions, push notifications, appearance, language, the status bar, biometrics, an app's data,
/// the clipboard and the orientation. Simulators and iPhones implement it with `simctl` and
/// `devicectl` (`DeviceControl`), Android with adb (`AndroidSettings`). What a device cannot do
/// throws a `DeveloperError` that says so and what to do instead.
public protocol DeviceSettings: Sendable {
    func setLocation(_ coordinate: Coordinate) async throws
    /// Moves along the waypoints at `speed` meters per second.
    func followRoute(_ waypoints: [Coordinate], speed: Double) async throws
    func clearLocation() async throws
    /// `permission` is one of `DeviceSettingsNames.permissions`, or on Android also a full
    /// android.permission name.
    func setPermission(_ permission: String, _ state: PermissionState, bundleID: String) async throws
    /// An APNs payload with an `aps` object.
    func sendPush(_ payload: JSONValue, to bundleID: String) async throws -> String
    func setAppearance(_ appearance: Appearance) async throws
    /// A BCP 47 language such as "de-DE", optionally for one app only.
    func setLanguage(_ language: String, bundleID: String?) async throws -> String
    /// Nil clears every override.
    func setStatusBar(_ override: StatusBarOverride?) async throws
    func biometrics(_ action: BiometricAction) async throws
    /// Deletes an app's data as if it had just been installed; `keychain` also empties the device's keychain.
    func resetApp(_ bundleID: String, keychain: Bool) async throws -> String
    func clipboard() async throws -> String
    func setClipboard(_ text: String) async throws
    func setOrientation(_ orientation: Orientation) async throws
}

/// The names the tools accept, shared by every backend.
public enum DeviceSettingsNames {
    /// iOS's privacy services as simctl names them; Android maps them to its permissions.
    public static let permissions = [
        "calendar", "contacts", "contacts-limited", "location", "location-always", "photos", "photos-add",
        "media-library", "microphone", "motion", "reminders", "siri", "camera", "notifications", "all",
    ]
}

// MARK: - Simulators and iPhones

/// Simulators go through `simctl` wherever it can do the job, since it works with every Xcode;
/// what only Xcode 27's `devicectl` can do (reduce motion, biometrics, orientation) needs it there.
/// iPhones go through `devicectl`, which needs Developer Mode.
extension DeviceControl: DeviceSettings {
    /// devicectl reaches this device for settings: every iPhone, and simulators with Xcode 27.
    private var devicectlReachesDevice: Bool { !isSimulator || !usesSimctl }

    private func requireDevicectl(_ what: String) throws {
        guard devicectlReachesDevice else {
            throw DeveloperError("\(what) on a simulator needs Xcode 27 or later, whose devicectl can do it.")
        }
    }

    private func simulatorOnly(_ what: String, instead: String) throws {
        guard isSimulator else { throw DeveloperError("\(what) works on simulators only. \(instead)") }
    }

    public func setLocation(_ coordinate: Coordinate) async throws {
        if isSimulator {
            try await simctl(["location", udid, "set", coordinate.pair])
        } else {
            _ = try await call(
                ["device", "simulate", "location", "coordinate"],
                options: ["--latitude", "\(coordinate.latitude)", "--longitude", "\(coordinate.longitude)"])
        }
    }

    public func followRoute(_ waypoints: [Coordinate], speed: Double) async throws {
        if isSimulator {
            try await simctl(["location", udid, "start", "--speed=\(speed)", "--interval=1"] + waypoints.map(\.pair))
        } else {
            _ = try await call(
                ["device", "simulate", "location", "route"],
                options: [
                    "--mode", "interval", "--interval", "1", "--speed", "\(speed)", "--waypoints",
                    waypoints.map(\.pair).joined(separator: " "),
                ])
        }
    }

    public func clearLocation() async throws {
        if isSimulator {
            try await simctl(["location", udid, "clear"])
        } else {
            _ = try await call(["device", "simulate", "location", "clear"])
        }
    }

    /// simctl's privacy services; camera and notifications have none.
    static let simulatorPermissions: Set<String> = [
        "all", "calendar", "contacts-limited", "contacts", "location", "location-always", "photos-add", "photos",
        "media-library", "microphone", "motion", "reminders", "siri",
    ]

    public func setPermission(_ permission: String, _ state: PermissionState, bundleID: String) async throws {
        try simulatorOnly(
            "Setting permissions", instead: "On an iPhone, change them in Settings or reinstall the app to reset them.")
        guard Self.simulatorPermissions.contains(permission) else {
            throw DeveloperError(
                "The iOS Simulator cannot set \(permission) from outside. It can set "
                    + Self.simulatorPermissions.sorted().joined(separator: ", ")
                    + ". Let the app ask, then tap Allow, e.g. with tap_text.")
        }
        if permission == "all", state != .reset {
            throw DeveloperError("all can only be reset. Grant or revoke one permission at a time.")
        }
        // simctl may stop the app while it changes a permission.
        try await simctl(["privacy", udid, state.rawValue, permission, bundleID])
    }

    public func sendPush(_ payload: JSONValue, to bundleID: String) async throws -> String {
        try simulatorOnly(
            "Sending a push notification",
            instead: "A real iPhone gets pushes from Apple's servers only, through your APNs key.")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-push-\(UUID().uuidString).json")
        try payload.encoded().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await simctl(["push", udid, bundleID, file.path])
        return "Sent a push notification to \(bundleID)."
    }

    public func setAppearance(_ appearance: Appearance) async throws {
        if devicectlReachesDevice {
            var options: [String] = []
            if let dark = appearance.dark { options += ["--mode", dark ? "dark" : "light"] }
            if let size = appearance.textSize {
                // The accessibility sizes need Larger Accessibility Sizes, and the others work either way.
                options += ["--larger-accessibility-sizes", size.hasPrefix("accessibility") ? "on" : "off"]
                options += ["--text-size", size]
            }
            if let contrast = appearance.increaseContrast { options += ["--increase-contrast", contrast ? "on" : "off"] }
            if let motion = appearance.reduceMotion { options += ["--reduce-motion", motion ? "on" : "off"] }
            _ = try await call(["device", "settings", "appearance"], options: options)
            return
        }
        if appearance.reduceMotion != nil { try requireDevicectl("Reduce Motion") }
        if let dark = appearance.dark { try await simctl(["ui", udid, "appearance", dark ? "dark" : "light"]) }
        if let size = appearance.textSize { try await simctl(["ui", udid, "content_size", size]) }
        if let contrast = appearance.increaseContrast {
            try await simctl(["ui", udid, "increase_contrast", contrast ? "enabled" : "disabled"])
        }
    }

    public func setLanguage(_ language: String, bundleID: String?) async throws -> String {
        try simulatorOnly(
            "Changing the language", instead: "On an iPhone, change it in Settings › General › Language & Region.")
        let locale = language.replacingOccurrences(of: "-", with: "_")
        try await simctl(["spawn", udid, "defaults", "write", "-g", "AppleLanguages", "-array", language])
        try await simctl(["spawn", udid, "defaults", "write", "-g", "AppleLocale", locale])
        return "The simulator's language is now \(language). Apps use it from their next launch: relaunch with launch_app."
            + (bundleID == nil ? "" : " iOS sets the language for the whole simulator, not for one app.")
    }

    public func setStatusBar(_ override: StatusBarOverride?) async throws {
        guard let override else {
            if isSimulator {
                try await simctl(["status_bar", udid, "clear"])
            } else {
                _ = try await call(["device", "simulate", "statusBar", "clear"])
            }
            return
        }
        if isSimulator {
            var options: [String] = []
            if let time = override.time { options += ["--time", time] }
            if let network = override.network { options += ["--dataNetwork", network] }
            if let bars = override.wifiBars { options += ["--wifiMode", "active", "--wifiBars", String(bars)] }
            if let bars = override.cellularBars { options += ["--cellularMode", "active", "--cellularBars", String(bars)] }
            if let state = override.batteryState { options += ["--batteryState", state] }
            if let level = override.batteryLevel { options += ["--batteryLevel", String(level)] }
            try await simctl(["status_bar", udid, "override"] + options)
            return
        }
        if override == .screenshot {
            _ = try await call(["device", "simulate", "statusBar", "preset"], arguments: ["screenshot"])
            return
        }
        var options: [String] = []
        if let time = override.time { options += ["--time", time] }
        if let network = override.network { options += ["--data-network", network == "lte" ? "LTE" : network == "5g" ? "5G" : network] }
        if let bars = override.wifiBars { options += ["--wifi-mode", "active", "--wifi-strength", String(min(max(bars, 1), 3))] }
        if let bars = override.cellularBars {
            options += ["--cellular-mode", "active", "--cellular-strength", String(min(max(bars + 1, 1), 5))]
        }
        if let state = override.batteryState { options += ["--battery-state", state == "discharging" ? "draining" : state] }
        if let level = override.batteryLevel { options += ["--battery-level", String(level)] }
        _ = try await call(["device", "simulate", "statusBar", "override"], options: options)
    }

    public func biometrics(_ action: BiometricAction) async throws {
        if isSimulator, !devicectlReachesDevice {
            // What Simulator.app's Features › Face ID menu posts, before devicectl could do it.
            let notifications: [[String]] =
                switch action {
                case .enroll, .unenroll:
                    [
                        ["-s", "com.apple.BiometricKit.enrollmentChanged", action == .enroll ? "1" : "0"],
                        ["-p", "com.apple.BiometricKit.enrollmentChanged"],
                    ]
                case .match:
                    [["-p", "com.apple.BiometricKit_Sim.pearl.match"], ["-p", "com.apple.BiometricKit_Sim.fingerTouch.match"]]
                case .fail:
                    [["-p", "com.apple.BiometricKit_Sim.pearl.nomatch"], ["-p", "com.apple.BiometricKit_Sim.fingerTouch.nomatch"]]
                }
            for arguments in notifications { try await simctl(["spawn", udid, "notifyutil"] + arguments) }
            return
        }
        switch action {
        case .match: _ = try await call(["device", "simulate", "biometrics"], options: ["--success"])
        case .fail: _ = try await call(["device", "simulate", "biometrics"], options: ["--failure"])
        case .enroll: _ = try await call(["device", "settings", "biometrics"], options: ["--enable"])
        case .unenroll: _ = try await call(["device", "settings", "biometrics"], options: ["--disable"])
        }
    }

    public func resetApp(_ bundleID: String, keychain: Bool) async throws -> String {
        try simulatorOnly(
            "Resetting an app", instead: "On an iPhone, remove it with uninstall_app and install the build again.")
        let path = try await simctl(["get_app_container", udid, bundleID, "data"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Only ever inside this simulator's app data, whatever simctl printed.
        guard path.contains("/CoreSimulator/Devices/\(udid)/data/Containers/Data/Application/"), !path.contains("..")
        else { throw DeveloperError("simctl named an unexpected data folder for \(bundleID): \(path)") }
        _ = try? await runner.run(Self.xcrun, ["simctl", "terminate", udid, bundleID], timeout: 20)
        let manager = FileManager.default
        let container = URL(fileURLWithPath: path, isDirectory: true)
        for folder in ["Documents", "Library", "tmp", "SystemData"] {
            let url = container.appendingPathComponent(folder)
            guard let items = try? manager.contentsOfDirectory(atPath: url.path) else { continue }
            for item in items { try manager.removeItem(at: url.appendingPathComponent(item)) }
        }
        if keychain { try await simctl(["keychain", udid, "reset"]) }
        return "Deleted the data of \(bundleID)"
            + (keychain ? " and emptied the simulator's keychain" : "") + ". Start it with launch_app."
    }

    public func clipboard() async throws -> String {
        if isSimulator { return try await simctl(["pbpaste", udid]) }
        let result = try await runner.run(
            try await devicectl(), ["device", "pasteboard", "paste", "--device", udid, "--timeout", "20"], timeout: 30)
        guard result.status == 0 else {
            throw DeveloperError(Self.message(fromConsole: result.output) ?? "devicectl could not read the clipboard.")
        }
        return result.output
    }

    public func setClipboard(_ text: String) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-clipboard-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        if isSimulator {
            // pbcopy reads stdin; the shell gets the UDID and the file as arguments, never as code.
            let result = try await runner.run(
                URL(fileURLWithPath: "/bin/sh"), ["-c", "exec /usr/bin/xcrun simctl pbcopy \"$0\" < \"$1\"", udid, file.path],
                timeout: 30)
            guard result.status == 0 else {
                throw DeveloperError("simctl pbcopy failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return
        }
        _ = try await call(["device", "pasteboard", "copy"], options: ["--file", file.path])
    }

    public func setOrientation(_ orientation: Orientation) async throws {
        try requireDevicectl("Rotating")
        _ = try await call(["device", "orientation", "set"], arguments: [orientation.devicectl])
    }
}
