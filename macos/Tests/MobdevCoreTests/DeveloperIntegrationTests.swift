import Foundation
import Testing
@testable import MobdevCore

/// Runs the developer tools against a real device or simulator through Xcode's devicectl. Opt-in,
/// because it acts on the device:
///
///     MOBDEV_TEST_DEVICE=<udid> MOBDEV_TEST_APP=/path/to/App.app swift test --filter DeveloperIntegration
///
/// installs the app, launches it (it should print at least one line) and uninstalls it.
///
///     MOBDEV_TEST_DEVICE=<udid> MOBDEV_TEST_BUNDLE_ID=<an installed developer app> swift test --filter DeveloperIntegration
///
/// only launches an installed app through the tools, reads its logs, stops it and reads crash
/// reports. Nothing is installed or removed.
@Suite(.serialized) struct DeveloperIntegrationTests {
    static let environment = ProcessInfo.processInfo.environment
    static let device = environment["MOBDEV_TEST_DEVICE"]
    static let app = environment["MOBDEV_TEST_APP"]
    static let bundleID = environment["MOBDEV_TEST_BUNDLE_ID"]

    @Test(.enabled(if: device != nil && bundleID != nil, "Set MOBDEV_TEST_DEVICE and MOBDEV_TEST_BUNDLE_ID"))
    func launchReadLogsAndStopAnInstalledApp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-integration")
        let control = DeviceControl(udid: Self.device!, reportsFolder: folder)
        let tools = PhoneTools(phone: FakePhone(lines: [], apps: control), activity: ActivityLog(), settleDelay: 0)
        func call(_ name: String, _ arguments: JSONValue = [:]) async throws -> ToolOutput {
            let output = try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
            print("── \(name) \(arguments.compactString)\n\(output.text)")
            return output
        }
        let app: JSONValue = .string(Self.bundleID!)

        let listed = try await call("list_apps")
        #expect(listed.text.contains(Self.bundleID!))

        let launched = try await call("launch_app", ["bundle_id": app])
        #expect(!launched.isError)
        var logs = try await call("logs", ["bundle_id": app])
        for _ in 0..<20 where logs.data?["lines"]?.arrayValue?.isEmpty ?? true {
            try await Task.sleep(nanoseconds: 500_000_000)
            logs = try await call("logs", ["bundle_id": app, "lines": 20])
        }
        #expect(logs.text.contains("\(Self.bundleID!): running"))

        let again = try await call("launch_app", ["bundle_id": app, "restart": false])
        #expect(again.text.contains("already running with its output captured"))

        let stopped = try await call("stop_app", ["bundle_id": app])
        #expect(stopped.text == "Stopped \(Self.bundleID!).")
        let after = try await call("logs", ["bundle_id": app, "lines": 1])
        #expect(!after.text.contains(": running"))

        let reports = try await call("crash_reports", ["limit": 3])
        #expect(!reports.isError)
        if let newest = reports.data?.arrayValue?.first?["name"]?.stringValue {
            let report = try await call("crash_reports", ["name": .string(newest)])
            #expect(!report.isError)
        }
    }

    @Test(.enabled(if: device != nil && app != nil, "Set MOBDEV_TEST_DEVICE and MOBDEV_TEST_APP"))
    func installLaunchReadLogsUninstall() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-integration")
        let control = DeviceControl(udid: Self.device!, reportsFolder: folder)

        let installed = try await control.install(at: URL(fileURLWithPath: Self.app!))
        #expect(installed.developer)
        let apps = try await control.apps(all: false)
        #expect(apps.contains { $0.bundleID == installed.bundleID })

        #expect(try await control.launch(installed.bundleID, arguments: [], environment: [:], restart: true) == .launched)
        #expect(control.logs.status(for: installed.bundleID) == "running")
        var lines: [AppLogs.Line] = []
        for _ in 0..<40 where lines.isEmpty {
            try await Task.sleep(nanoseconds: 250_000_000)
            lines = control.logs.read(app: installed.bundleID, after: nil, limit: 100, contains: nil).lines
        }
        #expect(!lines.isEmpty)

        let removed = try await control.uninstall(installed.bundleID)
        #expect(removed.bundleID == installed.bundleID)
        #expect(try await control.app(installed.bundleID) == nil)
    }

    static let networkApp = environment["MOBDEV_TEST_NETWORK_APP"]

    /// Network capture of an installed app that makes requests within a few seconds of its launch:
    ///
    ///     MOBDEV_TEST_DEVICE=<udid> MOBDEV_TEST_NETWORK_APP=<bundle id> swift test --filter DeveloperIntegration
    @Test(.enabled(if: device != nil && networkApp != nil, "Set MOBDEV_TEST_DEVICE and MOBDEV_TEST_NETWORK_APP"))
    func captureAnAppsRequests() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-integration")
        // Simulators have UUIDs as identifiers, iPhones "00008120-…".
        let control = DeviceControl(
            udid: Self.device!, reportsFolder: folder, simulator: UUID(uuidString: Self.device!) != nil)
        let tools = PhoneTools(phone: FakePhone(lines: [], apps: control), activity: ActivityLog(), settleDelay: 0)
        func call(_ name: String, _ arguments: JSONValue = [:]) async throws -> ToolOutput {
            let output = try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
            print("── \(name) \(arguments.compactString)\n\(output.text)")
            return output
        }
        let app: JSONValue = .string(Self.networkApp!)
        let started = try await call("start_network_capture", ["bundle_id": app])
        #expect(!started.isError)
        func count(_ log: ToolOutput) -> Int { log.data?["entries"]?.arrayValue?.count ?? 0 }
        var log = try await call("network_log")
        for _ in 0..<30 where count(log) == 0 {
            try await Task.sleep(nanoseconds: 500_000_000)
            log = try await tools.call("network_log", arguments: [:], source: "test", screenshotByDefault: false)
        }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        log = try await call("network_log", ["query": true])
        #expect(count(log) > 0)
        print(String(decoding: (log.data?["entries"] ?? .null).encoded(), as: UTF8.self))
        _ = try await call("logs", ["bundle_id": app, "lines": 30])
        let stopped = try await call("stop_network_capture")
        #expect(!stopped.isError)
        _ = try await call("stop_app", ["bundle_id": app])
    }
}
