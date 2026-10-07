import Foundation

/// A replayable list of tool calls for one device, saved as JSON:
///
///     {
///       "name": "Sign in",
///       "steps": [
///         {"launch_app": {"bundle_id": "com.example.app", "restart": true}},
///         {"tap_element": {"id": "email"}},
///         {"type_text": {"text": "me@example.com", "submit": true}},
///         {"wait_for_element": {"text": "Welcome"}},
///         "home"
///       ]
///     }
///
/// Each step is one tool with its arguments, exactly as an agent calls it; a bare name has none.
/// A plain array of steps is a flow too. Control steps, with keys no tool has, decide what runs:
///
///     {"if": {"visible": {"text": "Allow"}, "then": [...], "else": [...]}}
///     {"repeat": {"times": 3, "steps": [...]}}
///     {"repeat": {"while_visible": {"id": "next"}, "max": 10, "steps": [...]}}
///     {"retry": {"times": 2, "steps": [...]}}
///     {"run": "sign-in.json"}
///     {"set": {"EMAIL": "me@example.com"}}
///     {"extract": {"id": "total", "into": "TOTAL"}}
///
/// `${NAME}` in a step's strings is a variable from set or extract, and in tests also from the
/// project. Any step may carry `"optional": true` next to its key: its failure is reported, and the
/// flow goes on. Maestro's YAML flows load too (see `Maestro`).
public struct Flow: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        /// The tool, or for a control step its key: if, repeat, retry, run, set or extract.
        public var tool: String
        public var arguments: [String: JSONValue]
        /// What a control step does; nil for a tool call.
        public var control: Control?
        /// A failure of this step is reported, and the flow goes on.
        public var optional: Bool

        public init(_ tool: String, _ arguments: [String: JSONValue] = [:], optional: Bool = false) {
            self.tool = tool
            self.arguments = arguments
            self.control = nil
            self.optional = optional
        }

        public init(_ control: Control, optional: Bool = false) {
            self.tool = control.key
            self.arguments = [:]
            self.control = control
            self.optional = optional
        }

        /// The step as written in a flow file.
        public var json: JSONValue {
            var object: [String: JSONValue]
            if let control {
                object = [control.key: control.json]
            } else {
                if arguments.isEmpty, !optional { return .string(tool) }
                object = [tool: .object(arguments)]
            }
            if optional { object["optional"] = true }
            return .object(object)
        }

        /// "tap_element {"id":"email"}": the step on one line, as results and the window show it.
        public var summary: String {
            let text = control?.summary ?? (arguments.isEmpty ? tool : "\(tool) \(JSONValue.object(arguments).compactString)")
            return optional ? text + " (optional)" : text
        }

        /// The steps inside a control step, and those of a loaded subflow.
        public var children: [Step] {
            switch control {
            case .branch(_, let then, let otherwise)?: then + otherwise
            case .loop(_, let steps)?, .retry(_, let steps)?: steps
            case .subflow(_, let flow)?: flow?.steps ?? []
            default: []
            }
        }
    }

    /// An element by its identifier, or by its label (or, on a device without a UI tree, its text).
    public struct Target: Sendable, Equatable {
        public var id: String?
        public var text: String?

        public init(id: String? = nil, text: String? = nil) {
            self.id = id
            self.text = text
        }

        var json: JSONValue { id.map { ["id": .string($0)] } ?? ["text": .string(text ?? "")] }
    }

    /// What `if` decides by.
    public enum Condition: Sendable, Equatable {
        /// The element or text is on screen now.
        case visible(Target)
        case notVisible(Target)
        /// The device is "ios" (iPhones and simulators) or "android".
        case platform(String)
    }

    /// How often `repeat` runs its steps.
    public enum Loop: Sendable, Equatable {
        case times(Int)
        /// While the element is on screen, at most `max` rounds.
        case whileVisible(Target, max: Int)
        /// Until the element is on screen, at most `max` rounds.
        case untilVisible(Target, max: Int)
    }

    /// Reads an element of the UI tree into a variable.
    public struct Extraction: Sendable, Equatable {
        public var target: Target
        public var into: String
        /// "value" or "label"; nil reads the value, or the label of an element without one.
        public var from: String?
        public var index: Int?
        /// Seconds to wait for the element, default 5.
        public var timeout: Double?

        public init(target: Target, into: String, from: String? = nil, index: Int? = nil, timeout: Double? = nil) {
            self.target = target
            self.into = into
            self.from = from
            self.index = index
            self.timeout = timeout
        }
    }

    /// What a control step does.
    public indirect enum Control: Sendable, Equatable {
        case branch(Condition, then: [Step], else: [Step])
        case loop(Loop, steps: [Step])
        /// Runs the steps again from the first, up to `times` more times, while one fails.
        case retry(times: Int, steps: [Step])
        /// Another flow file, as written; `flow` once it is loaded.
        case subflow(path: String, flow: Flow?)
        case set([String: String])
        case extract(Extraction)

        /// The key the step has in a flow file.
        public var key: String {
            switch self {
            case .branch: "if"
            case .loop: "repeat"
            case .retry: "retry"
            case .subflow: "run"
            case .set: "set"
            case .extract: "extract"
            }
        }

        var json: JSONValue {
            switch self {
            case .branch(let condition, let then, let otherwise):
                var object = Flow.conditionJSON(condition)
                object["then"] = .array(then.map(\.json))
                if !otherwise.isEmpty { object["else"] = .array(otherwise.map(\.json)) }
                return .object(object)
            case .loop(let loop, let steps):
                var object = Flow.loopJSON(loop)
                object["steps"] = .array(steps.map(\.json))
                return .object(object)
            case .retry(let times, let steps):
                return ["times": .number(Double(times)), "steps": .array(steps.map(\.json))]
            case .subflow(let path, _):
                return .string(path)
            case .set(let values):
                return .object(values.mapValues(JSONValue.string))
            case .extract(let extraction):
                var object = extraction.target.json.objectValue ?? [:]
                object["into"] = .string(extraction.into)
                if let from = extraction.from { object["from"] = .string(from) }
                if let index = extraction.index { object["index"] = .number(Double(index)) }
                if let timeout = extraction.timeout { object["timeout"] = .number(timeout) }
                return .object(object)
            }
        }

        var summary: String {
            switch self {
            case .branch(let condition, _, _):
                switch condition {
                case .visible(let target): "if visible \(target.json.compactString)"
                case .notVisible(let target): "if not visible \(target.json.compactString)"
                case .platform(let platform): "if platform \(platform)"
                }
            case .loop(let loop, _):
                switch loop {
                case .times(let times): "repeat \(times) times"
                case .whileVisible(let target, let max): "repeat while visible \(target.json.compactString), at most \(max) times"
                case .untilVisible(let target, let max): "repeat until visible \(target.json.compactString), at most \(max) times"
                }
            case .retry(let times, _): "retry up to \(times) times"
            case .subflow(let path, _): "run \(path)"
            case .set(let values): "set \(JSONValue.object(values.mapValues(JSONValue.string)).compactString)"
            case .extract(let extraction): "extract \(extraction.target.json.compactString) into \(extraction.into)"
            }
        }
    }

    public var name: String
    public var steps: [Step]
    /// What a conversion from Maestro left out or changed, for whoever runs the flow.
    public var notes: [String]

    public init(name: String, steps: [Step], notes: [String] = []) {
        self.name = name
        self.steps = steps
        self.notes = notes
    }

    /// At most this many steps, counting those inside control steps and subflows, so a mistaken
    /// file cannot keep a device busy for hours.
    public static let maxSteps = 500
    /// At most this many steps run, counting every round of a repeat and every retry.
    public static let maxRunSteps = 2000
    /// Rounds of `repeat` and retries, so a loop always ends.
    static let maxRounds = 100
    static let defaultMaxRounds = 20
    static let maxRetries = 10
    /// How deep subflows may run subflows.
    static let maxSubflowDepth = 5
    /// The keys of control steps. No tool may have one of these names.
    public static let controlKeys: Set<String> = ["if", "repeat", "retry", "run", "set", "extract"]

    /// Every step, nested ones and those of loaded subflows included.
    var stepCount: Int { Self.count(steps) }

    static func count(_ steps: [Step]) -> Int { steps.reduce(0) { $0 + 1 + count($1.children) } }

    // MARK: Reading

    public static func parse(_ value: JSONValue, name fallback: String = "Flow") throws -> Flow {
        let list: [JSONValue]
        var name = fallback
        switch value {
        case .array(let items): list = items
        case .object(let object):
            guard let items = object["steps"]?.arrayValue else { throw ToolFailure("A flow needs a steps array.") }
            list = items
            if let given = object["name"]?.stringValue, !given.isEmpty { name = given }
        default: throw ToolFailure("A flow is an object with steps, or an array of steps.")
        }
        let flow = Flow(name: name, steps: try parseSteps(list, number: { "\($0 + 1)" }))
        try flow.checkSize()
        return flow
    }

    func checkSize() throws {
        guard stepCount <= Self.maxSteps else {
            throw ToolFailure(
                "A flow has at most \(Self.maxSteps) steps, counting those inside if, repeat and retry and in subflows; this one has \(stepCount)."
            )
        }
    }

    static func parseSteps(_ list: [JSONValue], number: (Int) -> String) throws -> [Step] {
        try list.enumerated().map { index, item in try parseStep(item, number: number(index)) }
    }

    static func parseStep(_ item: JSONValue, number: String) throws -> Step {
        switch item {
        case .string(let tool):
            guard !controlKeys.contains(tool) else {
                throw ToolFailure("Step \(number): \(tool) needs its settings, like \(example(tool)).")
            }
            return Step(tool)
        case .object(var object):
            var optional = false
            if object.count == 2, let flag = object["optional"] {
                guard let value = flag.boolValue else { throw ToolFailure("Step \(number): optional must be true or false.") }
                optional = value
                object["optional"] = nil
            }
            guard object.count == 1, let (key, value) = object.first, key != "optional" else {
                throw ToolFailure(
                    "Step \(number) must be a tool name or an object with one tool, like {\"tap_element\": {\"id\": \"save\"}}, and optionally \"optional\": true."
                )
            }
            if controlKeys.contains(key) {
                return Step(try parseControl(key, value, number: number), optional: optional)
            }
            switch value {
            case .object(let arguments): return Step(key, arguments, optional: optional)
            case .null: return Step(key, optional: optional)
            default: throw ToolFailure("Step \(number): the arguments of \(key) must be an object.")
            }
        default:
            throw ToolFailure(
                "Step \(number) must be a tool name or an object with one tool, like {\"tap_element\": {\"id\": \"save\"}}.")
        }
    }

    static func example(_ key: String) -> String {
        switch key {
        case "if": #"{"if": {"visible": {"text": "Allow"}, "then": [{"tap_element": {"text": "Allow"}}]}}"#
        case "repeat": #"{"repeat": {"times": 3, "steps": ["home"]}}"#
        case "retry": #"{"retry": {"times": 2, "steps": [{"tap_element": {"id": "reload"}}]}}"#
        case "run": #"{"run": "sign-in.json"}"#
        case "set": #"{"set": {"EMAIL": "me@example.com"}}"#
        default: #"{"extract": {"id": "total", "into": "TOTAL"}}"#
        }
    }

    static func parseControl(_ key: String, _ value: JSONValue, number: String) throws -> Control {
        func failure(_ message: String) -> ToolFailure { ToolFailure("Step \(number): \(message)") }
        switch key {
        case "run":
            guard let path = value.stringValue, !path.isEmpty else {
                throw failure("run takes the path of a flow file, like \(example(key)).")
            }
            return .subflow(path: path, flow: nil)
        case "set":
            guard let object = value.objectValue, !object.isEmpty else {
                throw failure("set takes variables and their values, like \(example(key)).")
            }
            var values: [String: String] = [:]
            for (name, item) in object {
                guard Variables.isName(name) else {
                    throw failure("\"\(name)\" is not a variable name: letters, digits and _, like EMAIL.")
                }
                switch item {
                case .string(let text): values[name] = text
                case .number, .bool: values[name] = item.compactString
                default: throw failure("the value of \(name) must be text.")
                }
            }
            return .set(values)
        default:
            break
        }
        guard let object = value.objectValue else { throw failure("\(key) takes an object, like \(example(key)).") }
        let fields = Fields(object: object, context: "Step \(number): \(key)")
        switch key {
        case "if":
            try fields.allow(["visible", "not_visible", "platform", "then", "else"])
            let conditions = ["visible", "not_visible", "platform"].filter { object[$0] != nil }
            guard conditions.count == 1 else {
                throw failure("if takes one of visible, not_visible and platform, like \(example(key)).")
            }
            let condition: Condition
            switch conditions[0] {
            case "visible": condition = .visible(try fields.target("visible"))
            case "not_visible": condition = .notVisible(try fields.target("not_visible"))
            default:
                guard let platform = object["platform"]?.stringValue, TestCase.platforms.contains(platform) else {
                    throw failure("platform must be \(TestCase.platforms.map { "\"\($0)\"" }.joined(separator: " or ")).")
                }
                condition = .platform(platform)
            }
            guard object["then"] != nil else { throw failure("if needs then: the steps to run when it holds.") }
            let then = try fields.steps("then", number: { "\(number).\($0 + 1)" })
            let offset = then.count
            let otherwise = object["else"] == nil ? [] : try fields.steps("else", number: { "\(number).\(offset + $0 + 1)" })
            return .branch(condition, then: then, else: otherwise)
        case "repeat":
            try fields.allow(["times", "while_visible", "until_visible", "max", "steps"])
            let modes = ["times", "while_visible", "until_visible"].filter { object[$0] != nil }
            guard modes.count == 1 else {
                throw failure(
                    "repeat takes one of times, while_visible and until_visible, like \(example(key)) or {\"repeat\": {\"until_visible\": {\"text\": \"Done\"}, \"max\": 10, \"steps\": [...]}}."
                )
            }
            let loop: Loop
            if modes[0] == "times" {
                guard object["max"] == nil else { throw failure("max goes with while_visible and until_visible; times is the count.") }
                loop = .times(try fields.int("times", in: 1...maxRounds) ?? 1)
            } else {
                let max = try fields.int("max", in: 1...maxRounds) ?? defaultMaxRounds
                let target = try fields.target(modes[0])
                loop = modes[0] == "while_visible" ? .whileVisible(target, max: max) : .untilVisible(target, max: max)
            }
            return .loop(loop, steps: try fields.steps("steps", number: { "\(number).\($0 + 1)" }, required: true))
        case "retry":
            try fields.allow(["times", "steps"])
            let times = try fields.int("times", in: 1...maxRetries) ?? 1
            return .retry(times: times, steps: try fields.steps("steps", number: { "\(number).\($0 + 1)" }, required: true))
        default:
            try fields.allow(["id", "text", "into", "from", "index", "timeout"])
            let target = try fields.target(nil)
            guard let into = object["into"]?.stringValue, Variables.isName(into) else {
                throw failure("extract needs into: the name of a variable, like TOTAL.")
            }
            var from: String?
            if let given = object["from"] {
                guard let text = given.stringValue, ["value", "label"].contains(text) else {
                    throw failure("from must be \"value\" or \"label\".")
                }
                from = text
            }
            let index = try fields.int("index", in: 0...999)
            var timeout: Double?
            if let given = object["timeout"] {
                guard let seconds = given.doubleValue, (0...60).contains(seconds) else {
                    throw failure("timeout must be seconds from 0 to 60.")
                }
                timeout = seconds
            }
            return .extract(Extraction(target: target, into: into, from: from, index: index, timeout: timeout))
        }
    }

    /// The fields of a control step's object, with errors that say which step.
    private struct Fields {
        let object: [String: JSONValue]
        let context: String

        func allow(_ keys: Set<String>) throws {
            if let unknown = object.keys.sorted().first(where: { !keys.contains($0) }) {
                throw ToolFailure("\(context) has an unknown key \"\(unknown)\". Keys: \(keys.sorted().joined(separator: ", ")).")
            }
        }

        func int(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
            guard let value = object[key] else { return nil }
            guard let number = value.doubleValue, number.rounded() == number, range.contains(Int(number)) else {
                throw ToolFailure("\(context): \(key) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
            }
            return Int(number)
        }

        func steps(_ key: String, number: (Int) -> String, required: Bool = false) throws -> [Step] {
            guard let list = object[key]?.arrayValue else { throw ToolFailure("\(context): \(key) must be a list of steps.") }
            guard !required || !list.isEmpty else { throw ToolFailure("\(context): \(key) needs at least one step.") }
            return try Flow.parseSteps(list, number: number)
        }

        /// {"id": …} or {"text": …}, a bare string for text; with `key` nil, from the object itself.
        func target(_ key: String?) throws -> Target {
            let value: JSONValue = key.map { object[$0] ?? .null } ?? .object(object)
            let what = key ?? "it"
            if let text = value.stringValue, !text.isEmpty { return Target(text: text) }
            if let fields = value.objectValue {
                let id = fields["id"]?.stringValue
                let text = fields["text"]?.stringValue
                if let id, !id.isEmpty, fields["text"] == nil { return Target(id: id) }
                if let text, !text.isEmpty, fields["id"] == nil { return Target(text: text) }
            }
            throw ToolFailure("\(context): \(what) needs an id or a text, like {\"id\": \"save\"} or {\"text\": \"Save\"}, not both.")
        }
    }

    static func conditionJSON(_ condition: Condition) -> [String: JSONValue] {
        switch condition {
        case .visible(let target): ["visible": target.json]
        case .notVisible(let target): ["not_visible": target.json]
        case .platform(let platform): ["platform": .string(platform)]
        }
    }

    static func loopJSON(_ loop: Loop) -> [String: JSONValue] {
        switch loop {
        case .times(let times): ["times": .number(Double(times))]
        case .whileVisible(let target, let max): ["while_visible": target.json, "max": .number(Double(max))]
        case .untilVisible(let target, let max): ["until_visible": target.json, "max": .number(Double(max))]
        }
    }

    /// A flow file: JSON, or Maestro's YAML (.yaml, .yml), with builds next to it found from
    /// anywhere and its subflows loaded, relative to the file and then to `folders`.
    public static func load(_ url: URL, folders: [URL] = []) throws -> Flow {
        var flow = try read(url)
        try flow.loadSubflows(relativeTo: url.deletingLastPathComponent(), also: folders, chain: [url.standardizedFileURL])
        return flow
    }

    /// A flow file as written, without loading its subflows.
    static func read(_ url: URL) throws -> Flow {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ToolFailure("Could not read \(url.path): \(error.localizedDescription)")
        }
        var flow: Flow
        if Maestro.isMaestroFile(url) {
            flow = try Maestro.flow(from: String(decoding: data, as: UTF8.self), file: url)
        } else {
            guard let value = try? JSONValue.parse(data) else { throw ToolFailure("\(url.lastPathComponent) is not JSON.") }
            flow = try parse(value, name: url.deletingPathExtension().lastPathComponent)
        }
        flow.resolveInstallPaths(relativeTo: url.deletingLastPathComponent())
        return flow
    }

    /// A build next to the flow file is found from wherever the flow runs: the app, an agent, CI.
    mutating func resolveInstallPaths(relativeTo folder: URL) {
        steps = Self.resolvingInstallPaths(steps, relativeTo: folder)
    }

    static func resolvingInstallPaths(_ steps: [Step], relativeTo folder: URL) -> [Step] {
        steps.map { step in
            var step = step
            if step.tool == "install_app", step.control == nil, let path = step.arguments["path"]?.stringValue,
                !path.hasPrefix("/"), !path.hasPrefix("~")
            {
                step.arguments["path"] = .string(folder.appendingPathComponent(path).standardizedFileURL.path)
            }
            // A subflow's builds are relative to its own file, which reading it took care of.
            if !step.isSubflow { step.mapChildren { resolvingInstallPaths($0, relativeTo: folder) } }
            return step
        }
    }

    /// Loads the flows that run steps name: a path relative to `folder` (the file that names it),
    /// else to one of `folders`, or an absolute one. Without a folder, only absolute paths work.
    mutating func loadSubflows(relativeTo folder: URL?, also folders: [URL] = [], chain: [URL] = []) throws {
        steps = try Self.loadingSubflows(steps, number: { "\($0 + 1)" }, folder: folder, folders: folders, chain: chain)
        try checkSize()
    }

    static func loadingSubflows(
        _ steps: [Step], number: (Int) -> String, folder: URL?, folders: [URL], chain: [URL]
    ) throws -> [Step] {
        try steps.enumerated().map { index, step in
            var step = step
            let stepNumber = number(index)
            switch step.control {
            case .subflow(let path, nil)?:
                let url = try subflowURL(path, number: stepNumber, folder: folder, folders: folders)
                if let start = chain.firstIndex(of: url) {
                    let loop = (chain[start...] + [url]).map(\.lastPathComponent).joined(separator: " → ")
                    throw ToolFailure("Step \(stepNumber): \(path) runs itself in a loop: \(loop).")
                }
                guard chain.count < maxSubflowDepth else {
                    throw ToolFailure("Step \(stepNumber): subflows may run other subflows at most \(maxSubflowDepth) deep.")
                }
                var flow = try read(url)
                flow.steps = try loadingSubflows(
                    flow.steps, number: { "\(stepNumber).\($0 + 1)" }, folder: url.deletingLastPathComponent(),
                    folders: folders, chain: chain + [url])
                step.control = .subflow(path: path, flow: flow)
            case .subflow?, nil:
                break
            default:
                // Numbered as written: else's steps count on from then's.
                var offset = 0
                try step.mapChildren { children in
                    let start = offset
                    offset += children.count
                    return try loadingSubflows(
                        children, number: { "\(stepNumber).\(start + $0 + 1)" }, folder: folder, folders: folders,
                        chain: chain)
                }
            }
            return step
        }
    }

    static func subflowURL(_ path: String, number: String, folder: URL?, folders: [URL]) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolFailure("Step \(number): there is no flow \(url.path).")
            }
            return url
        }
        guard let folder else {
            throw ToolFailure(
                "Step \(number): run \(path) needs an absolute path here, since the steps are not in a file.")
        }
        let candidates = ([folder] + folders).map { $0.appendingPathComponent(path).standardizedFileURL }
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            let places = candidates.map { $0.deletingLastPathComponent().path }
            throw ToolFailure("Step \(number): there is no flow \(path) in \(places.joined(separator: " or ")).")
        }
        return found
    }

    // MARK: Variables

    /// The first step that uses a variable neither known nor set by a set or extract step anywhere
    /// in the steps, with the error that says so. Checked before a run, so a typo in the last step
    /// does not leave a half-run flow.
    static func unsetVariable(in steps: [Step], variables: Variables) -> (index: Int, error: ToolFailure)? {
        var known = Set(variables.values.keys)
        func define(_ steps: [Step]) {
            for step in steps {
                switch step.control {
                case .set(let values)?: known.formUnion(values.keys)
                case .extract(let extraction)?: known.insert(extraction.into)
                default: break
                }
                define(step.children)
            }
        }
        define(steps)
        func used(_ step: Step) -> [String] {
            var names: [String]
            switch step.control {
            case nil: names = Variables.references(in: .object(step.arguments))
            case .branch(.visible(let target), _, _)?, .branch(.notVisible(let target), _, _)?,
                .loop(.whileVisible(let target, _), _)?, .loop(.untilVisible(let target, _), _)?:
                names = Variables.references(in: target.json)
            case .set(let values)?: names = values.values.flatMap { Variables.references(in: .string($0)) }
            case .extract(let extraction)?: names = Variables.references(in: extraction.target.json)
            default: names = []
            }
            return names + step.children.flatMap(used)
        }
        for (index, step) in steps.enumerated() {
            if let name = used(step).first(where: { !known.contains($0) }) {
                return (index, variables.unset(name))
            }
        }
        return nil
    }

    // MARK: Writing

    /// One step per line, so a flow reads and diffs well.
    public func encoded() -> Data {
        let lines = Self.encode(steps, indent: "    ")
        let text = "{\n  \"name\": \(JSONValue.string(name).compactString),\n  \"steps\": [\n"
            + lines + (steps.isEmpty ? "" : "\n") + "  ]\n}\n"
        return Data(text.utf8)
    }

    /// The steps as the lines of a JSON array, without the brackets: one line per tool call, and
    /// the steps inside a control step on lines of their own, indented below it.
    static func encode(_ steps: [Step], indent: String) -> String {
        steps.map { $0.lines(indent: indent).joined(separator: "\n") }.joined(separator: ",\n")
    }
}

extension Flow.Step {
    var isSubflow: Bool {
        if case .subflow? = control { return true }
        return false
    }

    /// Applies `transform` to every list of steps written inside this control step, in order.
    mutating func mapChildren(_ transform: ([Flow.Step]) throws -> [Flow.Step]) rethrows {
        switch control {
        case .branch(let condition, let then, let otherwise)?:
            let newThen = try transform(then)
            control = .branch(condition, then: newThen, else: otherwise.isEmpty ? [] : try transform(otherwise))
        case .loop(let loop, let steps)?: control = .loop(loop, steps: try transform(steps))
        case .retry(let times, let steps)?: control = .retry(times: times, steps: try transform(steps))
        default: break
        }
    }

    /// The step's JSON lines for `Flow.encode`.
    func lines(indent: String) -> [String] {
        let close = optional ? "},\"optional\":true}" : "}}"
        func block(_ head: [String: JSONValue], _ sections: [(String, [Flow.Step])]) -> [String] {
            // The head's fields first, compact, the condition before max, then each list of steps
            // one per line.
            let order = ["visible", "not_visible", "platform", "while_visible", "until_visible", "times", "max"]
            let fields = head.keys.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
                .map { "\(JSONValue.string($0).compactString):\(head[$0]!.compactString)," }.joined()
            var lines = ["\(indent){\"\(tool)\":{\(fields)\"\(sections[0].0)\":["]
            for (index, section) in sections.enumerated() {
                if index > 0 { lines.append("\(indent)],\"\(section.0)\":[") }
                let inner = Flow.encode(section.1, indent: indent + "  ")
                if !inner.isEmpty { lines.append(inner) }
            }
            lines.append("\(indent)]" + close)
            return lines
        }
        switch control {
        case .branch(let condition, let then, let otherwise)?:
            return block(Flow.conditionJSON(condition), [("then", then)] + (otherwise.isEmpty ? [] : [("else", otherwise)]))
        case .loop(let loop, let steps)?:
            return block(Flow.loopJSON(loop), [("steps", steps)])
        case .retry(let times, let steps)?:
            return block(["times": .number(Double(times))], [("steps", steps)])
        case nil where !arguments.isEmpty || optional:
            // The tool before "optional", which sorted keys would put first.
            return [
                "\(indent){\(JSONValue.string(tool).compactString):\(JSONValue.object(arguments).compactString)"
                    + (optional ? ",\"optional\":true}" : "}")
            ]
        default:
            return [indent + json.compactString]
        }
    }
}

// MARK: - Video

extension Flow {
    /// The file `run_flow` writes its video to: an absolute .mp4 path in a folder that exists.
    static func videoURL(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ToolFailure("video must be an absolute path on the Mac, like /tmp/run.mp4.")
        }
        let url = URL(fileURLWithPath: expanded)
        guard url.pathExtension.lowercased() == "mp4" else { throw ToolFailure("video must be a path ending in .mp4.") }
        var isFolder: ObjCBool = false
        let folder = url.deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            throw ToolFailure("The folder \(folder) does not exist; create it first.")
        }
        guard !FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) || !isFolder.boolValue else {
            throw ToolFailure("\(url.path) is a folder.")
        }
        return url
    }

    /// Runs a flow while recording `phone`'s screen to `video`, and says in the result where the
    /// video went. Without `video` it only runs the flow.
    public static func recording(
        _ phone: any PhoneBackend, to video: URL?, _ run: () async throws -> FlowResult
    ) async rethrows -> FlowResult {
        guard let video else { return try await run() }
        let recorder = ScreenRecorder.start(to: video) { phone.frame() }
        var result: FlowResult
        do {
            result = try await run()
        } catch {
            _ = try? await recorder.finish()
            try? FileManager.default.removeItem(at: video)
            throw error
        }
        do {
            result.video = try await recorder.finish()
        } catch {
            result.videoProblem = String(describing: error)
        }
        return result
    }
}

public struct FlowResult: Sendable {
    public struct StepResult: Sendable {
        public var step: Flow.Step
        public var text: String
        public var passed: Bool
        public var seconds: TimeInterval
        /// Where the step is written: "3", or "3.2" for the second step inside step 3. Empty for
        /// results made without one, which then count by position.
        public var number: String = ""
        /// "round 2" or "attempt 2" when a repeat or retry ran the step again.
        public var round: String? = nil
        /// It failed, and the flow went on: the step was optional, or its retry ran the steps again.
        public var tolerated: Bool = false

        /// How deep the step is nested: 0 for the flow's own steps.
        public var depth: Int { number.filter { $0 == "." }.count }

        /// "✓", "✗", or "–" for a failure the flow went on after.
        public var mark: String { passed ? "✓" : tolerated ? "–" : "✗" }

        /// "3.2. tap_element {…} (round 2)": the step's number, what it is and which round.
        public func label(_ fallback: Int) -> String {
            "\(number.isEmpty ? String(fallback) : number). \(step.summary)" + (round.map { " (\($0))" } ?? "")
        }
    }

    public var flow: Flow
    /// Every step that ran, in order: a control step before the steps inside it.
    public var steps: [StepResult]
    public var seconds: TimeInterval
    /// The run's video, when one was asked for and written.
    public var video: ScreenRecording?
    /// Why there is no video although one was asked for.
    public var videoProblem: String?

    /// The step that stopped the flow: the innermost that failed, after which nothing else ran.
    public var failure: (index: Int, result: StepResult)? {
        guard let index = steps.lastIndex(where: { !$0.passed && !$0.tolerated }) else { return nil }
        return (index, steps[index])
    }

    /// The failed step's number as the window and results show it.
    public var failedNumber: String? {
        failure.map { $0.result.number.isEmpty ? String($0.index + 1) : $0.result.number }
    }

    public var passed: Bool {
        let ran = steps.filter { $0.depth == 0 }.count
        return ran >= flow.steps.count && failure == nil
    }

    public var text: String {
        let total = flow.steps.count
        let lines = steps.enumerated().map { index, result in
            let first = result.text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let shown = result.passed ? first : result.text
            return String(repeating: "  ", count: result.depth) + "\(result.mark) \(result.label(index + 1)): \(shown)"
        }
        let head =
            passed
            ? "Flow \"\(flow.name)\" passed: \(steps.count) steps in \(String(format: "%.1f", seconds)) s."
            : "Flow \"\(flow.name)\" failed at step \(failedNumber ?? String(steps.count)) of \(total): \(failure.map { $0.result.step.summary + ($0.result.round.map { " (\($0))" } ?? "") } ?? "no steps")."
        return ([head] + lines + flow.notes.map { "Note: \($0)" } + [videoLine].compactMap { $0 }).joined(separator: "\n")
    }

    /// "Video: /path/run.mp4 (12.3 s, 98 frames)", or why there is none.
    public var videoLine: String? {
        if let video {
            return String(format: "Video: %@ (%.1f s, %d frames)", video.url.path, video.seconds, video.frames)
        }
        return videoProblem.map { "No video: \($0)" }
    }

    /// The run as Markdown, for a CI job summary or a pull request comment.
    public var markdown: String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = [
            "### \(passed ? "✅" : "❌") Mobdev flow: \(cell(flow.name))", "",
            passed
                ? String(format: "Passed: %d steps in %.1f s.", steps.count, seconds)
                : "Failed at step \(failedNumber ?? String(steps.count)) of \(flow.steps.count).",
            "", "| | Step | Time | Result |", "|---|---|---|---|",
        ]
        for (index, result) in steps.enumerated() {
            let text = result.passed ? (result.text.split(separator: "\n").first.map(String.init) ?? "") : result.text
            let icon = result.passed ? "✅" : result.tolerated ? "➖" : "❌"
            let number = result.number.isEmpty ? String(index + 1) : result.number
            let round = result.round.map { " (\($0))" } ?? ""
            lines.append(
                "| \(icon) | \(number). `\(cell(result.step.summary))`\(round) | "
                    + String(format: "%.1f s", result.seconds) + " | \(cell(text)) |")
        }
        if !flow.notes.isEmpty { lines += [""] + flow.notes.map { "Note: \(cell($0))" } }
        return lines.joined(separator: "\n") + "\n"
    }

    var json: JSONValue {
        // failed_step stays the number of the flow's own step; failed_at says where inside it.
        let failed = passed ? nil : failedNumber ?? String(steps.count)
        let top = failed.flatMap { Double($0.split(separator: ".").first.map(String.init) ?? "") }
        return [
            "name": .string(flow.name), "passed": .bool(passed), "seconds": .number((seconds * 10).rounded() / 10),
            "steps": .number(Double(flow.steps.count)),
            "failed_step": top.map(JSONValue.number) ?? .null,
            "failed_at": failed.map(JSONValue.string) ?? .null,
            "video": video.map { JSONValue.string($0.url.path) } ?? .null,
        ]
    }
}

// MARK: - Recording

/// Collects a device's steps while someone records a flow: every call made through the tools, by
/// an agent or in the app, and clicks, drags and keys in the app's window. Clicks become
/// tap_element when the tree read shortly before says what was under the pointer.
public final class FlowRecorder: Sendable {
    private struct State {
        var steps: [Flow.Step] = []
        /// The newest tree and when it was read; refreshed while recording.
        var tree: [UIElement]?
        var refresher: Task<Void, Never>?
    }

    private let state = Locked<State?>(nil)
    /// Keeps at most this many steps, dropping the oldest; nil keeps all.
    private let limit: Int?

    public init(limit: Int? = nil) { self.limit = limit }

    public var isRecording: Bool { state.get() != nil }
    public var stepCount: Int { state.get()?.steps.count ?? 0 }
    var hasTree: Bool { state.get()?.tree != nil }

    /// Starts recording. With `tree`, the elements on screen are read about every second and a
    /// half so clicks can be named by element; nil devices (iPhones) record coordinates.
    public func start(tree: (@Sendable () async throws -> [UIElement]?)? = nil) {
        stop()
        state.set(State())
        if let tree {
            let refresher = Task { [weak self] in
                while !Task.isCancelled, self?.isRecording == true {
                    let elements = try? await tree()
                    self?.state.withLock { $0?.tree = elements }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
            state.withLock { $0?.refresher = refresher }
        }
    }

    /// Stops recording and returns what was recorded.
    @discardableResult
    public func stop() -> [Flow.Step] {
        let finished = state.withLock { current -> State? in
            defer { current = nil }
            return current
        }
        finished?.refresher?.cancel()
        return finished?.steps ?? []
    }

    /// Calls that only look, and so replay nothing. Waits and assertions are kept: they are what a
    /// flow checks.
    static let skipped: Set<String> = [
        "status", "screenshot", "read_screen", "find_text", "ui_tree", "list_apps", "logs", "crash_reports",
        "list_devices", "run_flow", "run_tests", "observe", "start_recording", "stop_recording", "recent_steps",
        "crawl_app",
    ]

    /// Whether a call only looks. An accessibility audit checks something only with fail_on.
    static func onlyLooks(_ tool: String, _ arguments: [String: JSONValue]) -> Bool {
        skipped.contains(tool) || tool == "accessibility_audit" && (arguments["fail_on"] ?? .null).isNull
    }

    /// A successful tool call. Consecutive typing merges into one step.
    public func record(_ tool: String, _ arguments: [String: JSONValue]) {
        guard !Self.onlyLooks(tool, arguments) else { return }
        var arguments = arguments
        arguments["screenshot"] = nil
        arguments["device"] = nil
        state.withLock { current in
            guard current != nil else { return }
            if tool == "type_text", let last = current!.steps.last, last.tool == "type_text",
                last.arguments["submit"]?.boolValue != true,
                let before = last.arguments["text"]?.stringValue, let added = arguments["text"]?.stringValue
            {
                var merged = arguments
                merged["text"] = .string(before + added)
                current!.steps[current!.steps.count - 1] = Flow.Step(tool, merged)
            } else {
                current!.steps.append(Flow.Step(tool, arguments))
                if let limit, current!.steps.count > limit { current!.steps.removeFirst(current!.steps.count - limit) }
            }
        }
    }

    /// The steps so far, without stopping.
    public var steps: [Flow.Step] { state.get()?.steps ?? [] }

    /// Forgets the steps so far and keeps recording.
    public func clear() { state.withLock { $0?.steps = [] } }

    /// A click in the app's window, at a point given as fractions of the screen and in screenshot
    /// pixels. An element with a unique identifier or label under the point makes it tap_element.
    public func recordTap(at point: NormalizedPoint, pixels: (x: Int, y: Int)) {
        let tree = state.get()?.tree ?? []
        if let element = Self.element(at: point, in: tree) {
            record("tap_element", element)
        } else {
            record("tap", ["x": .number(Double(pixels.x)), "y": .number(Double(pixels.y))])
        }
    }

    /// Arguments for tap_element naming the smallest tappable element under the point, when its
    /// identifier (or else its label) picks it alone.
    public static func element(at point: NormalizedPoint, in tree: [UIElement]) -> [String: JSONValue]? {
        let under = tree.filter { $0.tappable && $0.frame.contains(CGPoint(x: point.x, y: point.y)) }
        guard let element = under.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        if !element.identifier.isEmpty,
            ElementQuery(id: element.identifier, text: nil).matches(in: tree).count == 1
        {
            return ["id": .string(element.identifier)]
        }
        if !element.label.isEmpty, ElementQuery(id: nil, text: element.label).matches(in: tree).count == 1 {
            return ["text": .string(element.label)]
        }
        return nil
    }

    /// The name press_key knows for a key the app's window passes on.
    public static func keyName(usage: UInt8) -> String? {
        let preferred = [
            "return", "escape", "backspace", "tab", "space", "right", "left", "down", "up", "forwarddelete",
            "home", "end", "pageup", "pagedown",
        ]
        return preferred.first { KeyboardLayout.namedKeys[$0] == usage }
            ?? KeyboardLayout.namedKeys.first { $0.value == usage }?.key
    }
}
