import Foundation
import Testing
@testable import MobdevCore

/// Real recordings with Instruments on a simulator of your own, through the tools:
///
///     xcrun simctl create mobdev-instruments "iPhone 17"   # prints its UDID; boot it
///     examples/flows/fixture/build.sh                     # MobdevFixture.app
///     MOBDEV_TEST_INSTRUMENTS_SIMULATOR=<udid> MOBDEV_TEST_SIMULATOR_APP=<path>/MobdevFixture.app \
///       swift test --filter InstrumentsIntegration
///
/// It installs and launches the fixture, samples it, reads the simulator's load, records Time
/// Profiler attached to it and to Settings.
@Suite(.serialized) struct InstrumentsIntegrationTests {
    static let environment = ProcessInfo.processInfo.environment
    static let simulator = environment["MOBDEV_TEST_INSTRUMENTS_SIMULATOR"]
    static let app = environment["MOBDEV_TEST_SIMULATOR_APP"]

    func call(_ tools: PhoneTools, _ name: String, _ arguments: JSONValue) async throws -> ToolOutput {
        try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
    }

    @Test(.enabled(if: simulator != nil && app != nil, "Set MOBDEV_TEST_INSTRUMENTS_SIMULATOR and MOBDEV_TEST_SIMULATOR_APP"))
    func recordsAndReadsASimulator() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-instruments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let control = DeviceControl(udid: Self.simulator!, reportsFolder: folder, simulator: true)
        let installed = try await control.install(at: URL(fileURLWithPath: Self.app!))
        try await control.activate(installed.bundleID)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let tools = PhoneTools(phone: DevLoopPhone(performance: control), activity: ActivityLog(), settleDelay: 0)

        let performance = try await call(tools, "performance", ["bundle_id": .string(installed.bundleID), "seconds": 2])
        print(performance.text)
        #expect(!performance.isError, "\(performance.text)")
        #expect((performance.data?["memory_mb"]?["peak"]?.doubleValue ?? 0) > 1)

        let load = try await call(tools, "device_load", ["count": 5])
        print(load.text)
        #expect(!load.isError, "\(load.text)")
        #expect((load.data?["processes"]?.doubleValue ?? 0) > 20)
        #expect(load.text.contains("SpringBoard"))

        let trace = folder.appendingPathComponent("fixture.trace")
        let recorded = try await call(
            tools, "record_trace", ["bundle_id": .string(installed.bundleID), "seconds": 3, "path": .string(trace.path)])
        print(recorded.text)
        #expect(!recorded.isError, "\(recorded.text)")
        #expect(FileManager.default.fileExists(atPath: trace.path))
        #expect(recorded.data?["template"] == "Time Profiler")
        // Attached, not launched: the app keeps running.
        #expect(try await control.runningPid(of: installed.bundleID) > 0)

        // A system app attaches too.
        try await control.activate("com.apple.Preferences")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let system = try await call(
            tools, "record_trace",
            ["bundle_id": "com.apple.Preferences", "seconds": 2, "path": .string(folder.appendingPathComponent("settings.trace").path)])
        print(system.text)
        #expect(!system.isError, "\(system.text)")
        _ = try? await control.stop("com.apple.Preferences")
    }
}
