import Foundation
import Testing
@testable import MobdevCore

/// Simulators with an Xcode older than 27, whose devicectl does not know them, go through simctl.
@Suite struct SimctlTests {
    /// Answers `xcrun simctl …` and records the calls; `start` plays a console.
    final class FakeSimctl: CommandRunning, @unchecked Sendable {
        let calls = Locked<[[String]]>([])
        var listapps = ""
        var console: [String] = []
        /// When set, the console ends with this status right after its lines, as simctl does when
        /// it could not launch the app.
        var exitStatus: Int32?

        func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
            calls.withLock { $0.append(arguments) }
            if arguments.dropFirst().first == "listapps" { return CommandResult(status: 0, output: listapps) }
            return CommandResult(status: 0, output: "")
        }

        func start(
            _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
            onExit: @escaping @Sendable (Int32) -> Void
        ) throws -> RunningCommand {
            calls.withLock { $0.append([executable.path] + arguments) }
            for line in console { onLine(line) }
            if let exitStatus { onExit(exitStatus) }
            return Stopper()
        }

        func runBinary(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, data: Data) {
            (0, Data())
        }

        struct Stopper: RunningCommand {
            func stop() {}
        }
    }

    /// What `xcrun simctl listapps` prints: an old-style property list.
    static let listapps = """
        {
            "com.apple.Preferences" =     {
                ApplicationType = System;
                CFBundleDisplayName = Settings;
                CFBundleIdentifier = "com.apple.Preferences";
                CFBundleShortVersionString = "1.0";
                CFBundleVersion = 1;
                Path = "/Library/Developer/CoreSimulator/Volumes/iOS/Preferences.app";
            };
            "dev.mobdev.fixture" =     {
                ApplicationType = User;
                CFBundleDisplayName = "Mobdev Fixture";
                CFBundleIdentifier = "dev.mobdev.fixture";
                CFBundleShortVersionString = "1.3";
                CFBundleVersion = 8;
                Path = "/Users/runner/Library/Developer/CoreSimulator/Devices/X/data/Containers/Bundle/Application/Y/MobdevFixture.app";
            };
        }
        """

    @Test func listappsBecomesInstalledApps() {
        let apps = DeviceControl.simctlApps(from: Self.listapps)
        #expect(apps.count == 2)
        let fixture = apps.first { $0.bundleID == "dev.mobdev.fixture" }
        #expect(fixture?.name == "Mobdev Fixture")
        #expect(fixture?.version == "1.3")
        #expect(fixture?.build == "8")
        #expect(fixture?.developer == true)
        #expect(apps.first { $0.bundleID == "com.apple.Preferences" }?.developer == false)
        #expect(DeviceControl.simctlApps(from: "not a list").isEmpty)
    }

    @Test func appsInstallLaunchAndRemoveThroughSimctl() async throws {
        let simctl = FakeSimctl()
        simctl.listapps = Self.listapps
        // simctl's own pid line, then the app's output.
        simctl.console = ["dev.mobdev.fixture: 4242", "fixture: launched"]
        let control = DeviceControl(
            udid: "SIM-1", runner: simctl, reportsFolder: FileManager.default.temporaryDirectory, simulator: true,
            simctl: true)

        let developer = try await control.apps(all: false)
        #expect(developer.map(\.bundleID) == ["dev.mobdev.fixture"])

        let app = FileManager.default.temporaryDirectory.appendingPathComponent("Fixture-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        try (["CFBundleIdentifier": "dev.mobdev.fixture"] as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        let installed = try await control.install(at: app)
        #expect(installed.name == "Mobdev Fixture")

        let outcome = try await control.launch("dev.mobdev.fixture", arguments: ["crash"], environment: ["A": "1"], restart: true)
        #expect(outcome == .launched)
        #expect(control.logs.read(app: "dev.mobdev.fixture", after: nil, limit: 10, contains: nil).lines.map(\.text) == ["fixture: launched"])

        try await control.open(URL(string: "mobdevfixture://hello")!)
        _ = try await control.uninstall("dev.mobdev.fixture")
        await #expect(throws: (any Error).self) { _ = try await control.uninstall("com.apple.Preferences") }

        let calls = simctl.calls.get()
        #expect(calls.contains(["simctl", "install", "SIM-1", app.path]))
        #expect(calls.contains(["simctl", "openurl", "SIM-1", "mobdevfixture://hello"]))
        #expect(calls.contains(["simctl", "uninstall", "SIM-1", "dev.mobdev.fixture"]))
        let launch = try #require(calls.first { $0.first == "/usr/bin/env" })
        #expect(launch.contains("SIMCTL_CHILD_OS_ACTIVITY_DT_MODE=YES"))
        #expect(launch.contains("SIMCTL_CHILD_A=1"))
        #expect(Array(launch.suffix(4)) == ["--terminate-running-process", "SIM-1", "dev.mobdev.fixture", "crash"])
        #expect(launch.contains("/usr/bin/script"))
        #expect(simctl.calls.get().filter { $0.first == "/usr/bin/env" }.count == 1)
    }

    /// On GitHub's runners the pid line arrived as "^D^H^Hdev.mobdev.fixture: 18379" through
    /// `script`'s terminal; it still means the app runs.
    @Test func aPidLineWithTerminalNoiseStillCountsAsTheStart() async throws {
        let simctl = FakeSimctl()
        simctl.listapps = Self.listapps
        simctl.console = ["\u{04}\u{08}\u{08}dev.mobdev.fixture: 18379\r", "fixture: launched"]
        let control = DeviceControl(
            udid: "SIM-1", runner: simctl, reportsFolder: FileManager.default.temporaryDirectory, simulator: true,
            simctl: true)
        let started = Date()
        let outcome = try await control.launch("dev.mobdev.fixture", arguments: [], environment: [:], restart: true)
        #expect(outcome == .launched)
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(control.logs.read(app: "dev.mobdev.fixture", after: nil, limit: 10, contains: nil).lines.map(\.text) == ["fixture: launched"])
        #expect(control.logs.status(for: "dev.mobdev.fixture") == "running")
        #expect(simctl.calls.get().filter { $0.first == "/usr/bin/env" }.count == 1)
    }

    /// A simctl that cannot launch the app prints why and exits before its pid line. GitHub's
    /// slow simulators do that right after an install, so the launch is tried three times and
    /// then fails with simctl's reason instead of a "Launched" that shows the home screen.
    @Test func aLaunchSimctlRefusesIsTriedAgainAndThenFails() async throws {
        let simctl = FakeSimctl()
        simctl.listapps = Self.listapps
        simctl.console = ["An error was encountered processing the command (domain=FBSOpenApplicationServiceErrorDomain, code=1):"]
        simctl.exitStatus = 1
        let control = DeviceControl(
            udid: "SIM-1", runner: simctl, reportsFolder: FileManager.default.temporaryDirectory, simulator: true,
            simctl: true)
        do {
            _ = try await control.launch("dev.mobdev.fixture", arguments: [], environment: [:], restart: true)
            Issue.record("the launch should fail")
        } catch {
            #expect(String(describing: error).hasPrefix("simctl could not launch dev.mobdev.fixture in 3 tries: An error was encountered"))
        }
        #expect(simctl.calls.get().filter { $0.first == "/usr/bin/env" }.count == DeviceControl.simctlLaunchAttempts)
        #expect(control.logs.status(for: "dev.mobdev.fixture") == "did not start")
    }
}
