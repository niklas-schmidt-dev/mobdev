import Foundation
import Testing
@testable import MobdevCore

/// Runs the developer tools against a real device or simulator through Xcode's devicectl. Opt-in,
/// because it installs and launches an app:
///
///     MOBDEV_TEST_DEVICE=<udid> MOBDEV_TEST_APP=/path/to/App.app swift test --filter DeveloperIntegration
///
/// The app should print at least one line after launch. It is uninstalled afterwards.
@Suite(.serialized) struct DeveloperIntegrationTests {
    static let environment = ProcessInfo.processInfo.environment
    static let device = environment["MOBDEV_TEST_DEVICE"]
    static let app = environment["MOBDEV_TEST_APP"]

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
}
