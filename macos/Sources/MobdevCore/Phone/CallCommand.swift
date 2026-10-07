import Foundation
import ImageIO

/// `Mobdev call <tool> [arguments]` and its shorthand `Mobdev <tool> key=value …`: one tool call from
/// a shell, for scripts and for agents that prefer a terminal to MCP. `Mobdev tools` lists the tools.
///
/// The call goes to the running app when there is one, so it reaches iPhones too and shows in the
/// app's activity. Without the app, or with --local, it runs in this process on a booted simulator
/// or Android device, as `Mobdev flow` does.
///
/// Prints the tool's text, or with --json the whole result; --image saves a screenshot the tool
/// returned. Exits 0 when the tool succeeded, 1 when it reported an error and 2 when it could not run.
public enum CallCommand {
    static let usage = """
        Usage: Mobdev call <tool> ['{"json": "arguments"}' | key=value …] [--device <id or name>] [--image <file>] [--json] [--local]
               Mobdev <tool> [key=value …]        the same, e.g. Mobdev tap x=120 y=300
               Mobdev tools [--json]              lists the tools

        Runs one Mobdev tool. Values are JSON where they parse as JSON (numbers, true, false,
        arrays, objects) and text otherwise: Mobdev type_text text="hello world" submit=true.
          --device  the device from list_devices; needed when several are connected
          --image   where to save the screenshot the tool returns (.png or .jpg); for screenshot,
                    observe with image=true, and actions with screenshot=true
          --json    print the whole result as JSON
          --local   run here on a booted simulator or Android device, not through the app
                    (always so for a Mobdev built with swift build, outside the app)
        """

    struct Options: Equatable {
        var tool: String
        var arguments: [String: JSONValue] = [:]
        var device: String?
        var image: String?
        var json = false
        var local = false
    }

    public static func run(_ arguments: [String]) -> Never {
        CommandSupport.run { await execute(arguments, output: CommandSupport.print) }
    }

    /// Whether `Mobdev <word>` means a tool, for the shorthand.
    public static func isTool(_ name: String) -> Bool {
        DeviceTools.definitions.contains { $0.name == name }
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var rest = arguments[...]
        guard let tool = rest.popFirst(), !tool.hasPrefix("-") else { throw ToolFailure("Which tool? Mobdev tools lists them.") }
        var options = Options(tool: tool)
        while let argument = rest.popFirst() {
            switch argument {
            case "--json": options.json = true
            case "--local": options.local = true
            case "--device", "--image":
                guard let value = rest.popFirst() else { throw ToolFailure("\(argument) needs a value.") }
                if argument == "--device" { options.device = value } else { options.image = value }
            case "-h", "--help": throw ToolFailure("")
            default:
                if argument.hasPrefix("{") {
                    guard case .object(let object)? = try? JSONValue.parse(Data(argument.utf8)) else {
                        throw ToolFailure("\(argument) is not a JSON object.")
                    }
                    options.arguments.merge(object) { $1 }
                } else if let equals = argument.firstIndex(of: "="), equals != argument.startIndex {
                    let key = String(argument[..<equals])
                    options.arguments[key] = value(String(argument[argument.index(after: equals)...]))
                } else {
                    throw ToolFailure("Unexpected \(argument). Pass arguments as key=value or as one JSON object.")
                }
            }
        }
        if let device = options.device { options.arguments["device"] = .string(device) }
        return options
    }

    /// JSON where the text is JSON, such as 12, true or [1,2]; text otherwise.
    static func value(_ text: String) -> JSONValue {
        if let parsed = try? JSONValue.parse(Data(text.utf8)) { return parsed }
        return .string(text)
    }

    static func execute(_ arguments: [String], output: @escaping @Sendable (String) -> Void) async -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            let message = String(describing: error)
            output(message.isEmpty ? usage : "\(message)\n\n\(usage)")
            return 2
        }
        guard isTool(options.tool) else {
            output("Unknown tool \(options.tool). Mobdev tools lists them.")
            return 2
        }
        var result: JSONValue
        do {
            // A binary outside an app bundle, as `swift build` makes, never reaches the installed
            // app: a developer's test call must not act on the iPhone that app controls.
            if options.local || MobdevPaths.appBundle == nil { throw LocalSocket.Failure.notRunning }
            result = try await callApp(options)
        } catch LocalSocket.Failure.notRunning {
            guard let local = await callHere(options, output: output) else { return 2 }
            result = local
        } catch {
            // It may have run, so it is not run again here: a second tap or text could do harm.
            output("Cannot reach Mobdev: \(error). The call may or may not have been carried out.")
            return 2
        }
        if let path = options.image {
            if let encoded = result["screenshot"]?["data"]?.stringValue, var data = Data(base64Encoded: encoded) {
                // Tools return JPEG; a .png name gets a PNG.
                if path.lowercased().hasSuffix(".png"), let source = CGImageSourceCreateWithData(data as CFData, nil),
                    let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let png = ImageTools.encode(image, png: true)
                {
                    data = png.data
                }
                do {
                    try data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                } catch {
                    output("Could not save the screenshot to \(path): \(error.localizedDescription)")
                    return 2
                }
            } else {
                output("The tool returned no screenshot to save. Pass screenshot=true for actions, image=true for observe.")
            }
        }
        if options.json {
            // The picture goes to --image or nowhere, never into the terminal.
            if case .object(var object) = result, case .object(var screenshot)? = object["screenshot"] {
                screenshot["data"] = nil
                if let path = options.image { screenshot["file"] = .string(path) }
                object["screenshot"] = .object(screenshot)
                result = .object(object)
            }
            output(String(decoding: result.encoded(), as: UTF8.self))
        } else {
            output(result["text"]?.stringValue ?? "")
        }
        return result["ok"]?.boolValue == true ? 0 : 1
    }

    /// Through the running app's private socket. Throws `LocalSocket.Failure.notRunning`, having sent
    /// nothing, when the app does not run.
    static func callApp(_ options: Options) async throws -> JSONValue {
        var headers = ["Content-Type": "application/json"]
        if let token = SecretStore.read(MobdevPaths.tokenFile) { headers["Authorization"] = "Bearer \(token)" }
        let body = JSONValue.object(options.arguments).encoded()
        let request = MCPStdioBridge.Bridge.request("POST", "/v1/tools/\(options.tool)", headers: headers, body: body)
        let response = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try LocalSocket.exchange(request, at: MobdevPaths.socketFile, timeout: 600) })
            }
        }
        let (data, status) = try MCPStdioBridge.Bridge.parse(response)
        guard let value = try? JSONValue.parse(data) else {
            return ["ok": false, "text": .string("Mobdev answered with status \(status) and no result.")]
        }
        // An unknown tool or a bad body comes back as {"error": …} without "text".
        if value["text"] == nil, let error = value["error"]?.stringValue { return ["ok": false, "text": .string(error)] }
        return value
    }

    /// In this process, on a booted simulator or Android device.
    static func callHere(_ options: Options, output: @escaping @Sendable (String) -> Void) async -> JSONValue? {
        if ["start_recording", "stop_recording", "tap_mark"].contains(options.tool) {
            output(
                "\(options.tool) needs the running Mobdev app: without it every call is a process of its own, which forgets the recording or the marks when it ends. Open Mobdev, or record a flow with Mobdev flow --artifacts.")
            return nil
        }
        let home = CommandSupport.home(artifacts: nil)
        defer { try? FileManager.default.removeItem(at: home.url) }
        guard let connection = await CommandSupport.connect(device: options.device, wait: 10, output: output) else {
            return nil
        }
        defer { connection.emulators.stop() }
        var arguments = options.arguments
        arguments["device"] = .string(connection.device.id)
        do {
            let result = try await connection.tools.call(
                options.tool, arguments: .object(arguments), source: "cli", screenshotByDefault: false)
            var body: [String: JSONValue] = ["ok": .bool(!result.isError), "text": .string(result.text)]
            if let data = result.data { body["data"] = data }
            if let image = result.image {
                body["screenshot"] = [
                    "mime_type": .string(image.mimeType), "width": .number(Double(image.width)),
                    "height": .number(Double(image.height)), "data": .string(image.data.base64EncodedString()),
                ]
            }
            return .object(body)
        } catch {
            output(String(describing: error))
            return nil
        }
    }

    /// Up to the first ". " that ends a sentence, not one inside "e.g." or a file name such as ".mp4".
    static func firstSentence(_ text: String) -> String {
        var searchStart = text.startIndex
        while let range = text.range(of: ". ", range: searchStart..<text.endIndex) {
            let before = text[text.startIndex..<range.lowerBound]
            let next = text[range.upperBound...].first
            if !before.hasSuffix("e.g"), !before.hasSuffix("i.e"), next?.isUppercase == true || next == "`" {
                return String(before) + "."
            }
            searchStart = range.upperBound
        }
        return text
    }

    /// `Mobdev tools`: every tool with its description, or with --json their schemas.
    public static func listTools(_ arguments: [String]) -> Never {
        let definitions = DeviceTools.definitions
        if arguments.contains("--json") {
            CommandSupport.print(String(decoding: JSONValue.array(definitions.map(\.mcpJSON)).encoded(), as: UTF8.self))
        } else {
            for definition in definitions {
                CommandSupport.print("\(definition.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(firstSentence(definition.description))")
            }
        }
        exit(0)
    }
}
