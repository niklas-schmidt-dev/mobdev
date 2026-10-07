import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

@Suite struct ObserveTests {
    /// An Android-style list: rows that can be tapped but have no label, with their text inside.
    static let rows: [UIElement] = [
        UIElement(
            role: "FrameLayout", label: "", identifier: "android:id/content", value: "",
            frame: CGRect(x: 0, y: 0, width: 1, height: 1), enabled: true, tappable: false),
        UIElement(
            role: "LinearLayout", label: "", identifier: "", value: "", frame: CGRect(x: 0, y: 0.2, width: 1, height: 0.1),
            enabled: true, tappable: true),
        UIElement(
            role: "TextView", label: "Network", identifier: "android:id/title", value: "",
            frame: CGRect(x: 0.2, y: 0.21, width: 0.5, height: 0.03), enabled: true, tappable: false),
        UIElement(
            role: "TextView", label: "Wi-Fi, hotspot", identifier: "android:id/summary", value: "",
            frame: CGRect(x: 0.2, y: 0.25, width: 0.5, height: 0.03), enabled: true, tappable: false),
        UIElement(
            role: "ImageView", label: "", identifier: "android:id/icon", value: "",
            frame: CGRect(x: 0.05, y: 0.22, width: 0.08, height: 0.05), enabled: true, tappable: false),
        UIElement(
            role: "Button", label: "", identifier: "save", value: "", frame: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.05),
            enabled: true, tappable: true),
        UIElement(
            role: "TextView", label: "Below the screen", identifier: "", value: "",
            frame: CGRect(x: 0.1, y: 1.2, width: 0.5, height: 0.05), enabled: true, tappable: false),
    ]

    func tools(tree: [UIElement]? = rows) -> (PhoneTools, FakePhone) {
        let phone = FakePhone(lines: [], tree: tree)
        return (PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0), phone)
    }

    @Test func marksFoldARowsTextIntoTheRow() throws {
        let marks = try #require(PhoneTools.marks(from: Self.rows))
        #expect(marks.map(\.label) == ["Network, Wi-Fi, hotspot", ""])
        #expect(marks.map(\.identifier) == ["", "save"])
        #expect(marks.map(\.number) == [1, 2])
    }

    @Test func observeListsMarksAndTapMarkTapsOne() async throws {
        let (tools, phone) = tools()
        let observed = try await tools.call("observe", arguments: [:], source: "test", screenshotByDefault: false)
        #expect(observed.text.contains("[1] LinearLayout \"Network, Wi-Fi, hotspot\""))
        #expect(observed.text.contains("[2] Button id=save"))
        #expect(observed.image == nil)
        #expect(observed.data?.arrayValue?.count == 2)

        tools.recorder.start()
        let tapped = try await tools.call("tap_mark", arguments: ["mark": 2], source: "test", screenshotByDefault: false)
        #expect(!tapped.isError)
        #expect(phone.events.get() == [.tap(NormalizedPoint(x: 0.5, y: 0.625), 0.08)])
        // Recorded so it replays without the marks.
        #expect(tools.recorder.stop() == [Flow.Step("tap_element", ["id": "save"])])

        let missing = try await tools.call("tap_mark", arguments: ["mark": 9], source: "test", screenshotByDefault: false)
        #expect(missing.isError)
        #expect(missing.text.contains("marks 1 to 2"))
    }

    @Test func observeCanDrawTheMarks() async throws {
        let (tools, _) = tools()
        let output = try await tools.call("observe", arguments: ["image": true], source: "test", screenshotByDefault: false)
        #expect(output.image?.mimeType == "image/jpeg")
        #expect(output.image?.height == 1280)
        let filtered = try await tools.call("observe", arguments: ["contains": "wi-fi"], source: "test", screenshotByDefault: false)
        #expect(filtered.data?.arrayValue?.count == 1)
    }

    @Test func tapMarkNeedsAnObserveFirst() async throws {
        let (tools, phone) = tools()
        let output = try await tools.call("tap_mark", arguments: ["mark": 1], source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("observe"))
        #expect(phone.events.get().isEmpty)
    }

    @Test func scrollUntilVisibleFindsWhatIsThere() async throws {
        let (tools, phone) = tools()
        let output = try await tools.call(
            "scroll_until_visible", arguments: ["id": "save"], source: "test", screenshotByDefault: false)
        #expect(output.text.contains("without scrolling"))
        #expect(phone.events.get().isEmpty)
    }

    /// The fake screen never moves, so the end of the list is reached after two scrolls.
    @Test func scrollUntilVisibleStopsAtTheEnd() async throws {
        let (tools, phone) = tools()
        let output = try await tools.call(
            "scroll_until_visible", arguments: ["text": "Below the screen"], source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("the end is reached"))
        #expect(phone.events.get() == [.scroll(5), .scroll(5)])
    }

    @Test func aStillScreenIsIdle() async throws {
        let (tools, _) = tools()
        let output = try await tools.call(
            "wait_for_idle", arguments: ["stable": 0.2], source: "test", screenshotByDefault: false)
        #expect(!output.isError)
        #expect(output.text.contains("still for 0.2 s"))
    }

    @Test func signaturesIgnoreTheStatusBar() {
        let plain = FakePhone.render(lines: [("Hello", 100, 1200)], width: 1179, height: 2556)
        let clock = FakePhone.render(lines: [("Hello", 100, 1200), ("9:41", 100, 60)], width: 1179, height: 2556)
        let moved = FakePhone.render(lines: [("Hello", 100, 1800)], width: 1179, height: 2556)
        let a = FrameSignature(plain)!, b = FrameSignature(clock)!, c = FrameSignature(moved)!
        #expect(a.changed(from: a) == 0)
        #expect(a.changed(from: b) < 0.002)
        #expect(a.changed(from: c) > 0.002)
    }
}

@Suite struct BlocklistTests {
    @Test func namesAndBundleIDsMatch() {
        let list = ["Sparkasse", "com.apple.mobilemail"]
        #expect(AppBlocklist.isBlocked("sparkasse", in: list))
        #expect(AppBlocklist.isBlocked("com.example.Sparkasse", in: list))
        #expect(AppBlocklist.isBlocked("de.sparkasse.app", in: list))
        #expect(AppBlocklist.isBlocked("com.apple.mobilemail", in: list))
        #expect(AppBlocklist.isBlocked("mobilemail", in: list))
        #expect(!AppBlocklist.isBlocked("Mail", in: list))
        #expect(!AppBlocklist.isBlocked("com.example.notes", in: list))
    }

    @Test func blockedAppsCannotBeOpened() throws {
        let list = ["Sparkasse"]
        #expect(throws: ToolFailure.self) { try AppBlocklist.check("open_app", Arguments(["name": "Sparkasse"]), list: list) }
        #expect(throws: ToolFailure.self) {
            try AppBlocklist.check("launch_app", Arguments(["bundle_id": "de.sparkasse.app"]), list: ["de.sparkasse.app"])
        }
        try AppBlocklist.check("open_app", Arguments(["name": "Notes"]), list: list)
        try AppBlocklist.check("tap", Arguments(["x": 1, "y": 2]), list: list)
    }
}

@Suite struct CallCommandTests {
    @Test func argumentsAreJSONWhereTheyParse() throws {
        let options = try CallCommand.parse([
            "tap", "x=120", "y=300.5", "text=hello world", "flag=true", "list=[1,2]", "--device", "SIM", "--json",
        ])
        #expect(options.tool == "tap")
        #expect(options.arguments["x"] == 120)
        #expect(options.arguments["y"] == 300.5)
        #expect(options.arguments["text"] == "hello world")
        #expect(options.arguments["flag"] == true)
        #expect(options.arguments["list"] == [1, 2])
        #expect(options.arguments["device"] == "SIM")
        #expect(options.json)
        let object = try CallCommand.parse(["type_text", #"{"text":"a=b","submit":true}"#, "--local"])
        #expect(object.arguments["text"] == "a=b")
        #expect(object.local)
        #expect(throws: ToolFailure.self) { try CallCommand.parse(["tap", "loose"]) }
        #expect(throws: ToolFailure.self) { try CallCommand.parse([]) }
        #expect(CallCommand.isTool("set_location"))
        #expect(!CallCommand.isTool("flow"))
        #expect(CallCommand.firstSentence("Press a key, e.g. space. More here.") == "Press a key, e.g. space.")
        #expect(CallCommand.firstSentence("Saves an .mp4 file. Then stops.") == "Saves an .mp4 file.")
        #expect(CallCommand.firstSentence("No period") == "No period")
    }
}
