import Foundation

/// Maestro's YAML flows, as Mobdev steps and back.
///
///     appId: com.example.app
///     ---
///     - launchApp:
///         clearState: true
///     - tapOn: "Sign in"
///     - inputText: "me@example.com"
///     - assertVisible:
///         id: "welcome"
///
/// becomes reset_app, launch_app, tap_element, type_text and wait_for_element. A command Mobdev
/// cannot do fails the whole file with its name and line, so a flow never half-works; what
/// changes on the way (a screenshot left out, a pattern read as text) goes into the flow's notes.
/// `export` writes a Mobdev flow as Maestro YAML, for the steps that have a Maestro command.
public enum Maestro {
    static func isMaestroFile(_ url: URL) -> Bool { ["yaml", "yml"].contains(url.pathExtension.lowercased()) }

    /// How long assertVisible and assertNotVisible wait, in seconds, as Maestro's own retries do.
    static let assertTimeout = 7.0
    /// The variable copyTextFrom fills and pasteText types.
    static let copiedText = "COPIED_TEXT"

    /// Commands with no Mobdev equivalent, and why or what to do instead.
    static let unsupported: [String: String] = [
        "evalScript": "Mobdev runs no JavaScript",
        "runScript": "Mobdev runs no JavaScript",
        "assertTrue": "it checks a JavaScript condition, which Mobdev does not run",
        "assertWithAI": "Mobdev does not judge screens with a model; use assertVisible",
        "assertNoDefectsWithAI": "Mobdev does not judge screens with a model",
        "extractTextWithAI": "Mobdev does not read screens with a model; use copyTextFrom",
        "inputRandomEmail": "write the text instead, or pass it as a variable",
        "inputRandomPersonName": "write the text instead, or pass it as a variable",
        "inputRandomNumber": "write the text instead, or pass it as a variable",
        "inputRandomText": "write the text instead, or pass it as a variable",
        "clearKeychain": "Mobdev empties the keychain only together with an app's data: launchApp with clearState and clearKeychain",
        "setAirplaneMode": "Mobdev cannot switch the network",
        "toggleAirplaneMode": "Mobdev cannot switch the network",
        "addMedia": "Mobdev cannot add photos or videos",
        "startRecording": "record the run with Mobdev flow --artifacts or run_flow's video instead",
        "stopRecording": "record the run with Mobdev flow --artifacts or run_flow's video instead",
    ]

    // MARK: Importing

    /// A Maestro flow as a Mobdev flow; `file` names it and its errors.
    public static func flow(from text: String, file: URL?) throws -> Flow {
        let fileName = file?.lastPathComponent ?? "flow.yaml"
        let documents: [YAMLNode?]
        do {
            documents = try YAML.documents(text)
        } catch let error as YAMLError {
            throw ToolFailure("\(fileName): \(error)")
        }
        let config: YAMLNode?
        let commands: YAMLNode?
        switch documents.count {
        case 1 where documents[0]?.items != nil || documents[0] == nil:
            config = nil
            commands = documents[0]
        case 1:
            throw ToolFailure("\(fileName) has no commands. They go in a list after a line with ---.")
        case 2:
            config = documents[0]
            commands = documents[1]
        default:
            throw ToolFailure("\(fileName) has \(documents.count) documents; a Maestro flow has a config, ---, and the commands.")
        }
        var importer = Importer(file: fileName)
        var name = file?.deletingPathExtension().lastPathComponent ?? "Flow"
        var steps: [Flow.Step] = []
        if let config, !config.isNull {
            guard let entries = config.entries else {
                throw ToolFailure("\(fileName): line \(config.line): the config before --- must be keys like appId: com.example.app.")
            }
            for entry in entries {
                switch entry.key {
                case "appId": importer.appId = try importer.string(entry.value, "appId")
                case "name": name = try importer.string(entry.value, "name")
                case "env": steps.append(contentsOf: try importer.env(entry.value))
                case "onFlowStart": steps.append(contentsOf: try importer.commands(entry.value))
                case "onFlowComplete":
                    throw importer.failure(
                        entry.line, "onFlowComplete is not supported by Mobdev: it runs even after a failure, and a Mobdev flow stops there.")
                case "url": throw importer.failure(entry.line, "url is for web flows, which Mobdev does not run.")
                case "tags", "jsEngine", "properties", "androidWebViewHierarchy", "ext": break
                default: importer.notes.append("line \(entry.line): the config's \(entry.key) is left out.")
                }
            }
        }
        if let commands, !commands.isNull { steps.append(contentsOf: try importer.commands(commands)) }
        let flow = Flow(name: name, steps: steps, notes: importer.notes)
        try flow.checkSize()
        return flow
    }

    struct Importer {
        let file: String
        var appId: String?
        var notes: [String] = []

        func failure(_ line: Int, _ message: String) -> ToolFailure { ToolFailure("\(file): line \(line): \(message)") }

        mutating func commands(_ node: YAMLNode) throws -> [Flow.Step] {
            guard let items = node.items else {
                throw failure(node.line, "expected a list of commands, each on a line starting with -.")
            }
            return try items.flatMap { try command($0) }
        }

        /// One command, as one or more steps.
        mutating func command(_ node: YAMLNode) throws -> [Flow.Step] {
            let name: String
            var argument: YAMLNode?
            switch node.value {
            case .scalar(let text, _):
                name = text
            case .mapping(let entries) where entries.count == 1:
                name = entries[0].key
                argument = entries[0].value.isNull ? nil : entries[0].value
            case .mapping(let entries):
                throw failure(
                    node.line,
                    "one command per list item; this one has \(entries.map(\.key).joined(separator: ", ")). Settings such as optional go inside the command.")
            default:
                throw failure(node.line, "expected a command, like - tapOn: \"Sign in\".")
            }
            let line = node.line
            var optional = false
            if let entries = argument?.entries, let flag = entries.first(where: { $0.key == "optional" }) {
                guard let value = flag.value.bool else { throw failure(flag.line, "optional must be true or false.") }
                optional = value
            }
            var steps = try convert(name, argument, line: line)
            if optional { steps = steps.map { var step = $0; step.optional = true; return step } }
            return steps
        }

        private mutating func convert(_ name: String, _ argument: YAMLNode?, line: Int) throws -> [Flow.Step] {
            let fields = Fields(node: argument, command: name, importer: self)
            switch name {
            case "launchApp":
                var bundle = appId
                var clearState = false
                var clearKeychain = false
                var restart = true
                var arguments: [JSONValue] = []
                var steps: [Flow.Step] = []
                if let argument, argument.entries == nil {
                    bundle = try string(argument, "launchApp")
                } else if argument != nil {
                    try fields.allow(["appId", "clearState", "clearKeychain", "stopApp", "arguments", "permissions"])
                    if let node = fields["appId"] { bundle = try string(node, "appId") }
                    clearState = try fields.bool("clearState") ?? false
                    clearKeychain = try fields.bool("clearKeychain") ?? false
                    restart = try fields.bool("stopApp") ?? true
                    if let node = fields["arguments"] {
                        guard let entries = node.entries else { throw failure(node.line, "arguments must be keys and values.") }
                        for entry in entries {
                            arguments.append(.string("-\(entry.key)"))
                            arguments.append(.string(try variables(try scalarText(entry.value, entry.key), line: entry.line)))
                        }
                    }
                }
                guard let bundle else {
                    throw failure(line, "launchApp needs an appId: in the config before ---, or as launchApp: com.example.app.")
                }
                if clearState || clearKeychain {
                    var reset: [String: JSONValue] = ["bundle_id": .string(bundle)]
                    if clearKeychain { reset["keychain"] = true }
                    steps.append(Flow.Step("reset_app", reset))
                    if clearKeychain, !clearState {
                        notes.append("line \(line): clearKeychain also clears the app's data, since Mobdev empties the keychain only with it.")
                    }
                }
                if let node = fields["permissions"] { steps += try permissions(node, bundle: bundle) }
                var launch: [String: JSONValue] = ["bundle_id": .string(bundle)]
                if !restart { launch["restart"] = false }
                if !arguments.isEmpty { launch["arguments"] = .array(arguments) }
                steps.append(Flow.Step("launch_app", launch))
                return steps
            case "stopApp", "killApp", "clearState":
                var bundle = appId
                if let argument { bundle = try string(argument, name) }
                guard let bundle else { throw failure(line, "\(name) needs an appId: in the config before ---, or as \(name): com.example.app.") }
                return [Flow.Step(name == "clearState" ? "reset_app" : "stop_app", ["bundle_id": .string(bundle)])]
            case "tapOn", "doubleTapOn", "longPressOn":
                let target = try selector(argument, command: name, line: line, extra: name == "tapOn" ? ["repeat", "delay"] : [])
                var step: Flow.Step
                if let point = target.point {
                    step = Flow.Step(name == "longPressOn" ? "long_press" : "tap", ["x": point.x, "y": point.y])
                } else {
                    var arguments = target.arguments
                    if name == "doubleTapOn" { arguments["double"] = true }
                    if name == "longPressOn" { arguments["hold"] = 1 }
                    step = Flow.Step("tap_element", arguments)
                }
                if name == "doubleTapOn", target.point != nil { step.arguments["double"] = true }
                if let times = try fields.int("repeat", in: 1...Flow.maxRounds), times > 1 {
                    return [Flow.Step(.loop(.times(times), steps: [step]))]
                }
                return [step]
            case "inputText":
                let text: String
                if argument?.entries != nil {
                    try fields.allow(["text"])
                    text = try string(fields["text"] ?? YAMLNode(value: .null, line: line), "text")
                } else {
                    text = try string(argument ?? YAMLNode(value: .null, line: line), "inputText")
                }
                return [Flow.Step("type_text", ["text": .string(try variables(text, line: line))])]
            case "pasteText":
                return [Flow.Step("type_text", ["text": .string("${\(Maestro.copiedText)}")])]
            case "eraseText":
                var count = 50
                if let argument, argument.entries == nil {
                    count = try int(argument, "eraseText", in: 1...10_000)
                } else if argument != nil {
                    try fields.allow(["charactersToErase"])
                    count = try fields.int("charactersToErase", in: 1...10_000) ?? 50
                }
                if count > 100 {
                    notes.append("line \(line): eraseText erases at most 100 characters in Mobdev, not \(count).")
                    count = 100
                }
                return [Flow.Step("press_key", ["key": "backspace", "count": .number(Double(count))])]
            case "assertVisible", "assertNotVisible":
                let target = try selector(argument, command: name, line: line, extra: [])
                guard target.point == nil else { throw failure(line, "\(name) takes text or an id, not a point.") }
                var arguments = target.query
                arguments["timeout"] = .number(Maestro.assertTimeout)
                if name == "assertNotVisible" { arguments["gone"] = true }
                if target.index != nil { notes.append("line \(line): \(name) ignores index; any match counts.") }
                return [Flow.Step("wait_for_element", arguments)]
            case "extendedWaitUntil":
                try fields.allow(["visible", "notVisible", "timeout"])
                let keys = ["visible", "notVisible"].filter { fields[$0] != nil }
                guard keys.count == 1, let node = fields[keys[0]] else {
                    throw failure(line, "extendedWaitUntil takes visible or notVisible, and a timeout in milliseconds.")
                }
                let target = try selector(node, command: keys[0], line: node.line, extra: [])
                var arguments = target.query
                let milliseconds = try fields.number("timeout") ?? 10_000
                if milliseconds > 60_000 { notes.append("line \(line): Mobdev waits at most 60 s, not \(Int(milliseconds / 1000)) s.") }
                arguments["timeout"] = .number(min(max(milliseconds / 1000, 0), 60))
                if keys[0] == "notVisible" { arguments["gone"] = true }
                return [Flow.Step("wait_for_element", arguments)]
            case "scrollUntilVisible":
                try fields.allow(["element", "direction", "timeout", "speed", "visibilityPercentage", "centerElement"])
                guard let element = fields["element"] else {
                    throw failure(line, "scrollUntilVisible needs element: the text or id to scroll to.")
                }
                var arguments = try selector(element, command: "element", line: element.line, extra: []).query
                if let direction = try fields.direction("direction") { arguments["direction"] = .string(direction) }
                if let milliseconds = try fields.number("timeout") {
                    arguments["max_scrolls"] = .number(Double(min(max(Int(milliseconds / 2000), 1), 50)))
                }
                return [Flow.Step("scroll_until_visible", arguments)]
            case "scroll":
                return [Flow.Step("scroll", ["direction": "down"])]
            case "swipe":
                try fields.allow(["direction", "start", "end", "duration", "from"])
                if fields["from"] != nil {
                    throw failure(line, "swipe from an element is not supported by Mobdev; swipe with start and end points instead.")
                }
                var arguments: [String: JSONValue]
                if let direction = try fields.direction("direction") {
                    let (from, to): ((String, String), (String, String)) = switch direction {
                    case "left": (("90%", "50%"), ("10%", "50%"))
                    case "right": (("10%", "50%"), ("90%", "50%"))
                    case "up": (("50%", "80%"), ("50%", "20%"))
                    default: (("50%", "20%"), ("50%", "80%"))
                    }
                    arguments = [
                        "from_x": .string(from.0), "from_y": .string(from.1), "to_x": .string(to.0), "to_y": .string(to.1),
                    ]
                } else if let start = fields["start"], let end = fields["end"] {
                    let from = try point(start)
                    let to = try point(end)
                    arguments = ["from_x": from.x, "from_y": from.y, "to_x": to.x, "to_y": to.y]
                } else {
                    throw failure(line, "swipe takes a direction, or start and end points like \"90%, 50%\".")
                }
                if let milliseconds = try fields.number("duration") {
                    arguments["duration"] = .number(min(max(milliseconds / 1000, 0.05), 5))
                }
                return [Flow.Step("swipe", arguments)]
            case "back":
                return [Maestro.back]
            case "pressKey":
                let key = try string(argument ?? YAMLNode(value: .null, line: line), "pressKey")
                switch key.lowercased() {
                case "enter": return [Flow.Step("press_key", ["key": "enter"])]
                case "backspace", "delete": return [Flow.Step("press_key", ["key": "backspace"])]
                case "tab": return [Flow.Step("press_key", ["key": "tab"])]
                case "escape": return [Flow.Step("press_key", ["key": "escape"])]
                case "home": return [Flow.Step("home")]
                case "back": return [Maestro.back]
                case "volume up": return [Flow.Step("press_key", ["key": "volume_up"])]
                case "volume down": return [Flow.Step("press_key", ["key": "volume_down"])]
                case "remote dpad up": return [Flow.Step("press_key", ["key": "up"])]
                case "remote dpad down": return [Flow.Step("press_key", ["key": "down"])]
                case "remote dpad left": return [Flow.Step("press_key", ["key": "left"])]
                case "remote dpad right": return [Flow.Step("press_key", ["key": "right"])]
                case "remote dpad center": return [Flow.Step("press_key", ["key": "enter"])]
                default: throw failure(line, "pressKey \(key) is not supported by Mobdev.")
                }
            case "hideKeyboard":
                notes.append(
                    "line \(line): hideKeyboard is left out. Mobdev types with a hardware keyboard on iOS, so the on-screen keyboard rarely shows; on Android, press Back with pressKey: Back if it covers something."
                )
                return []
            case "takeScreenshot":
                notes.append(
                    "line \(line): takeScreenshot is left out; Mobdev flow --artifacts and run_flow's video keep the whole run.")
                return []
            case "openLink":
                var url: String
                if let argument, argument.entries != nil {
                    try fields.allow(["link", "autoVerify", "browser"])
                    url = try string(fields["link"] ?? YAMLNode(value: .null, line: line), "link")
                } else {
                    url = try string(argument ?? YAMLNode(value: .null, line: line), "openLink")
                }
                url = try variables(url, line: line)
                return [Flow.Step("open_url", ["url": .string(url)])]
            case "waitForAnimationToEnd":
                try fields.allow(["timeout"])
                var arguments: [String: JSONValue] = [:]
                if let milliseconds = try fields.number("timeout") { arguments["timeout"] = .number(min(max(milliseconds / 1000, 0), 60)) }
                return [Flow.Step("wait_for_idle", arguments)]
            case "runFlow":
                var body: [Flow.Step]
                if let argument, argument.entries == nil {
                    return [Flow.Step(.subflow(path: try string(argument, "runFlow"), flow: nil))]
                }
                try fields.allow(["file", "commands", "when", "env"])
                if let file = fields["file"] {
                    guard fields["commands"] == nil else { throw failure(line, "runFlow takes file or commands, not both.") }
                    body = [Flow.Step(.subflow(path: try string(file, "file"), flow: nil))]
                } else if let commands = fields["commands"] {
                    body = try self.commands(commands)
                } else {
                    throw failure(line, "runFlow needs a file or commands.")
                }
                if let env = fields["env"] { body = try self.env(env) + body }
                if let when = fields["when"] { body = try conditions(when, then: body) }
                return body
            case "repeat":
                try fields.allow(["times", "while", "commands"])
                guard let commands = fields["commands"] else { throw failure(line, "repeat needs commands.") }
                let steps = try self.commands(commands)
                let times = try fields.int("times", in: 1...Flow.maxRounds)
                guard let condition = fields["while"] else {
                    guard let times else { throw failure(line, "repeat needs times or while.") }
                    return [Flow.Step(.loop(.times(times), steps: steps))]
                }
                let max = times ?? Flow.defaultMaxRounds
                let (key, target) = try visibility(condition, command: "while")
                return [Flow.Step(.loop(key == "visible" ? .whileVisible(target, max: max) : .untilVisible(target, max: max), steps: steps))]
            case "retry":
                try fields.allow(["maxRetries", "commands", "file"])
                let times = try fields.int("maxRetries", in: 1...Flow.maxRetries) ?? 1
                let steps: [Flow.Step]
                if let file = fields["file"] {
                    steps = [Flow.Step(.subflow(path: try string(file, "file"), flow: nil))]
                } else if let commands = fields["commands"] {
                    steps = try self.commands(commands)
                } else {
                    throw failure(line, "retry needs commands or a file.")
                }
                return [Flow.Step(.retry(times: times, steps: steps))]
            case "setLocation":
                try fields.allow(["latitude", "longitude"])
                guard let latitude = try fields.number("latitude"), let longitude = try fields.number("longitude") else {
                    throw failure(line, "setLocation needs latitude and longitude.")
                }
                return [Flow.Step("set_location", ["latitude": .number(latitude), "longitude": .number(longitude)])]
            case "travel":
                try fields.allow(["points", "speed"])
                guard let points = fields["points"]?.items, points.count >= 2 else {
                    throw failure(line, "travel needs points: two or more \"latitude, longitude\".")
                }
                let route: [JSONValue] = try points.map { point in
                    let parts = try string(point, "points").split(separator: ",").map {
                        Double($0.trimmingCharacters(in: .whitespaces))
                    }
                    guard parts.count == 2, let latitude = parts[0], let longitude = parts[1] else {
                        throw failure(point.line, "a point is \"latitude, longitude\", like \"52.52, 13.405\".")
                    }
                    return ["latitude": .number(latitude), "longitude": .number(longitude)]
                }
                var arguments: [String: JSONValue] = ["route": .array(route)]
                // Maestro's speed is in km/h, Mobdev's in meters per second.
                if let speed = try fields.number("speed") { arguments["speed"] = .number((speed / 3.6 * 10).rounded() / 10) }
                return [Flow.Step("set_location", arguments)]
            case "setOrientation":
                let given = try string(argument ?? YAMLNode(value: .null, line: line), "setOrientation")
                let orientation: String? = switch given.uppercased() {
                case "PORTRAIT": "portrait"
                case "LANDSCAPE_LEFT", "LANDSCAPE": "landscape_left"
                case "LANDSCAPE_RIGHT": "landscape_right"
                case "UPSIDE_DOWN", "PORTRAIT_UPSIDE_DOWN": "portrait_upside_down"
                default: nil
                }
                guard let orientation else {
                    throw failure(line, "setOrientation takes PORTRAIT, LANDSCAPE_LEFT, LANDSCAPE_RIGHT or UPSIDE_DOWN.")
                }
                return [Flow.Step("set_orientation", ["orientation": .string(orientation)])]
            case "setPermissions":
                try fields.allow(["appId", "permissions"])
                var bundle = appId
                if let node = fields["appId"] { bundle = try string(node, "appId") }
                guard let bundle, let node = fields["permissions"] else {
                    throw failure(line, "setPermissions needs permissions and an appId.")
                }
                return try permissions(node, bundle: bundle)
            case "copyTextFrom":
                let target = try selector(argument, command: name, line: line, extra: [])
                guard target.point == nil else { throw failure(line, "copyTextFrom takes text or an id, not a point.") }
                return [
                    Flow.Step(
                        .extract(Flow.Extraction(target: target.flowTarget, into: Maestro.copiedText, index: target.index)))
                ]
            default:
                if let reason = Maestro.unsupported[name] {
                    throw failure(line, "\(name) is not supported by Mobdev: \(reason).")
                }
                throw failure(line, "\(name) is not a Maestro command Mobdev knows.")
            }
        }

        /// `env:` as a set step.
        mutating func env(_ node: YAMLNode) throws -> [Flow.Step] {
            guard let entries = node.entries else { throw failure(node.line, "env must be names and values.") }
            guard !entries.isEmpty else { return [] }
            var values: [String: String] = [:]
            for entry in entries {
                guard Variables.isName(entry.key) else {
                    throw failure(entry.line, "\"\(entry.key)\" is not a variable name: letters, digits and _.")
                }
                values[entry.key] = try variables(try scalarText(entry.value, entry.key), line: entry.line)
            }
            return [Flow.Step(.set(values))]
        }

        /// runFlow's when, as ifs around the steps: every condition must hold.
        mutating func conditions(_ node: YAMLNode, then body: [Flow.Step]) throws -> [Flow.Step] {
            guard let entries = node.entries, !entries.isEmpty else {
                throw failure(node.line, "when takes visible, notVisible or platform.")
            }
            var steps = body
            for entry in entries.reversed() {
                let condition: Flow.Condition
                switch entry.key {
                case "visible", "notVisible":
                    let target = try selector(entry.value, command: entry.key, line: entry.line, extra: []).flowTarget
                    condition = entry.key == "visible" ? .visible(target) : .notVisible(target)
                case "platform":
                    let platform = try string(entry.value, "platform").lowercased()
                    guard platform == "ios" || platform == "android" else {
                        throw failure(entry.line, "platform \(platform) is not one Mobdev runs; use iOS or Android.")
                    }
                    condition = .platform(platform)
                case "true":
                    throw failure(entry.line, "when true: checks a JavaScript condition, which Mobdev does not run.")
                default:
                    throw failure(entry.line, "when takes visible, notVisible or platform, not \(entry.key).")
                }
                steps = [Flow.Step(.branch(condition, then: steps, else: []))]
            }
            return steps
        }

        /// repeat's while: visible or notVisible.
        mutating func visibility(_ node: YAMLNode, command: String) throws -> (String, Flow.Target) {
            guard let entries = node.entries, entries.count == 1, ["visible", "notVisible"].contains(entries[0].key) else {
                if node.entries?.first?.key == "true" {
                    throw failure(node.line, "\(command) true: checks a JavaScript condition, which Mobdev does not run.")
                }
                throw failure(node.line, "\(command) takes visible or notVisible.")
            }
            let target = try selector(entries[0].value, command: entries[0].key, line: entries[0].line, extra: [])
            return (entries[0].key, target.flowTarget)
        }

        func permissions(_ node: YAMLNode, bundle: String) throws -> [Flow.Step] {
            guard let entries = node.entries else { throw failure(node.line, "permissions must be names and allow, deny or unset.") }
            return try entries.map { entry in
                let permission = entry.key.lowercased() == "medialibrary" ? "media-library" : entry.key.lowercased()
                guard DeviceSettingsNames.permissions.contains(permission) else {
                    throw failure(entry.line, "the permission \(entry.key) is not one Mobdev sets. Permissions: \(DeviceSettingsNames.permissions.joined(separator: ", ")).")
                }
                let state: String
                switch try string(entry.value, entry.key).lowercased() {
                case "allow": state = "grant"
                case "deny": state = "revoke"
                case "unset": state = "reset"
                default: throw failure(entry.line, "\(entry.key) must be allow, deny or unset.")
                }
                return Flow.Step(
                    "set_permission", ["bundle_id": .string(bundle), "permission": .string(permission), "state": .string(state)])
            }
        }

        // MARK: Selectors

        struct Target {
            var id: String?
            var text: String?
            var index: Int?
            var point: (x: JSONValue, y: JSONValue)?

            var query: [String: JSONValue] { id.map { ["id": .string($0)] } ?? ["text": .string(text ?? "")] }
            var arguments: [String: JSONValue] {
                var arguments = query
                if let index { arguments["index"] = .number(Double(index)) }
                return arguments
            }
            var flowTarget: Flow.Target { Flow.Target(id: id, text: id == nil ? text : nil) }
        }

        /// What tapOn and the like point at: text (a bare string), id, index or point.
        mutating func selector(_ node: YAMLNode?, command: String, line: Int, extra: Set<String>) throws -> Target {
            guard let node else { throw failure(line, "\(command) needs text, an id or a point.") }
            if node.entries == nil {
                return Target(text: try text(try string(node, command), line: node.line))
            }
            let fields = Fields(node: node, command: command, importer: self)
            let relative = ["below", "above", "leftOf", "rightOf", "childOf", "containsChild", "containsDescendants"]
            for key in relative where fields[key] != nil {
                throw failure(fields.line(key), "\(command) \(key) is not supported by Mobdev; use an id or text that is unique.")
            }
            for key in ["enabled", "checked", "focused", "selected", "traits", "width", "height", "tolerance", "css"]
            where fields[key] != nil {
                throw failure(fields.line(key), "\(command) \(key) is not supported by Mobdev.")
            }
            try fields.allow(
                Set(["id", "text", "index", "point", "retryTapIfNoChange", "waitToSettleTimeoutMs", "waitUntilVisible"])
                    .union(extra))
            var target = Target()
            if let id = fields["id"] { target.id = try variables(try string(id, "id"), line: id.line) }
            if let text = fields["text"] { target.text = try self.text(try string(text, "text"), line: text.line) }
            if target.id != nil, target.text != nil {
                notes.append("line \(line): \(command) looks for the id only; Mobdev matches one of id and text.")
                target.text = nil
            }
            target.index = try fields.int("index", in: 0...999)
            if let point = fields["point"] {
                target.point = try self.point(point)
            } else if target.id == nil, target.text == nil {
                throw failure(line, "\(command) needs text, an id or a point.")
            }
            return target
        }

        /// "50%, 50%" stays a share of the screen; "100, 200" becomes screenshot pixels.
        mutating func point(_ node: YAMLNode) throws -> (x: JSONValue, y: JSONValue) {
            let parts = try string(node, "point").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { throw failure(node.line, "a point is \"x, y\", like \"50%, 50%\".") }
            func value(_ part: String) throws -> JSONValue {
                if part.hasSuffix("%"), let share = Double(part.dropLast()), (0...100).contains(share) { return .string(part) }
                guard let number = Double(part), number >= 0 else {
                    throw failure(node.line, "\(part) is not a coordinate; use pixels or a percentage like 50%.")
                }
                return .number(number)
            }
            let point = (x: try value(parts[0]), y: try value(parts[1]))
            if point.x.stringValue == nil || point.y.stringValue == nil {
                notes.append(
                    "line \(node.line): the point \(parts.joined(separator: ", ")) is read as pixels of Mobdev's screenshot (long edge 1280), which are not Maestro's; percentages carry over exactly.")
            }
            return point
        }

        /// Maestro matches text as a regular expression over the whole label; Mobdev looks for the
        /// text itself. Anchors and a leading or trailing .* go, escapes are undone, and a pattern
        /// that is still a pattern is noted.
        mutating func text(_ given: String, line: Int) throws -> String {
            var text = try variables(given, line: line)
            if text.hasPrefix("^") { text.removeFirst() }
            if text.hasSuffix("$"), !text.hasSuffix("\\$") { text.removeLast() }
            while text.hasPrefix(".*") { text.removeFirst(2) }
            while text.hasSuffix(".*"), !text.hasSuffix("\\.*") { text.removeLast(2) }
            var unescaped = ""
            var escaping = false
            var pattern = false
            for character in text {
                if escaping {
                    if character.isLetter || character.isNumber { pattern = true; unescaped.append("\\") }
                    unescaped.append(character)
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    unescaped.append(character)
                }
            }
            if pattern || unescaped.contains(".*") || unescaped.contains("|") || unescaped.contains("[") {
                notes.append("line \(line): Maestro reads \"\(given)\" as a pattern; Mobdev looks for \"\(unescaped)\" as text.")
            }
            guard !unescaped.isEmpty else { throw failure(line, "\"\(given)\" matches anything; name the text to look for.") }
            return unescaped
        }

        /// `${NAME}` stays, `${maestro.copiedText}` becomes the variable copyTextFrom fills, and
        /// any other JavaScript expression is refused.
        func variables(_ text: String, line: Int) throws -> String {
            let result = text.replacingOccurrences(of: "${maestro.copiedText}", with: "${\(Maestro.copiedText)}")
            var rest = result[...]
            while let start = rest.range(of: "${") {
                let after = rest[start.upperBound...]
                guard let end = after.firstIndex(of: "}") else { break }
                let inside = String(after[..<end])
                guard Variables.isName(inside) else {
                    throw failure(line, "${\(inside)} is JavaScript, which Mobdev does not run; only ${NAME} variables work.")
                }
                rest = after[after.index(after: end)...]
            }
            return result
        }

        // MARK: Values

        func string(_ node: YAMLNode, _ what: String) throws -> String {
            guard let text = node.string, !text.isEmpty else { throw failure(node.line, "\(what) must be text.") }
            return text
        }

        /// A scalar of any kind as text, for env and launch arguments.
        func scalarText(_ node: YAMLNode, _ what: String) throws -> String {
            guard let text = node.string else { throw failure(node.line, "\(what) must be a value, not a list or keys.") }
            return text
        }

        func int(_ node: YAMLNode, _ what: String, in range: ClosedRange<Int>) throws -> Int {
            guard let number = node.number, number.rounded() == number, range.contains(Int(number)) else {
                throw failure(node.line, "\(what) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
            }
            return Int(number)
        }
    }

    /// The settings of one command, with errors that name the command and the line.
    struct Fields {
        let node: YAMLNode?
        let command: String
        let importer: Importer

        subscript(key: String) -> YAMLNode? { node?[key].flatMap { $0.isNull ? nil : $0 } }

        func line(_ key: String) -> Int { node?.entries?.first { $0.key == key }?.line ?? node?.line ?? 0 }

        /// Every key is one of `keys`, label or optional, which every command takes.
        func allow(_ keys: Set<String>) throws {
            guard let node else { return }
            guard let entries = node.entries else {
                throw importer.failure(node.line, "\(command) takes settings like key: value here.")
            }
            let allowed = keys.union(["label", "optional"])
            if let unknown = entries.first(where: { !allowed.contains($0.key) }) {
                throw importer.failure(
                    unknown.line,
                    "\(command) \(unknown.key) is not supported by Mobdev. It takes \(keys.sorted().joined(separator: ", ")).")
            }
        }

        func bool(_ key: String) throws -> Bool? {
            guard let value = self[key] else { return nil }
            guard let flag = value.bool else { throw importer.failure(value.line, "\(key) must be true or false.") }
            return flag
        }

        func number(_ key: String) throws -> Double? {
            guard let value = self[key] else { return nil }
            guard let number = value.number else { throw importer.failure(value.line, "\(key) must be a number.") }
            return number
        }

        func int(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
            guard let value = self[key] else { return nil }
            return try importer.int(value, key, in: range)
        }

        /// UP, DOWN, LEFT or RIGHT, lowercased.
        func direction(_ key: String) throws -> String? {
            guard let value = self[key] else { return nil }
            let direction = value.string?.lowercased() ?? ""
            guard ["up", "down", "left", "right"].contains(direction) else {
                throw importer.failure(value.line, "\(key) must be UP, DOWN, LEFT or RIGHT.")
            }
            return direction
        }
    }

    /// Maestro's back: Android's Back key, and on iOS the navigation bar's back button, which has
    /// the identifier BackButton. press_key escape does not go back on iOS.
    static let back = Flow.Step(
        .branch(
            .platform("android"), then: [Flow.Step("press_key", ["key": "escape"])],
            else: [Flow.Step("tap_element", ["id": "BackButton"])]))
}
