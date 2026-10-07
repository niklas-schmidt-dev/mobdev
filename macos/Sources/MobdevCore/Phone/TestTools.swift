import Foundation

/// `run_tests`: a project's tests on this device, with results kept in the project.
extension PhoneTools {
    static let testDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "run_tests", title: "Run tests",
            description:
                "Run a project's tests on this device: the active project's (see list_projects), or the folder, mobdev.json or single test file in project. Installs the project's build for the device, plays each test, keeps a video and, for failures, a screenshot, and writes results.json and junit.xml into the project's output/runs. Returns every test's result, the first failure's screen, and where the files are. Pass tests to run some by file name.",
            inputSchema: schema(
                [
                    "project": ProjectTools.projectArgument(orTestFile: true),
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
                ], screenshot: false),
            readOnly: false)
    ]

    func runTestsTool(_ args: Arguments, source: String) async throws -> ToolOutput {
        let (project, selected) = try ProjectTools.locate(args, projects: projects)
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

/// Tools about projects, which need no device: which there are, creating and opening one, a
/// project's tests, writing a test or a flow, and the newest results.
public enum ProjectTools {
    static func projectArgument(orTestFile: Bool = false) -> JSONValue {
        [
            "type": "string",
            "description": .string(
                "The project: its folder on the Mac that runs Mobdev (like ~/code/my-app/mobdev), its mobdev.json, the repository holding a mobdev/ folder, or a known project's name"
                    + (orTestFile ? ", or one test file" : "") + ". Default the active project (list_projects)"),
        ]
    }

    public static let definitions: [ToolDefinition] = {
        let project = projectArgument()
        let steps: JSONValue = ["type": "array", "description": "The steps, each a tool name or {\"tool\": {arguments}}"]
        return [
            ToolDefinition(
                name: "list_projects", title: "List projects",
                description:
                    "The projects Mobdev knows and which one is active. A project is a folder in an app's repository, usually mobdev/, with mobdev.json (the app, its builds, what every test starts with), tests/, flows/, baselines/, screenshots/ and maps/, versioned with the code, and output/ for runs, recordings and crawls, which git ignores. When you work in a repository with a mobdev/ folder, Mobdev uses that project for your calls. Without a project, outputs go to Mobdev's own folder.",
                inputSchema: PhoneTools.schema([:], screenshot: false), readOnly: true),
            ToolDefinition(
                name: "create_project", title: "Create project",
                description:
                    "Create a project and make it active: writes mobdev.json into path, usually the folder mobdev in the app's repository, such as ~/code/my-app/mobdev. Ask the user where before creating one.",
                inputSchema: PhoneTools.schema(
                    [
                        "path": ["type": "string", "description": "The new project's folder, inside an existing folder"],
                        "name": ["type": "string", "description": "The app's name; default the repository's folder name"],
                        "bundle_id": ["type": "string", "description": "The app's bundle ID or Android package"],
                        "builds": [
                            "type": "object", "additionalProperties": ["type": "string"],
                            "description":
                                "Builds by platform (iphone, simulator, android), relative to the project, e.g. {\"simulator\": \"../build/MyApp.app\"}",
                        ],
                    ], required: ["path"], screenshot: false),
                readOnly: false),
            ToolDefinition(
                name: "open_project", title: "Open project",
                description:
                    "Make a project the active one, adding it to Mobdev's list: what agents and the app save without a path goes there. Your own calls keep using the project of your working folder if it has one.",
                inputSchema: PhoneTools.schema(["project": project], required: ["project"], screenshot: false),
                readOnly: false),
            ToolDefinition(
                name: "list_tests", title: "List tests",
                description:
                    "The tests of a project: tests/*.json (or Maestro .yaml), each a flow with a name, description, platforms and steps, and mobdev.json with the app's bundle id, builds per platform, before_each steps, variables and secrets. Also the newest run's results. Use run_tests to run them and save_test to add one.",
                inputSchema: PhoneTools.schema(["project": projectArgument(orTestFile: true)], screenshot: false),
                readOnly: true),
            ToolDefinition(
                name: "save_test", title: "Save test",
                description:
                    "Write a test into a project's tests folder as <file name>.json, replacing one with the same file name. Steps are tool calls as in a flow, e.g. [{\"tap_element\": {\"id\": \"login\"}}, {\"wait_for_element\": {\"text\": \"Welcome\"}}]; prefer tap_element and wait_for_element over coordinates, end with a wait that proves the result, and write ${NAME} for a variable from mobdev.json. Control steps work as in run_flow: if, repeat, retry, run (a subflow next to the test or in the project folder), set and extract. Creates the project folder and a minimal mobdev.json when an explicit project folder is missing.",
                inputSchema: PhoneTools.schema(
                    [
                        "project": project,
                        "name": ["type": "string", "description": "The test's name, e.g. Sign in"],
                        "steps": steps,
                        "description": ["type": "string", "description": "What the test proves, one sentence"],
                        "platforms": [
                            "type": "array", "items": ["type": "string", "enum": .array(TestCase.platforms.map(JSONValue.string))],
                            "description": "Only on these platforms: ios, android. Default both",
                        ],
                        "file": ["type": "string", "description": "File name without .json, default from the name"],
                    ], required: ["name", "steps"], screenshot: false),
                readOnly: false),
            ToolDefinition(
                name: "save_flow", title: "Save flow",
                description:
                    "Write a flow into a project's flows folder as <file name>.json, replacing one with the same file name, to replay with run_flow (path) or from the app. Steps as in save_test.",
                inputSchema: PhoneTools.schema(
                    [
                        "project": project,
                        "name": ["type": "string", "description": "The flow's name, e.g. Open settings"],
                        "steps": steps,
                        "file": ["type": "string", "description": "File name without .json, default from the name"],
                    ], required: ["name", "steps"], screenshot: false),
                readOnly: false),
            ToolDefinition(
                name: "test_result", title: "Test result",
                description:
                    "The results of a project's newest run of run_tests or the app (or of the run named by run): every test with its status, failed step, message, screenshot and video paths on the Mac.",
                inputSchema: PhoneTools.schema(
                    [
                        "project": project,
                        "run": ["type": "string", "description": "A run from list_tests, e.g. 2026-10-07 14.03.22; default the newest"],
                    ], screenshot: false),
                readOnly: true),
        ]
    }()

    public static func isProjectTool(_ name: String) -> Bool { definitions.contains { $0.name == name } }

    /// The project (and selected tests) a test tool means: a test file or a folder in `project`,
    /// else the current project.
    static func locate(_ args: Arguments, projects: ProjectList) throws -> (TestProject, [String]) {
        if args.has("project") {
            let path = (try args.string("project") as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue {
                return try TestProject.locate(path)  // A test file or a mobdev.json.
            }
        }
        guard let folder = try projects.resolve(args, required: true) else { throw ToolFailure(projects.missingProject) }
        return try TestProject.locate(folder.path)
    }

    static func call(_ name: String, _ args: Arguments, projects: ProjectList) throws -> ToolOutput {
        switch name {
        case "list_projects": return listProjects(projects)
        case "create_project": return try createProject(args, projects: projects)
        case "open_project": return try openProject(args, projects: projects)
        case "list_tests": return try listTests(args, projects: projects)
        case "save_test": return try saveTest(args, projects: projects)
        case "save_flow": return try saveFlow(args, projects: projects)
        case "test_result": return try testResult(args, projects: projects)
        default: throw UnknownToolError(name: name)
        }
    }

    // MARK: Projects

    private static func listProjects(_ projects: ProjectList) -> ToolOutput {
        var known = projects.known
        let current = projects.current()
        if let current, !known.contains(current) { known.insert(current, at: 0) }
        guard !known.isEmpty else {
            return ToolOutput(
                text: "No projects yet. " + projects.missingProject,
                data: ["projects": [], "active": .null, "current": .null])
        }
        var lines: [String] = []
        var items: [JSONValue] = []
        for folder in known {
            let project = try? TestProject.load(folder)
            var parts = ["\(project?.name ?? folder.lastPathComponent): \(folder.path)"]
            if folder == projects.active { parts.append("active") }
            if folder == current, folder != projects.active { parts.append("used for your calls (your working folder)") }
            if let project {
                if let bundleID = project.app.bundleID { parts.append("app \(bundleID)") }
                parts.append("\(project.tests.count) tests")
                if let last = TestRuns.result(for: project) { parts.append("newest run: \(last.summaryLine)") }
            } else {
                parts.append(TestProject.isProject(folder) ? "mobdev.json cannot be read" : "folder missing")
            }
            lines.append(parts.joined(separator: ". "))
            items.append([
                "name": .string(project?.name ?? folder.lastPathComponent), "folder": .string(folder.path),
                "active": .bool(folder == projects.active), "current": .bool(folder == current),
                "exists": .bool(project != nil), "bundle_id": project?.app.bundleID.map(JSONValue.string) ?? .null,
                "tests": .number(Double(project?.tests.count ?? 0)),
            ])
        }
        return ToolOutput(
            text: lines.joined(separator: "\n"),
            data: [
                "projects": .array(items), "active": projects.active.map { .string($0.path) } ?? .null,
                "current": current.map { .string($0.path) } ?? .null,
            ])
    }

    private static func createProject(_ args: Arguments, projects: ProjectList) throws -> ToolOutput {
        let path = (try args.string("path") as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else {
            throw ToolFailure("path must be an absolute path on the Mac that runs Mobdev, like ~/code/my-app/mobdev.")
        }
        let folder = ProjectList.normalized(URL(fileURLWithPath: path))
        let project = try TestProject.create(
            at: folder, name: args.has("name") ? try args.string("name", maxLength: 200) : nil,
            bundleID: args.has("bundle_id") ? try args.string("bundle_id") : nil, builds: try args.stringDictionary("builds"))
        projects.add(folder, activate: true)
        return ToolOutput(
            text:
                "Created the project \(project.name) in \(folder.path) and made it active. Save tests with save_test and flows with save_flow; recordings, screenshots, crawls and runs land there too.",
            data: project.json)
    }

    private static func openProject(_ args: Arguments, projects: ProjectList) throws -> ToolOutput {
        guard let folder = try projects.resolve(args, required: true) else { throw ToolFailure(projects.missingProject) }
        guard TestProject.isProject(folder) else {
            throw ToolFailure("\(folder.path) has no mobdev.json. Create a project there with create_project.")
        }
        let project = try TestProject.load(folder)
        let previous = projects.active
        projects.add(folder, activate: true)
        var text = "\(project.name) (\(folder.path)) is the active project now"
        if let previous, previous != folder { text += ", instead of \(ProjectList.name(of: previous))" }
        text += "."
        if let pinned = ProjectScope.pinned, pinned != folder {
            text += " Your own calls keep using \(ProjectList.name(of: pinned)), the project of your working folder."
        }
        return ToolOutput(text: text, data: project.json)
    }

    // MARK: Tests and flows

    private static func listTests(_ args: Arguments, projects: ProjectList) throws -> ToolOutput {
        let (project, _) = try locate(args, projects: projects)
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
    }

    /// Steps a test or a saved flow may hold: tools a flow can call, at any depth.
    private static func checkSteps(_ steps: [Flow.Step], what: String) throws {
        for step in steps {
            if step.control == nil, PhoneTools.definition(named: step.tool) == nil || PhoneTools.flowExcluded.contains(step.tool) {
                throw ToolFailure("Step \(step.summary) is not a tool a \(what) can call.")
            }
            if !step.isSubflow { try checkSteps(step.children, what: what) }
        }
    }

    private static func saveTest(_ args: Arguments, projects: ProjectList) throws -> ToolOutput {
        guard let folder = try projects.resolve(args, required: true) else { throw ToolFailure(projects.missingProject) }
        let name = try args.string("name", maxLength: 200)
        guard let steps = args.value["steps"], !steps.isNull else { throw ToolFailure("steps must be an array of steps.") }
        let slug = args.has("file") ? TestProject.slug(try args.string("file")) : TestProject.slug(name)
        let file = folder.appendingPathComponent(TestProject.testsFolderName, isDirectory: true)
            .appendingPathComponent("\(slug).json")
        var value: [String: JSONValue] = ["name": .string(name), "steps": steps]
        if args.has("description") { value["description"] = .string(try args.string("description", maxLength: 1000)) }
        if args.has("platforms") { value["platforms"] = .array(try args.stringArray("platforms").map(JSONValue.string)) }
        var test = try TestCase.parse(.object(value), file: file)
        try checkSteps(test.steps, what: "test")
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
            if created { projects.add(folder, activate: false) }
            projects.notifyOutput(folder, nil)
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
    }

    private static func saveFlow(_ args: Arguments, projects: ProjectList) throws -> ToolOutput {
        guard let folder = try projects.resolve(args, required: true) else { throw ToolFailure(projects.missingProject) }
        guard TestProject.isProject(folder) else {
            throw ToolFailure("\(folder.path) has no mobdev.json. Create a project there with create_project first.")
        }
        let name = try args.string("name", maxLength: 200)
        guard let steps = args.value["steps"]?.arrayValue else { throw ToolFailure("steps must be an array of steps.") }
        let flowsFolder = folder.appendingPathComponent(TestProject.flowsFolderName, isDirectory: true)
        let slug = args.has("file") ? TestProject.slug(try args.string("file")) : TestProject.slug(name)
        let file = flowsFolder.appendingPathComponent("\(slug).json")
        var flow = try Flow.parse(["name": .string(name), "steps": .array(steps)])
        try checkSteps(flow.steps, what: "flow")
        try flow.loadSubflows(relativeTo: flowsFolder, also: [folder])
        do {
            try FileManager.default.createDirectory(at: flowsFolder, withIntermediateDirectories: true)
            let replaced = FileManager.default.fileExists(atPath: file.path)
            try Flow(name: name, steps: try Flow.parse(["name": .string(name), "steps": .array(steps)]).steps).encoded()
                .write(to: file, options: .atomic)
            projects.notifyOutput(folder, nil)
            return ToolOutput(
                text: "\(replaced ? "Replaced" : "Saved") \(file.path) with \(flow.steps.count) steps. Replay it with run_flow and path.",
                data: ["file": .string(file.path), "steps": .number(Double(flow.steps.count))])
        } catch {
            throw ToolFailure("Could not write \(file.path): \(error.localizedDescription)")
        }
    }

    private static func testResult(_ args: Arguments, projects: ProjectList) throws -> ToolOutput {
        let (project, _) = try locate(args, projects: projects)
        let run = args.has("run") ? try args.string("run") : nil
        guard let result = TestRuns.result(for: project, run: run) else {
            let runs = TestRuns.runs(for: project).map(\.lastPathComponent)
            if let run {
                throw ToolFailure("No run \"\(run)\" for \(project.name). Runs: \(runs.isEmpty ? "none" : runs.joined(separator: ", ")).")
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
    }
}
