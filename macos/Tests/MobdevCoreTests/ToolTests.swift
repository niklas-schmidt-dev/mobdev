import Foundation
import Testing
@testable import MobdevCore

extension Trait where Self == ConditionTrait {
    /// Vision text recognition never returns on GitHub's virtualized macOS runners, so OCR tests
    /// only run on real Macs.
    static var needsTextRecognition: Self {
        .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "Vision text recognition hangs on CI runners")
    }
}

@Suite struct ToolTests {
    // 1179×2556 screen, screenshots are 590×1280.
    let phone = FakePhone(lines: [
        ("Settings", 420, 300), ("Wi-Fi", 120, 800), ("Bluetooth", 120, 1000), ("General", 120, 1200),
        ("General", 120, 1600),
    ])

    func tools(_ phone: FakePhone? = nil) -> (PhoneTools, ActivityLog) {
        let log = ActivityLog()
        return (PhoneTools(phone: phone ?? self.phone, activity: log, settleDelay: 0), log)
    }

    @Test func screenshotSizeKeepsAspectRatio() {
        let size = ScreenGeometry.screenshotSize(forFrameWidth: 1179, height: 2556)
        #expect(size.height == 1280)
        #expect(size.width == 590)
    }

    @Test func statusReportsScreenshotSpace() async throws {
        let (tools, _) = tools()
        let output = try await tools.call("status", arguments: nil, source: "test", screenshotByDefault: false)
        #expect(output.data?["ready"] == true)
        #expect(output.data?["screenshot"]?["width"] == 590)
        #expect(output.data?["screenshot"]?["height"] == 1280)
    }

    @Test func tapConvertsScreenshotPixelsToFractions() async throws {
        let (tools, log) = tools()
        let output = try await tools.call(
            "tap", arguments: ["x": 295, "y": 640], source: "test", screenshotByDefault: false)
        #expect(!output.isError)
        #expect(output.image == nil)
        #expect(phone.events.get() == [.tap(NormalizedPoint(x: 0.5, y: 0.5), 0.08)])
        #expect(log.all.first?.tool == "tap")
    }

    @Test func actionsReturnAScreenshotByDefaultOverMCP() async throws {
        let (tools, _) = tools()
        let output = try await tools.call("home", arguments: nil, source: "test", screenshotByDefault: true)
        #expect(output.image?.mimeType == "image/jpeg")
        #expect(output.image?.height == 1280)
        let skipped = try await tools.call(
            "home", arguments: ["screenshot": false], source: "test", screenshotByDefault: true)
        #expect(skipped.image == nil)
    }

    @Test func outOfRangeCoordinatesAreAToolError() async throws {
        let (tools, log) = tools()
        let output = try await tools.call("tap", arguments: ["x": 900, "y": 10], source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("590×1280"))
        #expect(phone.events.get().isEmpty)
        #expect(log.all.first?.failed == true)
    }

    @Test func touchNeedsBluetooth() async throws {
        let offline = FakePhone(lines: [], bluetoothConnected: false)
        let (tools, _) = tools(offline)
        let output = try await tools.call("tap", arguments: ["x": 10, "y": 10], source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("Settings > Bluetooth"))
    }

    @Test func unknownToolThrows() async {
        let (tools, _) = tools()
        await #expect(throws: UnknownToolError.self) {
            _ = try await tools.call("format_disk", arguments: nil, source: "test", screenshotByDefault: false)
        }
    }

    @Test func typeTextUsesTheKeyboardLayout() async throws {
        let german = FakePhone(lines: [], layout: .german)
        let (tools, log) = tools(german)
        _ = try await tools.call(
            "type_text", arguments: ["text": "zy", "submit": true], source: "test", screenshotByDefault: false)
        #expect(german.events.get() == [.type([KeyStroke(0x1C), KeyStroke(0x1D), KeyStroke(0x28)])])
        #expect(log.all.first?.summary == "typed 2 characters")
    }

    @Test(.needsTextRecognition) func readScreenFindsTextWithOCR() async throws {
        let (tools, _) = tools()
        let output = try await tools.call("read_screen", arguments: nil, source: "test", screenshotByDefault: false)
        #expect(output.text.contains("Settings"))
        #expect(output.text.contains("Bluetooth"))
    }

    @Test(.needsTextRecognition) func tapTextTapsTheRecognizedLabel() async throws {
        let (tools, _) = tools()
        let output = try await tools.call(
            "tap_text", arguments: ["text": "bluetooth"], source: "test", screenshotByDefault: false)
        #expect(!output.isError, "\(output.text)")
        guard case .tap(let point, _) = phone.events.get().first else {
            Issue.record("no tap")
            return
        }
        // "Bluetooth" is drawn at y=1000 of 2556 and starts at x=120.
        #expect(abs(point.y - 1000.0 / 2556.0) < 0.02)
        #expect(point.x > 120.0 / 1179.0 && point.x < 0.5)
    }

    @Test(.needsTextRecognition) func tapTextRefusesAmbiguousMatchesWithoutIndex() async throws {
        let (tools, _) = tools()
        let ambiguous = try await tools.call(
            "tap_text", arguments: ["text": "General"], source: "test", screenshotByDefault: false)
        #expect(ambiguous.isError)
        #expect(ambiguous.text.contains("appears 2 times"))
        #expect(phone.events.get().isEmpty)

        let second = try await tools.call(
            "tap_text", arguments: ["text": "General", "index": 1], source: "test", screenshotByDefault: false)
        #expect(!second.isError)
        guard case .tap(let point, _) = phone.events.get().first else {
            Issue.record("no tap")
            return
        }
        #expect(abs(point.y - 1600.0 / 2556.0) < 0.02)
    }

    @Test(.needsTextRecognition) func tapTextReportsMissingText() async throws {
        let (tools, _) = tools()
        let output = try await tools.call(
            "tap_text", arguments: ["text": "Airplane Mode"], source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("not visible"))
    }

    @Test(.needsTextRecognition) func waitForTextReturnsWhenVisibleAndTimesOutOtherwise() async throws {
        let (tools, _) = tools()
        let found = try await tools.call(
            "wait_for_text", arguments: ["text": "Wi-Fi", "timeout": 1], source: "test", screenshotByDefault: false)
        #expect(!found.isError)
        let missing = try await tools.call(
            "wait_for_text", arguments: ["text": "Cellular", "timeout": 0], source: "test", screenshotByDefault: false)
        #expect(missing.isError)
    }

    @Test func openAppUsesSpotlight() async throws {
        let (tools, _) = tools()
        _ = try await tools.call("open_app", arguments: ["name": "Maps"], source: "test", screenshotByDefault: false)
        let events = phone.events.get()
        #expect(events.first == .button(.home))
        #expect(events.contains(.key(KeyStroke(0x2C, KeyStroke.command))))
        #expect(events.last == .key(KeyStroke(0x28)))
    }
}
