import Foundation
import Testing
@testable import MobdevCore

@Suite struct TestRunnerTests {
    /// A fresh folder for one test, removed afterwards by the caller.
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("tests"), withIntermediateDirectories: true)
        return url
    }

    func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    func tools(_ phone: FakePhone) -> PhoneTools {
        PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
    }
}

extension PhoneTools {
    /// Every test of a project, without video, for the tests here.
    func runTests(project: TestProject, output: URL) async -> TestRunResult {
        await runTests(project, options: TestRunOptions(output: output, video: false), source: "test")
    }
}

extension TestRunnerTests {

    @Test func parsesAProjectAndItsTests() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            """
            {"name": "Fixture", "app": {"bundle_id": "dev.mobdev.fixture", "builds": {"simulator": "build/Fixture.app"}},
             "before_each": [{"launch_app": {"bundle_id": "dev.mobdev.fixture", "restart": true}}],
             "variables": {"EMAIL": "me@example.com"}, "secrets": ["PASSWORD"]}
            """, to: root.appendingPathComponent("mobdev.json"))
        try write(
            """
            {"name": "Sign in", "description": "Signs in.", "platforms": ["ios"], "steps": [{"tap_element": {"id": "email"}}, "home"]}
            """, to: root.appendingPathComponent("tests/sign-in.json"))
        try write("[\"home\"]", to: root.appendingPathComponent("tests/a-bare-list.json"))
        try write("not a test", to: root.appendingPathComponent("tests/notes.txt"))

        let project = try TestProject.load(root)
        #expect(project.name == "Fixture")
        #expect(project.app.bundleID == "dev.mobdev.fixture")
        #expect(project.build(for: .simulator)?.path == root.appendingPathComponent("build/Fixture.app").path)
        #expect(project.build(for: .android) == nil)
        #expect(project.beforeEach == [Flow.Step("launch_app", ["bundle_id": "dev.mobdev.fixture", "restart": true])])
        #expect(project.variables == ["EMAIL": "me@example.com"])
        #expect(project.secrets == ["PASSWORD"])
        #expect(project.tests.map(\.slug) == ["a-bare-list", "sign-in"])
        let signIn = try #require(project.test("Sign in"))
        #expect(signIn.slug == "sign-in")
        #expect(signIn.description == "Signs in.")
        #expect(signIn.platforms == ["ios"])
        #expect(signIn.runs(on: .simulator))
        #expect(!signIn.runs(on: .android))
        #expect(signIn.steps.count == 2)
        #expect(project.test("sign-in")?.name == "Sign in")
        #expect(project.test("Sign In")?.slug == "sign-in")
        #expect(project.test("a-bare-list")?.name == "a-bare-list")
        #expect(project.test("nope") == nil)

        // The files round-trip, one step per line.
        #expect(try TestProject.parse(try JSONValue.parse(project.encoded()), folder: root).variables == project.variables)
        let text = String(decoding: signIn.encoded(), as: UTF8.self)
        #expect(text.contains("\n    {\"tap_element\":{\"id\":\"email\"}},\n    \"home\"\n"))
        #expect(try TestCase.parse(try JSONValue.parse(signIn.encoded()), file: signIn.file) == signIn)

        #expect(TestProject.slug("Sign in (Pro)!") == "sign-in-pro")
        #expect(TestProject.slug("Überweisung") == "uberweisung")
        #expect(TestProject.slug("***") == "test")

        // A folder with tests but no mobdev.json is a project named after the folder.
        try FileManager.default.removeItem(at: root.appendingPathComponent("mobdev.json"))
        #expect(try TestProject.load(root).name == root.lastPathComponent)
        try FileManager.default.removeItem(at: root.appendingPathComponent("tests"))
        #expect(throws: (any Error).self) { try TestProject.load(root) }
    }

    @Test func rejectsMistakesInTheFiles() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        func project(_ json: String) throws -> TestProject {
            try TestProject.parse(try JSONValue.parse(Data(json.utf8)), folder: root)
        }
        #expect(throws: (any Error).self) { try project("{\"nmae\": \"x\"}") }
        #expect(throws: (any Error).self) { try project("{\"app\": {\"builds\": {\"ipad\": \"x.app\"}}}") }
        #expect(throws: (any Error).self) { try project("{\"variables\": {\"my email\": \"x\"}}") }
        #expect(throws: (any Error).self) { try project("{\"variables\": {\"EMAIL\": 1}}") }
        #expect(throws: (any Error).self) { try project("{\"secrets\": \"PASSWORD\"}") }
        #expect(throws: (any Error).self) { try project("{\"before_each\": [{\"tap\": 1}]}") }
        #expect(try project("{}").name == root.lastPathComponent)

        let file = root.appendingPathComponent("tests/t.json")
        func test(_ json: String) throws -> TestCase { try TestCase.parse(try JSONValue.parse(Data(json.utf8)), file: file) }
        #expect(throws: (any Error).self) { try test("{\"steps\": [], \"platform\": \"ios\"}") }
        #expect(throws: (any Error).self) { try test("{\"steps\": [], \"platforms\": [\"web\"]}") }
        #expect(throws: (any Error).self) { try test("{\"steps\": [], \"description\": 3}") }
        #expect(throws: (any Error).self) { try test("{\"name\": \"x\"}") }
        #expect(try test("{\"steps\": []}").name == "t")
    }

    @Test func substitutesVariablesAndRedactsSecrets() throws {
        let variables = Variables(values: ["EMAIL": "me@example.com", "PASSWORD": "hunter2"], secrets: ["PASSWORD"])
        let filled = try variables.substitute(["text": "${EMAIL} and ${PASSWORD}", "nested": ["x": ["${EMAIL}"]], "n": 1])
        #expect(filled == ["text": "me@example.com and hunter2", "nested": ["x": ["me@example.com"]], "n": 1])
        #expect(try variables.substitute("cost: ${ 5 } or ${EMAIL") == "cost: ${ 5 } or ${EMAIL")
        #expect(try variables.substitute("${EMAIL}${EMAIL}") == "me@example.comme@example.com")
        #expect(throws: (any Error).self) { try variables.substitute("${NOPE}") }
        do {
            _ = try variables.substitute("${NOPE}")
        } catch {
            #expect(String(describing: error).contains("Variable NOPE is not set"))
        }
        #expect(variables.redact("Typed hunter2 twice: hunter2") == "Typed ${PASSWORD} twice: ${PASSWORD}")
        #expect(Variables.isName("EMAIL_2"))
        #expect(!Variables.isName("2EMAIL"))
        #expect(!Variables.isName("my email"))

        // The run beats the environment, which beats the file; secrets come from the run or the environment.
        let project = TestProject(
            folder: URL(fileURLWithPath: "/tmp/p"), name: "p", variables: ["EMAIL": "file@example.com", "LANG_": "file"],
            secrets: ["PASSWORD"])
        let merged = Variables(
            project: project, overrides: ["EMAIL": "run@example.com"],
            environment: ["EMAIL": "env@example.com", "LANG_": "env", "PASSWORD": "s3cret", "OTHER": "ignored"])
        #expect(merged.values == ["EMAIL": "run@example.com", "LANG_": "env", "PASSWORD": "s3cret"])
    }

    @Test func runsTestsAndWritesResultsAndJUnit() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("{\"name\": \"Fixture\", \"before_each\": [\"home\"]}", to: root.appendingPathComponent("mobdev.json"))
        try write(
            "{\"name\": \"Types\", \"steps\": [{\"type_text\": {\"text\": \"hi\"}}, {\"tap\": {\"x\": 10, \"y\": 20}}]}",
            to: root.appendingPathComponent("tests/a-types.json"))
        try write(
            "{\"name\": \"Taps outside\", \"steps\": [{\"tap\": {\"x\": 5000, \"y\": 1}}, \"home\"]}",
            to: root.appendingPathComponent("tests/b-fails.json"))
        try write(
            "{\"name\": \"Android only\", \"platforms\": [\"android\"], \"steps\": [\"home\"]}",
            to: root.appendingPathComponent("tests/c-android.json"))
        let project = try TestProject.load(root)
        let phone = FakePhone(lines: [])
        let output = root.appendingPathComponent("out")
        let finished = Locked<[String]>([])

        let result = await tools(phone).runTests(project, options: TestRunOptions(output: output, video: false), source: "test") { test in
            finished.withLock { $0.append(test.slug) }
        }
        #expect(finished.get() == ["a-types", "b-fails", "c-android"])
        #expect(!result.passed)
        #expect(result.counts == (1, 1, 1))
        #expect(result.device.kind == "iPhone")
        #expect(result.error == nil)
        #expect(!result.cancelled)
        #expect(result.summaryLine.hasPrefix("Tests \"Fixture\" on Device: 1 passed, 1 failed, 1 skipped in "))

        let passed = result.tests[0]
        #expect(passed.status == .passed)
        #expect(passed.steps.map(\.summary) == ["home", "type_text {\"text\":\"hi\"}", "tap {\"x\":10,\"y\":20}"])
        #expect(passed.steps.allSatisfy { $0.passed })
        #expect(passed.failedStep == nil)
        #expect(passed.screenshot == nil)
        #expect(passed.video == nil)
        #expect(passed.line.hasPrefix("✓ Types ("))

        let failed = result.tests[1]
        #expect(failed.status == .failed)
        #expect(failed.failedStep == 2)
        #expect(failed.steps.count == 2)
        #expect(failed.message.hasPrefix("step 2 of 3, tap {\"x\":5000,\"y\":1}: (5000, 1) is outside the screenshot"))
        let screenshot = try #require(failed.screenshot)
        #expect(screenshot == output.appendingPathComponent("b-fails/failure.png").path)
        #expect(FileManager.default.fileExists(atPath: screenshot))
        #expect(result.failureImage?.mimeType == "image/jpeg")
        #expect(failed.line.hasPrefix("✗ Taps outside ("))

        let skipped = result.tests[2]
        #expect(skipped.status == .skipped)
        #expect(skipped.message == "not for ios")
        #expect(skipped.line == "– Android only: not for ios")
        // before_each, typing and a tap for the first test; before_each for the second, whose tap
        // failed before touching the phone; nothing for the skipped one.
        #expect(phone.events.get().count == 4)

        // results.json reads back as the same run, and junit.xml has a case per test.
        let saved = try TestRunResult.load(output)
        #expect(saved.tests == result.tests)
        #expect(saved.project == "Fixture")
        #expect(saved.output == output.path)
        let junit = try String(contentsOf: output.appendingPathComponent("junit.xml"), encoding: .utf8)
        #expect(junit.contains("<testsuites name=\"Mobdev\" tests=\"3\" failures=\"1\" errors=\"0\" skipped=\"1\""))
        #expect(junit.contains("<testcase name=\"Types\" classname=\"Fixture\""))
        #expect(junit.contains("<failure message=\"step 2 of 3, tap {&quot;x&quot;:5000,&quot;y&quot;:1}: (5000, 1) is outside the screenshot, which is 590×1280 px.\">"))
        #expect(junit.contains("<skipped message=\"not for ios\"/>"))
        #expect(result.text.contains("Screenshot: \(screenshot)"))
        #expect(result.text.hasSuffix("Results: \(output.path)/results.json"))

        // A selection runs only those tests; an unknown one runs nothing.
        let some = await tools(phone).runTests(
            project, options: TestRunOptions(output: root.appendingPathComponent("out2"), tests: ["Taps outside"], video: false),
            source: "test")
        #expect(some.tests.map(\.slug) == ["b-fails"])
        let none = await tools(phone).runTests(
            project, options: TestRunOptions(output: root.appendingPathComponent("out3"), tests: ["nope"], video: false),
            source: "test")
        #expect(none.tests.isEmpty)
        #expect(none.error == "No test \"nope\" in Fixture. Tests: a-types, b-fails, c-android.")
        #expect(!none.passed)
        #expect(try TestRunResult.load(root.appendingPathComponent("out3")).error == none.error)
        #expect(none.junit.contains("<testcase name=\"Setup\""))
    }

    @Test func variablesFillStepsAndSecretsStayOut() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "{\"variables\": {\"GREETING\": \"hello\"}, \"secrets\": [\"PASSWORD\"]}",
            to: root.appendingPathComponent("mobdev.json"))
        try write(
            "{\"steps\": [{\"type_text\": {\"text\": \"${GREETING}\"}}, {\"open_app\": {\"name\": \"${PASSWORD}\"}}]}",
            to: root.appendingPathComponent("tests/vars.json"))
        try write("{\"steps\": [\"home\", {\"type_text\": {\"text\": \"${NOPE}\"}}]}", to: root.appendingPathComponent("tests/missing.json"))
        let project = try TestProject.load(root)
        let phone = FakePhone(lines: [])
        let result = await tools(phone).runTests(
            project, options: TestRunOptions(output: root.appendingPathComponent("out"), variables: ["PASSWORD": "hunter2"], video: false),
            source: "test")

        let missing = try #require(result.tests.first { $0.slug == "missing" })
        #expect(missing.status == .failed)
        #expect(missing.failedStep == 2)
        #expect(missing.steps.isEmpty)
        #expect(missing.message.contains("Variable NOPE is not set"))

        let vars = try #require(result.tests.first { $0.slug == "vars" })
        #expect(vars.status == .passed)
        #expect(vars.steps[0].summary == "type_text {\"text\":\"${GREETING}\"}")
        #expect(vars.steps[0].text == "Typed 5 characters.")
        #expect(vars.steps[1].text == "Searched Spotlight for \"${PASSWORD}\" and opened the top hit.")
        let saved = try String(contentsOf: root.appendingPathComponent("out/results.json"), encoding: .utf8)
        #expect(!saved.contains("hunter2"))
        #expect(!result.junit.contains("hunter2"))
    }

    /// A failure carries what the app printed during the test and how the app is doing, so the
    /// reason is in the results rather than in a log an agent would have to fetch.
    @Test func aFailureCarriesTheAppsOutputAndState() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("{\"app\": {\"bundle_id\": \"dev.mobdev.fixture\"}}", to: root.appendingPathComponent("mobdev.json"))
        try write(
            "{\"steps\": [{\"open_url\": {\"url\": \"mobdevfixture://one\"}}, {\"tap\": {\"x\": 9999, \"y\": 1}}]}",
            to: root.appendingPathComponent("tests/fails.json"))
        try write("{\"steps\": [{\"open_url\": {\"url\": \"mobdevfixture://two\"}}]}", to: root.appendingPathComponent("tests/passes.json"))
        let apps = FakeApps()
        apps.logs.append(app: "dev.mobdev.fixture", text: "fixture: from before the run")
        apps.logs.setStatus("exited with code 3", for: "dev.mobdev.fixture")
        let phone = FakePhone(lines: [], apps: apps)
        let result = await tools(phone).runTests(project: try TestProject.load(root), output: root.appendingPathComponent("out"))

        let failed = try #require(result.tests.first { $0.slug == "fails" })
        #expect(failed.status == .failed)
        #expect(failed.message.hasSuffix("is outside the screenshot, which is 590×1280 px. The app exited with code 3."))
        #expect(failed.log == ["fixture: opened mobdevfixture://one"])
        #expect(failed.detailLines.contains("  The app printed:"))
        #expect(failed.detailLines.contains("    fixture: opened mobdevfixture://one"))
        #expect(result.text.contains("    fixture: opened mobdevfixture://one"))
        #expect(result.junit.contains("The app printed:\nfixture: opened mobdevfixture://one</failure>"))
        let passed = try #require(result.tests.first { $0.slug == "passes" })
        #expect(passed.log == nil)
        #expect(passed.detailLines.isEmpty)
        #expect(try TestRunResult.load(root.appendingPathComponent("out")).tests == result.tests)
    }

    @Test func projectToolsListSaveRunAndReport() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = root.appendingPathComponent("runs")
        TestRuns.rootOverride.set(runs)
        defer { TestRuns.rootOverride.set(nil) }
        let project = root.appendingPathComponent("project")
        let files = DeviceTools(hub: DeviceHub(keyboardLayout: .us) {}, settleDelay: 0)

        // Saving into a folder that does not exist yet creates the project.
        let saved = try await files.call(
            "save_test",
            arguments: [
                "project": .string(project.path), "name": "Goes home", "description": "Presses home.",
                "steps": ["home", ["tap": ["x": 1, "y": 2]]],
            ], source: "test", screenshotByDefault: false)
        #expect(!saved.isError, "\(saved.text)")
        #expect(saved.text.hasPrefix("Saved \(project.path)/tests/goes-home.json with 2 steps. Created \(project.path)/mobdev.json"))
        #expect(saved.data?["file"] == .string(project.appendingPathComponent("tests/goes-home.json").path))
        let loaded = try TestProject.load(project)
        #expect(loaded.name == "project")
        #expect(loaded.tests.map(\.name) == ["Goes home"])
        #expect(loaded.tests[0].description == "Presses home.")
        let replaced = try await files.call(
            "save_test",
            arguments: ["project": .string(project.path), "name": "Goes home", "description": "Presses home.", "steps": ["home"]],
            source: "test", screenshotByDefault: false)
        #expect(replaced.text.hasPrefix("Replaced "))
        #expect(try TestProject.load(project).tests[0].steps.count == 1)
        let bad = try await files.call(
            "save_test", arguments: ["project": .string(project.path), "name": "Bad", "steps": [["run_flow": ["path": "x"]]]],
            source: "test", screenshotByDefault: false)
        #expect(bad.isError)
        #expect(bad.text.contains("not a tool a test can call"))
        let relative = try await files.call(
            "save_test", arguments: ["project": "project", "name": "Bad", "steps": ["home"]], source: "test",
            screenshotByDefault: false)
        #expect(relative.isError)
        #expect(try TestProject.load(project).tests.count == 1)

        let listed = try await files.call(
            "list_tests", arguments: ["project": .string(project.path)], source: "test", screenshotByDefault: false)
        #expect(!listed.isError)
        #expect(listed.text.contains("1 tests:\n  goes-home: Goes home, 1 steps. Presses home."))
        #expect(listed.data?["last_run"] == .null)
        let early = try await files.call(
            "test_result", arguments: ["project": .string(project.path)], source: "test", screenshotByDefault: false)
        #expect(early.isError)
        #expect(early.text.contains("No results yet"))

        // Running through the tool keeps the results in the app's folder, where test_result finds them.
        let phone = FakePhone(lines: [])
        let device = tools(phone)
        let passed = try await device.call(
            "run_tests", arguments: ["project": .string(project.path), "video": false], source: "test", screenshotByDefault: false)
        #expect(!passed.isError, "\(passed.text)")
        #expect(passed.image == nil)
        #expect(passed.data?["tests"]?.arrayValue?.count == 1)
        try write("{\"steps\": [{\"tap\": {\"x\": 9999, \"y\": 1}}]}", to: project.appendingPathComponent("tests/fails.json"))
        let failed = try await device.call(
            "run_tests", arguments: ["project": .string(project.path), "tests": ["fails"], "video": false], source: "test",
            screenshotByDefault: false)
        #expect(failed.isError)
        #expect(failed.image?.mimeType == "image/jpeg")
        #expect(failed.text.hasPrefix("Tests \"project\" on Device: 0 passed, 1 failed in "))
        let runFolders = TestRuns.runs(for: loaded)
        #expect(runFolders.count == 2)
        #expect(runFolders.allSatisfy { $0.path.hasPrefix(runs.path) })

        let report = try await files.call(
            "test_result", arguments: ["project": .string(project.path)], source: "test", screenshotByDefault: false)
        #expect(!report.isError)
        #expect(report.text.contains("✗ fails ("))
        #expect(report.text.contains("\nfails:\n  ✗ 1. tap {\"x\":9999,\"y\":1}:"))
        #expect(report.data?["tests"]?.arrayValue?.first?["status"] == "failed")
        let older = try await files.call(
            "test_result", arguments: ["project": .string(project.path), "run": .string(runFolders[1].lastPathComponent)],
            source: "test", screenshotByDefault: false)
        #expect(older.data?["tests"]?.arrayValue?.first?["status"] == "passed")
        let unknown = try await files.call(
            "test_result", arguments: ["project": .string(project.path), "run": "2001-01-01 00.00.00"], source: "test",
            screenshotByDefault: false)
        #expect(unknown.isError)
        let listedAgain = try await files.call(
            "list_tests", arguments: ["project": .string(project.path)], source: "test", screenshotByDefault: false)
        #expect(listedAgain.text.contains("fails: fails, 1 steps. last run failed"))
        #expect(listedAgain.text.contains("goes-home: Goes home, 1 steps. Presses home."))
        #expect(listedAgain.data?["runs"]?.arrayValue?.count == 2)

        // The newest 20 runs are kept.
        for _ in 0..<25 { _ = try TestRuns.newRunFolder(for: loaded) }
        #expect(TestRuns.runs(for: loaded).count == TestRuns.kept)
    }

    @Test func locatesAProjectFromAnyOfItsPaths() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("{\"name\": \"P\"}", to: root.appendingPathComponent("mobdev.json"))
        try write("{\"steps\": [\"home\"]}", to: root.appendingPathComponent("tests/one.json"))
        try write("{\"steps\": [\"home\"]}", to: root.appendingPathComponent("tests/two.json"))
        try write("{\"name\": \"Loose\", \"steps\": [\"home\"]}", to: root.appendingPathComponent("loose.json"))

        let whole = try TestProject.locate(root.path)
        #expect(whole.project.name == "P")
        #expect(whole.tests.isEmpty)
        #expect(try TestProject.locate(root.appendingPathComponent("mobdev.json").path).project.tests.count == 2)
        let one = try TestProject.locate(root.appendingPathComponent("tests/one.json").path)
        #expect(one.project.name == "P")
        #expect(one.project.tests.count == 2)
        #expect(one.tests == ["one"])
        let loose = try TestProject.locate(root.appendingPathComponent("loose.json").path)
        #expect(loose.project.name == "Loose")
        #expect(loose.project.tests.map(\.slug) == ["loose"])
        #expect(loose.tests == ["loose"])
        #expect(throws: (any Error).self) { try TestProject.locate("relative/path") }
        #expect(throws: (any Error).self) { try TestProject.locate(root.appendingPathComponent("missing").path) }
        #expect(throws: (any Error).self) { try TestProject.locate(root.appendingPathComponent("tests/notes.txt").path) }
    }

    @Test func commandLineOptions() throws {
        let options = try TestCommand.parse([
            "mobdev", "--device", "Pixel", "--artifacts", "out", "--test", "a", "--test", "B name", "--var", "EMAIL=me@x.com",
            "--var", "EMPTY=", "--no-video", "--wait", "5",
        ])
        #expect(
            options
                == TestCommand.Options(
                    project: "mobdev", device: "Pixel", artifacts: "out", tests: ["a", "B name"],
                    variables: ["EMAIL": "me@x.com", "EMPTY": ""], video: false, wait: 5))
        #expect(try TestCommand.parse(["p"]).wait == 120)
        #expect(throws: (any Error).self) { try TestCommand.parse([]) }
        #expect(throws: (any Error).self) { try TestCommand.parse(["a", "b"]) }
        #expect(throws: (any Error).self) { try TestCommand.parse(["a", "--var", "EMAIL"]) }
        #expect(throws: (any Error).self) { try TestCommand.parse(["a", "--var", "my email=x"]) }
        #expect(throws: (any Error).self) { try TestCommand.parse(["a", "--test"]) }
        #expect(throws: (any Error).self) { try TestCommand.parse(["a", "--wait", "soon"]) }
    }
}
