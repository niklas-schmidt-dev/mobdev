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

    /// A finite but huge coordinate used to trap while formatting the error.
    @Test func hugeCoordinatesAreAToolErrorNotACrash() async throws {
        let (tools, _) = tools()
        for value in [1e20, -1e20, 1e300, 9.3e18] {
            let output = try await tools.call(
                "tap", arguments: ["x": .number(value), "y": 10], source: "test", screenshotByDefault: false)
            #expect(output.isError)
            #expect(output.text.contains("outside the screenshot"))
        }
        #expect(phone.events.get().isEmpty)
    }

    @Test func typingIsLimitedPerCall() async throws {
        let (tools, _) = tools()
        let long = String(repeating: "a", count: PhoneTools.maxTypedCharacters + 1)
        let output = try await tools.call("type_text", arguments: ["text": .string(long)], source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("at most 1000"))
        let app = try await tools.call(
            "open_app", arguments: ["name": .string(String(repeating: "a", count: 101))], source: "test",
            screenshotByDefault: false)
        #expect(app.isError)
        #expect(phone.events.get().isEmpty)
        _ = try await tools.call(
            "type_text", arguments: ["text": .string(String(long.dropLast()))], source: "test", screenshotByDefault: false)
        #expect(phone.events.get().count == 1)
    }

    @Test func touchNeedsBluetooth() async throws {
        let offline = FakePhone(lines: [], bluetoothConnected: false)
        let (tools, _) = tools(offline)
        let output = try await tools.call("tap", arguments: ["x": 10, "y": 10], source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("Settings > Bluetooth"))
    }

    /// With Snap to Item on, iOS taps the nearest item instead of swiping, so the swipe stops.
    @Test func swipeRefusesWhenThePointerSnaps() async throws {
        let snapping = FakePhone(lines: [], pointerCheckResult: .snaps)
        let (tools, _) = tools(snapping)
        let swipe: JSONValue = ["from_x": 295, "from_y": 960, "to_x": 295, "to_y": 320]
        let output = try await tools.call("swipe", arguments: swipe, source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("Snap to Item"))
        #expect(snapping.events.get() == [.checkPointer(NormalizedPoint(x: 0.5, y: 0.75))])
        let status = try await tools.call("status", arguments: nil, source: "test", screenshotByDefault: false)
        #expect(status.data?["pointer"] == "snaps")
        #expect(status.text.contains("Pointer: snaps to items"))
    }

    @Test func swipeChecksThePointerUntilItFollows() async throws {
        let following = FakePhone(lines: [], pointerCheckResult: .follows)
        let (tools, _) = tools(following)
        let swipe: JSONValue = ["from_x": 295, "from_y": 960, "to_x": 295, "to_y": 320]
        for _ in 0..<2 {
            let output = try await tools.call("swipe", arguments: swipe, source: "test", screenshotByDefault: false)
            #expect(!output.isError)
        }
        let start = NormalizedPoint(x: 0.5, y: 0.75), end = NormalizedPoint(x: 0.5, y: 0.25)
        #expect(following.events.get() == [.checkPointer(start), .swipe(start, end), .swipe(start, end)])
    }

    /// Positive wheel ticks reveal content further down on an iPhone.
    @Test func scrollDirectionMatchesTheContent() async throws {
        let (tools, _) = tools()
        _ = try await tools.call(
            "scroll", arguments: ["direction": "down", "amount": 3], source: "test", screenshotByDefault: false)
        _ = try await tools.call(
            "scroll", arguments: ["direction": "up", "amount": 2], source: "test", screenshotByDefault: false)
        #expect(phone.events.get() == [.scroll(3), .scroll(-2)])
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

    // MARK: Text tools when text recognition fails

    /// A simulator's tree: a title, a field with typed text, and a button around its label.
    static let tree = [
        UIElement(
            role: "StaticText", label: "Willkommen", identifier: "", value: "",
            frame: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.04), enabled: true, tappable: false),
        UIElement(
            role: "TextField", label: "Name", identifier: "", value: "Niklas",
            frame: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.05), enabled: true, tappable: true),
        UIElement(
            role: "Button", label: "Weiter", identifier: "next", value: "",
            frame: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.06), enabled: true, tappable: true),
        UIElement(
            role: "StaticText", label: "Weiter", identifier: "", value: "",
            frame: CGRect(x: 0.4, y: 0.81, width: 0.2, height: 0.04), enabled: true, tappable: false),
    ]

    func toolsWithoutRecognition(tree: [UIElement]?) -> (PhoneTools, FakePhone, ActivityLog) {
        let phone = FakePhone(lines: [("Weiter", 120, 300)], tree: tree)
        let log = ActivityLog()
        let tools = PhoneTools(phone: phone, activity: log, settleDelay: 0) { _, _ in
            throw TextRecognitionError("Vision failed: e5rtError(13); on the CPU: e5rtError(13)")
        }
        return (tools, phone, log)
    }

    @Test func textToolsReadTheUITreeWhenRecognitionFails() async throws {
        let (tools, phone, log) = toolsWithoutRecognition(tree: Self.tree)
        let screen = try await tools.call("read_screen", arguments: nil, source: "test", screenshotByDefault: false)
        #expect(!screen.isError)
        #expect(
            screen.text.split(separator: "\n") == [
                "Text recognition failed, so Mobdev read the UI tree instead.", "Willkommen @ (207, 154)",
                "Name: Niklas @ (295, 416)", "Weiter @ (295, 1062)", "Weiter @ (295, 1062)",
            ])
        #expect(log.all.first?.summary == PhoneTools.fromTreeNote)

        let field = try await tools.call("find_text", arguments: ["text": "niklas"], source: "test", screenshotByDefault: false)
        #expect(field.text.hasSuffix("0: Niklas @ (295, 416) (exact)"))

        // The button wins over the label inside it.
        let tapped = try await tools.call("tap_text", arguments: ["text": "weiter"], source: "test", screenshotByDefault: false)
        #expect(tapped.text == "Tapped \"Weiter\" at (295, 1062). " + PhoneTools.fromTreeNote)
        #expect(phone.events.get() == [.tap(Self.tree[2].center, 0.08)])

        let visible = try await tools.call(
            "wait_for_text", arguments: ["text": "Willkommen", "timeout": 1], source: "test", screenshotByDefault: false)
        #expect(visible.text == "\"Willkommen\" is visible. " + PhoneTools.fromTreeNote)
        let stays = try await tools.call(
            "wait_for_text", arguments: ["text": "Willkommen", "gone": true, "timeout": 0], source: "test",
            screenshotByDefault: false)
        #expect(stays.isError)
        #expect(stays.text.contains("is still visible"))
    }

    @Test func textToolsExplainARecognitionFailureWithoutATree() async throws {
        let (tools, phone, _) = toolsWithoutRecognition(tree: nil)
        let calls: [(String, JSONValue?)] = [
            ("read_screen", nil), ("find_text", ["text": "Weiter"]), ("tap_text", ["text": "Weiter"]),
            ("wait_for_text", ["text": "Weiter", "timeout": 0]),
        ]
        for (name, arguments) in calls {
            let output = try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
            #expect(output.isError)
            let lines = output.text.split(separator: "\n")
            #expect(
                lines.first
                    == "Text recognition failed in macOS, so Mobdev cannot read the text on this screen right now. Use screenshot to look at it; the next call may work again.")
            #expect(lines.last == "Details: Vision failed: e5rtError(13); on the CPU: e5rtError(13)")
        }
        #expect(phone.events.get().isEmpty)
    }

    @Test func openAppUsesSpotlight() async throws {
        let (tools, _) = tools()
        _ = try await tools.call("open_app", arguments: ["name": "Maps"], source: "test", screenshotByDefault: false)
        let events = phone.events.get()
        #expect(events.first == .button(.home))
        #expect(events.contains(.key(KeyStroke(0x2C, KeyStroke.command))))
        #expect(!events.contains(.button(.search)))
        #expect(events.last == .key(KeyStroke(0x28)))
    }
}
