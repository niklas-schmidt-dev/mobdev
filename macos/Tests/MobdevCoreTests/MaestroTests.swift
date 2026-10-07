import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// The YAML subset, Maestro flows in and out, and where they run: run_flow, Mobdev flow, tests.
@Suite struct MaestroTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-maestro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func error(_ work: () throws -> Any) -> String {
        do {
            _ = try work()
            return "no error"
        } catch {
            return String(describing: error)
        }
    }

    // MARK: YAML

    @Test func parsesTheYAMLMaestroFlowsUse() throws {
        let text = """
            # A comment, and a config.
            appId: com.example.app   # after a value
            name: "Sign in: the \\"real\\" one"
            tags: [smoke, 'it''s', {a: b}]
            ---
            - launchApp
            - tapOn: Sign in # comment
            - tapOn:
                id: email
                index: 0
            - inputText: it's # an apostrophe is text
            - swipe: {start: "90%, 50%", end: [10, 20],
                      duration: 400}
            - runFlow:
                commands:
                - tapOn: A
                -   back
            - evalScript: |
                output.x = 1
                # not a comment

                more
            - folded: >-
                one
                two

                three
            - url: https://example.com/a#b
            - list:
              - - nested
            """
        let documents = try YAML.documents(text)
        #expect(documents.count == 2)
        let config = try #require(documents[0])
        #expect(config["appId"]?.string == "com.example.app")
        #expect(config["appId"]?.line == 2)
        #expect(config["name"]?.string == "Sign in: the \"real\" one")
        #expect(config["tags"]?.items?.map { $0.string ?? "map" } == ["smoke", "it's", "map"])
        #expect(config["tags"]?.items?[2]["a"]?.string == "b")

        let commands = try #require(documents[1]?.items)
        #expect(commands.count == 10)
        #expect(commands[0].string == "launchApp")
        #expect(commands[0].line == 6)
        #expect(commands[1]["tapOn"]?.string == "Sign in")
        #expect(commands[2]["tapOn"]?["id"]?.string == "email")
        #expect(commands[2]["tapOn"]?["index"]?.number == 0)
        #expect(commands[3]["inputText"]?.string == "it's")
        let swipe = try #require(commands[4]["swipe"])
        #expect(swipe["start"]?.string == "90%, 50%")
        #expect(swipe["end"]?.items?.compactMap(\.number) == [10, 20])
        #expect(swipe["duration"]?.number == 400)
        let runFlow = try #require(commands[5]["runFlow"]?["commands"]?.items)
        #expect(runFlow.count == 2)
        #expect(runFlow[0]["tapOn"]?.string == "A")
        #expect(runFlow[1].string == "back")
        #expect(runFlow[1].line == 17)
        #expect(commands[6]["evalScript"]?.string == "output.x = 1\n# not a comment\n\nmore\n")
        #expect(commands[7]["folded"]?.string == "one two\nthree")
        #expect(commands[8]["url"]?.string == "https://example.com/a#b")
        #expect(commands[9]["list"]?.items?.first?.items?.first?.string == "nested")
        #expect(commands[9].line == 29)

        // Scalars stay text: whoever reads them decides.
        let scalars = try #require(try YAML.documents("a: NO\nb: 1.10\nc: true\nd: ~\ne: 'true'\nf:\n").first!)
        #expect(scalars["a"]?.string == "NO")
        #expect(scalars["a"]?.bool == nil)
        #expect(scalars["b"]?.string == "1.10")
        #expect(scalars["c"]?.bool == true)
        #expect(scalars["d"]?.isNull == true)
        #expect(scalars["e"]?.bool == nil)
        #expect(scalars["f"]?.isNull == true)
        #expect(try YAML.documents("\"\\u00e9\\t\\n\"").first??.string == "é\t\n")

        // A file that starts with --- has only its commands.
        #expect(try YAML.documents("---\n- back\n").count == 1)
        #expect(try YAML.documents("# only a comment\n").first! == nil)
    }

    @Test func yamlMistakesSayTheLine() {
        #expect(error { try YAML.documents("a:\n\tb: 1") } == "line 2: indent with spaces, not tabs.")
        #expect(error { try YAML.documents("- \"open") }.hasPrefix("line 1: the string's closing \" is missing"))
        #expect(error { try YAML.documents("a: &anchor x") } == "line 1: anchors, aliases and tags (&) are not supported.")
        #expect(error { try YAML.documents("a: [1, 2") } == "line 1: [ is not closed.")
        #expect(error { try YAML.documents("a: 1\na: 2") } == "line 2: a appears twice.")
        #expect(error { try YAML.documents("a: one\n  two") } == "line 2: a value that goes on over several lines needs quotes or |.")
        #expect(error { try YAML.documents("- a\n    - b") }.hasPrefix("line 2:"))
        #expect(error { try YAML.documents("--- - a") } == "line 1: put the document on the line after ---.")
        #expect(error { try YAML.documents("a: \"\\q\"") } == "line 1: unknown escape \\q in a double-quoted string.")
    }

    @Test func writesYAMLThatReadsBack() throws {
        let value = YAML.Out.list([
            .plain("back"),
            .map([("tapOn", .string("Say \"hi\"\n\\o/"))]),
            .map([("runFlow", .map([("when", .map([("visible", .string("A"))])), ("commands", .list([.plain("scroll"), .map([("eraseText", .number(5))])]))]))]),
            .map([("swipe", .map([("duration", .number(0.25)), ("x", .bool(true)), ("empty", .list([]))]))]),
        ])
        let text = YAML.emit(value).joined(separator: "\n")
        #expect(
            text == """
                - back
                - tapOn: "Say \\"hi\\"\\n\\\\o/"
                - runFlow:
                    when:
                      visible: "A"
                    commands:
                      - scroll
                      - eraseText: 5
                - swipe:
                    duration: 0.25
                    x: true
                    empty: []
                """)
        let read = try #require(try YAML.documents(text).first!?.items)
        #expect(read[1]["tapOn"]?.string == "Say \"hi\"\n\\o/")
        #expect(read[2]["runFlow"]?["commands"]?.items?[1]["eraseText"]?.number == 5)
    }

    // MARK: Maestro to Mobdev

    static let signIn = """
        # Sign in and check the welcome screen.
        appId: com.example.app
        name: Sign in
        tags:
          - smoke
        env:
          EMAIL: me@example.com
        ---
        - launchApp:
            clearState: true
            permissions:
              notifications: allow
        - tapOn: "Sign in"
        - tapOn:
            id: "email"
        - inputText: ${EMAIL}
        - tapOn: {id: password}
        - inputText: 'it''s secret'
        - pressKey: Enter
        - assertVisible: "Welcome.*"
        - runFlow:
            when:
              visible: "Allow notifications"
            commands:
              - tapOn: Allow
        - scrollUntilVisible:
            element:
              text: "Settings"
            direction: DOWN
            timeout: 20000
        - swipe:
            direction: LEFT
        - swipe:
            start: 90%, 50%
            end: 10%, 50%
            duration: 500
        - tapOn:
            point: "50%,90%"
        - doubleTapOn: Photo
        - longPressOn:
            id: photo
        - eraseText: 5
        - back
        - hideKeyboard
        - takeScreenshot: home
        - waitForAnimationToEnd
        - extendedWaitUntil:
            notVisible: "Loading"
            timeout: 15000
        - repeat:
            times: 3
            commands:
            - scroll
        - repeat:
            while:
              visible: Next
            commands:
              - tapOn: Next
        - retry:
            maxRetries: 2
            commands:
              - tapOn: Reload
              - assertVisible: Loaded
        - copyTextFrom:
            id: code
        - pasteText
        - openLink: https://example.com/path?a=1#frag
        - setLocation:
            latitude: 52.52
            longitude: "13.405"
        - runFlow: subflows/logout.yaml
        - stopApp
        - killApp: com.other.app
        - clearState
        - tapOn:
            text: "Not now"
            optional: true
        - assertNotVisible:
            id: spinner
        - pressKey: Home
        - pressKey: Volume Up
        - setOrientation: LANDSCAPE_LEFT
        - travel:
            points:
              - "52.52, 13.405"
              - "52.53, 13.41"
            speed: 36
        - runFlow:
            when:
              platform: Android
            env:
              WHO: robot
            commands:
              - inputText: ${WHO} copied ${maestro.copiedText}
        """

    @Test func convertsARealisticMaestroFlow() throws {
        let flow = try Maestro.flow(from: Self.signIn, file: URL(fileURLWithPath: "/tmp/sign-in.yaml"))
        #expect(flow.name == "Sign in")
        let expected: [Flow.Step] = [
            Flow.Step(.set(["EMAIL": "me@example.com"])),
            Flow.Step("reset_app", ["bundle_id": "com.example.app"]),
            Flow.Step("set_permission", ["bundle_id": "com.example.app", "permission": "notifications", "state": "grant"]),
            Flow.Step("launch_app", ["bundle_id": "com.example.app"]),
            Flow.Step("tap_element", ["text": "Sign in"]),
            Flow.Step("tap_element", ["id": "email"]),
            Flow.Step("type_text", ["text": "${EMAIL}"]),
            Flow.Step("tap_element", ["id": "password"]),
            Flow.Step("type_text", ["text": "it's secret"]),
            Flow.Step("press_key", ["key": "enter"]),
            Flow.Step("wait_for_element", ["text": "Welcome", "timeout": 7]),
            Flow.Step(.branch(.visible(Flow.Target(text: "Allow notifications")), then: [Flow.Step("tap_element", ["text": "Allow"])], else: [])),
            Flow.Step("scroll_until_visible", ["text": "Settings", "direction": "down", "max_scrolls": 10]),
            Flow.Step("swipe", ["from_x": "90%", "from_y": "50%", "to_x": "10%", "to_y": "50%"]),
            Flow.Step("swipe", ["from_x": "90%", "from_y": "50%", "to_x": "10%", "to_y": "50%", "duration": 0.5]),
            Flow.Step("tap", ["x": "50%", "y": "90%"]),
            Flow.Step("tap_element", ["text": "Photo", "double": true]),
            Flow.Step("tap_element", ["id": "photo", "hold": 1]),
            Flow.Step("press_key", ["key": "backspace", "count": 5]),
            Maestro.back,
            Flow.Step("wait_for_idle"),
            Flow.Step("wait_for_element", ["text": "Loading", "timeout": 15, "gone": true]),
            Flow.Step(.loop(.times(3), steps: [Flow.Step("scroll", ["direction": "down"])])),
            Flow.Step(.loop(.whileVisible(Flow.Target(text: "Next"), max: 20), steps: [Flow.Step("tap_element", ["text": "Next"])])),
            Flow.Step(
                .retry(
                    times: 2,
                    steps: [Flow.Step("tap_element", ["text": "Reload"]), Flow.Step("wait_for_element", ["text": "Loaded", "timeout": 7])])),
            Flow.Step(.extract(Flow.Extraction(target: Flow.Target(id: "code"), into: "COPIED_TEXT"))),
            Flow.Step("type_text", ["text": "${COPIED_TEXT}"]),
            Flow.Step("open_url", ["url": "https://example.com/path?a=1#frag"]),
            Flow.Step("set_location", ["latitude": 52.52, "longitude": 13.405]),
            Flow.Step(.subflow(path: "subflows/logout.yaml", flow: nil)),
            Flow.Step("stop_app", ["bundle_id": "com.example.app"]),
            Flow.Step("stop_app", ["bundle_id": "com.other.app"]),
            Flow.Step("reset_app", ["bundle_id": "com.example.app"]),
            Flow.Step("tap_element", ["text": "Not now"], optional: true),
            Flow.Step("wait_for_element", ["id": "spinner", "timeout": 7, "gone": true]),
            Flow.Step("home"),
            Flow.Step("press_key", ["key": "volume_up"]),
            Flow.Step("set_orientation", ["orientation": "landscape_left"]),
            Flow.Step(
                "set_location",
                ["route": [["latitude": 52.52, "longitude": 13.405], ["latitude": 52.53, "longitude": 13.41]], "speed": 10]),
            Flow.Step(
                .branch(
                    .platform("android"),
                    then: [Flow.Step(.set(["WHO": "robot"])), Flow.Step("type_text", ["text": "${WHO} copied ${COPIED_TEXT}"])],
                    else: [])),
        ]
        #expect(flow.steps.count == expected.count)
        for (index, (got, want)) in zip(flow.steps, expected).enumerated() {
            #expect(got == want, "step \(index + 1)")
        }
        #expect(flow.notes == [
            "line 44: hideKeyboard is left out. Mobdev types with a hardware keyboard on iOS, so the on-screen keyboard rarely shows; on Android, press Back with pressKey: Back if it covers something.",
            "line 45: takeScreenshot is left out; Mobdev flow --artifacts and run_flow's video keep the whole run.",
        ])
        // The converted flow is a valid Mobdev flow: it writes and parses back.
        #expect(try Flow.parse(try JSONValue.parse(flow.encoded())).steps == flow.steps)
    }

    @Test func unsupportedCommandsFailWithTheirLine() {
        func message(_ commands: String, config: String = "appId: com.example.app") -> String {
            error { try Maestro.flow(from: config + "\n---\n" + commands, file: URL(fileURLWithPath: "/x/flow.yaml")) }
        }
        #expect(message("- tapOn: A\n- evalScript: |\n    output.x = 1\n    \tif (a) {}\n")
            == "flow.yaml: line 4: evalScript is not supported by Mobdev: Mobdev runs no JavaScript.")
        #expect(message("- runScript: setup.js") == "flow.yaml: line 3: runScript is not supported by Mobdev: Mobdev runs no JavaScript.")
        #expect(message("- tapOn:\n    text: A\n    below: B") == "flow.yaml: line 5: tapOn below is not supported by Mobdev; use an id or text that is unique.")
        #expect(message("- tapOn:\n    text: A\n    enabled: true") == "flow.yaml: line 5: tapOn enabled is not supported by Mobdev.")
        #expect(message("- tapOn:\n    textt: A").hasPrefix("flow.yaml: line 4: tapOn textt is not supported by Mobdev. It takes"))
        #expect(message("- inputText: ${output.name}")
            == "flow.yaml: line 3: ${output.name} is JavaScript, which Mobdev does not run; only ${NAME} variables work.")
        #expect(message("- flyTo: moon") == "flow.yaml: line 3: flyTo is not a Maestro command Mobdev knows.")
        #expect(message("- tapOn: A\n  inputText: B").hasPrefix("flow.yaml: line 3: one command per list item"))
        #expect(message("- launchApp", config: "name: x") .contains("launchApp needs an appId"))
        #expect(message("- assertTrue: ${a == b}").contains("assertTrue is not supported by Mobdev"))
        #expect(message("- runFlow:\n    when:\n      true: ${x}\n    commands: [back]").contains("line 5: when true: checks a JavaScript condition"))
        #expect(message("- repeat:\n    commands: [back]") == "flow.yaml: line 3: repeat needs times or while.")
        #expect(message("- swipe:\n    from: {id: a}\n    direction: UP").contains("swipe from an element is not supported"))
        #expect(message("- pressKey: Lock") == "flow.yaml: line 3: pressKey Lock is not supported by Mobdev.")
        #expect(message("- tapOn: \".*\"").contains("matches anything"))
        #expect(message("- tapOn: A", config: "appId: x\nonFlowComplete:\n  - back").contains("line 2: onFlowComplete is not supported"))
        #expect(error { try Maestro.flow(from: "appId: x\n", file: nil) }.contains("has no commands"))
        #expect(error { try Maestro.flow(from: "- tapOn: \"A", file: URL(fileURLWithPath: "/x/bad.yaml")) }
            .hasPrefix("bad.yaml: line 1: the string's closing"))
    }

    @Test func patternsAndPointsAreNoted() throws {
        let flow = try Maestro.flow(
            from: "appId: x\n---\n- tapOn: \"^Price \\\\$5\\\\.00$\"\n- tapOn: \"Item [0-9]+\"\n- tapOn:\n    point: 100, 200\n- tapOn:\n    id: a\n    text: b",
            file: nil)
        #expect(flow.steps[0] == Flow.Step("tap_element", ["text": "Price $5.00"]))
        #expect(flow.steps[1] == Flow.Step("tap_element", ["text": "Item [0-9]+"]))
        #expect(flow.steps[2] == Flow.Step("tap", ["x": 100, "y": 200]))
        #expect(flow.steps[3] == Flow.Step("tap_element", ["id": "a"]))
        #expect(flow.notes.count == 3)
        #expect(flow.notes[0] == "line 4: Maestro reads \"Item [0-9]+\" as a pattern; Mobdev looks for \"Item [0-9]+\" as text.")
        #expect(flow.notes[1].hasPrefix("line 6: the point 100, 200 is read as pixels of Mobdev's screenshot"))
        #expect(flow.notes[2] == "line 7: tapOn looks for the id only; Mobdev matches one of id and text.")
    }

    // MARK: Mobdev to Maestro

    @Test func exportsAndReadsBackTheSameSteps() throws {
        let imported = try Maestro.flow(from: Self.signIn, file: URL(fileURLWithPath: "/tmp/sign-in.yaml"))
        let (yaml, notes) = try Maestro.export(imported)
        #expect(yaml.hasPrefix("appId: \"com.example.app\"\nname: \"Sign in\"\nenv:\n  EMAIL: \"me@example.com\"\n---\n- clearState\n"))
        #expect(yaml.contains("\n- back\n"))
        #expect(yaml.contains("\n- tapOn: \"Sign in\"\n"))
        #expect(yaml.contains("\n- copyTextFrom:\n    id: \"code\"\n- pasteText\n"))
        #expect(yaml.contains("\n- tapOn:\n    text: \"Not now\"\n    optional: true\n"))
        #expect(
            yaml.hasSuffix(
                "\n- runFlow:\n    when:\n      platform: Android\n    env:\n      WHO: \"robot\"\n    commands:\n      - inputText: \"${WHO} copied ${maestro.copiedText}\"\n"
            ))
        #expect(notes.isEmpty, "\(notes)")
        // Read back, it is the same flow.
        let again = try Maestro.flow(from: yaml, file: URL(fileURLWithPath: "/tmp/sign-in.yaml"))
        #expect(again.name == imported.name)
        #expect(again.steps.count == imported.steps.count)
        for (index, (got, want)) in zip(again.steps, imported.steps).enumerated() {
            #expect(got == want, "step \(index + 1)")
        }

        // Launching after a reset is launchApp with clearState; an app other than the config's says which.
        let launch = Flow(name: "Launch", steps: [
            Flow.Step("reset_app", ["bundle_id": "com.example.app", "keychain": true]),
            Flow.Step("launch_app", ["bundle_id": "com.example.app", "restart": false, "arguments": ["-onboarding", "off"]]),
            Flow.Step("launch_app", ["bundle_id": "com.other.app"]),
            Flow.Step("tap", ["x": 100, "y": 200]),
            Flow.Step("press_key", ["key": "escape"]),
            Flow.Step(.branch(.platform("ios"), then: [Flow.Step("home")], else: [Flow.Step("press_key", ["key": "tab"])])),
            Flow.Step(.subflow(path: "logout.json", flow: nil)),
        ])
        let (exported, launchNotes) = try Maestro.export(launch)
        #expect(
            exported == """
                appId: "com.example.app"
                name: "Launch"
                ---
                - launchApp:
                    clearState: true
                    clearKeychain: true
                    stopApp: false
                    arguments:
                      onboarding: "off"
                - launchApp:
                    appId: "com.other.app"
                - tapOn:
                    point: "100,200"
                - back
                - runFlow:
                    when:
                      platform: iOS
                    commands:
                      - pressKey: Home
                - runFlow:
                    when:
                      platform: Android
                    commands:
                      - pressKey: Tab
                - runFlow: "logout.yaml"

                """)
        #expect(launchNotes.count == 3)
        #expect(launchNotes[2] == "7: logout.json becomes logout.yaml; convert it too: Mobdev convert logout.json > logout.yaml.")
        let back = try Maestro.flow(from: exported, file: nil)
        #expect(back.steps[0] == Flow.Step("reset_app", ["bundle_id": "com.example.app", "keychain": true]))
        #expect(back.steps[1] == launch.steps[1])
    }

    @Test func stepsWithoutAMaestroCommandFailTogether() {
        let flow = Flow(name: "x", steps: [
            Flow.Step("launch_app", ["bundle_id": "a"]),
            Flow.Step("observe"),
            Flow.Step(.branch(.visible(Flow.Target(text: "A")), then: ["home"].map { Flow.Step($0) }, else: [Flow.Step("home")])),
            Flow.Step(.set(["A": "b"])),
            Flow.Step(.extract(Flow.Extraction(target: Flow.Target(id: "x"), into: "TOTAL"))),
            Flow.Step("press_key", ["key": "a", "modifiers": ["cmd"]]),
        ])
        let message = error { try Maestro.export(flow) }
        #expect(message.hasPrefix("These steps have no Maestro command:\n  2. observe: no Maestro command does what observe does."))
        #expect(message.contains("\n  3. if visible {\"text\":\"A\"}: Maestro has no else"))
        #expect(message.contains("\n  4. set {\"A\":\"b\"}: Maestro sets variables only in env"))
        #expect(message.contains("\n  5. extract {\"id\":\"x\"} into TOTAL: Maestro copies text only into"))
        #expect(message.contains("\n  6. press_key {\"key\":\"a\",\"modifiers\":[\"cmd\"]}: Maestro presses no key combinations."))
        // A flow without an app gets a note instead of an appId.
        let (yaml, notes) = try! Maestro.export(Flow(name: "Home", steps: [Flow.Step("home")]))
        #expect(yaml == "name: \"Home\"\n---\n- pressKey: Home\n")
        #expect(notes.first?.contains("add appId") == true)
    }

    @Test func convertCommandPrintsTheOtherFormat() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let yaml = root.appendingPathComponent("flow.yaml")
        try Data("appId: com.example.app\n---\n- launchApp\n- takeScreenshot: a\n- tapOn: OK\n".utf8).write(to: yaml)
        let printed = Locked("")
        let errors = Locked<[String]>([])
        func run(_ arguments: [String]) -> Int32 {
            printed.set("")
            errors.set([])
            return ConvertCommand.execute(arguments, output: { text in printed.withLock { $0 += text } }, error: { line in errors.withLock { $0.append(line) } })
        }
        #expect(run([yaml.path]) == 0)
        #expect(
            printed.get() == """
                {
                  "name": "flow",
                  "steps": [
                    {"launch_app":{"bundle_id":"com.example.app"}},
                    {"tap_element":{"text":"OK"}}
                  ]
                }

                """)
        #expect(errors.get() == ["Note: line 4: takeScreenshot is left out; Mobdev flow --artifacts and run_flow's video keep the whole run."])

        let json = root.appendingPathComponent("flow.json")
        try Data(printed.get().utf8).write(to: json)
        #expect(run([json.path]) == 0)
        #expect(printed.get() == "appId: \"com.example.app\"\nname: \"flow\"\n---\n- launchApp\n- tapOn: \"OK\"\n")
        #expect(run([yaml.path, "--to", "maestro"]) == 0)
        #expect(printed.get().hasSuffix("- tapOn: \"OK\"\n"))

        try Data(#"["observe"]"#.utf8).write(to: json)
        #expect(run([json.path]) == 2)
        #expect(errors.get().first?.hasPrefix("These steps have no Maestro command") == true)
        #expect(run([]) == 2)
        #expect(run([json.path, "--to", "xml"]) == 2)
        #expect(try ConvertCommand.parse(["a.json", "--to", "mobdev"]) == ConvertCommand.Options(file: "a.json", to: "mobdev"))
    }

    // MARK: Running

    @Test func runFlowAndTestsTakeMaestroFiles() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tests"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("flows"), withIntermediateDirectories: true)
        try Data("appId: com.example.app\n---\n- pressKey: Home\n".utf8).write(to: root.appendingPathComponent("flows/home.yaml"))
        try Data(
            "appId: com.example.app\nname: Goes home\n---\n- runFlow: ../flows/home.yaml\n- tapOn:\n    point: 50%, 50%\n- hideKeyboard\n".utf8
        ).write(to: root.appendingPathComponent("tests/goes-home.yaml"))
        try Data(#"{"name": "JSON", "steps": [{"run": "flows/home.yaml"}]}"#.utf8).write(to: root.appendingPathComponent("tests/json.json"))

        let phone = FakePhone(lines: [])
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let output = try await tools.call(
            "run_flow", arguments: ["path": .string(root.appendingPathComponent("tests/goes-home.yaml").path)], source: "test",
            screenshotByDefault: false)
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.hasPrefix("Flow \"Goes home\" passed: 3 steps"))
        #expect(output.text.contains("\n  ✓ 1.1. home: Went to the home screen."))
        #expect(output.text.contains("\nNote: line 7: hideKeyboard is left out."))
        #expect(phone.events.get() == [.button(.home), .tap(NormalizedPoint(x: 0.5, y: 0.5), 0.08)])

        let project = try TestProject.load(root)
        #expect(project.tests.map(\.slug) == ["goes-home", "json"])
        #expect(project.tests[0].name == "Goes home")
        let result = await tools.runTests(project, options: TestRunOptions(output: root.appendingPathComponent("out"), video: false), source: "test")
        #expect(result.passed, "\(result.text)")
        #expect(result.tests.map(\.status) == [.passed, .passed])
        #expect(try TestProject.locate(root.appendingPathComponent("tests/goes-home.yaml").path).tests == ["goes-home"])

        // Two files for one test are a mistake to fix.
        try Data("- back\n".utf8).write(to: root.appendingPathComponent("tests/json.yml"))
        #expect(error { try TestProject.load(root) }.contains("json.json and json.yml in"))
    }
}
