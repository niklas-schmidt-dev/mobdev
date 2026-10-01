import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

@Suite struct FlowTests {
    @Test func parsesStepsAndWritesOneStepPerLine() throws {
        let json = """
            {"name": "Sign in", "steps": [
              {"tap_element": {"id": "email"}},
              {"type_text": {"text": "me@example.com", "submit": true}},
              "home",
              {"screenshot": null}
            ]}
            """
        let flow = try Flow.parse(try JSONValue.parse(Data(json.utf8)))
        #expect(flow.name == "Sign in")
        #expect(flow.steps == [
            Flow.Step("tap_element", ["id": "email"]),
            Flow.Step("type_text", ["text": "me@example.com", "submit": true]),
            Flow.Step("home"), Flow.Step("screenshot"),
        ])
        let text = String(decoding: flow.encoded(), as: UTF8.self)
        #expect(text.contains("\n    {\"tap_element\":{\"id\":\"email\"}},\n"))
        #expect(text.contains("\n    \"home\",\n"))
        #expect(try Flow.parse(try JSONValue.parse(flow.encoded())) == flow)

        let bare = try Flow.parse(["home", ["tap": ["x": 1, "y": 2]]], name: "login")
        #expect(bare.name == "login")
        #expect(bare.steps.count == 2)
        #expect(throws: (any Error).self) { try Flow.parse(["home": [:]]) }
        #expect(throws: (any Error).self) { try Flow.parse([["tap": 1]]) }
        #expect(throws: (any Error).self) { try Flow.parse([["tap": ["x": 1], "home": [:]]]) }
    }

    func tools(_ phone: FakePhone) -> PhoneTools {
        PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
    }

    @Test func runsEveryStepAndStopsAtTheFirstFailure() async throws {
        let phone = FakePhone(lines: [("Settings", 420, 300)])
        let tools = tools(phone)
        let passing = try await tools.call(
            "run_flow",
            arguments: ["steps": [["tap": ["x": 100, "y": 200]], "home", ["type_text": ["text": "hi"]]]],
            source: "test", screenshotByDefault: false)
        #expect(!passing.isError, "\(passing.text)")
        #expect(passing.text.hasPrefix("Flow \"Flow\" passed: 3 steps"))
        #expect(phone.events.get().count == 3)

        let failing = try await tools.call(
            "run_flow",
            arguments: ["steps": ["home", ["tap": ["x": 5000, "y": 1]], "home"]],
            source: "test", screenshotByDefault: false)
        #expect(failing.isError)
        #expect(failing.text.hasPrefix("Flow \"Flow\" failed at step 2 of 3: tap {\"x\":5000,\"y\":1}."))
        #expect(failing.data?["failed_step"] == 2)
        // The third step never ran: one more home, no second.
        #expect(phone.events.get().count == 4)
    }

    @Test func refusesNestedFlowsAndOtherDevices() async throws {
        let tools = tools(FakePhone(lines: []))
        let nested = try await tools.call(
            "run_flow", arguments: ["steps": [["run_flow": ["path": "/tmp/x.json"]]]], source: "test",
            screenshotByDefault: false)
        #expect(nested.isError)
        #expect(nested.text.contains("cannot run inside a flow"))
        let other = try await tools.call(
            "run_flow", arguments: ["steps": [["home": ["device": "other"]]]], source: "test", screenshotByDefault: false)
        #expect(other.isError)
        let unknown = try await tools.call(
            "run_flow", arguments: ["steps": ["fly"]], source: "test", screenshotByDefault: false)
        #expect(unknown.text.contains("Unknown tool: fly"))
    }

    @Test func runsAFlowFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-flow-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Flow(name: "Smoke", steps: [Flow.Step("home")]).encoded().write(to: file)
        let output = try await tools(FakePhone(lines: [])).call(
            "run_flow", arguments: ["path": .string(file.path)], source: "test", screenshotByDefault: false)
        #expect(output.text.hasPrefix("Flow \"Smoke\" passed: 1 steps"))
        let missing = try await tools(FakePhone(lines: [])).call(
            "run_flow", arguments: ["path": "/nonexistent/flow.json"], source: "test", screenshotByDefault: false)
        #expect(missing.isError)
    }

    @Test func recordsActionsAndSkipsLooks() async throws {
        let tools = tools(FakePhone(lines: []))
        tools.recorder.start()
        _ = try await tools.call("status", arguments: nil, source: "test", screenshotByDefault: false)
        _ = try await tools.call("tap", arguments: ["x": 10, "y": 20, "screenshot": true], source: "test", screenshotByDefault: false)
        _ = try await tools.call("tap", arguments: ["x": 9999, "y": 1], source: "test", screenshotByDefault: false)
        _ = try await tools.call("type_text", arguments: ["text": "he"], source: "test", screenshotByDefault: false)
        _ = try await tools.call("type_text", arguments: ["text": "llo", "submit": true], source: "test", screenshotByDefault: false)
        _ = try await tools.call("type_text", arguments: ["text": "!"], source: "test", screenshotByDefault: false)
        _ = try await tools.call("home", arguments: nil, source: "test", screenshotByDefault: false)
        #expect(tools.recorder.stepCount == 4)
        let steps = tools.recorder.stop()
        #expect(steps == [
            Flow.Step("tap", ["x": 10, "y": 20]),
            Flow.Step("type_text", ["text": "hello", "submit": true]),
            Flow.Step("type_text", ["text": "!"]),
            Flow.Step("home"),
        ])
        #expect(!tools.recorder.isRecording)
        _ = try await tools.call("home", arguments: nil, source: "test", screenshotByDefault: false)
        #expect(tools.recorder.stop().isEmpty)
    }

    @Test func clicksBecomeElementTapsWhenTheTreeNamesThem() async throws {
        func element(_ label: String, _ id: String, _ frame: CGRect, tappable: Bool = true) -> UIElement {
            UIElement(role: "Button", label: label, identifier: id, value: "", frame: frame, enabled: true, tappable: tappable)
        }
        let tree = [
            element("", "", CGRect(x: 0, y: 0, width: 1, height: 1)),
            element("Save", "save_button", CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1)),
            element("Row", "", CGRect(x: 0, y: 0.5, width: 1, height: 0.1)),
            element("Row", "", CGRect(x: 0, y: 0.6, width: 1, height: 0.1)),
            element("Cancel", "", CGRect(x: 0.5, y: 0.1, width: 0.3, height: 0.1)),
        ]
        #expect(FlowRecorder.element(at: NormalizedPoint(x: 0.2, y: 0.15), in: tree) == ["id": "save_button"])
        #expect(FlowRecorder.element(at: NormalizedPoint(x: 0.6, y: 0.15), in: tree) == ["text": "Cancel"])
        // Two rows share a label, and the background has neither: coordinates it is.
        #expect(FlowRecorder.element(at: NormalizedPoint(x: 0.5, y: 0.55), in: tree) == nil)
        #expect(FlowRecorder.element(at: NormalizedPoint(x: 0.5, y: 0.9), in: tree) == nil)

        let recorder = FlowRecorder()
        recorder.start { tree }
        for _ in 0..<100 where !recorder.hasTree { try await Task.sleep(nanoseconds: 20_000_000) }
        recorder.recordTap(at: NormalizedPoint(x: 0.2, y: 0.15), pixels: (10, 20))
        recorder.recordTap(at: NormalizedPoint(x: 0.5, y: 0.55), pixels: (30, 40))
        #expect(recorder.stop() == [
            Flow.Step("tap_element", ["id": "save_button"]), Flow.Step("tap", ["x": 30, "y": 40]),
        ])
        #expect(FlowRecorder.keyName(usage: 0x28) == "return")
        #expect(FlowRecorder.keyName(usage: 0x2A) == "backspace")
    }

    @Test func commandLineOptions() throws {
        let options = try FlowCommand.parse(["login.json", "--device", "Pixel", "--artifacts", "out", "--wait", "5"])
        #expect(options == FlowCommand.Options(file: "login.json", device: "Pixel", artifacts: "out", wait: 5))
        #expect(throws: (any Error).self) { try FlowCommand.parse([]) }
        #expect(throws: (any Error).self) { try FlowCommand.parse(["a.json", "b.json"]) }
        #expect(throws: (any Error).self) { try FlowCommand.parse(["a.json", "--device"]) }
        #expect(throws: (any Error).self) { try FlowCommand.parse(["a.json", "--wait", "soon"]) }
    }
}
