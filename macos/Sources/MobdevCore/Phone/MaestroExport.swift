import Foundation

extension Maestro {
    /// A Mobdev flow as Maestro YAML, and notes on what changed on the way. Steps that have no
    /// Maestro command fail together, each with its number, so nothing is dropped silently.
    public static func export(_ flow: Flow) throws -> (yaml: String, notes: [String]) {
        var exporter = Exporter()
        exporter.appId = Self.appId(in: flow.steps)
        var steps = flow.steps
        // A first set step of plain values is Maestro's env.
        var env: [(String, YAML.Out)] = []
        if let values = Exporter.env(steps.first) {
            env = values
            steps.removeFirst()
        }
        let offset = env.isEmpty ? 0 : 1
        let commands = exporter.commands(steps, number: { String(offset + $0 + 1) })
        guard exporter.problems.isEmpty else {
            throw ToolFailure(
                "These steps have no Maestro command:\n" + exporter.problems.map { "  \($0)" }.joined(separator: "\n"))
        }
        var config: [(String, YAML.Out)] = []
        if let appId = exporter.appId {
            config.append(("appId", .string(appId)))
        } else {
            exporter.notes.append("The flow launches no app, so the config has no appId; Maestro needs one: add appId: <bundle id>.")
        }
        config.append(("name", .string(flow.name)))
        if !env.isEmpty { config.append(("env", .map(env))) }
        let lines = YAML.emit(.map(config)) + ["---"] + YAML.emit(.list(commands))
        return (lines.joined(separator: "\n") + "\n", exporter.notes)
    }

    /// The app the flow is about: the first one it launches, resets, stops or sets a permission of.
    static func appId(in steps: [Flow.Step]) -> String? {
        for step in steps {
            if step.control == nil, ["launch_app", "reset_app", "stop_app", "set_permission"].contains(step.tool),
                let bundle = step.arguments["bundle_id"]?.stringValue
            {
                return bundle
            }
            if !step.isSubflow, let found = appId(in: step.children) { return found }
        }
        return nil
    }

    struct Exporter {
        var appId: String?
        var notes: [String] = []
        var problems: [String] = []

        mutating func commands(_ steps: [Flow.Step], number: (Int) -> String) -> [YAML.Out] {
            var commands: [YAML.Out] = []
            var index = 0
            while index < steps.count {
                // reset_app and then launch_app of the same app is launchApp with clearState.
                let step = steps[index]
                if index + 1 < steps.count, step.control == nil, step.tool == "reset_app", !step.optional,
                    case let next = steps[index + 1], next.control == nil, next.tool == "launch_app", !next.optional,
                    let bundle = step.arguments["bundle_id"]?.stringValue, next.arguments["bundle_id"]?.stringValue == bundle
                {
                    do {
                        commands.append(
                            try launchApp(
                                next.arguments, number: number(index + 1), clearState: true,
                                clearKeychain: step.arguments["keychain"]?.boolValue == true))
                    } catch {
                        problems.append("\(number(index + 1)). \(next.summary): \(error)")
                    }
                    index += 2
                    continue
                }
                commands += command(step, number: number(index))
                index += 1
            }
            return commands
        }

        private mutating func launchApp(
            _ arguments: [String: JSONValue], number: String, clearState: Bool = false, clearKeychain: Bool = false
        ) throws -> YAML.Out {
            guard let bundle = arguments["bundle_id"]?.stringValue else { throw NoCommand("it has no bundle_id.") }
            var settings: [(String, YAML.Out)] = []
            if bundle != appId { settings.append(("appId", .string(bundle))) }
            if clearState { settings.append(("clearState", .bool(true))) }
            if clearKeychain { settings.append(("clearKeychain", .bool(true))) }
            if arguments["restart"]?.boolValue == false { settings.append(("stopApp", .bool(false))) }
            if let list = arguments["arguments"]?.arrayValue, !list.isEmpty {
                let texts = list.compactMap(\.stringValue)
                guard texts.count == list.count, texts.count % 2 == 0,
                    stride(from: 0, to: texts.count, by: 2).allSatisfy({ texts[$0].hasPrefix("-") })
                else { throw NoCommand("Maestro's arguments are pairs; write them as \"-key\", \"value\".") }
                let pairs = stride(from: 0, to: texts.count, by: 2).map {
                    (String(texts[$0].dropFirst()), YAML.Out.string(texts[$0 + 1]))
                }
                settings.append(("arguments", .map(pairs)))
            }
            if arguments["environment"] != nil {
                notes.append("\(number): launch_app's environment is left out; Maestro has none.")
            }
            return settings.isEmpty ? .plain("launchApp") : command("launchApp", .map(settings))
        }

        /// Commands that take their settings, and so optional, as keys.
        static let selectorCommands: Set<String> = [
            "tapOn", "doubleTapOn", "longPressOn", "copyTextFrom", "assertVisible", "assertNotVisible",
        ]

        /// One step as Maestro commands; a problem, and nothing, when there is none.
        mutating func command(_ step: Flow.Step, number: String) -> [YAML.Out] {
            var commands: [YAML.Out]
            do {
                commands = try convert(step, number: number)
            } catch {
                problems.append("\(number). \(step.summary): \(error)")
                return []
            }
            guard step.optional else { return commands }
            return commands.map { command in
                guard case .map(let entries) = command, entries.count == 1 else {
                    problems.append("\(number). \(step.summary): this command cannot be optional in Maestro.")
                    return command
                }
                switch entries[0].1 {
                case .map(let settings):
                    return .map([(entries[0].0, .map(settings + [("optional", .bool(true))]))])
                case .string(let text) where Self.selectorCommands.contains(entries[0].0):
                    return .map([(entries[0].0, .map([("text", .string(text)), ("optional", .bool(true))]))])
                default:
                    problems.append("\(number). \(step.summary): this command cannot be optional in Maestro.")
                    return command
                }
            }
        }

        private struct NoCommand: Error, CustomStringConvertible {
            let description: String
            init(_ description: String) { self.description = description }
        }

        private func command(_ name: String, _ value: YAML.Out) -> YAML.Out { .map([(name, value)]) }

        private mutating func convert(_ step: Flow.Step, number: String) throws -> [YAML.Out] {
            if let control = step.control { return try convert(control, step: step, number: number) }
            let arguments = step.arguments
            func string(_ key: String) -> String? { arguments[key]?.stringValue }
            switch step.tool {
            case "launch_app":
                return [try launchApp(arguments, number: number)]
            case "reset_app", "stop_app":
                guard let bundle = string("bundle_id") else { throw NoCommand("it has no bundle_id.") }
                if arguments["keychain"]?.boolValue == true {
                    throw NoCommand("Maestro clears the keychain only with launchApp's clearKeychain; launch the app right after.")
                }
                let name = step.tool == "reset_app" ? "clearState" : "stopApp"
                return [bundle == appId ? .plain(name) : command(name, .string(bundle))]
            case "tap", "long_press":
                guard let x = arguments["x"], let y = arguments["y"] else { throw NoCommand("it has no x and y.") }
                let name =
                    step.tool == "long_press" ? "longPressOn" : arguments["double"]?.boolValue == true ? "doubleTapOn" : "tapOn"
                if x.stringValue == nil || y.stringValue == nil {
                    notes.append(
                        "\(number): the point is in pixels of Mobdev's screenshot; Maestro's pixels differ, so check it or use percentages.")
                }
                return [command(name, .map([("point", .string("\(coordinate(x)),\(coordinate(y))"))]))]
            case "tap_element", "tap_text":
                let name =
                    arguments["hold"] != nil ? "longPressOn" : arguments["double"]?.boolValue == true ? "doubleTapOn" : "tapOn"
                return [command(name, try selector(arguments, index: arguments["index"]?.doubleValue))]
            case "type_text":
                guard let text = string("text") else { throw NoCommand("it has no text.") }
                let typed =
                    text == "${\(Maestro.copiedText)}" ? YAML.Out.plain("pasteText") : command("inputText", .string(maestroVariables(text)))
                return [typed] + (arguments["submit"]?.boolValue == true ? [command("pressKey", .plain("Enter"))] : [])
            case "press_key":
                guard let key = string("key")?.lowercased() else { throw NoCommand("it has no key.") }
                guard arguments["modifiers"]?.arrayValue?.isEmpty ?? true else {
                    throw NoCommand("Maestro presses no key combinations.")
                }
                let count = Int(arguments["count"]?.doubleValue ?? 1)
                let name: String
                switch key {
                case "backspace", "delete": return [command("eraseText", .number(Double(count)))]
                case "enter", "return": name = "Enter"
                case "tab": name = "Tab"
                case "escape", "esc":
                    notes.append("\(number): press_key escape becomes back, as it is on Android.")
                    return Array(repeating: .plain("back"), count: count)
                case "volume_up": name = "Volume Up"
                case "volume_down": name = "Volume Down"
                case "up", "down", "left", "right": name = "Remote Dpad \(key.capitalized)"
                default: throw NoCommand("Maestro has no key \(key).")
                }
                return Array(repeating: command("pressKey", .plain(name)), count: count)
            case "home":
                return [command("pressKey", .plain("Home"))]
            case "wait_for_element", "wait_for_text":
                let gone = arguments["gone"]?.boolValue == true
                let seconds = arguments["timeout"]?.doubleValue ?? 10
                // The wait an assertion became goes back to the assertion.
                if seconds == Maestro.assertTimeout {
                    return [command(gone ? "assertNotVisible" : "assertVisible", try selector(arguments))]
                }
                return [
                    command(
                        "extendedWaitUntil",
                        .map([
                            (gone ? "notVisible" : "visible", try selector(arguments)),
                            ("timeout", .number((seconds * 1000).rounded())),
                        ]))
                ]
            case "scroll_until_visible":
                var settings: [(String, YAML.Out)] = [("element", try selector(arguments))]
                if let direction = string("direction") { settings.append(("direction", .plain(direction.uppercased()))) }
                if let scrolls = arguments["max_scrolls"]?.doubleValue { settings.append(("timeout", .number(scrolls * 2000))) }
                return [command("scrollUntilVisible", .map(settings))]
            case "scroll":
                // Maestro's scroll goes down; the other ways are swipes, the finger the other way.
                switch string("direction") {
                case "down": return [.plain("scroll")]
                case "up": return [command("swipe", .map([("direction", .plain("DOWN"))]))]
                case "left": return [command("swipe", .map([("direction", .plain("RIGHT"))]))]
                case "right": return [command("swipe", .map([("direction", .plain("LEFT"))]))]
                default: throw NoCommand("it has no direction.")
                }
            case "swipe":
                guard let fromX = arguments["from_x"], let fromY = arguments["from_y"], let toX = arguments["to_x"],
                    let toY = arguments["to_y"]
                else { throw NoCommand("it needs from_x, from_y, to_x and to_y.") }
                if [fromX, fromY, toX, toY].contains(where: { $0.stringValue == nil }) {
                    notes.append(
                        "\(number): the swipe is in pixels of Mobdev's screenshot; Maestro's pixels differ, so check it or use percentages.")
                }
                var settings: [(String, YAML.Out)] = [
                    ("start", .string("\(coordinate(fromX)), \(coordinate(fromY))")),
                    ("end", .string("\(coordinate(toX)), \(coordinate(toY))")),
                ]
                if let seconds = arguments["duration"]?.doubleValue {
                    settings.append(("duration", .number((seconds * 1000).rounded())))
                }
                return [command("swipe", .map(settings))]
            case "open_url":
                guard let url = string("url") else { throw NoCommand("it has no url.") }
                return [command("openLink", .string(maestroVariables(url)))]
            case "wait_for_idle":
                guard let seconds = arguments["timeout"]?.doubleValue else { return [.plain("waitForAnimationToEnd")] }
                return [command("waitForAnimationToEnd", .map([("timeout", .number((seconds * 1000).rounded()))]))]
            case "set_location":
                if let latitude = arguments["latitude"]?.doubleValue, let longitude = arguments["longitude"]?.doubleValue {
                    return [command("setLocation", .map([("latitude", .number(latitude)), ("longitude", .number(longitude))]))]
                }
                if let route = arguments["route"]?.arrayValue {
                    let points: [YAML.Out] = route.compactMap { point in
                        guard let latitude = point["latitude"]?.doubleValue, let longitude = point["longitude"]?.doubleValue
                        else { return nil }
                        return .string("\(JSONValue.number(latitude).compactString), \(JSONValue.number(longitude).compactString)")
                    }
                    // Maestro's speed is in km/h.
                    let speed = (arguments["speed"]?.doubleValue ?? 10) * 3.6
                    return [command("travel", .map([("points", .list(points)), ("speed", .number((speed * 10).rounded() / 10))]))]
                }
                throw NoCommand("Maestro cannot stop a simulated location.")
            case "set_orientation":
                let orientation: String? =
                    switch string("orientation") {
                    case "portrait": "PORTRAIT"
                    case "landscape_left": "LANDSCAPE_LEFT"
                    case "landscape_right": "LANDSCAPE_RIGHT"
                    case "portrait_upside_down": "UPSIDE_DOWN"
                    default: nil
                    }
                guard let orientation else { throw NoCommand("it has no orientation.") }
                return [command("setOrientation", .plain(orientation))]
            case "set_permission":
                guard let bundle = string("bundle_id"), let permission = string("permission") else {
                    throw NoCommand("it needs bundle_id and permission.")
                }
                let state: String =
                    switch string("state") ?? "grant" {
                    case "revoke": "deny"
                    case "reset": "unset"
                    default: "allow"
                    }
                var settings: [(String, YAML.Out)] = []
                if bundle != appId { settings.append(("appId", .string(bundle))) }
                let name = permission == "media-library" ? "medialibrary" : permission
                settings.append(("permissions", .map([(name, .plain(state))])))
                return [command("setPermissions", .map(settings))]
            default:
                throw NoCommand("no Maestro command does what \(step.tool) does.")
            }
        }

        private mutating func convert(_ control: Flow.Control, step: Flow.Step, number: String) throws -> [YAML.Out] {
            let inner = { (index: Int) in "\(number).\(index + 1)" }
            switch control {
            case .branch where control == Maestro.back.control:
                return [.plain("back")]
            case .branch(.platform(let platform), let then, let otherwise):
                // The platform does not change while a flow runs, so else is the other platform.
                let name = platform == "ios" ? "iOS" : "Android"
                var commands = [runFlow(when: [("platform", .plain(name))], then, number: inner)]
                if !otherwise.isEmpty {
                    let other = platform == "ios" ? "Android" : "iOS"
                    let offset = then.count
                    commands.append(runFlow(when: [("platform", .plain(other))], otherwise, number: { inner(offset + $0) }))
                }
                return commands
            case .branch(let condition, let then, let otherwise):
                guard otherwise.isEmpty else {
                    throw NoCommand(
                        "Maestro has no else, and two runFlows are not the same: the then steps may change what is visible.")
                }
                let when: (String, YAML.Out)
                switch condition {
                case .visible(let target): when = ("visible", try selector(target))
                case .notVisible(let target): when = ("notVisible", try selector(target))
                case .platform: throw NoCommand("a platform condition is handled above.")
                }
                return [runFlow(when: [when], then, number: inner)]
            case .loop(let loop, let steps):
                let settings: [(String, YAML.Out)] =
                    switch loop {
                    case .times(let times): [("times", .number(Double(times)))]
                    case .whileVisible(let target, let max):
                        [("while", .map([("visible", try selector(target))])), ("times", .number(Double(max)))]
                    case .untilVisible(let target, let max):
                        [("while", .map([("notVisible", try selector(target))])), ("times", .number(Double(max)))]
                    }
                return [command("repeat", .map(settings + [("commands", .list(commands(steps, number: inner)))]))]
            case .retry(let times, let steps):
                return [
                    command(
                        "retry", .map([("maxRetries", .number(Double(times))), ("commands", .list(commands(steps, number: inner)))]))
                ]
            case .subflow(let path, _):
                var target = path
                if !Maestro.isMaestroFile(URL(fileURLWithPath: path)) {
                    target = (path as NSString).deletingPathExtension + ".yaml"
                    notes.append("\(number): \(path) becomes \(target); convert it too: Mobdev convert \(path) > \(target).")
                }
                return [command("runFlow", .string(target))]
            case .set:
                throw NoCommand("Maestro sets variables only in env, at the start of a flow or in runFlow.")
            case .extract(let extraction):
                guard extraction.into == Maestro.copiedText else {
                    throw NoCommand(
                        "Maestro copies text only into ${maestro.copiedText}; extract into \(Maestro.copiedText) to export it.")
                }
                if extraction.from == "value" { notes.append("\(number): copyTextFrom copies the element's text.") }
                return [command("copyTextFrom", try selector(extraction.target, index: extraction.index.map(Double.init)))]
            }
        }

        /// runFlow with when around the steps; a first set step of plain values is its env.
        private mutating func runFlow(when: [(String, YAML.Out)], _ steps: [Flow.Step], number: @escaping (Int) -> String)
            -> YAML.Out
        {
            var settings: [(String, YAML.Out)] = [("when", .map(when))]
            var steps = steps
            var offset = 0
            if let env = Self.env(steps.first) {
                settings.append(("env", .map(env)))
                steps.removeFirst()
                offset = 1
            }
            settings.append(("commands", .list(commands(steps, number: { number(offset + $0) }))))
            return command("runFlow", .map(settings))
        }

        /// A set step of plain values, which needs no other variable, as Maestro's env.
        static func env(_ step: Flow.Step?) -> [(String, YAML.Out)]? {
            guard case .set(let values)? = step?.control, step?.optional == false,
                values.values.allSatisfy({ Variables.references(in: .string($0)).isEmpty })
            else { return nil }
            return values.keys.sorted().map { ($0, .string(values[$0]!)) }
        }

        /// A bare string for text, {id: …} for an identifier, with index when there is one.
        private func selector(_ arguments: [String: JSONValue], index: Double? = nil) throws -> YAML.Out {
            var settings: [(String, YAML.Out)]
            if let id = arguments["id"]?.stringValue {
                settings = [("id", .string(maestroVariables(id)))]
            } else if let text = arguments["text"]?.stringValue {
                guard let index else { return .string(pattern(text)) }
                settings = [("text", .string(pattern(text)))]
                settings.append(("index", .number(index)))
                return .map(settings)
            } else {
                throw NoCommand("it needs an id or a text.")
            }
            if let index { settings.append(("index", .number(index))) }
            return .map(settings)
        }

        private func selector(_ target: Flow.Target, index: Double? = nil) throws -> YAML.Out {
            try selector(target.id.map { ["id": .string($0)] } ?? ["text": .string(target.text ?? "")], index: index)
        }

        private func coordinate(_ value: JSONValue) -> String {
            value.stringValue ?? value.compactString
        }

        /// Maestro matches text as a regular expression, so its special characters are escaped;
        /// `${NAME}` stays a variable.
        private func pattern(_ text: String) -> String {
            var result = ""
            var rest = maestroVariables(text)[...]
            while let start = rest.range(of: "${"), let end = rest[start.upperBound...].firstIndex(of: "}") {
                result += NSRegularExpression.escapedPattern(for: String(rest[..<start.lowerBound]))
                result += rest[start.lowerBound...end]
                rest = rest[rest.index(after: end)...]
            }
            return result + NSRegularExpression.escapedPattern(for: String(rest))
        }

        /// The variable copyTextFrom fills is Maestro's ${maestro.copiedText}.
        private func maestroVariables(_ text: String) -> String {
            text.replacingOccurrences(of: "${\(Maestro.copiedText)}", with: "${maestro.copiedText}")
        }
    }
}
