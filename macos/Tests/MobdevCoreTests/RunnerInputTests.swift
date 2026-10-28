import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// An iPhone's input on its two routes: Mobdev Runner while it runs (Developer Mode), the Mac's
/// Bluetooth keyboard and pointer otherwise.
@Suite struct RunnerInputTests {
    static let middle = NormalizedPoint(x: 0.5, y: 0.5)

    // MARK: Routing

    @Test func everyInputGoesThroughTheRunnerWhileItRuns() async throws {
        let runner = FakeRunner()
        let apps = FakeApps(platform: .iPhone)
        apps.listed.set([
            InstalledApp(bundleID: "com.apple.Preferences", name: "Settings", version: "27.0", build: "1", developer: false, location: nil)
        ])
        // No Bluetooth at all: an iPhone set up with Developer Mode only.
        let input = IPhoneInput(runner: runner, bluetooth: { throw HIDError.notConnected }, layout: .german)

        try await input.tap(at: Self.middle, hold: 0.08)
        try await input.tap(at: Self.middle, hold: 1.5)
        try await input.doubleTap(at: Self.middle)
        try await input.swipe(from: NormalizedPoint(x: 0.5, y: 0.8), to: NormalizedPoint(x: 0.5, y: 0.2), duration: 0.3)
        try await input.type(KeyboardLayout.german.strokes(typing: "Grüße @ é"))
        try await input.press(KeyStroke(0x28))
        try await input.press(try KeyboardLayout.german.stroke(forKey: "space", modifiers: ["cmd"]))
        try await input.press(.home)
        try await input.press(.volumeUp)
        #expect(try await input.typeText("😀"))
        #expect(try await input.openApp(named: "settings", apps: apps) == "Opened Settings (com.apple.Preferences).")

        #expect(runner.events.get() == [
            .tap(Self.middle, 0.08), .tap(Self.middle, 1.5), .doubleTap(Self.middle),
            .drag(NormalizedPoint(x: 0.5, y: 0.8), NormalizedPoint(x: 0.5, y: 0.2), 0.3),
            .type("Grüße @ é"), .key("return", []), .key("space", ["cmd"]), .button("home"), .button("volume_up"),
            .type("😀"), .activate("com.apple.Preferences"),
        ])
    }

    @Test func theWheelBecomesASwipeThroughTheRunner() async throws {
        let runner = FakeRunner()
        let input = IPhoneInput(runner: runner, bluetooth: { throw HIDError.notConnected }, layout: .us)
        try await input.scroll(at: Self.middle, ticks: 5)
        try await input.pan(at: Self.middle, ticks: -5)
        let events = runner.events.get()
        guard events.count == 2, case .drag(let down, let downEnd, _) = events[0], case .drag(let left, let leftEnd, _) = events[1]
        else {
            Issue.record("expected two drags, got \(events)")
            return
        }
        // Content further down: the finger moves up. Content further left: the finger moves right.
        #expect(down.y > downEnd.y && down.x == downEnd.x)
        #expect(left.x < leftEnd.x && left.y == leftEnd.y)
    }

    @Test func withoutTheRunnerInputGoesOverBluetooth() async throws {
        let bluetooth = FakeBluetooth()
        let input = IPhoneInput(runner: nil, bluetooth: { bluetooth }, layout: .us)
        try await input.tap(at: Self.middle, hold: 0.08)
        try await input.doubleTap(at: Self.middle)
        try await input.swipe(from: Self.middle, to: NormalizedPoint(x: 0.5, y: 0.1), duration: 0.3)
        try await input.scroll(at: Self.middle, ticks: 3)
        try await input.pan(at: Self.middle, ticks: 2)
        try await input.press(KeyStroke(0x28))
        try await input.press(.mute)
        #expect(try await input.typeText("hello") == false)
        #expect(try await input.openApp(named: "Settings", apps: FakeApps(platform: .iPhone)) == nil)
        #expect(bluetooth.events.get() == [
            .tap(0.08), .tap(0.05), .tap(0.05), .swipe, .scroll(3), .pan(2), .key(KeyStroke(0x28)), .consumer(.mute),
        ])
    }

    @Test func buttonsTheRunnerLacksNeedBluetooth() async throws {
        let runner = FakeRunner()
        await #expect(throws: ToolFailure.self) {
            try await IPhoneInput(runner: runner, bluetooth: { throw HIDError.notConnected }, layout: .us).press(.mute)
        }
        let bluetooth = FakeBluetooth()
        try await IPhoneInput(runner: runner, bluetooth: { bluetooth }, layout: .us).press(.playPause)
        #expect(bluetooth.events.get() == [.consumer(.playPause)])
        #expect(runner.events.get().isEmpty)
    }

    // MARK: Keys

    @Test func keyStrokesBecomeTheRunnersKeys() throws {
        func key(_ name: String, _ modifiers: [String] = [], _ layout: KeyboardLayout = .us) throws -> (String, [String])? {
            RunnerKeys.key(for: try layout.stroke(forKey: name, modifiers: modifiers), layout: layout).map { ($0.name, $0.modifiers) }
        }
        #expect(try key("enter")! == ("return", []))
        #expect(try key("tab", ["shift"])! == ("tab", ["shift"]))
        #expect(try key("up")! == ("up", []))
        #expect(try key("f5")! == ("f5", []))
        #expect(try key("space", ["cmd"])! == ("space", ["cmd"]))
        #expect(try key("a", ["cmd"])! == ("a", ["cmd"]))
        // A character keeps the shift and option that type it on the layout: "@" is option-L in German.
        #expect(try key("@", [], .german)! == ("@", []))
        #expect(try key("z", ["ctrl"], .german)! == ("z", ["ctrl"]))
        #expect(RunnerKeys.key(for: KeyStroke(0x1D, KeyStroke.shift), layout: .us)! == ("Z", []))
        // The German dead key for accents alone types nothing.
        #expect(RunnerKeys.key(for: KeyStroke(0x2E), layout: .german) == nil)
    }

    @Test func strokesThatTypeCharactersBecomeText() throws {
        for layout in KeyboardLayout.allCases {
            let text = "Hello, World! ß € é ñ\n"
            #expect(RunnerKeys.text(for: try layout.strokes(typing: text), layout: layout) == text)
        }
        // A shortcut is not text.
        #expect(RunnerKeys.text(for: [KeyStroke(0x04, KeyStroke.command)], layout: .us) == nil)
    }

    // MARK: The tools on the runner route

    @Test func statusSaysInputGoesThroughTheRunner() async throws {
        let phone = FakePhone(lines: [], bluetoothConnected: false)
        phone.route.set((.runner, .running))
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let output = try await tools.call("status", arguments: nil, source: "test", screenshotByDefault: false)
        let lines = output.text.components(separatedBy: "\n")
        #expect(lines.first == "Ready.")
        #expect(lines.contains("Input: Mobdev Runner (Developer Mode)"))
        // No keyboard layout or AssistiveTouch pointer to care about.
        #expect(!output.text.contains("Keyboard layout"))
        #expect(!output.text.contains("Bluetooth"))
        #expect(output.data?["input"]?["route"]?.stringValue == "Mobdev Runner")
        #expect(output.data?["runner"]?.stringValue == "Running")
        #expect(output.data?["ready"]?.boolValue == true)
    }

    @Test func whileTheRunnerStartsInputWaitsForItOrBluetooth() async throws {
        let phone = FakePhone(lines: [], bluetoothConnected: false)
        phone.route.set((.bluetooth, .building))
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let status = try await tools.call("status", arguments: nil, source: "test", screenshotByDefault: false)
        #expect(status.text.hasPrefix("Not ready."))
        #expect(status.text.contains("Mobdev Runner (Developer Mode): Building with Xcode…"))
        let tap = try await tools.call("tap", arguments: ["x": 100, "y": 100], source: "test", screenshotByDefault: false)
        #expect(tap.isError)
        #expect(tap.text.contains("still starting"))

        phone.route.set((.bluetooth, .failed("No Account for Team \"Q1W2E3R4T5\".")))
        let failed = try await tools.call("tap", arguments: ["x": 100, "y": 100], source: "test", screenshotByDefault: false)
        #expect(failed.text.contains("No Account for Team"))
        #expect(failed.text.contains("Try Again under Developer Mode Control"))
        #expect(phone.events.get().isEmpty)
    }

    @Test func swipesThroughTheRunnerNeedNoPointerCheck() async throws {
        let phone = FakePhone(lines: [], bluetoothConnected: false, pointerCheckResult: .snaps)
        phone.route.set((.runner, .running))
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let output = try await tools.call(
            "swipe", arguments: ["from_x": 295, "from_y": 1000, "to_x": 295, "to_y": 300], source: "test",
            screenshotByDefault: false)
        #expect(!output.isError, "\(output.text)")
        #expect(phone.events.get().count == 1)
        if case .swipe = phone.events.get().first {} else { Issue.record("expected a swipe, got \(phone.events.get())") }
    }

    @Test func aDoubleTapIsOneCallToThePhone() async throws {
        let phone = DoubleTapPhone(lines: [])
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let output = try await tools.call("tap", arguments: ["x": 100, "y": 100, "double": true], source: "test", screenshotByDefault: false)
        #expect(output.text.hasPrefix("Double-tapped"))
        #expect(phone.doubleTaps.get() == 1)
        #expect(phone.events.get().isEmpty)
    }

    @Test func iPhonesOnEitherRouteRefuseToLock() async throws {
        let phone = FakePhone(lines: [], bluetoothConnected: false)
        phone.route.set((.runner, .running))
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let output = try await tools.call("press_button", arguments: ["button": "lock"], source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("does not lock an iPhone"))
    }

    // MARK: Requests

    @Test func runnerRequestsCarryTheirBodies() async throws {
        let answer = JSONValue.object(["ok": true]).encoded()
        let fake = try FakeUSBMux(serials: [(3, "0000811000AB12CD34EF5678", "USB")]) { _ in
            Data("HTTP/1.1 200 OK\r\nContent-Length: \(answer.count)\r\n\r\n".utf8) + answer
        }
        defer { fake.stop() }
        let client = RunnerClient(
            route: .usb(udid: "0000811000AB12CD34EF5678"), port: 47270, token: "t", usbmux: USBMux(socketPath: fake.path))
        func last() throws -> (head: String, body: JSONValue) {
            let request = String(decoding: fake.received.get(), as: UTF8.self)
            let parts = request.components(separatedBy: "\r\n\r\n")
            return (parts[0], try JSONValue.parse(Data(parts[1].utf8)))
        }

        try await client.tap(NormalizedPoint(x: 0.25, y: 0.75), hold: 0.08)
        #expect(try last().head.hasPrefix("POST /tap "))
        #expect(try last().body == ["x": 0.25, "y": 0.75])
        try await client.tap(NormalizedPoint(x: 0.25, y: 0.75), hold: 2)
        #expect(try last().body == ["x": 0.25, "y": 0.75, "hold": 2])
        try await client.doubleTap(NormalizedPoint(x: 0.5, y: 0.5))
        #expect(try last().body == ["x": 0.5, "y": 0.5, "count": 2])
        try await client.drag(from: NormalizedPoint(x: 0.5, y: 0.8), to: NormalizedPoint(x: 0.5, y: 0.2), duration: 0.3)
        #expect(try last().head.hasPrefix("POST /drag "))
        #expect(try last().body == ["from": [0.5, 0.8], "to": [0.5, 0.2], "duration": 0.3, "press": 0.05, "hold": 0])
        try await client.key("space", modifiers: ["cmd"])
        #expect(try last().body == ["key": "space", "modifiers": ["cmd"]])
        try await client.key("a")
        #expect(try last().body == ["key": "a"])
        try await client.button("home")
        #expect(try last().head.hasPrefix("POST /button "))
        #expect(try last().body == ["name": "home"])
        try await client.activate("com.apple.Preferences")
        #expect(try last().head.hasPrefix("POST /activate "))
        #expect(try last().body == ["bundle": "com.apple.Preferences"])
    }

    @Test func anOlderRunnerIsRefused() async throws {
        let body = JSONValue.object(["ok": true, "version": 1]).encoded()
        let fake = try FakeUSBMux(serials: [(3, "0000811000AB12CD34EF5678", "USB")]) { _ in
            Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        }
        defer { fake.stop() }
        let client = RunnerClient(
            route: .usb(udid: "0000811000AB12CD34EF5678"), port: 47270, token: "t", usbmux: USBMux(socketPath: fake.path))
        await #expect(throws: RunnerClient.VersionMismatch.self) { try await client.health() }
        #expect(throws: Never.self) { try RunnerClient.checkVersion(["version": .number(Double(RunnerClient.protocolVersion))]) }
        #expect(UIRunner.summary("error: \(RunnerClient.VersionMismatch(version: 1))")?.hasSuffix("Click Try Again to build it again.") == true)
    }
}

/// Mobdev Runner without a device: records what it was asked to do.
final class FakeRunner: RunnerControl, @unchecked Sendable {
    enum Event: Equatable {
        case tap(NormalizedPoint, TimeInterval)
        case doubleTap(NormalizedPoint)
        case drag(NormalizedPoint, NormalizedPoint, TimeInterval)
        case type(String)
        case key(String, [String])
        case button(String)
        case activate(String)
    }

    let events = Locked<[Event]>([])
    let tree = Locked<[UIElement]>([])

    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws { events.withLock { $0.append(.tap(point, hold)) } }
    func doubleTap(at point: NormalizedPoint) async throws { events.withLock { $0.append(.doubleTap(point)) } }
    func drag(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {
        events.withLock { $0.append(.drag(start, end, duration)) }
    }
    func type(_ text: String) async throws { events.withLock { $0.append(.type(text)) } }
    func press(key: String, modifiers: [String]) async throws { events.withLock { $0.append(.key(key, modifiers)) } }
    func press(button: String) async throws { events.withLock { $0.append(.button(button)) } }
    func activate(_ bundleID: String) async throws { events.withLock { $0.append(.activate(bundleID)) } }
    func elements() async throws -> [UIElement] { tree.get() }
}

/// The Bluetooth keyboard and pointer without Bluetooth: records what it was asked to send.
final class FakeBluetooth: BluetoothInput, @unchecked Sendable {
    enum Event: Equatable {
        case tap(TimeInterval)
        case swipe
        case scroll(Int)
        case pan(Int)
        case type([KeyStroke])
        case key(KeyStroke)
        case consumer(ConsumerUsage)
    }

    let events = Locked<[Event]>([])

    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws { events.withLock { $0.append(.tap(hold)) } }
    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {
        events.withLock { $0.append(.swipe) }
    }
    func scroll(at point: NormalizedPoint, ticks: Int) async throws { events.withLock { $0.append(.scroll(ticks)) } }
    func pan(at point: NormalizedPoint, ticks: Int) async throws { events.withLock { $0.append(.pan(ticks)) } }
    func type(_ strokes: [KeyStroke]) async throws { events.withLock { $0.append(.type(strokes)) } }
    func press(_ stroke: KeyStroke) async throws { events.withLock { $0.append(.key(stroke)) } }
    func consumer(_ usage: ConsumerUsage) async throws { events.withLock { $0.append(.consumer(usage)) } }
}

/// A phone with its own double tap, as an iPhone has through Mobdev Runner.
private final class DoubleTapPhone: FakePhone, @unchecked Sendable {
    let doubleTaps = Locked(0)
    override func doubleTap(at point: NormalizedPoint) async throws { doubleTaps.withLock { $0 += 1 } }
}
