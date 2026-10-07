import Foundation
import Testing
@testable import MobdevCore

/// This Mac's side of live view, run against a relay for a while so the browser side can be checked
/// by hand or with a headless browser: RelayClient, LiveStreams and the API router, as the app wires
/// them, without the app. Opt-in:
///
///     MOBDEV_LIVE_RELAY=https://relay.<name>.localhost MOBDEV_LIVE_SECRET=mdh_… [MOBDEV_LIVE_TOKEN=mda_…] \
///       [MOBDEV_LIVE_SIMULATOR=<udid> [MOBDEV_LIVE_APP=…/MobdevFixture.app]] [MOBDEV_LIVE_SECONDS=120] \
///       [MOBDEV_LIVE_OFF=1] [MOBDEV_LIVE_LOG=/tmp/harness.log] swift test --filter LiveHarness
///
/// With a simulator it streams that one (and installs and opens the app, if given); without, a fake
/// phone. MOBDEV_LIVE_OFF leaves live view turned off, as the app starts. It reports what the
/// viewers do as it lands in the device's activity, and the fixture app's taps at the end, into
/// MOBDEV_LIVE_LOG as it happens (`swift test` shows a test's output only once the test ends).
@Suite struct LiveHarnessTests {
    static let environment = ProcessInfo.processInfo.environment

    private static func say(_ line: String) {
        guard let path = environment["MOBDEV_LIVE_LOG"], let handle = FileHandle(forWritingAtPath: path) else {
            return print("harness: \(line)")
        }
        handle.seekToEndOfFile()
        handle.write(Data("harness: \(line)\n".utf8))
        try? handle.close()
    }

    @Test(.enabled(if: environment["MOBDEV_LIVE_RELAY"] != nil, "MOBDEV_LIVE_RELAY is not set"))
    func serveLiveView() async throws {
        let environment = Self.environment
        let relay = try RelayClient.validatedURL(environment["MOBDEV_LIVE_RELAY"] ?? "")
        let secret = try #require(environment["MOBDEV_LIVE_SECRET"], "MOBDEV_LIVE_SECRET is not set")
        let seconds = Double(environment["MOBDEV_LIVE_SECONDS"] ?? "") ?? 120

        let tools: any ToolCalling
        let summary: DeviceSummary
        let activity: ActivityLog?
        var emulators: EmulatorHub?
        if let udid = environment["MOBDEV_LIVE_SIMULATOR"] {
            let hub = EmulatorHub(adb: nil) {}
            emulators = hub
            hub.start()
            for _ in 0..<120 where !hub.devices.contains(where: { $0.id == udid }) {
                try await Task.sleep(for: .milliseconds(250))
            }
            let device = try #require(hub.devices.first { $0.id == udid }, "\(udid) is not booted")
            let deviceTools = DeviceTools(hub: DeviceHub(keyboardLayout: .us) {}, emulators: hub, settleDelay: 0.3)
            if let app = environment["MOBDEV_LIVE_APP"] {
                for (tool, arguments) in [
                    ("install_app", ["path": JSONValue.string(app)]), ("launch_app", ["bundle_id": "dev.mobdev.fixture"]),
                ] {
                    let output = try await deviceTools.call(
                        tool, arguments: .object(arguments.merging(["device": .string(udid)]) { $1 }), source: "test",
                        screenshotByDefault: false)
                    Self.say("\(tool): \(output.text)")
                }
            }
            tools = deviceTools
            summary = DeviceSummary(device)
            activity = device.activity
        } else {
            let phone = FakePhone(lines: [("Mobdev live view", 200, 400), ("Fake iPhone", 200, 520)])
            let log = ActivityLog()
            tools = PhoneTools(phone: phone, activity: log, settleDelay: 0)
            summary = DeviceSummary(
                id: "fake-phone", name: "Fake iPhone", model: "iPhone17,1", modelName: "iPhone 16 Pro", osVersion: "27.0",
                deviceClass: "iPhone", screen: true, bluetooth: true, ready: true)
            activity = log
        }
        defer { emulators?.stop(waiting: true) }
        activity?.observe { entries in
            guard let entry = entries.first, entry.source == "browser" else { return }
            Self.say("activity \(entry.tool): \(entry.summary)")
        }

        let router = APIRouter(tools: tools, token: { "unused" }, port: { 0 })
        let live = LiveStreams(tools: tools, allowed: environment["MOBDEV_LIVE_OFF"] == nil) { sessions in
            Self.say("watched now: \(sessions.map { "\($0.deviceName) by \(LiveStreams.describe($0.viewers))" })")
        }
        let client = RelayClient(live: live, handler: { request in await router.handle(request, from: .relay) }) { state in
            Self.say("relay \(state.summary)")
        }
        client.updateDevices([summary])
        client.start(url: relay, secret: secret, hostName: "harness", accessToken: environment["MOBDEV_LIVE_TOKEN"])
        defer { client.stop() }
        Self.say("serving \(summary.id) for \(Int(seconds)) s")
        try await Task.sleep(for: .seconds(seconds))

        if environment["MOBDEV_LIVE_APP"] != nil, let udid = environment["MOBDEV_LIVE_SIMULATOR"] {
            let logs = try await tools.call(
                "logs", arguments: ["device": .string(udid), "bundle_id": "dev.mobdev.fixture"], source: "test",
                screenshotByDefault: false)
            for line in logs.text.split(separator: "\n") where line.contains("fixture: tap") { Self.say(String(line)) }
            _ = try? await tools.call(
                "uninstall_app", arguments: ["device": .string(udid), "bundle_id": "dev.mobdev.fixture"], source: "test",
                screenshotByDefault: false)
        }
    }
}
