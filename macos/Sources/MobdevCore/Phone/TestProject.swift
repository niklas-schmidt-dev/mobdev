import Foundation

/// The tests of one app, in a folder of its repository, as the app, the tools and `Mobdev test`
/// read them:
///
///     my-app/
///       mobdev.json
///       tests/
///         sign-in.json
///         checkout.yaml
///
/// `mobdev.json` names the app and what every test starts with. Every key is optional:
///
///     {
///       "name": "My App",
///       "app": {
///         "bundle_id": "com.example.MyApp",
///         "builds": {"simulator": "build/MyApp.app", "android": "build/app.apk"}
///       },
///       "before_each": [{"launch_app": {"bundle_id": "com.example.MyApp", "restart": true}}],
///       "variables": {"EMAIL": "me@example.com"},
///       "secrets": ["PASSWORD"]
///     }
///
/// A build is installed once per run on a device of its platform (`iphone`, `simulator` or
/// `android`), relative to the project folder. `before_each` runs before every test. `${NAME}` in
/// a step's strings is replaced by a variable; a run and the environment override the file. A
/// secret is a variable whose value comes from the run or the environment only and never appears
/// in results. A test is a flow in JSON or Maestro's YAML; its `run` steps name subflows next to
/// it or relative to the project folder.
public struct TestProject: Sendable, Equatable {
    public struct App: Sendable, Equatable {
        public var bundleID: String?
        /// By platform, relative to the project folder.
        public var builds: [String: String]

        public init(bundleID: String? = nil, builds: [String: String] = [:]) {
            self.bundleID = bundleID
            self.builds = builds
        }
    }

    public static let fileName = "mobdev.json"
    public static let testsFolderName = "tests"
    static let buildPlatforms = ["iphone", "simulator", "android"]
    static let keys: Set<String> = ["name", "app", "before_each", "variables", "secrets"]

    public var folder: URL
    public var name: String
    public var app: App
    public var beforeEach: [Flow.Step]
    public var variables: [String: String]
    public var secrets: [String]
    /// The tests in `tests/`, by file name.
    public var tests: [TestCase]

    public init(
        folder: URL, name: String, app: App = App(), beforeEach: [Flow.Step] = [], variables: [String: String] = [:],
        secrets: [String] = [], tests: [TestCase] = []
    ) {
        self.folder = folder
        self.name = name
        self.app = app
        self.beforeEach = beforeEach
        self.variables = variables
        self.secrets = secrets
        self.tests = tests
    }

    public var file: URL { folder.appendingPathComponent(Self.fileName) }
    public var testsFolder: URL { folder.appendingPathComponent(Self.testsFolderName, isDirectory: true) }

    /// The build to install on a device of this kind, as an absolute path.
    public func build(for kind: DeviceKind) -> URL? {
        guard let path = app.builds[Self.buildPlatform(kind)] else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: folder).standardizedFileURL
    }

    static func buildPlatform(_ kind: DeviceKind) -> String {
        switch kind {
        case .iPhone: "iphone"
        case .simulator: "simulator"
        case .android: "android"
        }
    }

    /// A test by its file name (without .json or .yaml) or its name.
    public func test(_ query: String) -> TestCase? {
        tests.first { $0.slug == query } ?? tests.first { $0.name == query }
            ?? tests.first { $0.slug == Self.slug(query) }
    }

    /// A file name for a test or project name: "Sign in (Pro)" becomes "sign-in-pro".
    public static func slug(_ name: String) -> String {
        let lowered = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "test" : String(collapsed.prefix(80))
    }

    // MARK: Reading

    /// The project in a folder: its `mobdev.json` when there is one, and every test in `tests/`.
    /// A folder with neither is not a project.
    public static func load(_ folder: URL) throws -> TestProject {
        let folder = folder.standardizedFileURL
        let files = FileManager.default
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw ToolFailure("\(folder.path) is not a folder.")
        }
        let file = folder.appendingPathComponent(fileName)
        var project: TestProject
        if files.fileExists(atPath: file.path) {
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                throw ToolFailure("Could not read \(file.path): \(error.localizedDescription)")
            }
            guard let value = try? JSONValue.parse(data) else { throw ToolFailure("\(file.path) is not JSON.") }
            project = try parse(value, folder: folder)
        } else {
            let testsFolder = folder.appendingPathComponent(testsFolderName)
            guard files.fileExists(atPath: testsFolder.path, isDirectory: &isFolder), isFolder.boolValue else {
                throw ToolFailure(
                    "\(folder.path) has no \(fileName) and no \(testsFolderName) folder. A project is a folder with tests/*.json or Maestro tests/*.yaml, and optionally \(fileName) naming the app."
                )
            }
            project = TestProject(folder: folder, name: folder.lastPathComponent)
        }
        project.tests = try loadTests(in: project.testsFolder)
        return project
    }

    static func loadTests(in folder: URL) throws -> [TestCase] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let project = folder.deletingLastPathComponent()
        let tests = try names.filter { TestCase.isTestFile($0) && !$0.hasPrefix(".") }.sorted()
            .map { try TestCase.load(folder.appendingPathComponent($0), project: project) }
        var seen: [String: String] = [:]
        for test in tests {
            if let other = seen[test.slug] {
                throw ToolFailure(
                    "\(other) and \(test.file.lastPathComponent) in \(folder.path) are both the test \(test.slug); rename one.")
            }
            seen[test.slug] = test.file.lastPathComponent
        }
        return tests
    }

    public static func parse(_ value: JSONValue, folder: URL) throws -> TestProject {
        guard let object = value.objectValue else { throw ToolFailure("\(fileName) must be a JSON object.") }
        if let unknown = object.keys.sorted().first(where: { !keys.contains($0) }) {
            throw ToolFailure(
                "\(fileName) has an unknown key \"\(unknown)\". Keys: \(keys.sorted().joined(separator: ", ")).")
        }
        var project = TestProject(folder: folder, name: object["name"]?.stringValue ?? folder.lastPathComponent)
        if project.name.isEmpty { project.name = folder.lastPathComponent }
        if let app = object["app"], !app.isNull {
            guard let fields = app.objectValue else { throw ToolFailure("app must be an object.") }
            if let id = fields["bundle_id"], !id.isNull {
                guard let string = id.stringValue, !string.isEmpty else { throw ToolFailure("app.bundle_id must be a string.") }
                project.app.bundleID = string
            }
            if let builds = fields["builds"], !builds.isNull {
                guard let map = builds.objectValue else { throw ToolFailure("app.builds must be an object.") }
                for (platform, path) in map {
                    guard buildPlatforms.contains(platform) else {
                        throw ToolFailure(
                            "app.builds has an unknown platform \"\(platform)\". Platforms: \(buildPlatforms.joined(separator: ", ")).")
                    }
                    guard let string = path.stringValue, !string.isEmpty else {
                        throw ToolFailure("app.builds.\(platform) must be a path.")
                    }
                    project.app.builds[platform] = string
                }
            }
        }
        if let before = object["before_each"], !before.isNull {
            guard before.arrayValue != nil else { throw ToolFailure("before_each must be an array of steps.") }
            do {
                var flow = try Flow.parse(before, name: "before_each")
                try flow.loadSubflows(relativeTo: folder)
                project.beforeEach = flow.steps
            } catch {
                throw ToolFailure("before_each: \(error)")
            }
        }
        if let variables = object["variables"], !variables.isNull {
            guard let map = variables.objectValue else { throw ToolFailure("variables must be an object of strings.") }
            for (name, value) in map {
                guard Variables.isName(name) else {
                    throw ToolFailure("\"\(name)\" is not a variable name: letters, digits and _, like EMAIL.")
                }
                guard let string = value.stringValue else { throw ToolFailure("variables.\(name) must be a string.") }
                project.variables[name] = string
            }
        }
        if let secrets = object["secrets"], !secrets.isNull {
            guard let items = secrets.arrayValue, let names = Optional(items.compactMap(\.stringValue)),
                names.count == items.count
            else { throw ToolFailure("secrets must be an array of variable names.") }
            for name in names where !Variables.isName(name) {
                throw ToolFailure("\"\(name)\" is not a variable name: letters, digits and _, like PASSWORD.")
            }
            project.secrets = names
        }
        return project
    }

    /// A path as agents and the command line pass it: a project folder, its `mobdev.json`, or one
    /// test file (then only that test is selected). A test file outside a project is a project of
    /// its own.
    public static func locate(_ path: String) throws -> (project: TestProject, tests: [String]) {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ToolFailure("project must be an absolute path on the Mac that runs Mobdev, like ~/code/my-app/mobdev.")
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            throw ToolFailure("\(url.path) does not exist on this Mac.")
        }
        if isFolder.boolValue { return (try load(url), []) }
        if url.lastPathComponent == fileName { return (try load(url.deletingLastPathComponent()), []) }
        guard TestCase.isTestFile(url.lastPathComponent) else {
            throw ToolFailure("\(url.path) is neither a project folder nor a test (.json, or Maestro's .yaml).")
        }
        let folder = url.deletingLastPathComponent()
        if folder.lastPathComponent == testsFolderName {
            let root = folder.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(fileName).path) {
                let test = try TestCase.load(url, project: root)
                return (try load(root), [test.slug])
            }
        }
        let test = try TestCase.load(url)
        return (TestProject(folder: folder, name: test.name, tests: [test]), [test.slug])
    }

    // MARK: Writing

    /// `mobdev.json`, with one step per line like a flow.
    public func encoded() -> Data {
        var lines = ["  \"name\": \(JSONValue.string(name).compactString)"]
        var appFields: [String] = []
        if let bundleID = app.bundleID { appFields.append("\"bundle_id\": \(JSONValue.string(bundleID).compactString)") }
        if !app.builds.isEmpty {
            appFields.append("\"builds\": \(JSONValue.object(app.builds.mapValues(JSONValue.string)).compactString)")
        }
        if !appFields.isEmpty { lines.append("  \"app\": {" + appFields.joined(separator: ", ") + "}") }
        if !beforeEach.isEmpty {
            lines.append("  \"before_each\": [\n" + Flow.encode(beforeEach, indent: "    ") + "\n  ]")
        }
        if !variables.isEmpty {
            lines.append("  \"variables\": \(JSONValue.object(variables.mapValues(JSONValue.string)).compactString)")
        }
        if !secrets.isEmpty { lines.append("  \"secrets\": \(JSONValue.array(secrets.map(JSONValue.string)).compactString)") }
        return Data(("{\n" + lines.joined(separator: ",\n") + "\n}\n").utf8)
    }

    public var json: JSONValue {
        var app: [String: JSONValue] = [:]
        if let bundleID = self.app.bundleID { app["bundle_id"] = .string(bundleID) }
        if !self.app.builds.isEmpty { app["builds"] = .object(self.app.builds.mapValues(JSONValue.string)) }
        return [
            "name": .string(name), "folder": .string(folder.path), "file": .string(file.path), "app": .object(app),
            "before_each": .array(beforeEach.map(\.json)),
            "variables": .object(variables.mapValues(JSONValue.string)),
            "secrets": .array(secrets.map(JSONValue.string)),
            "tests": .array(tests.map(\.json)),
        ]
    }
}

/// One test: a flow in `tests/`, with a description and the platforms it runs on. A Maestro flow
/// (.yaml) is a test too, named by its config's name.
///
///     {
///       "name": "Sign in",
///       "description": "A member signs in and sees the welcome screen.",
///       "platforms": ["ios"],
///       "steps": [
///         {"tap_element": {"id": "email"}},
///         {"type_text": {"text": "${EMAIL}", "submit": true}},
///         {"wait_for_element": {"text": "Welcome"}}
///       ]
///     }
public struct TestCase: Sendable, Equatable {
    public static let platforms = ["ios", "android"]
    static let keys: Set<String> = ["name", "description", "platforms", "steps"]

    public var file: URL
    /// The file name without .json or .yaml: what selects the test.
    public var slug: String
    public var name: String
    public var description: String
    /// "ios" (iPhones and simulators) and "android"; empty for every platform.
    public var platforms: [String]
    public var steps: [Flow.Step]

    public init(file: URL, name: String, description: String = "", platforms: [String] = [], steps: [Flow.Step]) {
        self.file = file
        self.slug = file.deletingPathExtension().lastPathComponent
        self.name = name
        self.description = description
        self.platforms = platforms
        self.steps = steps
    }

    /// The flow the runner plays: the steps, with a build next to the file found from anywhere.
    public var flow: Flow {
        var flow = Flow(name: name, steps: steps)
        flow.resolveInstallPaths(relativeTo: file.deletingLastPathComponent())
        return flow
    }

    public static func platformName(_ kind: DeviceKind) -> String { kind == .android ? "android" : "ios" }

    public func runs(on kind: DeviceKind) -> Bool { platforms.isEmpty || platforms.contains(Self.platformName(kind)) }

    /// A test file name: .json, or Maestro's .yaml and .yml.
    static func isTestFile(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasSuffix(".json") || Maestro.isMaestroFile(URL(fileURLWithPath: lowered))
    }

    /// A test file with its subflows loaded, from next to it and else from `project`.
    public static func load(_ url: URL, project: URL? = nil) throws -> TestCase {
        var test: TestCase
        if Maestro.isMaestroFile(url) {
            let flow = try Flow.read(url)
            test = TestCase(file: url, name: flow.name, steps: flow.steps)
        } else {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw ToolFailure("Could not read \(url.path): \(error.localizedDescription)")
            }
            guard let value = try? JSONValue.parse(data) else { throw ToolFailure("\(url.lastPathComponent) is not JSON.") }
            test = try parse(value, file: url)
        }
        try test.loadSubflows(project: project)
        return test
    }

    /// Loads the subflows its run steps name, next to the test and else in the project folder.
    mutating func loadSubflows(project: URL?) throws {
        var flow = Flow(name: name, steps: steps)
        do {
            try flow.loadSubflows(
                relativeTo: file.deletingLastPathComponent(), also: project.map { [$0] } ?? [],
                chain: [file.standardizedFileURL])
        } catch {
            throw ToolFailure("\(file.lastPathComponent): \(error)")
        }
        steps = flow.steps
    }

    public static func parse(_ value: JSONValue, file: URL) throws -> TestCase {
        let fallback = file.deletingPathExtension().lastPathComponent
        let flow: Flow
        do {
            flow = try Flow.parse(value, name: fallback)
        } catch {
            throw ToolFailure("\(file.lastPathComponent): \(error)")
        }
        var test = TestCase(file: file, name: flow.name, steps: flow.steps)
        guard let object = value.objectValue else { return test }
        if let unknown = object.keys.sorted().first(where: { !keys.contains($0) }) {
            throw ToolFailure(
                "\(file.lastPathComponent) has an unknown key \"\(unknown)\". Keys: \(keys.sorted().joined(separator: ", ")).")
        }
        if let description = object["description"], !description.isNull {
            guard let string = description.stringValue else {
                throw ToolFailure("\(file.lastPathComponent): description must be a string.")
            }
            test.description = string
        }
        if let platforms = object["platforms"], !platforms.isNull {
            guard let items = platforms.arrayValue, let names = Optional(items.compactMap(\.stringValue)),
                names.count == items.count
            else { throw ToolFailure("\(file.lastPathComponent): platforms must be an array like [\"ios\", \"android\"].") }
            for name in names where !Self.platforms.contains(name) {
                throw ToolFailure(
                    "\(file.lastPathComponent): unknown platform \"\(name)\". Platforms: \(Self.platforms.joined(separator: ", ")).")
            }
            test.platforms = names
        }
        return test
    }

    /// One step per line, like a flow, so a test reads and diffs well.
    public func encoded() -> Data {
        var lines = ["  \"name\": \(JSONValue.string(name).compactString)"]
        if !description.isEmpty { lines.append("  \"description\": \(JSONValue.string(description).compactString)") }
        if !platforms.isEmpty {
            lines.append("  \"platforms\": \(JSONValue.array(platforms.map(JSONValue.string)).compactString)")
        }
        let steps = Flow.encode(self.steps, indent: "    ")
        lines.append("  \"steps\": [\n" + steps + (self.steps.isEmpty ? "" : "\n") + "  ]")
        return Data(("{\n" + lines.joined(separator: ",\n") + "\n}\n").utf8)
    }

    public var json: JSONValue {
        [
            "name": .string(name), "slug": .string(slug), "file": .string(file.path),
            "description": .string(description), "platforms": .array(platforms.map(JSONValue.string)),
            "steps": .number(Double(steps.count)),
        ]
    }
}

/// `${NAME}` in a step's strings. In tests, values come from the run, then the environment, then
/// the project file; secrets are the names whose values stay out of every result. A flow's set and
/// extract steps add values while it runs.
struct Variables: Sendable {
    private(set) var values: [String: String]
    let secrets: Set<String>
    /// Where a variable that is not set can be set, for the error that says so.
    let hint: String

    static let flowHint =
        "Set it with a set or extract step before the step that uses it, or pass it with --var to Mobdev flow or in variables to run_flow."

    init(values: [String: String] = [:], secrets: [String] = [], hint: String = Variables.flowHint) {
        self.values = values
        self.secrets = Set(secrets)
        self.hint = hint
    }

    init(project: TestProject, overrides: [String: String], environment: [String: String]) {
        var values = project.variables
        for name in Set(project.variables.keys).union(project.secrets) {
            if let value = environment[name] { values[name] = value }
        }
        for (name, value) in overrides { values[name] = value }
        self.init(
            values: values, secrets: project.secrets,
            hint:
                "Set it under variables in \(TestProject.fileName) or with a set step, pass it in variables when running the tests, or export it."
        )
    }

    static func isName(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    mutating func set(_ name: String, _ value: String) { values[name] = value }

    /// The names of the variables a value uses, in order.
    static func references(in value: JSONValue) -> [String] {
        switch value {
        case .string(let text):
            var names: [String] = []
            var rest = text[...]
            while let start = rest.range(of: "${") {
                let after = rest[start.upperBound...]
                if let end = after.firstIndex(of: "}"), isName(String(after[..<end])) {
                    names.append(String(after[..<end]))
                    rest = after[after.index(after: end)...]
                } else {
                    rest = after
                }
            }
            return names
        case .array(let items): return items.flatMap(references)
        case .object(let object): return object.keys.sorted().flatMap { references(in: object[$0]!) }
        default: return []
        }
    }

    /// The error for a variable that is not set, saying where to set it.
    func unset(_ name: String) -> ToolFailure {
        let hint = secrets.contains(name)
            ? "Pass it in variables when running the tests, or export it before Mobdev test."
            : self.hint
        return ToolFailure("Variable \(name) is not set. \(hint)")
    }

    /// The step's arguments with every `${NAME}` replaced. A name without a value is an error
    /// that says where to set it.
    func substitute(_ value: JSONValue) throws -> JSONValue {
        switch value {
        case .string(let text): return .string(try substitute(text))
        case .array(let items): return .array(try items.map(substitute))
        case .object(let object): return .object(try object.mapValues(substitute))
        default: return value
        }
    }

    func substitute(_ text: String) throws -> String {
        guard text.contains("${") else { return text }
        var result = ""
        var rest = text[...]
        while let start = rest.range(of: "${") {
            result += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: "}"), Self.isName(String(after[..<end])) else {
                result += "${"
                rest = after
                continue
            }
            let name = String(after[..<end])
            guard let value = values[name] else { throw unset(name) }
            result += value
            rest = after[after.index(after: end)...]
        }
        return result + rest
    }

    /// Text with every secret's value replaced by its name.
    func redact(_ text: String) -> String {
        var text = text
        for name in secrets.sorted() {
            guard let value = values[name], !value.isEmpty else { continue }
            text = text.replacingOccurrences(of: value, with: "${\(name)}")
        }
        return text
    }
}
