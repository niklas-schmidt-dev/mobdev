import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

@Suite struct UITreeTests {
    /// A trimmed `uiautomator dump` of Android Settings on a 1280×2856 screen.
    static let settingsXML = """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">\
        <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.android.settings" \
        content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" \
        focused="false" scrollable="false" long-clickable="false" password="false" selected="false" \
        bounds="[0,0][1280,2856]">\
        <node index="0" text="Search settings" resource-id="com.android.settings:id/search_action_bar_title" \
        class="android.widget.TextView" package="com.android.settings" content-desc="" checkable="false" \
        checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" \
        long-clickable="false" password="false" selected="false" bounds="[160,400][800,480]" />\
        <node index="1" text="" resource-id="com.android.settings:id/search_bar" class="android.widget.LinearLayout" \
        package="com.android.settings" content-desc="Search" checkable="false" checked="false" clickable="true" \
        enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" \
        selected="false" bounds="[64,360][1216,520]" />\
        <node index="2" text="Network &amp; internet" resource-id="android:id/title" class="android.widget.TextView" \
        package="com.android.settings" content-desc="" checkable="false" checked="false" clickable="false" \
        enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" \
        selected="false" bounds="[240,700][900,780]" />\
        <node index="3" text="" resource-id="android:id/switch_widget" class="android.widget.Switch" \
        package="com.android.settings" content-desc="" checkable="true" checked="true" clickable="true" \
        enabled="false" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" \
        selected="false" bounds="[1100,700][1216,780]" />\
        <node index="4" text="" resource-id="" class="android.view.View" package="com.android.settings" \
        content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" \
        focused="false" scrollable="false" long-clickable="false" password="false" selected="false" \
        bounds="[0,0][0,0]" />\
        </node></hierarchy>
        """

    @Test func parsesAndroidHierarchy() throws {
        let elements = try #require(AndroidHierarchyParser.parse(Data(Self.settingsXML.utf8), width: 1280, height: 2856))
        // The empty-bounds node is dropped.
        #expect(elements.count == 5)
        let search = elements[2]
        #expect(search.role == "LinearLayout")
        #expect(search.label == "Search")
        #expect(search.identifier == "com.android.settings:id/search_bar")
        #expect(search.tappable)
        #expect(abs(search.frame.minX - 64.0 / 1280) < 0.0001)
        #expect(abs(search.frame.height - 160.0 / 2856) < 0.0001)
        #expect(elements[3].label == "Network & internet")
        #expect(!elements[3].tappable)
        let toggle = elements[4]
        #expect(toggle.role == "Switch")
        #expect(toggle.value == "on")
        #expect(!toggle.enabled)
        #expect(AndroidHierarchyParser.parse(Data("not xml".utf8), width: 1, height: 1) == nil)
    }

    func phone() throws -> FakePhone {
        let elements = try #require(AndroidHierarchyParser.parse(Data(Self.settingsXML.utf8), width: 1280, height: 2856))
        return FakePhone(lines: [], tree: elements)
    }

    @Test func uiTreeListsLabelledElementsInScreenshotPixels() async throws {
        let tools = PhoneTools(phone: try phone(), activity: ActivityLog(), settleDelay: 0)
        let output = try await tools.call("ui_tree", arguments: nil, source: "test", screenshotByDefault: false)
        #expect(!output.isError)
        // The root layout and nothing else lacks both label and identifier.
        guard case .array(let items) = output.data else { Issue.record("no array"); return }
        #expect(items.count == 4)
        #expect(output.text.contains("LinearLayout \"Search\" id=com.android.settings:id/search_bar"))
        #expect(output.text.contains("value=on disabled"))
        let all = try await tools.call("ui_tree", arguments: ["all": true], source: "test", screenshotByDefault: false)
        guard case .array(let everything) = all.data else { Issue.record("no array"); return }
        #expect(everything.count == 5)
        let filtered = try await tools.call(
            "ui_tree", arguments: ["contains": "internet"], source: "test", screenshotByDefault: false)
        guard case .array(let one) = filtered.data else { Issue.record("no array"); return }
        #expect(one.count == 1)
        // Screenshots of a 1179×2556 fake are 590×1280; the element's center maps into that space.
        #expect(one.first?["x"] == .number((570.0 / 1280 * 590).rounded()))
    }

    @Test func tapElementPrefersTappableMatches() async throws {
        let fake = try phone()
        let tools = PhoneTools(phone: fake, activity: ActivityLog(), settleDelay: 0)
        // "Search settings" (text) and "Search" (the bar) both contain "search"; "Search" is exact.
        let output = try await tools.call(
            "tap_element", arguments: ["text": "search"], source: "test", screenshotByDefault: false)
        #expect(!output.isError, "\(output.text)")
        let byID = try await tools.call(
            "tap_element", arguments: ["id": "switch_widget"], source: "test", screenshotByDefault: false)
        #expect(!byID.isError, "\(byID.text)")
        let taps = fake.events.get().compactMap { event -> NormalizedPoint? in
            if case .tap(let point, _) = event { return point }
            return nil
        }
        #expect(taps.count == 2)
        #expect(abs(taps[0].x - 640.0 / 1280) < 0.001)
        #expect(abs(taps[0].y - 440.0 / 2856) < 0.001)
        #expect(abs(taps[1].x - 1158.0 / 1280) < 0.001)
        let missing = try await tools.call(
            "tap_element", arguments: ["text": "Battery", "timeout": 0], source: "test", screenshotByDefault: false)
        #expect(missing.isError)
        #expect(missing.text.contains("ui_tree"))
    }

    @Test func waitForElementChecksPresenceAndAbsence() async throws {
        let tools = PhoneTools(phone: try phone(), activity: ActivityLog(), settleDelay: 0)
        let found = try await tools.call(
            "wait_for_element", arguments: ["id": "search_bar", "timeout": 0], source: "test", screenshotByDefault: false)
        #expect(!found.isError, "\(found.text)")
        let gone = try await tools.call(
            "wait_for_element", arguments: ["text": "Battery", "gone": true, "timeout": 0], source: "test",
            screenshotByDefault: false)
        #expect(!gone.isError)
        let timedOut = try await tools.call(
            "wait_for_element", arguments: ["text": "Battery", "timeout": 0.6], source: "test", screenshotByDefault: false)
        #expect(timedOut.isError)
        #expect(timedOut.text.contains("Timed out after 0.6 s"))
        let noQuery = try await tools.call("wait_for_element", arguments: [:], source: "test", screenshotByDefault: false)
        #expect(noQuery.text == "Pass id or text.")
    }

    /// Seen on the iPhone: the Spotlight pill and its wrapper share id and frame.
    @Test func anElementAndItsWrapperAtTheSamePlaceCountOnce() async throws {
        let frame = CGRect(x: 0.3, y: 0.8, width: 0.4, height: 0.04)
        let fake = FakePhone(
            lines: [],
            tree: [
                UIElement(role: "Other", label: "", identifier: "spotlight-pill", value: "", frame: frame, enabled: true, tappable: false),
                UIElement(role: "Other", label: "Suchen", identifier: "spotlight-pill", value: "", frame: frame, enabled: true, tappable: false),
                UIElement(
                    role: "Other", label: "Suchen", identifier: "spotlight-pill", value: "",
                    frame: frame.offsetBy(dx: 0, dy: 0.1), enabled: true, tappable: false),
            ])
        let tools = PhoneTools(phone: fake, activity: ActivityLog(), settleDelay: 0)
        let twoPlaces = try await tools.call(
            "tap_element", arguments: ["id": "spotlight-pill"], source: "test", screenshotByDefault: false)
        #expect(twoPlaces.text.contains("2 elements match"))
        let one = ElementQuery(id: "spotlight-pill", text: nil).matches(in: Array(fake.tree!.prefix(2)))
        #expect(one.count == 1)
        #expect(one.first?.label == "Suchen")
    }

    @Test func iPhoneExplainsItHasNoTree() async throws {
        let tools = PhoneTools(phone: FakePhone(lines: []), activity: ActivityLog(), settleDelay: 0)
        let output = try await tools.call("ui_tree", arguments: nil, source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("read_screen"))
        // And how to get one: Mobdev Runner.
        #expect(output.text.contains("Developer Mode"))
        #expect(output.text.contains("Turn On under UI Tree"))
    }
}
