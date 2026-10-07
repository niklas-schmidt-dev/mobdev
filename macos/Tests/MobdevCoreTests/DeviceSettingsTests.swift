import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// Records what the settings tools ask of a device.
final class FakeSettings: DeviceSettings, @unchecked Sendable {
    let calls = Locked<[String]>([])
    let payloads = Locked<[JSONValue]>([])

    private func note(_ call: String) { calls.withLock { $0.append(call) } }

    func setLocation(_ coordinate: Coordinate) async throws { note("location \(coordinate.pair)") }
    func followRoute(_ waypoints: [Coordinate], speed: Double) async throws {
        note("route \(waypoints.map(\.pair).joined(separator: " ")) at \(speed)")
    }
    func clearLocation() async throws { note("clear location") }
    func setPermission(_ permission: String, _ state: PermissionState, bundleID: String) async throws {
        note("\(state.rawValue) \(permission) \(bundleID)")
    }
    func sendPush(_ payload: JSONValue, to bundleID: String) async throws -> String {
        payloads.withLock { $0.append(payload) }
        note("push \(bundleID)")
        return "Sent."
    }
    func setAppearance(_ appearance: Appearance) async throws {
        note("appearance dark=\(appearance.dark.map(String.init) ?? "-") size=\(appearance.textSize ?? "-")")
    }
    func setLanguage(_ language: String, bundleID: String?) async throws -> String {
        note("language \(language) \(bundleID ?? "-")")
        return "Language set."
    }
    func savedLanguage(bundleID: String?) async throws -> SavedLanguage {
        note("save language \(bundleID ?? "-")")
        return SavedLanguage(languages: ["en-US"], locale: "en_US")
    }
    func restoreLanguage(_ saved: SavedLanguage, bundleID: String?) async throws {
        note("restore language \(saved.languages.joined(separator: ",")) \(bundleID ?? "-")")
    }
    func setStatusBar(_ override: StatusBarOverride?) async throws {
        note(override.map { "status bar \($0.time ?? "-") \($0.batteryLevel.map(String.init) ?? "-")" } ?? "status bar clear")
    }
    func biometrics(_ action: BiometricAction) async throws { note("biometrics \(action.rawValue)") }
    func resetApp(_ bundleID: String, keychain: Bool) async throws -> String {
        note("reset \(bundleID) keychain=\(keychain)")
        return "Reset."
    }
    func clipboard() async throws -> String { "copied text" }
    func setClipboard(_ text: String) async throws { note("clipboard \(text)") }
    func setOrientation(_ orientation: Orientation) async throws { note("orientation \(orientation.rawValue)") }
}

@Suite struct SettingsToolTests {
    func tools(_ settings: FakeSettings? = FakeSettings()) -> PhoneTools {
        PhoneTools(phone: FakePhone(lines: [], settings: settings), activity: ActivityLog(), settleDelay: 0)
    }

    func call(_ tools: PhoneTools, _ name: String, _ arguments: JSONValue) async throws -> ToolOutput {
        try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
    }

    @Test func locationTakesAPointARouteOrClear() async throws {
        let settings = FakeSettings()
        let tools = tools(settings)
        #expect(try await !call(tools, "set_location", ["latitude": 52.52, "longitude": 13.405]).isError)
        let route: JSONValue = [
            "route": [["latitude": 1, "longitude": 2], [3, 4]], "speed": 5,
        ]
        #expect(try await !call(tools, "set_location", route).isError)
        #expect(try await !call(tools, "set_location", ["clear": true]).isError)
        #expect(settings.calls.get() == ["location 52.52,13.405", "route 1.0,2.0 3.0,4.0 at 5.0", "clear location"])

        let outside = try await call(tools, "set_location", ["latitude": 100, "longitude": 0])
        #expect(outside.isError)
        #expect(outside.text.contains("latitude must be between"))
        #expect(try await call(tools, "set_location", ["route": [[1, 2]]]).isError)
        #expect(try await call(tools, "set_location", [:]).isError)
        #expect(settings.calls.get().count == 3)
    }

    @Test func permissionsDefaultToGrant() async throws {
        let settings = FakeSettings()
        let tools = tools(settings)
        let granted = try await call(tools, "set_permission", ["bundle_id": "com.example.app", "permission": "photos"])
        #expect(granted.text == "Granted photos to com.example.app.")
        _ = try await call(tools, "set_permission", ["bundle_id": "com.example.app", "permission": "camera", "state": "reset"])
        let wrong = try await call(tools, "set_permission", ["bundle_id": "a.b", "permission": "photos", "state": "maybe"])
        #expect(wrong.isError)
        #expect(settings.calls.get() == ["grant photos com.example.app", "reset camera com.example.app"])
    }

    @Test func pushBuildsAnAPNsPayload() async throws {
        let settings = FakeSettings()
        let tools = tools(settings)
        let output = try await call(
            tools, "send_push",
            ["bundle_id": "com.example.app", "title": "Hi", "body": "There", "badge": 3, "data": ["deeplink": "app://inbox"]])
        #expect(!output.isError)
        let payload = try #require(settings.payloads.get().first)
        #expect(payload["aps"]?["alert"]?["title"] == "Hi")
        #expect(payload["aps"]?["alert"]?["body"] == "There")
        #expect(payload["aps"]?["badge"] == 3)
        #expect(payload["deeplink"] == "app://inbox")

        let whole: JSONValue = ["aps": ["content-available": 1], "id": 7]
        _ = try await call(tools, "send_push", ["bundle_id": "com.example.app", "payload": whole])
        #expect(settings.payloads.get().last == whole)

        #expect(try await call(tools, "send_push", ["bundle_id": "a.b"]).isError)
        #expect(try await call(tools, "send_push", ["bundle_id": "a.b", "payload": ["no": "aps"]]).isError)
        let huge = String(repeating: "x", count: 5000)
        let tooBig = try await call(tools, "send_push", ["bundle_id": "a.b", "body": .string(huge)])
        #expect(tooBig.text.contains("at most 4096"))
    }

    @Test func appearanceAndStatusBar() async throws {
        let settings = FakeSettings()
        let tools = tools(settings)
        let dark = try await call(tools, "set_appearance", ["dark": true, "text_size": "accessibility-large"])
        #expect(dark.text == "Set dark mode, text size accessibility-large.")
        #expect(try await call(tools, "set_appearance", [:]).isError)
        #expect(try await call(tools, "set_appearance", ["text_size": "huge"]).isError)

        _ = try await call(tools, "set_status_bar", ["preset": "screenshot", "battery_level": 80])
        _ = try await call(tools, "set_status_bar", ["preset": "clear"])
        #expect(try await call(tools, "set_status_bar", [:]).isError)
        #expect(
            settings.calls.get() == [
                "appearance dark=true size=accessibility-large", "status bar 9:41 80", "status bar clear",
            ])
    }

    @Test func otherSettingsReachTheDevice() async throws {
        let settings = FakeSettings()
        let tools = tools(settings)
        _ = try await call(tools, "set_language", ["language": "de-DE"])
        #expect(try await call(tools, "set_language", ["language": "de DE; rm -rf"]).isError)
        _ = try await call(tools, "biometrics", ["action": "match"])
        _ = try await call(tools, "reset_app", ["bundle_id": "com.example.app", "keychain": true])
        _ = try await call(tools, "clipboard", ["text": "hello"])
        let read = try await call(tools, "clipboard", [:])
        #expect(read.text == "copied text")
        _ = try await call(tools, "set_orientation", ["orientation": "landscape_left"])
        #expect(
            settings.calls.get() == [
                "language de-DE -", "biometrics match", "reset com.example.app keychain=true", "clipboard hello",
                "orientation landscape_left",
            ])
    }

    @Test func aDeviceWithoutSettingsSaysWhy() async throws {
        let output = try await call(tools(nil), "set_location", ["latitude": 1, "longitude": 2])
        #expect(output.isError)
        #expect(output.text.contains("not available"))
    }
}

@Suite struct SimulatorSettingsTests {
    func control(_ simctl: SimctlTests.FakeSimctl) -> DeviceControl {
        DeviceControl(
            udid: "SIM-1", runner: simctl, reportsFolder: FileManager.default.temporaryDirectory, simulator: true,
            simctl: true)
    }

    @Test func simulatorSettingsGoThroughSimctl() async throws {
        let simctl = SimctlTests.FakeSimctl()
        let control = control(simctl)
        try await control.setLocation(Coordinate(latitude: 52.52, longitude: 13.405))
        try await control.followRoute(
            [Coordinate(latitude: 1, longitude: 2), Coordinate(latitude: 3, longitude: 4)], speed: 20)
        try await control.setPermission("photos", .grant, bundleID: "com.example.app")
        try await control.setAppearance(Appearance(dark: true, textSize: "small", increaseContrast: true))
        try await control.setStatusBar(.screenshot)
        try await control.setStatusBar(nil)
        _ = try await control.setLanguage("de-DE", bundleID: nil)
        try await control.biometrics(.match)
        #expect(
            simctl.calls.get() == [
                ["simctl", "location", "SIM-1", "set", "52.52,13.405"],
                ["simctl", "location", "SIM-1", "start", "--speed=20.0", "--interval=1", "1.0,2.0", "3.0,4.0"],
                ["simctl", "privacy", "SIM-1", "grant", "photos", "com.example.app"],
                ["simctl", "ui", "SIM-1", "appearance", "dark"],
                ["simctl", "ui", "SIM-1", "content_size", "small"],
                ["simctl", "ui", "SIM-1", "increase_contrast", "enabled"],
                [
                    "simctl", "status_bar", "SIM-1", "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode",
                    "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState",
                    "charged", "--batteryLevel", "100",
                ],
                ["simctl", "status_bar", "SIM-1", "clear"],
                ["simctl", "spawn", "SIM-1", "defaults", "write", "-g", "AppleLanguages", "-array", "de-DE"],
                ["simctl", "spawn", "SIM-1", "defaults", "write", "-g", "AppleLocale", "de_DE"],
                ["simctl", "spawn", "SIM-1", "notifyutil", "-p", "com.apple.BiometricKit_Sim.pearl.match"],
                ["simctl", "spawn", "SIM-1", "notifyutil", "-p", "com.apple.BiometricKit_Sim.fingerTouch.match"],
            ])
    }

    @Test func simulatorRefusesWhatItCannotDo() async throws {
        let simctl = SimctlTests.FakeSimctl()
        let control = control(simctl)
        await #expect(throws: DeveloperError.self) { try await control.setPermission("camera", .grant, bundleID: "a.b") }
        await #expect(throws: DeveloperError.self) { try await control.setPermission("all", .grant, bundleID: "a.b") }
        // Reduce Motion and rotating need Xcode 27's devicectl.
        await #expect(throws: DeveloperError.self) { try await control.setAppearance(Appearance(reduceMotion: true)) }
        await #expect(throws: DeveloperError.self) { try await control.setOrientation(.landscapeLeft) }
        #expect(simctl.calls.get().isEmpty)
    }

    @Test func iPhonesRefuseSimulatorOnlySettings() async throws {
        let iPhone = DeviceControl(
            udid: "IPHONE", runner: SimctlTests.FakeSimctl(), reportsFolder: FileManager.default.temporaryDirectory)
        await #expect(throws: DeveloperError.self) { try await iPhone.setPermission("photos", .grant, bundleID: "a.b") }
        await #expect(throws: DeveloperError.self) { _ = try await iPhone.sendPush(["aps": [:]], to: "a.b") }
        await #expect(throws: DeveloperError.self) { _ = try await iPhone.resetApp("a.b", keychain: false) }
        await #expect(throws: DeveloperError.self) { _ = try await iPhone.setLanguage("de-DE", bundleID: nil) }
    }
}

@Suite struct AndroidSettingsTests {
    @Test func routesStepAlongTheWaypoints() {
        let start = Coordinate(latitude: 52.52, longitude: 13.405)
        let end = Coordinate(latitude: 52.521, longitude: 13.405)  // About 111 m north.
        let distance = AndroidSettings.distance(start, end)
        #expect(abs(distance - 111.2) < 1)
        let points = AndroidSettings.routePoints([start, end], speed: 50, interval: 1)
        #expect(points.count == 4)  // Start, then three steps of at most 50 m.
        #expect(points.first == start)
        #expect(points.last == end)
    }

    @Test func iOSPermissionNamesMapToAndroid() throws {
        #expect(try AndroidSettings.androidPermissions("camera") == ["android.permission.CAMERA"])
        #expect(try AndroidSettings.androidPermissions("notifications") == ["android.permission.POST_NOTIFICATIONS"])
        #expect(try AndroidSettings.androidPermissions("location").count == 2)
        #expect(try AndroidSettings.androidPermissions("android.permission.READ_SMS") == ["android.permission.READ_SMS"])
        #expect(throws: DeveloperError.self) { try AndroidSettings.androidPermissions("siri") }
        #expect(throws: DeveloperError.self) { try AndroidSettings.androidPermissions("android.permission.X; reboot") }
        #expect(Set(AndroidSettings.fontScales.keys) == Set(Appearance.textSizes))
    }
}
