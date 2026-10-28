import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// A flow, a test run or a crawl holds its device: other callers' actions fail with "Busy" until
/// it ends, while tools that only look keep working.
@Suite struct DeviceHoldTests {
    let phone = FakePhone(
        lines: [],
        tree: [
            UIElement(
                role: "Button", label: "Sign In", identifier: "", value: "", frame: CGRect(x: 0.3, y: 0.8, width: 0.4, height: 0.05),
                enabled: true, tappable: true)
        ])

    func call(_ tools: PhoneTools, _ name: String, _ arguments: JSONValue? = nil, source: String = "relay") async throws
        -> ToolOutput
    {
        try await tools.call(name, arguments: arguments, source: source, screenshotByDefault: false)
    }

    @Test func aRunningFlowHoldsTheDevice() async throws {
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        // Its own steps act; the wait keeps it running for a moment.
        let flow = Task {
            try await call(
                tools, "run_flow", ["steps": ["home", ["wait_for_element": ["text": "Nope", "timeout": 1.5]]]], source: "local")
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let other = try await call(tools, "home")
        #expect(other.isError)
        #expect(other.text.hasPrefix("Busy: a flow from local is running on this device. Wait for it to finish."))
        #expect(try await !call(tools, "ui_tree").isError)
        let second = try await call(tools, "run_flow", ["steps": ["home"]])
        #expect(second.text.hasPrefix("Busy: a flow from local"))

        let result = try await flow.value
        #expect(result.text.contains("✓ 1. home"), "\(result.text)")
        #expect(phone.events.get().filter { $0 == .button(.home) }.count == 1)
        #expect(try await !call(tools, "home").isError)
    }

    @Test func aTestRunThatFindsTheDeviceHeldSaysSo() async throws {
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-hold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tests"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("mobdev.json"))
        try Data("{\"steps\": [\"home\"]}".utf8).write(to: root.appendingPathComponent("tests/home.json"))
        let project = try TestProject.load(root)

        let flow = Task {
            try await call(tools, "run_flow", ["steps": [["wait_for_element": ["text": "Nope", "timeout": 1.5]]]])
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let blocked = await tools.runTests(
            project, options: TestRunOptions(output: root.appendingPathComponent("out"), video: false), source: "app")
        #expect(blocked.error?.hasPrefix("Busy: a flow from relay") == true)
        #expect(blocked.tests.isEmpty)
        _ = try await flow.value

        let run = await tools.runTests(
            project, options: TestRunOptions(output: root.appendingPathComponent("out2"), video: false), source: "app")
        #expect(run.error == nil)
        #expect(run.tests.first?.status == .passed)
    }
}
