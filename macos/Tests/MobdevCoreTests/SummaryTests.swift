import Foundation
import Testing
@testable import MobdevCore

/// What just worked becomes steps for a test.
@Suite struct RecentStepsTests {
    @Test func recentStepsKeepWhatSucceeded() async throws {
        let phone = FakePhone(lines: [("Settings", 420, 300)])
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        func call(_ name: String, _ arguments: JSONValue) async throws -> ToolOutput {
            try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
        }
        _ = try await call("tap", ["x": 10, "y": 20])
        _ = try await call("screenshot", [:])  // Only looks.
        _ = try await call("tap", ["x": 9999, "y": 20])  // Fails.
        _ = try await call("type_text", ["text": "Hel"])
        _ = try await call("type_text", ["text": "lo", "submit": true])
        let recent = try await call("recent_steps", [:])
        #expect(recent.data?["steps"] == [["tap": ["x": 10, "y": 20]], ["type_text": ["text": "Hello", "submit": true]]])
        #expect(recent.text.contains("1. tap"))
        let last = try await call("recent_steps", ["count": 1])
        #expect(last.data?["steps"]?.arrayValue?.count == 1)
        _ = try await call("recent_steps", ["clear": true])
        let cleared = try await call("recent_steps", [:])
        #expect(cleared.data?["steps"] == [])
    }

    @Test func buttonsArePressedButAnIPhoneIsNeverLocked() async throws {
        let phone = FakePhone(lines: [])
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let volume = try await tools.call("press_button", arguments: ["button": "volume_up"], source: "test", screenshotByDefault: false)
        #expect(volume.text == "Pressed volume up.")
        let lock = try await tools.call("press_button", arguments: ["button": "lock"], source: "test", screenshotByDefault: false)
        #expect(lock.isError)
        #expect(phone.events.get() == [.button(.volumeUp)])
    }

    @Test func shortcutsRunThroughALinkWhereAppsAreReachable() async throws {
        let apps = FakeApps()
        let phone = FakePhone(lines: [], apps: apps)
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let output = try await tools.call(
            "run_shortcut", arguments: ["name": "Focus on"], source: "test", screenshotByDefault: false)
        #expect(!output.isError)
        #expect(apps.opened.get() == [URL(string: "shortcuts://run-shortcut?name=Focus%20on")!])
    }
}

@Suite struct TestCommandDevicesTests {
    @Test func severalDevicesAndSimulators() throws {
        let options = try TestCommand.parse([
            "p", "--device", "A", "--device", "B", "--simulator", "iPhone 17", "--simulator", "iPhone SE (3rd generation),ios-26",
        ])
        #expect(options.device == "A")
        #expect(options.deviceQueries == ["A", "B"])
        #expect(options.simulators == ["iPhone 17", "iPhone SE (3rd generation),ios-26"])
        #expect(throws: (any Error).self) { try TestCommand.parse(["p", "--simulator"]) }
    }
}

/// The Markdown that CI job summaries and pull request comments show.
@Suite struct SummaryTests {
    @Test func aFlowSummaryShowsEveryStep() {
        let flow = Flow(name: "Sign in", steps: [Flow.Step("tap_element", ["id": "email"]), Flow.Step("home")])
        let result = FlowResult(
            flow: flow,
            steps: [
                .init(step: flow.steps[0], text: "Tapped TextField at (1, 2).", passed: true, seconds: 0.4),
                .init(step: flow.steps[1], text: "No | pipes\nhere", passed: false, seconds: 0.1),
            ], seconds: 0.5)
        let markdown = result.markdown
        #expect(markdown.hasPrefix("### ❌ Mobdev flow: Sign in"))
        #expect(markdown.contains("Failed at step 2 of 2."))
        #expect(markdown.contains("| ✅ | 1. `tap_element {\"id\":\"email\"}` | 0.4 s | Tapped TextField at (1, 2). |"))
        #expect(markdown.contains("No \\| pipes here"))
    }

    @Test func aTestSummaryHasATable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString)")
        let project = try TestProject.parse(["name": "My App"], folder: folder)
        var result = TestRunResult(
            project: project, device: .init(id: "SIM", name: "iPhone 17", kind: "simulator"), output: folder)
        result.seconds = 3
        result.tests = [
            .init(
                name: "Sign in", slug: "sign-in", file: "tests/sign-in.json", status: .passed, seconds: 2, steps: [],
                failedStep: nil, message: "", screenshot: nil, video: nil),
            .init(
                name: "Pay", slug: "pay", file: "tests/pay.json", status: .skipped, seconds: 0, steps: [], failedStep: nil,
                message: "not for ios", screenshot: nil, video: nil),
        ]
        let markdown = result.markdown
        #expect(markdown.hasPrefix("### ✅ Mobdev tests: My App on iPhone 17"))
        #expect(markdown.contains("1 passed, 0 failed, 1 skipped in 3.0 s.") == false)
        #expect(markdown.contains("1 passed, 1 skipped in 3.0 s."))
        #expect(markdown.contains("| ✅ | Sign in | 2.0 s |  |"))
        #expect(markdown.contains("| ⏭️ | Pay |  | not for ios |"))
        try result.write()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("summary.md").path))
    }
}
