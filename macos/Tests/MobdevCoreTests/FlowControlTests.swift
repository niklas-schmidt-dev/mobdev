import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// An Android device for the platform condition: a fake phone that says what it is.
final class FakeAndroid: FakePhone, Device, @unchecked Sendable {
    let id = "emulator-5554"
    let name = "Pixel"
    var info: DeviceInfo? { nil }
    let kind = DeviceKind.android
    let activity = ActivityLog()
}

/// Control steps: if, repeat, retry, run, set, extract and optional, how they parse, write back,
/// run and report.
@Suite struct FlowControlTests {
    static func button(_ label: String, id: String = "", y: Double, value: String = "") -> UIElement {
        UIElement(
            role: "Button", label: label, identifier: id, value: value, frame: CGRect(x: 0.1, y: y, width: 0.8, height: 0.05),
            enabled: true, tappable: true)
    }

    /// Text recognition finds the given lines anywhere; nothing else.
    func tools(_ phone: FakePhone, text: [String] = []) -> PhoneTools {
        PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0) { _, query in
            text.filter { query == nil || $0.localizedCaseInsensitiveContains(query!) }.map {
                TextMatch(text: $0, box: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.03), confidence: 1, exact: $0 == query)
            }
        }
    }

    func flow(_ json: String) throws -> Flow { try Flow.parse(try JSONValue.parse(Data(json.utf8))) }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Parsing and writing

    @Test func parsesControlStepsAndWritesThemBack() throws {
        let parsed = try flow(
            """
            {"name": "Controls", "steps": [
              {"if": {"visible": {"text": "Allow"}, "then": [{"tap_element": {"text": "Allow"}}], "else": ["home"]}},
              {"if": {"not_visible": "Signed in", "then": []}},
              {"if": {"platform": "android", "then": [{"press_key": {"key": "escape"}}]}},
              {"repeat": {"times": 3, "steps": [{"scroll": {"direction": "down"}}]}},
              {"repeat": {"while_visible": {"id": "next"}, "max": 5, "steps": [{"tap_element": {"id": "next"}}]}},
              {"repeat": {"until_visible": {"text": "Done"}, "steps": ["home"]}},
              {"retry": {"times": 2, "steps": [{"tap_element": {"id": "reload"}}, {"wait_for_element": {"text": "Loaded"}}]}},
              {"run": "sign-in.json"},
              {"set": {"EMAIL": "me@example.com", "COUNT": 3}},
              {"extract": {"id": "total", "into": "TOTAL", "from": "label", "index": 1, "timeout": 2}},
              {"tap_element": {"text": "Not now"}, "optional": true},
              {"retry": {"steps": ["home"]}, "optional": true}
            ]}
            """)
        let steps = parsed.steps
        #expect(steps.count == 12)
        #expect(
            steps[0].control
                == .branch(
                    .visible(Flow.Target(text: "Allow")), then: [Flow.Step("tap_element", ["text": "Allow"])], else: [Flow.Step("home")]))
        #expect(steps[1].control == .branch(.notVisible(Flow.Target(text: "Signed in")), then: [], else: []))
        #expect(steps[2].control == .branch(.platform("android"), then: [Flow.Step("press_key", ["key": "escape"])], else: []))
        #expect(steps[3].control == .loop(.times(3), steps: [Flow.Step("scroll", ["direction": "down"])]))
        #expect(steps[4].control == .loop(.whileVisible(Flow.Target(id: "next"), max: 5), steps: [Flow.Step("tap_element", ["id": "next"])]))
        // until_visible without max stops after 20 rounds.
        #expect(steps[5].control == .loop(.untilVisible(Flow.Target(text: "Done"), max: 20), steps: [Flow.Step("home")]))
        #expect(steps[6].tool == "retry")
        #expect(steps[7].control == .subflow(path: "sign-in.json", flow: nil))
        #expect(steps[8].control == .set(["EMAIL": "me@example.com", "COUNT": "3"]))
        #expect(
            steps[9].control
                == .extract(Flow.Extraction(target: Flow.Target(id: "total"), into: "TOTAL", from: "label", index: 1, timeout: 2)))
        #expect(steps[10] == Flow.Step("tap_element", ["text": "Not now"], optional: true))
        #expect(steps[11].optional && steps[11].control == .retry(times: 1, steps: [Flow.Step("home")]))
        // Every step counts, nested ones too.
        #expect(parsed.stepCount == 12 + 2 + 1 + 1 + 1 + 1 + 2 + 1)

        // The file round-trips, with the steps inside a control step on lines of their own.
        let text = String(decoding: parsed.encoded(), as: UTF8.self)
        #expect(try Flow.parse(try JSONValue.parse(parsed.encoded()), name: "x") == parsed)
        #expect(
            text.contains(
                """
                    {"if":{"visible":{"text":"Allow"},"then":[
                      {"tap_element":{"text":"Allow"}}
                    ],"else":[
                      "home"
                    ]}},
                """))
        #expect(text.contains("\n    {\"repeat\":{\"times\":3,\"steps\":[\n      {\"scroll\":{\"direction\":\"down\"}}\n    ]}},\n"))
        #expect(text.contains("\n    {\"repeat\":{\"while_visible\":{\"id\":\"next\"},\"max\":5,\"steps\":[\n"))
        #expect(text.contains("\n    {\"run\":\"sign-in.json\"},\n"))
        #expect(text.contains("\n    {\"tap_element\":{\"text\":\"Not now\"},\"optional\":true},\n"))
        #expect(text.contains("\n    {\"retry\":{\"times\":1,\"steps\":[\n      \"home\"\n    ]},\"optional\":true}\n"))

        // One-line summaries for results.
        #expect(steps.map(\.summary) == [
            "if visible {\"text\":\"Allow\"}", "if not visible {\"text\":\"Signed in\"}", "if platform android",
            "repeat 3 times", "repeat while visible {\"id\":\"next\"}, at most 5 times",
            "repeat until visible {\"text\":\"Done\"}, at most 20 times", "retry up to 2 times", "run sign-in.json",
            "set {\"COUNT\":\"3\",\"EMAIL\":\"me@example.com\"}", "extract {\"id\":\"total\"} into TOTAL",
            "tap_element {\"text\":\"Not now\"} (optional)", "retry up to 1 times (optional)",
        ])
    }

    @Test func mistakesSayWhichStep() throws {
        func message(_ json: String) -> String {
            do {
                _ = try flow(json)
                return "parsed"
            } catch {
                return String(describing: error)
            }
        }
        #expect(message(#"["home", {"repeat": {"times": 2, "steps": ["home", {"tap": 1}]}}]"#)
            == "Step 2.2: the arguments of tap must be an object.")
        #expect(message(#"[{"if": {"visible": {"text": "A"}, "then": ["home"], "else": ["home", {"tap": 1}]}}]"#)
            == "Step 1.3: the arguments of tap must be an object.")
        #expect(message(#"[{"repeat": {"times": 2}}]"#).hasPrefix("Step 1: repeat: steps must be a list"))
        #expect(message(#"[{"repeat": {"times": 2, "steps": []}}]"#).hasPrefix("Step 1: repeat: steps needs at least one step"))
        #expect(message(#"[{"repeat": {"times": 0, "steps": ["home"]}}]"#).contains("times must be a whole number from 1 to 100"))
        #expect(message(#"[{"repeat": {"times": 2, "max": 3, "steps": ["home"]}}]"#).contains("max goes with while_visible"))
        #expect(message(#"[{"repeat": {"while_visible": {"id": "a"}, "max": 500, "steps": ["home"]}}]"#).contains("from 1 to 100"))
        #expect(message(#"[{"repeat": {"tims": 2, "steps": ["home"]}}]"#).contains("unknown key \"tims\""))
        #expect(message(#"[{"retry": {"times": 11, "steps": ["home"]}}]"#).contains("from 1 to 10"))
        #expect(message(#"[{"if": {"then": ["home"]}}]"#).contains("one of visible, not_visible and platform"))
        #expect(message(#"[{"if": {"visible": {"id": "a", "text": "b"}, "then": []}}]"#).contains("needs an id or a text"))
        #expect(message(#"[{"if": {"platform": "web", "then": []}}]"#).contains("platform must be"))
        #expect(message(#"[{"if": {"visible": "A"}}]"#).contains("if needs then"))
        #expect(message(#"[{"set": {"my name": "x"}}]"#).contains("is not a variable name"))
        #expect(message(#"[{"set": {}}]"#).contains("set takes variables"))
        #expect(message(#"[{"extract": {"id": "a"}}]"#).contains("extract needs into"))
        #expect(message(#"[{"extract": {"id": "a", "into": "A", "from": "text"}}]"#).contains("from must be"))
        #expect(message(#"[{"run": ""}]"#).contains("run takes the path"))
        #expect(message(#"["repeat"]"#).contains("Step 1: repeat needs its settings"))
        #expect(message(#"[{"home": null, "optional": "yes"}]"#).contains("optional must be true or false"))
        #expect(message(#"[{"optional": true}]"#).contains("must be a tool name"))
        #expect(message(#"[{"home": null, "tap": {}}]"#).contains("must be a tool name"))
    }

    @Test func noToolIsNamedLikeAControlStep() {
        let names = Set(PhoneTools.definitions.map(\.name) + DeviceTools.definitions.map(\.name))
        #expect(names.isDisjoint(with: Flow.controlKeys))
        #expect(!names.contains("optional"))
    }

    @Test func stepsInsideControlStepsCountAgainstTheLimit() throws {
        let inner = Array(repeating: JSONValue.string("home"), count: 300)
        let big: JSONValue = [["repeat": ["times": 2, "steps": .array(inner)]], ["retry": ["steps": .array(inner)]]]
        #expect(throws: (any Error).self) { try Flow.parse(big) }
        do {
            _ = try Flow.parse(big)
        } catch {
            #expect(String(describing: error).contains("at most 500 steps, counting those inside"))
        }
        #expect(try Flow.parse([["repeat": ["times": 2, "steps": .array(inner)]]]).stepCount == 301)
    }

    // MARK: Running

    @Test func ifRunsThenOrElseByWhatIsOnScreen() async throws {
        let phone = FakePhone(lines: [], tree: [Self.button("Allow", y: 0.5)])
        let tools = tools(phone)
        let flow = try flow(
            """
            [{"if": {"visible": {"text": "Allow"}, "then": [{"tap_element": {"text": "Allow"}}], "else": ["home"]}},
             {"if": {"not_visible": {"id": "consent"}, "then": [{"type_text": {"text": "x"}}]}},
             {"if": {"visible": {"text": "Nope"}, "then": ["home"]}},
             {"if": {"platform": "android", "then": ["home"], "else": [{"press_key": {"key": "tab"}}]}}]
            """)
        let result = await tools.run(flow, source: "test")
        #expect(result.passed, "\(result.text)")
        #expect(result.steps.map(\.number) == ["1", "1.1", "2", "2.1", "3", "4", "4.2"])
        #expect(result.steps[0].text == "\"Allow\" is visible, so the then steps ran.")
        #expect(result.steps[4].text == "\"Nope\" is not visible; nothing to do.")
        #expect(result.steps[5].text == "The device runs iOS, so the else steps ran.")
        // Allow tapped, x typed, tab pressed; home never.
        let events = phone.events.get()
        #expect(events.count == 3)
        #expect(!events.contains(.button(.home)))
        #expect(result.text.contains("\n✓ 1. if visible {\"text\":\"Allow\"}: \"Allow\" is visible, so the then steps ran.\n  ✓ 1.1. tap_element {\"text\":\"Allow\"}: Tapped Button \"Allow\""))

        // An element off screen is not visible.
        let below = FakePhone(lines: [], tree: [UIElement(
            role: "Button", label: "Allow", identifier: "", value: "", frame: CGRect(x: 0.1, y: 1.4, width: 0.8, height: 0.05),
            enabled: true, tappable: true)])
        #expect(try await self.tools(below).isVisible(Flow.Target(text: "Allow"), variables: Variables()) == false)

        // On Android, the then steps.
        let android = FakeAndroid(lines: [], tree: [])
        let onAndroid = await self.tools(android).run(
            try self.flow(#"[{"if": {"platform": "android", "then": ["home"], "else": [{"press_key": {"key": "tab"}}]}}]"#),
            source: "test")
        #expect(onAndroid.steps.map(\.number) == ["1", "1.1"])
        #expect(android.events.get() == [.button(.home)])
    }

    @Test func withoutATreeTextIsReadFromTheScreenAndIdsFail() async throws {
        let phone = FakePhone(lines: [])
        let tools = tools(phone, text: ["Welcome back"])
        let result = await tools.run(
            try flow(#"[{"if": {"visible": "Welcome", "then": ["home"]}}, {"if": {"visible": {"id": "x"}, "then": ["home"]}}]"#),
            source: "test")
        #expect(!result.passed)
        #expect(result.steps.map(\.number) == ["1", "1.1", "2"])
        #expect(result.steps[2].text.contains("no UI tree"))
        #expect(result.failedNumber == "2")
    }

    @Test func repeatRunsTimesWhileAndUntilWithACap() async throws {
        // Three pages: "Next" goes until the last, which says "Done".
        let phone = FakePhone(lines: [], tree: [Self.button("Next", id: "next", y: 0.8)])
        let pages = Locked(0)
        phone.onTap.set { _ in
            let page = pages.withLock { count -> Int in
                count += 1
                return count
            }
            phone.currentTree.set(page >= 3 ? [Self.button("Done", y: 0.5)] : [Self.button("Next", id: "next", y: 0.8)])
        }
        let tools = tools(phone)
        let result = await tools.run(
            try flow(
                """
                [{"repeat": {"times": 2, "steps": [{"scroll": {"direction": "down"}}]}},
                 {"repeat": {"while_visible": {"id": "next"}, "steps": [{"tap_element": {"id": "next"}}]}},
                 {"repeat": {"until_visible": {"text": "Done"}, "steps": ["home"]}},
                 {"repeat": {"until_visible": {"text": "Never"}, "max": 3, "steps": [{"press_key": {"key": "tab"}}]}}]
                """), source: "test")
        #expect(result.passed, "\(result.text)")
        #expect(result.steps.map(\.number) == ["1", "1.1", "1.1", "2", "2.1", "2.1", "2.1", "3", "4", "4.1", "4.1", "4.1"])
        #expect(result.steps.map(\.round) == [nil, nil, "round 2", nil, nil, "round 2", "round 3", nil, nil, nil, "round 2", "round 3"])
        #expect(result.steps[0].text == "Ran 2 times.")
        #expect(result.steps[3].text == "Ran 3 times, until id \"next\" was not visible.")
        #expect(result.steps[7].text == "Ran 0 times, until \"Done\" was visible.")
        #expect(result.steps[8].text == "Stopped after 3 rounds, the most it may run; \"Never\" is still not visible.")
        #expect(result.text.contains("\n  ✓ 1.1. scroll {\"direction\":\"down\"} (round 2): Scrolled down by 5."))
        #expect(result.markdown.contains("| ✅ | 1.1. `scroll {\"direction\":\"down\"}` (round 2) |"))

        // A failure inside a round stops the flow and says where.
        let failing = await tools.run(
            try flow(#"[{"repeat": {"times": 3, "steps": [{"tap": {"x": 10, "y": 10}}, {"tap": {"x": 99999, "y": 1}}]}}]"#),
            source: "test")
        #expect(!failing.passed)
        #expect(failing.failedNumber == "1.2")
        #expect(failing.steps.map(\.number) == ["1", "1.1", "1.2"])
        #expect(failing.steps[0].text == "Step 1.2 failed in round 1.")
        #expect(failing.text.hasPrefix("Flow \"Flow\" failed at step 1.2 of 1: tap {\"x\":99999,\"y\":1}."))
        #expect(failing.json["failed_step"] == 1)
        #expect(failing.json["failed_at"] == "1.2")
    }

    @Test func retryRunsTheBlockAgainUntilItPasses() async throws {
        // "Loaded" appears after the second tap on reload.
        let phone = FakePhone(lines: [], tree: [Self.button("Reload", id: "reload", y: 0.2)])
        let taps = Locked(0)
        phone.onTap.set { _ in
            if taps.withLock({ count -> Int in
                count += 1
                return count
            }) >= 2 {
                phone.currentTree.set([Self.button("Reload", id: "reload", y: 0.2), Self.button("Loaded", y: 0.5)])
            }
        }
        let tools = tools(phone)
        let flow = try flow(
            #"[{"retry": {"times": 2, "steps": [{"tap_element": {"id": "reload"}}, {"wait_for_element": {"text": "Loaded", "timeout": 0}}]}}, "home"]"#)
        let result = await tools.run(flow, source: "test")
        #expect(result.passed, "\(result.text)")
        #expect(result.steps.map(\.number) == ["1", "1.1", "1.2", "1.1", "1.2", "2"])
        #expect(result.steps.map(\.round) == [nil, nil, nil, "attempt 2", "attempt 2", nil])
        #expect(result.steps[0].text == "Passed on attempt 2.")
        #expect(!result.steps[2].passed && result.steps[2].tolerated)
        #expect(result.text.contains("\n  – 1.2. wait_for_element {\"text\":\"Loaded\",\"timeout\":0}: Timed out"))

        // Out of attempts, the flow fails at the last one.
        let never = FakePhone(lines: [], tree: [Self.button("Reload", id: "reload", y: 0.2)])
        let failed = await self.tools(never).run(flow, source: "test")
        #expect(!failed.passed)
        #expect(failed.steps.count == 7)
        #expect(failed.steps[0].text == "Failed 3 times; the last time at step 1.2.")
        #expect(failed.failure?.result.round == "attempt 3")
        #expect(failed.text.hasPrefix("Flow \"Flow\" failed at step 1.2 of 2: wait_for_element {\"text\":\"Loaded\",\"timeout\":0} (attempt 3)."))
    }

    @Test func optionalStepsFailWithoutStoppingTheFlow() async throws {
        let phone = FakePhone(lines: [], tree: [])
        let result = await tools(phone).run(
            try flow(
                #"[{"tap_element": {"text": "Not now", "timeout": 0}, "optional": true}, {"if": {"platform": "ios", "then": [{"tap": {"x": 99999, "y": 0}}]}, "optional": true}, "home"]"#),
            source: "test")
        #expect(result.passed, "\(result.text)")
        #expect(result.steps.map(\.mark) == ["–", "–", "–", "✓"])
        #expect(result.steps[0].text.hasPrefix("Failed, and the flow goes on since the step is optional: No element with label \"Not now\""))
        #expect(phone.events.get() == [.button(.home)])
        #expect(result.markdown.contains("| ➖ | 1. `tap_element {\"text\":\"Not now\",\"timeout\":0} (optional)`"))
    }

    @Test func setAndExtractFillLaterStepsAndSecretsStayOut() async throws {
        let phone = FakePhone(lines: [], tree: [
            Self.button("Total", id: "total", y: 0.3, value: "12.00"), Self.button("Code", id: "code", y: 0.4),
        ])
        let tools = tools(phone)
        let flow = try flow(
            """
            [{"set": {"GREETING": "Hi ${NAME}", "PASSWORD": "${SECRET}"}},
             {"extract": {"id": "total", "into": "TOTAL"}},
             {"extract": {"id": "total", "into": "LABEL", "from": "label"}},
             {"type_text": {"text": "${GREETING}: ${TOTAL} (${LABEL}) ${PASSWORD}"}}]
            """)
        let variables = Variables(values: ["NAME": "Ada", "SECRET": "hunter2"], secrets: ["SECRET"])
        let result = await tools.run(flow, variables: variables, source: "test")
        #expect(result.passed, "\(result.text)")
        #expect(result.steps[0].text == "GREETING is \"Hi Ada\", PASSWORD is \"${SECRET}\".")
        #expect(result.steps[1].text == "TOTAL is \"12.00\", from the value of Button \"Total\".")
        #expect(result.steps[2].text == "LABEL is \"Total\", from the label of Button \"Total\".")
        #expect(result.steps[3].step.summary.contains("${GREETING}"))
        #expect(!result.text.contains("hunter2"))
        let typed = phone.events.get().compactMap { event -> [KeyStroke]? in
            if case .type(let strokes) = event { return strokes }
            return nil
        }
        #expect(typed.count == 1)
        #expect(typed[0] == (try KeyboardLayout.us.strokes(typing: "Hi Ada: 12.00 (Total) hunter2")))

        // A name used but never set fails before anything runs, at the step that uses it.
        let unset = await tools.run(try self.flow(#"["home", {"repeat": {"times": 2, "steps": [{"type_text": {"text": "${NOPE}"}}]}}]"#), source: "test")
        #expect(!unset.passed)
        #expect(unset.steps.count == 1)
        #expect(unset.steps[0].number == "2")
        #expect(unset.steps[0].text.hasPrefix("Variable NOPE is not set. Set it with a set or extract step"))
        #expect(phone.events.get().count == 1)
        // Set anywhere in the flow is enough for the check; the run says when it was too late.
        let late = await tools.run(try self.flow(#"[{"type_text": {"text": "${LATER}"}}, {"set": {"LATER": "x"}}]"#), source: "test")
        #expect(late.steps.map(\.number) == ["1"])
        #expect(late.steps[0].text.hasPrefix("Variable LATER is not set."))

        // extract waits like tap_element, and says what is ambiguous.
        let none = await tools.run(try self.flow(#"[{"extract": {"text": "Missing", "into": "X", "timeout": 0}}]"#), source: "test")
        #expect(none.steps[0].text.hasPrefix("No element with label \"Missing\" to extract from."))
        let two = FakePhone(lines: [], tree: [Self.button("Row", y: 0.1), Self.button("Row", y: 0.2)])
        let ambiguous = await self.tools(two).run(try self.flow(#"[{"extract": {"text": "Row", "into": "X"}}]"#), source: "test")
        #expect(ambiguous.steps[0].text.hasPrefix("2 elements match. Pass index:"))
    }

    @Test func subflowsLoadRelativeToTheirFileAndReportNested() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("common"), withIntermediateDirectories: true)
        try Data(#"{"name": "Sign in", "steps": [{"run": "type.json"}, "home"]}"#.utf8)
            .write(to: root.appendingPathComponent("common/sign-in.json"))
        try Data(#"[{"type_text": {"text": "${WHO}"}}, {"install_app": {"path": "build/App.app"}}]"#.utf8)
            .write(to: root.appendingPathComponent("common/type.json"))
        try Data(#"[{"set": {"WHO": "me"}}, {"run": "common/sign-in.json"}, {"press_key": {"key": "tab"}}]"#.utf8)
            .write(to: root.appendingPathComponent("main.json"))

        let flow = try Flow.load(root.appendingPathComponent("main.json"))
        #expect(flow.stepCount == 7)
        guard case .subflow("common/sign-in.json", let signIn?)? = flow.steps[1].control,
            case .subflow("type.json", let typing?)? = signIn.steps[0].control
        else {
            Issue.record("subflows not loaded: \(flow.steps)")
            return
        }
        #expect(signIn.name == "Sign in")
        // A subflow's build is next to the subflow.
        #expect(typing.steps[1].arguments["path"] == .string(root.appendingPathComponent("common/build/App.app").path))
        // Written back, a subflow is its path again.
        #expect(String(decoding: flow.encoded(), as: UTF8.self).contains("{\"run\":\"common/sign-in.json\"}"))

        let phone = FakePhone(lines: [])
        let output = try await tools(phone).call(
            "run_flow", arguments: ["path": .string(root.appendingPathComponent("main.json").path)], source: "test",
            screenshotByDefault: false)
        // install_app fails on a fake without apps, at 2.1.2.
        #expect(output.isError)
        #expect(output.text.hasPrefix("Flow \"main\" failed at step 2.1.2 of 3: install_app"))
        #expect(output.text.contains("\n✗ 2. run common/sign-in.json: Step 2.1.2 of \"Sign in\" failed."))
        #expect(output.text.contains("\n    ✓ 2.1.1. type_text {\"text\":\"${WHO}\"}: Typed 2 characters."))
        #expect(output.data?["failed_at"] == "2.1.2")

        // Missing files, loops and depth are errors before anything runs.
        try Data(#"[{"run": "missing.json"}]"#.utf8).write(to: root.appendingPathComponent("missing-ref.json"))
        #expect(throws: (any Error).self) { try Flow.load(root.appendingPathComponent("missing-ref.json")) }
        try Data(#"[{"run": "b.json"}]"#.utf8).write(to: root.appendingPathComponent("a.json"))
        try Data(#"["home", {"repeat": {"times": 2, "steps": [{"run": "a.json"}]}}]"#.utf8).write(to: root.appendingPathComponent("b.json"))
        do {
            _ = try Flow.load(root.appendingPathComponent("a.json"))
            Issue.record("a loop loaded")
        } catch {
            #expect(String(describing: error) == "Step 1.2.1: a.json runs itself in a loop: a.json → b.json → a.json.")
        }
        for level in 0..<7 {
            try Data("[{\"run\": \"level\(level + 1).json\"}]".utf8).write(to: root.appendingPathComponent("level\(level).json"))
        }
        try Data("[\"home\"]".utf8).write(to: root.appendingPathComponent("level7.json"))
        do {
            _ = try Flow.load(root.appendingPathComponent("level0.json"))
            Issue.record("too deep loaded")
        } catch {
            #expect(String(describing: error).contains("at most 5 deep"))
        }
        // Inline steps need absolute paths.
        let inline = try await tools(phone).call(
            "run_flow", arguments: ["steps": [["run": "main.json"]]], source: "test", screenshotByDefault: false)
        #expect(inline.text.contains("needs an absolute path"))
        let absolute = try await tools(phone).call(
            "run_flow", arguments: ["steps": [["run": .string(root.appendingPathComponent("level7.json").path)]]],
            source: "test", screenshotByDefault: false)
        #expect(!absolute.isError, "\(absolute.text)")
    }

    @Test func aRunStopsAtItsStepCapAndOnCancellation() async throws {
        let phone = FakePhone(lines: [])
        let tools = tools(phone)
        // 100 rounds of 10 repeats of 3 steps would be 3000; the run stops at 2000.
        let flow = try flow(
            #"[{"repeat": {"times": 100, "steps": [{"repeat": {"times": 10, "steps": [{"press_key": {"key": "tab"}}, {"press_key": {"key": "tab"}}]}}]}}]"#)
        let capped = await tools.run(flow, source: "test")
        #expect(!capped.passed)
        #expect(capped.failure?.result.text.hasPrefix("The flow ran 2000 steps, the most one run may take.") == true)
        #expect(phone.events.get().count < 2000)

        let slow = try self.flow(#"[{"repeat": {"times": 100, "steps": [{"wait_for_element": {"text": "Never", "timeout": 60}}]}}]"#)
        let waiting = FakePhone(lines: [], tree: [])
        let task = Task { await self.tools(waiting).run(slow, source: "test") }
        try await Task.sleep(nanoseconds: 300_000_000)
        let started = Date()
        task.cancel()
        let result = await task.value
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(!result.passed)
        #expect(result.failure?.result.text == "Cancelled.")
        #expect(result.steps.count == 2)
    }

    @Test func testsNumberNestedStepsAndKeepSecretsOut() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tests"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("flows"), withIntermediateDirectories: true)
        try Data(#"{"before_each": [{"run": "flows/start.json"}], "secrets": ["PASSWORD"]}"#.utf8)
            .write(to: root.appendingPathComponent("mobdev.json"))
        try Data(#"["home"]"#.utf8).write(to: root.appendingPathComponent("flows/start.json"))
        try Data(#"[{"type_text": {"text": "${PASSWORD}"}}]"#.utf8).write(to: root.appendingPathComponent("flows/password.json"))
        try Data(
            #"{"name": "Nested", "steps": [{"run": "flows/password.json"}, {"repeat": {"times": 2, "steps": [{"tap": {"x": 1, "y": 1}}]}}, {"if": {"platform": "ios", "then": [{"tap": {"x": 99999, "y": 1}}]}}]}"#.utf8
        ).write(to: root.appendingPathComponent("tests/nested.json"))
        let project = try TestProject.load(root)
        #expect(project.beforeEach.first?.children == [Flow.Step("home")])
        let phone = FakePhone(lines: [])
        let result = await tools(phone).runTests(
            project, options: TestRunOptions(output: root.appendingPathComponent("out"), variables: ["PASSWORD": "hunter2"], video: false),
            source: "test")
        let test = try #require(result.tests.first)
        #expect(test.status == .failed)
        #expect(test.steps.map { $0.number ?? "" } == ["1", "1.1", "2", "2.1", "3", "3.1", "3.1", "4", "4.1"])
        #expect(test.steps[6].round == "round 2")
        #expect(test.failedStep == 4)
        #expect(test.message.hasPrefix("step 4.1 of 4, tap {\"x\":99999,\"y\":1}: (99999, 1) is outside the screenshot"))
        #expect(test.stepLines[1] == "  ✓ 1.1. home: Went to the home screen.")
        #expect(test.stepLines[6].hasPrefix("  ✓ 3.1. tap {\"x\":1,\"y\":1} (round 2): Tapped"))
        let saved = try String(contentsOf: root.appendingPathComponent("out/results.json"), encoding: .utf8)
        #expect(!saved.contains("hunter2"))
        #expect(saved.contains("\"number\" : \"3.1\""))
        #expect(try TestRunResult.load(root.appendingPathComponent("out")).tests == result.tests)
        // Results written before steps had numbers still load.
        let old = #"{"summary": "home", "text": "Went home.", "passed": true, "seconds": 0.1}"#
        let step = try JSONDecoder().decode(TestRunResult.Step.self, from: Data(old.utf8))
        #expect(step.number == nil)
        #expect(step.line(3) == "✓ 3. home: Went home.")
    }

    // MARK: Tool additions for Maestro flows

    @Test func tapsTakePercentagesDoubleTapsAndHolds() async throws {
        let phone = FakePhone(lines: [], tree: [Self.button("Photo", id: "photo", y: 0.5)])
        let tools = tools(phone, text: ["Photo"])
        func call(_ name: String, _ arguments: JSONValue) async throws -> ToolOutput {
            try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
        }
        let center = try await call("tap", ["x": "50%", "y": "25%"])
        #expect(center.text == "Tapped (295, 320).")
        #expect(phone.events.get().last == .tap(NormalizedPoint(x: 0.5, y: 0.25), 0.08))
        #expect(try await call("tap", ["x": "150%", "y": "1"]).text.contains("from 0% to 100%"))
        let double = try await call("tap", ["x": 10, "y": 10, "double": true])
        #expect(double.text.hasPrefix("Double-tapped"))
        let element = try await call("tap_element", ["id": "photo", "double": true])
        #expect(element.text.hasPrefix("Double-tapped Button \"Photo\""))
        let held = try await call("tap_element", ["id": "photo", "hold": 2])
        #expect(held.text.hasPrefix("Pressed Button \"Photo\""))
        #expect(phone.events.get().last == .tap(Self.button("Photo", y: 0.5).center, 2))
        let text = try await call("tap_text", ["text": "Photo", "hold": 1.5])
        #expect(text.text.hasPrefix("Pressed \"Photo\""))
        let swipe = try await call("swipe", ["from_x": "90%", "from_y": "50%", "to_x": "10%", "to_y": "50%"])
        #expect(!swipe.isError, "\(swipe.text)")
        #expect(phone.events.get().last == .swipe(NormalizedPoint(x: 0.9, y: 0.5), NormalizedPoint(x: 0.1, y: 0.5)))

        let before = phone.events.get().count
        let erase = try await call("press_key", ["key": "backspace", "count": 3])
        #expect(erase.text == "Pressed backspace 3 times.")
        #expect(phone.events.get().count == before + 3)
        let volume = try await call("press_key", ["key": "volume_up"])
        #expect(volume.text == "Pressed volume_up.")
        #expect(phone.events.get().last == .button(.volumeUp))
        #expect(try await call("press_key", ["key": "tab", "count": 101]).isError)
    }
}
