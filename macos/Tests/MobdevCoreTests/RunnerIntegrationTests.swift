import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// Builds Mobdev Runner for a simulator with Xcode, starts it and drives the Settings app through it:
/// /tree, /tap and /type, then ui_tree, tap_element and wait_for_element on top. A simulator needs no
/// signing, and its runner listens on the Mac's 127.0.0.1. Opt-in, because it builds for a minute
/// or two and acts on the simulator:
///
///     MOBDEV_TEST_RUNNER_SIMULATOR=<udid> swift test --filter RunnerIntegration
@Suite(.serialized) struct RunnerIntegrationTests {
    static let simulator = ProcessInfo.processInfo.environment["MOBDEV_TEST_RUNNER_SIMULATOR"]
    static let settings = "com.apple.Preferences"

    @Test(.enabled(if: simulator != nil, "Set MOBDEV_TEST_RUNNER_SIMULATOR"), .timeLimit(.minutes(15)))
    func runnerServesTreeTapsAndTyping() async throws {
        let udid = Self.simulator!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        // Not the default port, so a runner Mobdev keeps for another simulator does not answer.
        let runner = UIRunner(udid: udid, simulator: true, folder: folder, port: 47291)
        defer { runner.stop() }

        let started = Date()
        runner.start(team: nil)
        while runner.state != .running, Date().timeIntervalSince(started) < 600 {
            if case .failed(let reason) = runner.state {
                Issue.record("Mobdev Runner failed: \(reason)")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        try #require(runner.state == .running)
        print("── runner running after \(Int(Date().timeIntervalSince(started))) s")

        // Settings' rows carry identifiers in every language.
        try await launchSettings(udid)
        var elements = try await read(runner) { $0.contains { $0.identifier == "com.apple.settings.general" } }
        let general = try #require(elements.first { $0.identifier == "com.apple.settings.general" })
        #expect(general.role == "Button")
        #expect(general.tappable)
        #expect(general.frame.minX >= 0 && general.frame.maxX <= 1 && general.frame.minY >= 0 && general.frame.maxY <= 1)
        let clock = Date()
        _ = try await runner.elements()
        print("── \(elements.count) elements; one read takes \(Int(Date().timeIntervalSince(clock) * 1000)) ms")

        // Tap the search field and type accents and emoji, which the Bluetooth keyboard cannot.
        let search = try #require(elements.first { $0.role == "SearchField" })
        try await runner.tap(at: search.center)
        try await Task.sleep(for: .seconds(1))
        let text = "Grüße 😀 ñ"
        try await runner.type(text)
        elements = try await read(runner) { $0.contains { $0.role == "SearchField" && $0.value == text } }
        #expect(elements.contains { $0.role == "SearchField" && $0.value == text })

        // With no field focused, typing fails with XCTest's reason, cut to its first sentence.
        try await launchSettings(udid)
        _ = try await read(runner) { $0.contains { $0.identifier == "com.apple.settings.general" } }
        do {
            try await runner.type("x")
            Issue.record("Typing without a focused field succeeded")
        } catch {
            #expect("\(error)".contains("keyboard focus"))
            #expect(!"\(error)".contains("\n"))
        }

        // The tools on top, as on an iPhone whose tree comes from the runner.
        let tools = PhoneTools(phone: RunnerPhone(runner: runner), activity: ActivityLog(), settleDelay: 0)
        let tree = try await tools.call("ui_tree", arguments: ["contains": "settings.general"], source: "test", screenshotByDefault: false)
        #expect(!tree.isError, "\(tree.text)")
        #expect(tree.text.contains("Button"))
        let tapped = try await tools.call(
            "tap_element", arguments: ["id": "com.apple.settings.general"], source: "test", screenshotByDefault: false)
        #expect(!tapped.isError, "\(tapped.text)")
        // General opens and replaces the list it was in.
        let gone = try await tools.call(
            "wait_for_element", arguments: ["id": "com.apple.settings.general", "gone": true, "timeout": 10], source: "test",
            screenshotByDefault: false)
        #expect(!gone.isError, "\(gone.text)")

        runner.stop()
        #expect(runner.state == .off)
        // Ending xcodebuild ends the test on the simulator, and with it the server.
        let client = RunnerClient(route: .loopback, port: 47291, token: "")
        var closed = false
        for _ in 0..<20 where !closed {
            do {
                _ = try await client.call("GET", "/health", timeout: 2)
            } catch {
                closed = "\(error)".contains("Could not connect")
            }
            if !closed { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(closed, "The runner still answers after stop()")

        // Starting again reuses the build, as when the iPhone comes back or Mobdev starts.
        let restarted = Date()
        runner.start(team: nil)
        while runner.state != .running, Date().timeIntervalSince(restarted) < 300 {
            if case .failed(let reason) = runner.state {
                Issue.record("Mobdev Runner failed on restart: \(reason)")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        #expect(runner.state == .running)
        print("── running again after \(Int(Date().timeIntervalSince(restarted))) s")
        #expect(try await runner.elements().contains { $0.identifier.hasPrefix("com.apple.settings.") })
    }

    /// Reads the tree from a runner already running on an iPhone, through usbmuxd. Read-only: it
    /// sends no taps or text. Start the runner with `TEST_RUNNER_MOBDEV_RUNNER_TOKEN=<token>`.
    ///
    ///     MOBDEV_TEST_RUNNER_DEVICE=<udid> MOBDEV_TEST_RUNNER_TOKEN=<token> \
    ///       swift test --filter runnerOnAnIPhoneAnswersOverUSB
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOBDEV_TEST_RUNNER_DEVICE"] != nil, "Set MOBDEV_TEST_RUNNER_DEVICE"))
    func runnerOnAnIPhoneAnswersOverUSB() async throws {
        let environment = ProcessInfo.processInfo.environment
        let client = RunnerClient(
            route: .usb(udid: environment["MOBDEV_TEST_RUNNER_DEVICE"]!), port: UIRunner.defaultPort,
            token: environment["MOBDEV_TEST_RUNNER_TOKEN"] ?? "")
        try await client.health()
        let raw = try await client.call("GET", "/tree", timeout: 30)
        print("── apps \(raw["apps"]?.compactString ?? ""), screen \(raw["screen"]?.compactString ?? "")")
        let elements = try RunnerClient.elements(fromTree: raw)
        for element in elements.prefix(40) where !element.label.isEmpty || !element.identifier.isEmpty {
            print("   \(element.role) \"\(element.label)\" id=\(element.identifier) center=(\(element.center.x), \(element.center.y))")
        }
        #expect(!elements.isEmpty)
    }

    /// Asks the Mac's usbmuxd which devices it carries. Read-only: nothing reaches a device.
    ///
    ///     MOBDEV_TEST_USBMUXD=<udid of a connected iPhone> swift test --filter RunnerIntegration
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOBDEV_TEST_USBMUXD"] != nil, "Set MOBDEV_TEST_USBMUXD"))
    func usbmuxdListsTheConnectedIPhone() throws {
        let udid = ProcessInfo.processInfo.environment["MOBDEV_TEST_USBMUXD"]!
        let devices = try USBMux().devices()
        print("── usbmuxd: \(devices.map { "\($0.id) \($0.serial) \($0.connection)" })")
        #expect(devices.contains { USBMux.normalized($0.serial) == USBMux.normalized(udid) })
    }

    private func launchSettings(_ udid: String) async throws {
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            ["simctl", "launch", "--terminate-running-process", udid, Self.settings], timeout: 60)
        try #require(result.status == 0, "\(result.output)")
    }

    /// Reads the tree until `accepted` holds, for up to 15 seconds, and returns the last tree.
    private func read(_ runner: UIRunner, until accepted: ([UIElement]) -> Bool) async throws -> [UIElement] {
        var elements: [UIElement] = []
        for _ in 0..<30 {
            elements = try await runner.elements()
            if accepted(elements) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        return elements
    }
}

/// A phone whose tree, taps and typing go through Mobdev Runner, as HardwareDevice's do with
/// the runner on. The screen size is an iPhone 17's in pixels.
private final class RunnerPhone: PhoneBackend, @unchecked Sendable {
    let runner: UIRunner
    init(runner: UIRunner) { self.runner = runner }

    func status() -> PhoneStatus {
        PhoneStatus(
            screen: .connected(name: "Simulator", width: 1206, height: 2622), bluetooth: .connected(hosts: 1),
            keyboardLayout: .us)
    }

    func frame() -> CGImage? { nil }
    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws { try await runner.tap(at: point) }
    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {}
    func scroll(at point: NormalizedPoint, ticks: Int) async throws {}
    func pan(at point: NormalizedPoint, ticks: Int) async throws {}
    func type(_ strokes: [KeyStroke]) async throws {}
    func press(_ stroke: KeyStroke) async throws {}
    func press(_ button: ConsumerUsage) async throws {}
    func typeText(_ text: String) async throws -> Bool {
        try await runner.type(text)
        return true
    }
    func uiTree() async throws -> [UIElement]? { try await runner.elements() }
}
