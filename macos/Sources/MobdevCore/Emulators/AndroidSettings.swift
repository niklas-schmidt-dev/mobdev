import Foundation

/// Device settings on Android through adb: the emulator console for location and fingerprints, the
/// package manager for permissions and data, `settings` and `cmd` for the rest.
final class AndroidSettings: DeviceSettings, @unchecked Sendable {
    let serial: String
    let adb: ADB
    private let isEmulator: @Sendable () -> Bool
    /// The route being followed, so a new location or route ends it.
    private let route = Locked<Task<Void, Never>?>(nil)

    init(serial: String, adb: ADB, isEmulator: @escaping @Sendable () -> Bool) {
        self.serial = serial
        self.adb = adb
        self.isEmulator = isEmulator
    }

    deinit { route.get()?.cancel() }

    private func shell(_ command: String) async throws -> String {
        try await adb.shell(serial, command, timeout: 20)
    }

    /// A command for the emulator's console, such as "geo fix 13.4 52.5".
    private func console(_ arguments: [String], what: String) async throws {
        guard isEmulator() else {
            throw DeveloperError(
                "\(what) works on Android emulators only. On a phone, install a mock location or test app instead.")
        }
        let result = try await adb.run(serial, ["emu"] + arguments, timeout: 15)
        guard result.status == 0, !result.output.contains("KO") else {
            throw DeveloperError(
                "The emulator refused \(arguments.first ?? "it"): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: Location

    /// The console takes longitude first.
    private func fix(_ coordinate: Coordinate) async throws {
        try await console(["geo", "fix", "\(coordinate.longitude)", "\(coordinate.latitude)"], what: "Setting the location")
    }

    func setLocation(_ coordinate: Coordinate) async throws {
        route.withLock { $0?.cancel(); $0 = nil }
        try await fix(coordinate)
    }

    /// The console has no routes, so Mobdev moves the emulator along the waypoints once a second.
    func followRoute(_ waypoints: [Coordinate], speed: Double) async throws {
        try await setLocation(waypoints[0])
        let points = Self.routePoints(waypoints, speed: speed, interval: 1)
        let task = Task { [weak self] in
            for point in points.dropFirst() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                try? await self.fix(point)
            }
        }
        route.withLock { $0?.cancel(); $0 = task }
    }

    func clearLocation() async throws {
        route.withLock { $0?.cancel(); $0 = nil }
    }

    /// Positions every `interval` seconds when moving at `speed` m/s along straight lines between
    /// the waypoints, the first and last waypoint included.
    static func routePoints(_ waypoints: [Coordinate], speed: Double, interval: TimeInterval) -> [Coordinate] {
        guard let first = waypoints.first else { return [] }
        var points = [first]
        let step = max(speed * interval, 0.1)
        for (from, to) in zip(waypoints, waypoints.dropFirst()) {
            let count = max(Int((distance(from, to) / step).rounded(.up)), 1)
            for index in 1...count {
                let t = Double(index) / Double(count)
                points.append(
                    Coordinate(
                        latitude: from.latitude + (to.latitude - from.latitude) * t,
                        longitude: from.longitude + (to.longitude - from.longitude) * t))
            }
        }
        return points
    }

    /// Meters between two points, close enough for routes in a test.
    static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let radians = Double.pi / 180
        let x = (b.longitude - a.longitude) * radians * cos((a.latitude + b.latitude) / 2 * radians)
        let y = (b.latitude - a.latitude) * radians
        return (x * x + y * y).squareRoot() * 6_371_000
    }

    // MARK: Permissions

    /// iOS's service names to Android's runtime permissions.
    static func androidPermissions(_ name: String) throws -> [String] {
        if name.hasPrefix("android.permission.") {
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) else {
                throw DeveloperError("\(name) is not a permission name.")
            }
            return [name]
        }
        let permissions: [String: [String]] = [
            "camera": ["CAMERA"],
            "microphone": ["RECORD_AUDIO"],
            "location": ["ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION"],
            "location-always": ["ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION"],
            "contacts": ["READ_CONTACTS", "WRITE_CONTACTS"],
            "contacts-limited": ["READ_CONTACTS"],
            "calendar": ["READ_CALENDAR", "WRITE_CALENDAR"],
            "photos": ["READ_MEDIA_IMAGES", "READ_MEDIA_VIDEO"],
            "photos-add": ["READ_MEDIA_IMAGES"],
            "media-library": ["READ_MEDIA_AUDIO"],
            "motion": ["ACTIVITY_RECOGNITION"],
            "notifications": ["POST_NOTIFICATIONS"],
        ]
        guard let mapped = permissions[name] else {
            throw DeveloperError(
                "Android has no \(name) permission. Use one of \(permissions.keys.sorted().joined(separator: ", ")) or a full android.permission name.")
        }
        return mapped.map { "android.permission.\($0)" }
    }

    func setPermission(_ permission: String, _ state: PermissionState, bundleID: String) async throws {
        let package = try ADB.checkPackage(bundleID)
        var failures: [String] = []
        for name in try Self.androidPermissions(permission) {
            let command = switch state {
            case .grant: "pm grant \(package) \(name)"
            case .revoke: "pm revoke \(package) \(name)"
            // Revoked without the "user decided" flags, the app asks again.
            case .reset: "pm revoke \(package) \(name); pm clear-permission-flags \(package) \(name) user-set user-fixed"
            }
            let output = try await shell(command + " 2>&1")
            if output.contains("Exception") || output.contains("Error") {
                failures.append(output.split(separator: "\n").first.map(String.init) ?? output)
            }
        }
        if !failures.isEmpty {
            throw DeveloperError(
                "Android refused: \(failures.joined(separator: " ")) The app must declare the permission in its manifest, and it must be one that is asked for at runtime.")
        }
    }

    // MARK: Notifications

    /// Android has no simulated pushes; the shell posts the notification, so it looks like one.
    func sendPush(_ payload: JSONValue, to bundleID: String) async throws -> String {
        let alert = payload["aps"]?["alert"]
        let title = alert?["title"]?.stringValue ?? payload["title"]?.stringValue ?? ""
        let body = alert?.stringValue ?? alert?["body"]?.stringValue ?? payload["body"]?.stringValue ?? ""
        guard !title.isEmpty || !body.isEmpty else {
            throw DeveloperError("Pass a title or body: Android shows the notification, not a payload for the app.")
        }
        var command = "cmd notification post"
        if !title.isEmpty { command += " -t \(ADB.quote(title))" }
        command += " mobdev \(ADB.quote(body.isEmpty ? title : body))"
        _ = try await shell(command)
        return "Posted a notification on Android. It comes from the shell, not through Firebase, so \(bundleID) does not receive it as a message."
    }

    // MARK: Appearance

    /// Android's font scales for iOS's text sizes, the nearest step.
    static let fontScales: [String: Double] = [
        "extra-small": 0.8, "small": 0.85, "medium": 0.9, "large": 1.0, "extra-large": 1.15, "extra-extra-large": 1.3,
        "extra-extra-extra-large": 1.5, "accessibility-medium": 1.6, "accessibility-large": 1.7,
        "accessibility-extra-large": 1.8, "accessibility-extra-extra-large": 1.9,
        "accessibility-extra-extra-extra-large": 2.0,
    ]

    func setAppearance(_ appearance: Appearance) async throws {
        var commands: [String] = []
        if let dark = appearance.dark { commands.append("cmd uimode night \(dark ? "yes" : "no")") }
        if let size = appearance.textSize, let scale = Self.fontScales[size] {
            commands.append("settings put system font_scale \(scale)")
        }
        if let contrast = appearance.increaseContrast {
            commands.append("settings put secure high_text_contrast_enabled \(contrast ? 1 : 0)")
        }
        if let motion = appearance.reduceMotion {
            for setting in ["animator_duration_scale", "transition_animation_scale", "window_animation_scale"] {
                commands.append("settings put global \(setting) \(motion ? 0 : 1)")
            }
        }
        _ = try await shell(commands.joined(separator: "; "))
    }

    func setLanguage(_ language: String, bundleID: String?) async throws -> String {
        guard let bundleID else {
            throw DeveloperError(
                "Android changes the whole device's language only with root. Pass bundle_id to set it for one app (Android 13 and later).")
        }
        let package = try ADB.checkPackage(bundleID)
        guard language.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw DeveloperError("\(language) is not a language tag such as de-DE.")
        }
        let output = try await shell("cmd locale set-app-locales \(package) --locales \(language) 2>&1")
        if output.contains("Unknown command") || output.contains("Exception") {
            throw DeveloperError("Android could not set the app's language: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return "\(package) now uses \(language)."
    }

    // MARK: Status bar

    /// System UI's demo mode, which shows fixed values until it is left.
    func setStatusBar(_ override: StatusBarOverride?) async throws {
        let demo = "am broadcast -a com.android.systemui.demo -e command"
        guard let override else {
            _ = try await shell("\(demo) exit")
            return
        }
        var commands = ["settings put global sysui_demo_allowed 1", "\(demo) enter", "\(demo) notifications -e visible false"]
        if let time = override.time {
            let digits = time.filter(\.isNumber)
            let hhmm = digits.count == 3 ? "0" + digits : String(digits.prefix(4))
            if hhmm.count == 4 { commands.append("\(demo) clock -e hhmm \(hhmm)") }
        }
        if override.batteryLevel != nil || override.batteryState != nil {
            var battery = "\(demo) battery"
            if let level = override.batteryLevel { battery += " -e level \(level)" }
            if let state = override.batteryState { battery += " -e plugged \(state == "discharging" ? "false" : "true")" }
            commands.append(battery)
        }
        if let bars = override.wifiBars { commands.append("\(demo) network -e wifi show -e level \(min(bars, 4))") }
        if let bars = override.cellularBars { commands.append("\(demo) network -e mobile show -e level \(min(bars, 4))") }
        _ = try await shell(commands.joined(separator: "; "))
    }

    // MARK: Biometrics

    /// The emulator's virtual fingerprint sensor. Finger 1 is the one enrolled in Settings.
    func biometrics(_ action: BiometricAction) async throws {
        switch action {
        case .match: try await console(["finger", "touch", "1"], what: "Simulating a fingerprint")
        case .fail: try await console(["finger", "touch", "99"], what: "Simulating a fingerprint")
        case .enroll, .unenroll:
            throw DeveloperError(
                "Android enrolls fingerprints in Settings › Security only. Add one there (biometrics match touches the sensor when Settings asks), then use match and fail.")
        }
    }

    // MARK: Data, clipboard, orientation

    func resetApp(_ bundleID: String, keychain: Bool) async throws -> String {
        let package = try ADB.checkPackage(bundleID)
        let output = try await shell("pm clear \(package) 2>&1")
        guard output.contains("Success") else {
            throw DeveloperError("pm clear failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return "Deleted the data of \(package), its saved keys included. Start it with launch_app."
    }

    func clipboard() async throws -> String {
        throw DeveloperError("Android lets apps read the clipboard only while they are in front; adb cannot. Read the field with ui_tree instead.")
    }

    func setClipboard(_ text: String) async throws {
        throw DeveloperError("adb cannot set Android's clipboard. Type the text into the field with type_text instead.")
    }

    func setOrientation(_ orientation: Orientation) async throws {
        let rotation = switch orientation {
        case .portrait: 0
        case .landscapeLeft: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        }
        _ = try await shell("settings put system accelerometer_rotation 0; settings put system user_rotation \(rotation)")
    }
}
