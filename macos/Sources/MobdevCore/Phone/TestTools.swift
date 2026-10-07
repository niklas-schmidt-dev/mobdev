import Foundation

/// `run_tests`: a project's tests on this device, with results kept in the app's folder.
extension PhoneTools {
    static let testDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "run_tests", title: "Run tests",
            description:
                "Run a project's tests on this device: a folder with tests/*.json (or Maestro .yaml) and optionally mobdev.json naming the app, its builds and the steps every test starts with (see list_tests). Installs the project's build for the device, plays each test, keeps a video and, for failures, a screenshot, and writes results.json and junit.xml. Returns every test's result, the first failure's screen, and where the files are. Pass tests to run some by file name.",
            inputSchema: schema(
                [
                    "project": [
                        "type": "string",
                        "description": "The project folder on the Mac that runs Mobdev, its mobdev.json, or one test file",
                    ],
                    "tests": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Tests to run, by file name without .json or .yaml; default all",
                    ],
                    "variables": [
                        "type": "object", "additionalProperties": ["type": "string"],
                        "description": "Values for ${NAME} in the steps, over the project's variables; secrets go here",
                    ],
                    "video": ["type": "boolean", "description": "Record each test, default true"],
                    "language": [
                        "type": "string",
                        "description":
                            "Run the tests in this language, e.g. de-DE: the simulator's, or the Android app's (needs the project's bundle_id). Steps see it as ${LANGUAGE}; the old language comes back afterwards",
                    ],
                ], required: ["project"], screenshot: false),
            readOnly: false)
    ]

    func runTestsTool(_ args: Arguments, source: String) async throws -> ToolOutput {
        let (project, selected) = try TestProject.locate(try args.string("project"))
        var tests = try args.stringArray("tests")
        if tests.isEmpty { tests = selected }
        let options = TestRunOptions(
            output: try TestRuns.newRunFolder(for: project), tests: tests,
            variables: try args.stringDictionary("variables"), video: args.bool("video") ?? true,
            language: args.has("language") ? try args.string("language") : nil)
        let result = await runTests(project, options: options, source: source)
        return ToolOutput(text: result.text, data: result.json, image: result.failureImage, isError: !result.passed)
    }
}

/// Tools about a project's files, which need no device: what tests there are, writing one, and
/// the newest results.
public enum ProjectTools {
    public static let definitions: [ToolDefinition] = {
        let project: JSONValue = [
            "type": "string",
            "description": "The project folder on the Mac that runs Mobdev, like ~/code/my-app/mobdev, or its mobdev.json",
        ]
        return [
            ToolDefinition(
                name: "list_tests", title: "List tests",
                description:
                    "The tests of a project: a folder with tests/*.json (or Maestro .yaml), each a flow with a name, description, platforms and steps, and optionally mobdev.json with the app's bundle id, builds per platform, before_each steps, variables and secrets. Also the newest run's results. Use run_tests to run them and save_test to add one.",
                inputSchema: PhoneTools.schema(["project": project], required: ["project"], screenshot: false),
                readOnly: true),
            ToolDefinition(
                name: "save_test", title: "Save test",
                description:
                    "Write a test into a project's tests folder as <file name>.json, replacing one with the same file name. Steps are tool calls as in a flow, e.g. [{\"tap_element\": {\"id\": \"login\"}}, {\"wait_for_element\": {\"text\": \"Welcome\"}}]; prefer tap_element and wait_for_element over coordinates, end with a wait that proves the result, and write ${NAME} for a variable from mobdev.json. Control steps work as in run_flow: if, repeat, retry, run (a subflow next to the test or in the project folder), set and extract. Creates the project folder and a minimal mobdev.json when missing.",
                inputSchema: PhoneTools.schema(
                    [
                        "project": project,
                        "name": ["type": "string", "description": "The test's name, e.g. Sign in"],
                        "steps": ["type": "array", "description": "The steps, each a tool name or {\"tool\": {arguments}}"],
                        "description": ["type": "string", "description": "What the test proves, one sentence"],
                        "platforms": [
                            "type": "array", "items": ["type": "string", "enum": .array(TestCase.platforms.map(JSONValue.string))],
                            "description": "Only on these platforms: ios, android. Default both",
                        ],
                        "file": ["type": "string", "description": "File name without .json, default from the name"],
                    ], required: ["project", "name", "steps"], screenshot: false),
                readOnly: false),
            ToolDefinition(
                name: "test_result", title: "Test result",
                description:
                    "The results of a project's newest run of run_tests or the Tests window (or of the run named by run): every test with its status, failed step, message, screenshot and video paths on the Mac.",
                inputSchema: PhoneTools.schema(
                    [
                        "project": project,
                        "run": ["type": "string", "description": "A run from list_tests, e.g. 2026-10-07 14.03.22; default the newest"],
                    ], required: ["project"], screenshot: false),
                readOnly: true),
        ]
    }()

    public static func isProjectTool(_ name: String) -> Bool { definitions.contains { $0.name == name } }

    static func call(_ name: String, _ args: Arguments) throws -> ToolOutput {
        switch name {
        case "list_tests":
            let (project, _) = try TestProject.locate(try args.string("project"))
            var lines = ["\(project.name) in \(project.folder.path)"]
            if let bundleID = project.app.bundleID { lines.append("App: \(bundleID)") }
            if !project.app.builds.isEmpty {
                lines.append("Builds: " + project.app.builds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            }
            if !project.beforeEach.isEmpty {
                lines.append("Before each test: " + project.beforeEach.map(\.summary).joined(separator: "; "))
            }
            if !project.variables.isEmpty { lines.append("Variables: " + project.variables.keys.sorted().joined(separator: ", ")) }
            if !project.secrets.isEmpty { lines.append("Secrets: " + project.secrets.joined(separator: ", ")) }
            let last = TestRuns.result(for: project)
            if project.tests.isEmpty {
                lines.append("No tests yet. Add one with save_test, or write tests/<name>.json.")
            } else {
                lines.append("\(project.tests.count) tests:")
                for test in project.tests {
                    var parts = ["\(test.slug): \(test.name), \(test.steps.count) steps"]
                    if !test.platforms.isEmpty { parts.append(test.platforms.joined(separator: " and ")) }
                    if let outcome = last?.tests.first(where: { $0.slug == test.slug }) {
                        parts.append("last run \(outcome.status.rawValue)")
                    }
                    if !test.description.isEmpty { parts.append(test.description) }
                    lines.append("  " + parts.joined(separator: ". "))
                }
            }
            if let last {
                lines.append("Newest run: \(last.summaryLine) Call test_result for details.")
            }
            var data = project.json
            if case .object(var object) = data {
                object["last_run"] = last?.json ?? .null
                object["runs"] = .array(TestRuns.runs(for: project).map { .string($0.lastPathComponent) })
                data = .object(object)
            }
            return ToolOutput(text: lines.joined(separator: "\n"), data: data)
        case "save_test":
            let path = try args.string("project")
            let name = try args.string("name", maxLength: 200)
            guard let steps = args.value["steps"], !steps.isNull else { throw ToolFailure("steps must be an array of steps.") }
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw ToolFailure("project must be an absolute path on the Mac that runs Mobdev, like ~/code/my-app/mobdev.")
            }
            var folder = URL(fileURLWithPath: expanded).standardizedFileURL
            if folder.lastPathComponent == TestProject.fileName { folder = folder.deletingLastPathComponent() }
            let slug = args.has("file") ? TestProject.slug(try args.string("file")) : TestProject.slug(name)
            let file = folder.appendingPathComponent(TestProject.testsFolderName, isDirectory: true)
                .appendingPathComponent("\(slug).json")
            var value: [String: JSONValue] = ["name": .string(name), "steps": steps]
            if args.has("description") { value["description"] = .string(try args.string("description", maxLength: 1000)) }
            if args.has("platforms") { value["platforms"] = .array(try args.stringArray("platforms").map(JSONValue.string)) }
            var test = try TestCase.parse(.object(value), file: file)
            func check(_ steps: [Flow.Step]) throws {
                for step in steps {
                    if step.control == nil,
                        PhoneTools.definition(named: step.tool) == nil || PhoneTools.flowExcluded.contains(step.tool)
                    {
                        throw ToolFailure("Step \(step.summary) is not a tool a test can call.")
                    }
                    if !step.isSubflow { try check(step.children) }
                }
            }
            try check(test.steps)
            // A subflow that is not there fails now, not when the project loads next.
            try test.loadSubflows(project: folder)
            let files = FileManager.default
            var isFolder: ObjCBool = false
            if files.fileExists(atPath: folder.path, isDirectory: &isFolder), !isFolder.boolValue {
                throw ToolFailure("\(folder.path) is a file, not a project folder.")
            }
            for other in ["yaml", "yml"] {
                let maestro = file.deletingPathExtension().appendingPathExtension(other)
                if files.fileExists(atPath: maestro.path) {
                    throw ToolFailure("\(maestro.path) already is the test \(slug), a Maestro flow. Pass another file name.")
                }
            }
            do {
                try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let projectFile = folder.appendingPathComponent(TestProject.fileName)
                var created = false
                if !files.fileExists(atPath: projectFile.path) {
                    try TestProject(folder: folder, name: folder.lastPathComponent).encoded().write(to: projectFile)
                    created = true
                }
                let replaced = files.fileExists(atPath: file.path)
                try test.encoded().write(to: file, options: .atomic)
                let project = try TestProject.load(folder)
                var text = "\(replaced ? "Replaced" : "Saved") \(file.path) with \(test.steps.count) steps."
                if created {
                    text += " Created \(projectFile.path); add the app's bundle_id, builds and before_each there."
                }
                text += " The project has \(project.tests.count) tests. Run them with run_tests."
                return ToolOutput(text: text, data: ["file": .string(file.path), "project": project.json])
            } catch let failure as ToolFailure {
                throw failure
            } catch {
                throw ToolFailure("Could not write \(file.path): \(error.localizedDescription)")
            }
        case "test_result":
            let (project, _) = try TestProject.locate(try args.string("project"))
            let run = args.has("run") ? try args.string("run") : nil
            guard let result = TestRuns.result(for: project, run: run) else {
                let runs = TestRuns.runs(for: project).map(\.lastPathComponent)
                if let run {
                    throw ToolFailure(
                        "No run \"\(run)\" for \(project.name). Runs: \(runs.isEmpty ? "none" : runs.joined(separator: ", ")).")
                }
                throw ToolFailure("No results yet for \(project.name). Run its tests with run_tests.")
            }
            var lines = [result.text]
            for test in result.tests where test.status == .failed {
                lines.append("")
                lines.append("\(test.name):")
                lines += test.stepLines.map { "  " + $0 }
            }
            return ToolOutput(text: lines.joined(separator: "\n"), data: result.json)
        default:
            throw UnknownToolError(name: name)
        }
    }
}
