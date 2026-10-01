import Foundation
import Testing
@testable import MobdevCore

/// Drives a booted simulator and a running Android emulator through the same tools agents use.
/// Opt-in, because they act on those devices:
///
///     MOBDEV_TEST_SIMULATOR=<udid> MOBDEV_TEST_SIMULATOR_APP=../examples/flows/fixture/MobdevFixture.app \
///       swift test --filter EmulatorIntegration
///     MOBDEV_TEST_ANDROID=<serial> swift test --filter EmulatorIntegration
///
/// The simulator app is the fixture in examples/flows/fixture (build it with its build.sh): it
/// prints every tap as a fraction of the screen, echoes typed text and crashes when launched with
/// the argument "crash". It is uninstalled afterwards. On Android the test uses the Settings app and crashes it with `am crash`.
@Suite(.serialized) struct EmulatorIntegrationTests {
    static let environment = ProcessInfo.processInfo.environment
    static let simulator = environment["MOBDEV_TEST_SIMULATOR"]
    static let simulatorApp = environment["MOBDEV_TEST_SIMULATOR_APP"]
    static let android = environment["MOBDEV_TEST_ANDROID"]

    final class Session: Sendable {
        let emulators: EmulatorHub
        let tools: DeviceTools
        let device: String

        init(device: String, adb: ADB?) async throws {
            self.device = device
            emulators = EmulatorHub(adb: adb) {}
            tools = DeviceTools(hub: DeviceHub(keyboardLayout: .us) {}, emulators: emulators, settleDelay: 0)
            emulators.start()
            for _ in 0..<60 where !emulators.devices.contains(where: { $0.id == device }) {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            try #require(emulators.devices.contains { $0.id == device }, "\(device) did not appear")
        }

        @discardableResult
        func call(_ name: String, _ arguments: JSONValue = [:]) async throws -> ToolOutput {
            var arguments = arguments
            if case .object(var object) = arguments {
                object["device"] = .string(device)
                arguments = .object(object)
            }
            let output = try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
            if name != "logs" { print("── \(name) \(arguments.compactString)\n\(output.text.prefix(800))") }
            return output
        }

        /// The newest captured lines, after waiting for one containing `text`.
        func waitForLog(_ bundleID: String, containing text: String, after cursor: Int) async throws -> String {
            for _ in 0..<40 {
                let logs = try await call("logs", ["bundle_id": .string(bundleID), "after": .number(Double(cursor)), "lines": 200])
                if logs.text.contains(text) { return logs.text }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            let logs = try await call("logs", ["bundle_id": .string(bundleID), "after": .number(Double(cursor)), "lines": 200])
            Issue.record("No log line containing \"\(text)\":\n\(logs.text)")
            return ""
        }

        func cursor(_ bundleID: String) async throws -> Int {
            let logs = try await call("logs", ["bundle_id": .string(bundleID), "lines": 1])
            return Int(logs.data?["cursor"]?.doubleValue ?? 0)
        }

        func stop() { emulators.stop() }
    }

    @Test(.enabled(if: simulator != nil && simulatorApp != nil, "Set MOBDEV_TEST_SIMULATOR and MOBDEV_TEST_SIMULATOR_APP"))
    func simulatorEndToEnd() async throws {
        let session = try await Session(device: Self.simulator!, adb: nil)
        defer { session.stop() }
        let app: JSONValue = "dev.mobdev.fixture"

        let listed = try await session.call("list_devices")
        #expect(listed.text.contains("Simulator"))
        let status = try await session.call("status")
        #expect(status.data?["ready"] == true)
        let width = try #require(status.data?["screenshot"]?["width"]?.doubleValue)
        let height = try #require(status.data?["screenshot"]?["height"]?.doubleValue)

        let installed = try await session.call("install_app", ["path": .string(Self.simulatorApp!)])
        #expect(!installed.isError)
        let launched = try await session.call("launch_app", ["bundle_id": app])
        #expect(!launched.isError)
        // devicectl attaches the console a moment after launch, so the very first lines can be
        // missed; the screen says when the app is up.
        let ready = try await session.call("wait_for_text", ["text": "Tap anywhere", "timeout": 15])
        #expect(!ready.isError)
        var cursor = try await session.cursor("dev.mobdev.fixture")

        // A tap lands where it was aimed: the fixture prints it as a fraction of the screen.
        try await session.call("tap", ["x": .number((width * 0.5).rounded()), "y": .number((height * 0.2).rounded())])
        let tapped = try await session.waitForLog("dev.mobdev.fixture", containing: "fixture: tap", after: cursor)
        let tapLine = tapped.split(whereSeparator: \.isNewline).first { $0.contains("fixture: tap") } ?? ""
        let fractions = tapLine.split(whereSeparator: \.isWhitespace).suffix(2).compactMap { Double($0) }
        #expect(fractions.count == 2, "\(tapLine.debugDescription)")
        if fractions.count == 2 {
            #expect(abs(fractions[0] - 0.5) < 0.01)
            #expect(abs(fractions[1] - 0.2) < 0.01)
        }
        cursor = try await session.cursor("dev.mobdev.fixture")

        // Typing, including y and z, which a German layout swaps. An address is left alone by
        // auto-correction and starts with a digit, so nothing is capitalized.
        try await session.call("tap_text", ["text": "Type here"])
        try await Task.sleep(nanoseconds: 800_000_000)
        try await session.call("type_text", ["text": "42 zyx@mobdev.dev", "submit": true])
        let typed = try await session.waitForLog("dev.mobdev.fixture", containing: "fixture: submitted", after: cursor)
        #expect(typed.contains("fixture: submitted 42 zyx@mobdev.dev"))
        cursor = try await session.cursor("dev.mobdev.fixture")

        // The element tree names controls by their accessibility identifiers.
        let tree = try await session.call("ui_tree")
        #expect(tree.text.contains("Button \"Ping\" id=fixture.ping"), "\(tree.text)")
        #expect(tree.text.contains("id=fixture.field"))
        let pinged = try await session.call("tap_element", ["id": "fixture.ping"])
        #expect(!pinged.isError)
        _ = try await session.waitForLog("dev.mobdev.fixture", containing: "fixture: ping", after: cursor)
        cursor = try await session.cursor("dev.mobdev.fixture")

        // The same as a flow, which waits for what it taps.
        let flow = try await session.call(
            "run_flow", ["steps": [["tap_element": ["text": "Ping"]], ["wait_for_element": ["id": "fixture.field"]]]])
        #expect(!flow.isError, "\(flow.text)")
        _ = try await session.waitForLog("dev.mobdev.fixture", containing: "fixture: ping", after: cursor)
        cursor = try await session.cursor("dev.mobdev.fixture")

        // Swiping the list reveals later rows.
        try await session.call(
            "swipe",
            ["from_x": .number((width * 0.5).rounded()), "from_y": .number((height * 0.66).rounded()),
             "to_x": .number((width * 0.5).rounded()), "to_y": .number((height * 0.46).rounded())])
        _ = try await session.waitForLog("dev.mobdev.fixture", containing: "visible", after: cursor)

        let screenshot = try await session.call("screenshot")
        #expect(screenshot.image != nil)
        let read = try await session.call("read_screen")
        #expect(read.text.contains("Mobdev Fixture"))

        try await session.call("home")
        let opened = try await session.call("open_app", ["name": "Mobdev Fixture"])
        #expect(opened.text.contains("dev.mobdev.fixture"))
        let deepLink = try await session.call("open_url", ["url": "mobdevfixture://hello"])
        #expect(!deepLink.isError)

        // A crash is reported by logs and crash_reports.
        try await session.call("launch_app", ["bundle_id": app, "arguments": ["crash"]])
        var crashed = false
        for _ in 0..<40 where !crashed {
            try await Task.sleep(nanoseconds: 250_000_000)
            crashed = try await session.call("logs", ["bundle_id": app, "lines": 1]).text.contains("crashed")
        }
        #expect(crashed)
        var reports = try await session.call("crash_reports", ["app": app, "limit": 1])
        for _ in 0..<20 where reports.data?.arrayValue?.isEmpty ?? true {
            try await Task.sleep(nanoseconds: 500_000_000)
            reports = try await session.call("crash_reports", ["app": app, "limit": 1])
        }
        let reportName = try #require(reports.data?.arrayValue?.first?["name"]?.stringValue)
        let report = try await session.call("crash_reports", ["name": .string(reportName)])
        #expect(report.text.contains("EXC_BREAKPOINT"))

        let stopped = try await session.call("stop_app", ["bundle_id": app])
        #expect(!stopped.isError)
        let removed = try await session.call("uninstall_app", ["bundle_id": app])
        #expect(!removed.isError)
    }

    @Test(.enabled(if: android != nil, "Set MOBDEV_TEST_ANDROID"))
    func androidEndToEnd() async throws {
        let adb = try #require(ADB.find())
        let session = try await Session(device: Self.android!, adb: adb)
        defer { session.stop() }
        let settings: JSONValue = "com.android.settings"

        let listed = try await session.call("list_devices")
        #expect(listed.text.contains("Android"))
        let screenshot = try await session.call("screenshot")
        #expect(screenshot.image != nil)
        let status = try await session.call("status")
        #expect(status.data?["ready"] == true)

        // Settings reopens where it was left; stopped first, it opens on its main page.
        try await session.call("stop_app", ["bundle_id": settings])
        let opened = try await session.call("open_app", ["name": "Settings"])
        #expect(opened.text.contains("com.android.settings"))
        let visible = try await session.call("wait_for_text", ["text": "Network", "timeout": 10])
        #expect(!visible.isError)
        let tree = try await session.call("ui_tree", ["contains": "network"])
        #expect(tree.text.contains("\"Network & internet\" id=android:id/title"), "\(tree.text)")
        let scrolled = try await session.call("scroll", ["direction": "down", "amount": 8])
        #expect(!scrolled.isError)
        try await session.call("home")

        let launched = try await session.call("launch_app", ["bundle_id": settings])
        #expect(launched.text.contains("Launched"))
        let running = try await session.call("logs", ["bundle_id": settings, "lines": 5])
        #expect(running.text.contains("com.android.settings: running"))

        _ = try await adb.shell(Self.android!, "am crash com.android.settings")
        var crashed = ""
        for _ in 0..<20 where !crashed.contains("crashed") {
            try await Task.sleep(nanoseconds: 500_000_000)
            crashed = try await session.call("logs", ["bundle_id": settings, "lines": 1]).text
        }
        #expect(crashed.contains("crashed: android.app.RemoteServiceException"))
        let reports = try await session.call("crash_reports", ["app": settings, "limit": 1])
        let reportName = try #require(reports.data?.arrayValue?.first?["name"]?.stringValue)
        let report = try await session.call("crash_reports", ["name": .string(reportName)])
        #expect(report.text.contains("shell-induced crash"))

        let stopped = try await session.call("stop_app", ["bundle_id": settings])
        #expect(!stopped.isError)
        let refused = try await session.call("uninstall_app", ["bundle_id": settings])
        #expect(refused.isError)
        #expect(refused.text.contains("system app"))
        try await session.call("home")
    }

    /// Typing, keys and links in Settings, then an .apk from MOBDEV_TEST_ANDROID_APK: installed,
    /// launched, removed and installed again, so the device ends as it started.
    @Test(.enabled(if: android != nil && environment["MOBDEV_TEST_ANDROID_APK"] != nil, "Set MOBDEV_TEST_ANDROID_APK"))
    func androidInputAndApps() async throws {
        let adb = try #require(ADB.find())
        let session = try await Session(device: Self.android!, adb: adb)
        defer { session.stop() }

        try await session.call("stop_app", ["bundle_id": "com.android.settings"])
        try await session.call("open_app", ["name": "Settings"])
        _ = try await session.call("wait_for_text", ["text": "Network", "timeout": 10])
        // The search bar is a clickable layout without a label of its own, found by its resource id.
        let search = try await session.call("tap_element", ["id": "search_action_bar"])
        #expect(!search.isError)
        // The search page takes over the screen; the main page's "Network" is gone once it is up.
        try await session.call("wait_for_text", ["text": "Network", "gone": true, "timeout": 10])
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await session.call("type_text", ["text": "display"])
        let found = try await session.call("wait_for_text", ["text": "Display size", "timeout": 10])
        #expect(!found.isError)
        try await session.call("press_key", ["key": "escape"])
        try await session.call("press_key", ["key": "escape"])
        try await session.call("home")
        let link = try await session.call("open_url", ["url": "https://example.com"])
        #expect(!link.isError)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await session.call("home")

        let apk = Self.environment["MOBDEV_TEST_ANDROID_APK"]!
        let installed = try await session.call("install_app", ["path": .string(apk)])
        #expect(!installed.isError)
        let package = try #require(installed.data?["bundle_id"]?.stringValue)
        let listed = try await session.call("list_apps")
        #expect(listed.text.contains(package))
        let launched = try await session.call("launch_app", ["bundle_id": .string(package)])
        #expect(launched.text.contains("Launched"))
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let logs = try await session.call("logs", ["bundle_id": .string(package), "lines": 5])
        #expect((logs.data?["lines"]?.arrayValue?.count ?? 0) > 0)
        print("── logs\n\(logs.text)")
        let removed = try await session.call("uninstall_app", ["bundle_id": .string(package)])
        #expect(removed.text.contains("Removed"))
        let again = try await session.call("install_app", ["path": .string(apk)])
        #expect(!again.isError)
        try await session.call("home")
    }
}
