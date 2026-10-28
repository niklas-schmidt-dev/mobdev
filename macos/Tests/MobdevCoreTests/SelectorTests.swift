import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// tap_element and wait_for_element on a sign-in screen, found by role, value, state, region and
/// the label next to them.
@Suite struct SelectorTests {
    static func element(
        _ role: String, _ label: String, id: String = "", value: String = "", x: Double, y: Double,
        enabled: Bool = true, tappable: Bool = true
    ) -> UIElement {
        UIElement(
            role: role, label: label, identifier: id, value: value, frame: CGRect(x: x, y: y, width: 0.3, height: 0.04),
            enabled: enabled, tappable: tappable)
    }

    /// As fractions of a 1179×2556 screen, whose screenshots are 590×1280.
    static let signIn = [
        element("StaticText", "Email", x: 0.1, y: 0.20, tappable: false),
        element("TextField", "", id: "email", x: 0.1, y: 0.25),
        element("StaticText", "Password", x: 0.1, y: 0.35, tappable: false),
        element("SecureTextField", "", id: "password", x: 0.1, y: 0.40),
        element("Switch", "Remember me", value: "off", x: 0.6, y: 0.50),
        element("Button", "Sign In", x: 0.35, y: 0.80, enabled: false),
        element("Button", "Help", x: 0.35, y: 0.90),
    ]

    let phone = FakePhone(lines: [], tree: signIn)

    func call(_ name: String, _ arguments: JSONValue) async throws -> ToolOutput {
        try await PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
            .call(name, arguments: arguments, source: "test", screenshotByDefault: false)
    }

    func tap(_ arguments: JSONValue) async throws -> (ToolOutput, NormalizedPoint?) {
        let before = phone.events.get().count
        let output = try await call("tap_element", arguments)
        let taps = phone.events.get().dropFirst(before).compactMap { event -> NormalizedPoint? in
            if case .tap(let point, _) = event { return point }
            return nil
        }
        return (output, taps.first)
    }

    @Test func nearPicksTheClosestOnTheGivenSide() async throws {
        let (email, emailTap) = try await tap(["role": "textfield", "near": ["text": "Email", "direction": "below"]])
        #expect(!email.isError, "\(email.text)")
        #expect(abs((emailTap?.y ?? 0) - 0.27) < 0.001)
        let (password, passwordTap) = try await tap(["role": "textfield", "near": ["text": "Password", "direction": "below"]])
        #expect(!password.isError, "\(password.text)")
        #expect(abs((passwordTap?.y ?? 0) - 0.42) < 0.001)
        let (shorthand, shorthandTap) = try await tap(["role": "switch", "near": "Password"])
        #expect(!shorthand.isError)
        #expect(abs((shorthandTap?.y ?? 0) - 0.52) < 0.001)
        let (nothing, _) = try await tap(["role": "textfield", "near": ["text": "Nowhere"], "timeout": 0])
        #expect(nothing.isError)
        #expect(nothing.text.hasPrefix("No element with role textfield near \"Nowhere\". On screen:\n"))
    }

    @Test func fieldsCombineAndStateNarrowsThem() async throws {
        let (ambiguous, _) = try await tap(["role": "button", "region": "bottom_half", "timeout": 0])
        #expect(ambiguous.text.hasPrefix("2 elements match. Pass index:"))
        let (enabled, enabledTap) = try await tap(["role": "button", "enabled": true])
        #expect(enabled.text == "Tapped Button \"Help\" at (295, 1178).")
        #expect(abs((enabledTap?.y ?? 0) - 0.92) < 0.001)
        let (regex, _) = try await tap(["regex": "^sign"])
        #expect(regex.text.hasPrefix("Tapped Button \"Sign In\""))
        let (value, _) = try await tap(["role": "switch", "value": "off"])
        #expect(value.text.hasPrefix("Tapped Switch \"Remember me\""))
        #expect(ElementQuery.matches(role: "CheckBox", query: "switch"))  // A UISwitch in the simulator's tree.
        #expect(ElementQuery.matches(role: "SwitchCompat", query: "switch"))
        #expect(ElementQuery.matches(role: "EditText", query: "textfield"))
        #expect(ElementQuery.matches(role: "ImageButton", query: "button"))
        #expect(!ElementQuery.matches(role: "TextField", query: "text"))
        #expect(ElementQuery.matches(role: "Heading", query: "heading"))
        let (both, _) = try await tap(["id": "email", "text": "Password", "timeout": 0])
        #expect(both.text.hasPrefix("No element with id \"email\" label \"Password\"."))
        let (top, _) = try await tap(["role": "button", "region": "top_half", "timeout": 0])
        #expect(top.isError)
    }

    @Test func mistakesAreNamed() async throws {
        #expect(try await tap(["regex": "(", "timeout": 0]).0.text == "regex \"(\" is not a valid regular expression.")
        #expect(try await tap(["text": "Help", "region": "middle"]).0.text.hasPrefix("region must be one of top_half"))
        #expect(try await tap(["role": "button", "near": ["direction": "below"]]).0.text.hasPrefix("near needs text"))
        #expect(try await tap(["role": "button", "near": ["text": "Email", "direction": "under"]]).0.text.hasPrefix("near.direction must be one of below"))
    }

    @Test func waitingForAnEnabledButton() async throws {
        let disabled = try await call("wait_for_element", ["text": "Sign In", "enabled": true, "timeout": 0])
        #expect(disabled.isError)
        #expect(disabled.text.contains("no element with label \"Sign In\" enabled appeared"))
        let present = try await call("wait_for_element", ["role": "button", "text": "Sign In", "enabled": false, "timeout": 0])
        #expect(present.text == "Found role button label \"Sign In\" disabled.")
    }

    @Test func aWholeLabelElsewhereDoesNotHideAFieldThatFits() async throws {
        let phone = FakePhone(lines: [], tree: [
            Self.element("StaticText", "Email", x: 0.1, y: 0.2, tappable: false),
            Self.element("TextField", "Email address", x: 0.1, y: 0.3),
        ])
        let output = try await PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
            .call("tap_element", arguments: ["role": "textfield", "text": "Email"], source: "test", screenshotByDefault: false)
        #expect(output.text.hasPrefix("Tapped TextField \"Email address\""), "\(output.text)")
    }

    @Test func anEmptyValueFindsAnEmptyField() async throws {
        let empty = try await call("wait_for_element", ["role": "textfield", "value": "", "near": "Password", "timeout": 0])
        #expect(empty.text == "Found role textfield value \"\" near \"Password\".", "\(empty.text)")
        #expect(try await call("wait_for_element", ["value": 5, "timeout": 0]).text == "value must be a string.")
    }

    @Test func aWholeLabelOnTheOtherSideDoesNotHideOneOnTheAskedSide() async throws {
        let phone = FakePhone(lines: [], tree: [
            Self.element("Button", "Save", x: 0.35, y: 0.2),
            Self.element("StaticText", "Total", x: 0.35, y: 0.5, tappable: false),
            Self.element("Button", "Save changes", x: 0.35, y: 0.7),
        ])
        let output = try await PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0).call(
            "tap_element", arguments: ["text": "Save", "near": ["text": "Total", "direction": "below"]], source: "test",
            screenshotByDefault: false)
        #expect(output.text.hasPrefix("Tapped Button \"Save changes\""), "\(output.text)")
    }

    /// The tree can be read before the screen's picture arrives, as while a simulator starts.
    @Test func waitingNeedsNoPicture() async throws {
        phone.screen.set(.searching)
        #expect(try await !call("wait_for_element", ["role": "button", "text": "Help", "timeout": 0]).isError)
        #expect(try await !call("wait_for_element", ["role": "button", "near": "Sign In", "timeout": 0]).isError)
    }

    /// Fractions of a screen twice as high as wide: 0.3 across is nearer than 0.2 down.
    @Test func nearMeasuresAsTheScreenLooks() async throws {
        let phone = FakePhone(lines: [], tree: [
            Self.element("StaticText", "Total", x: 0.35, y: 0.48, tappable: false),
            Self.element("Button", "Down", x: 0.35, y: 0.68),
            Self.element("Button", "Across", x: 0.65, y: 0.48),
        ])
        let output = try await PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
            .call("tap_element", arguments: ["role": "button", "near": "Total"], source: "test", screenshotByDefault: false)
        #expect(output.text.hasPrefix("Tapped Button \"Across\""), "\(output.text)")
    }

    /// Every backend says on or off for a switch; iOS 27's simulator gives "1" as text.
    @Test func switchesAreOnOrOffInTheSimulatorToo() throws {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.checkBox)
        element.setAccessibilityLabel("Haptic Feedback")
        element.setAccessibilityValue("1")
        element.setAccessibilityFrame(CGRect(x: 10, y: 10, width: 100, height: 40))
        let screen = CGRect(x: 0, y: 0, width: 400, height: 800)
        #expect(SimulatorAccessibility.element(element, in: screen)?.value == "on")
        element.setAccessibilityValue(NSNumber(value: 0))
        #expect(SimulatorAccessibility.element(element, in: screen)?.value == "off")
    }

    @Test func androidFieldsHoldTheirText() throws {
        let xml = """
            <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">
            <node class="android.widget.EditText" text="me@example.com" hint="Email" resource-id="com.example:id/email" clickable="true" enabled="true" bounds="[0,100][1080,200]" />
            <node class="android.widget.EditText" text="Password" hint="Password" resource-id="com.example:id/password" clickable="true" enabled="true" bounds="[0,300][1080,400]" />
            </hierarchy>
            """
        let elements = try #require(AndroidHierarchyParser.parse(Data(xml.utf8), width: 1080, height: 2400))
        #expect(elements.map(\.value) == ["me@example.com", ""])
        var query = ElementQuery(id: nil, text: nil)
        query.value = "me@example.com"
        #expect(query.matches(in: elements).map(\.identifier) == ["com.example:id/email"])
    }
}
