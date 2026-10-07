import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

@Suite struct AppToolTests {
    func element(_ role: String, _ label: String, _ frame: CGRect, tappable: Bool) -> UIElement {
        UIElement(role: role, label: label, identifier: "", value: "", frame: frame, enabled: true, tappable: tappable)
    }

    /// iOS's prompt for a custom URL scheme opened from outside the app, as the tree shows it.
    var prompt: [UIElement] {
        [
            element("StaticText", "Open in “Mobdev Fixture”?", CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.05), tappable: false),
            element("Button", "Cancel", CGRect(x: 0.1, y: 0.5, width: 0.25, height: 0.125), tappable: true),
            element("Button", "Open", CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.125), tappable: true),
        ]
    }

    func tools(_ phone: FakePhone) -> PhoneTools { PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0) }

    /// On GitHub's simulators (simctl before Xcode 27) the prompt stays over SpringBoard and hides
    /// the app from every later step, so open_url taps Open itself.
    @Test func openURLConfirmsTheOpenInPrompt() async throws {
        let apps = FakeApps()
        let phone = FakePhone(lines: [], apps: apps, tree: prompt)
        // The prompt, then the app's own screen once Open was tapped.
        phone.laterTree.set((afterReads: 1, tree: []))
        let output = try await tools(phone).call(
            "open_url", arguments: ["url": "mobdevfixture://hello"], source: "test", screenshotByDefault: false)
        #expect(!output.isError)
        #expect(output.text == "Opened mobdevfixture://hello. iOS asked whether to open it in the app; Mobdev tapped Open.")
        #expect(apps.opened.get().map(\.absoluteString) == ["mobdevfixture://hello"])
        #expect(phone.events.get() == [.tap(NormalizedPoint(x: 0.625, y: 0.5625), 0.08)])
    }

    /// A slow simulator swallowed the first tap, so Open is tapped again while the prompt stays,
    /// and a prompt that outlasts every tap is reported instead of being called confirmed.
    @Test func openURLTapsAgainWhileThePromptStays() async throws {
        let phone = FakePhone(lines: [], apps: FakeApps(), tree: prompt)
        let output = try await tools(phone).call(
            "open_url", arguments: ["url": "mobdevfixture://stuck"], source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("Mobdev tapped Open 3 times, but the prompt is still there"))
        #expect(phone.events.get().count == PhoneTools.openPromptTaps)
    }

    /// Where simctl opens the URL, the prompt is expected and waited for well past a moment: on
    /// GitHub's slow simulators it showed up seconds after the URL was opened.
    @Test func openURLWaitsLongerForAnExpectedPrompt() async throws {
        let own = [element("Button", "Ping", CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.05), tappable: true)]
        let phone = FakePhone(lines: [], apps: FakeApps(mayPromptToOpenURL: true), tree: own)
        // The app's own screen for 15 tree reads, almost four seconds, then the prompt.
        phone.laterTree.set((afterReads: 15, tree: prompt))
        let started = Date()
        let output = try await tools(phone).call(
            "open_url", arguments: ["url": "mobdevfixture://late"], source: "test", screenshotByDefault: false)
        #expect(output.text.hasSuffix("Mobdev tapped Open 3 times, but the prompt is still there. Tap its Open button, e.g. with tap_element."))
        #expect(phone.events.get().first == .tap(NormalizedPoint(x: 0.625, y: 0.5625), 0.08))
        #expect(Date().timeIntervalSince(started) > 3)
    }

    @Test func openURLLeavesOtherScreensAlone() async throws {
        // An app's own Open button, without the prompt's title, is not the prompt.
        let own = [element("Button", "Open", CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.125), tappable: true)]
        let phone = FakePhone(lines: [], apps: FakeApps(), tree: own)
        let output = try await tools(phone).call(
            "open_url", arguments: ["url": "mobdevfixture://x"], source: "test", screenshotByDefault: false)
        #expect(output.text == "Opened mobdevfixture://x.")
        #expect(phone.events.get().isEmpty)

        // Web links never prompt, and an iPhone without a tree is left as it is.
        let web = FakePhone(lines: [], apps: FakeApps(), tree: prompt)
        let page = try await tools(web).call(
            "open_url", arguments: ["url": "https://example.com"], source: "test", screenshotByDefault: false)
        #expect(page.text == "Opened https://example.com.")
        #expect(web.events.get().isEmpty)
        let bare = FakePhone(lines: [], apps: FakeApps())
        let link = try await tools(bare).call(
            "open_url", arguments: ["url": "mobdevfixture://x"], source: "test", screenshotByDefault: false)
        #expect(link.text == "Opened mobdevfixture://x.")
        #expect(bare.events.get().isEmpty)

        #expect(PhoneTools.openPromptButton(in: prompt)?.label == "Open")
        #expect(PhoneTools.openPromptButton(in: own) == nil)
    }
}
