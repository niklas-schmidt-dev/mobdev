import CoreGraphics
import Foundation

public struct ToolDefinition: Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    public let readOnly: Bool

    /// The tool as listed by MCP `tools/list`.
    public var mcpJSON: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": ["title": .string(title), "readOnlyHint": .bool(readOnly), "openWorldHint": true],
        ]
    }
}

public struct ToolOutput: Sendable {
    public var text: String
    public var data: JSONValue?
    public var image: EncodedImage?
    public var isError: Bool

    public init(text: String, data: JSONValue? = nil, image: EncodedImage? = nil, isError: Bool = false) {
        self.text = text
        self.data = data
        self.image = image
        self.isError = isError
    }
}

public struct UnknownToolError: Error, CustomStringConvertible {
    public let name: String
    public var description: String { "Unknown tool: \(name)" }
}

/// A problem the agent can fix, reported as a tool error rather than a protocol error.
struct ToolFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The phone actions shared by MCP, the REST API and the relay.
public final class PhoneTools: Sendable {
    let phone: PhoneBackend
    private let activity: ActivityLog
    private let settleDelay: TimeInterval

    public init(phone: PhoneBackend, activity: ActivityLog, settleDelay: TimeInterval = 0.6) {
        self.phone = phone
        self.activity = activity
        self.settleDelay = settleDelay
    }

    /// Typing takes about 60 ms per character and holds the phone's input until done, so one call
    /// stays well within the relays' 90-second limit.
    static let maxTypedCharacters = 1000

    public static let instructions = """
        Mobdev controls a real iPhone connected to this Mac: it reads the screen over USB and taps and \
        types as a Bluetooth keyboard and pointer. Coordinates are pixels of the image returned by \
        `screenshot` (origin top-left); the size never changes while the phone keeps its orientation. \
        Prefer `tap_text` and `find_text` for visible labels, and `open_app` to launch an app by name. \
        Actions return a fresh screenshot unless `screenshot` is false. The phone must stay unlocked. \
        With Developer Mode on the iPhone and Xcode on the Mac, `install_app`, `launch_app`, `logs` and \
        `crash_reports` close the loop for apps you build: install a build, run it, read its output.
        """

    /// A tool's input schema. Tools with `screenshot` return a screenshot after acting.
    static func schema(_ properties: [String: JSONValue], required: [String] = [], screenshot: Bool = true)
        -> JSONValue
    {
        var properties = properties
        if screenshot {
            properties["screenshot"] = [
                "type": "boolean", "description": "Return a screenshot after the action (default true over MCP)",
            ]
        }
        return [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": false,
        ]
    }

    public static let definitions: [ToolDefinition] = {
        let point: [String: JSONValue] = [
            "x": ["type": "number", "description": "X in screenshot pixels"],
            "y": ["type": "number", "description": "Y in screenshot pixels"],
        ]
        func schema(_ properties: [String: JSONValue], required: [String] = [], screenshot: Bool = true) -> JSONValue {
            PhoneTools.schema(properties, required: required, screenshot: screenshot)
        }
        return [
            ToolDefinition(
                name: "status", title: "Phone status",
                description: "Whether the iPhone screen (USB) and input (Bluetooth) are ready, and the screenshot size.",
                inputSchema: schema([:], screenshot: false), readOnly: true),
            ToolDefinition(
                name: "screenshot", title: "Screenshot",
                description: "Capture the iPhone screen. Tap and swipe coordinates are pixels of this image.",
                inputSchema: schema([:], screenshot: false), readOnly: true),
            ToolDefinition(
                name: "tap", title: "Tap",
                description: "Tap at a point of the screenshot.",
                inputSchema: schema(point, required: ["x", "y"]), readOnly: false),
            ToolDefinition(
                name: "long_press", title: "Long press",
                description: "Touch and hold at a point, e.g. for context menus or to rearrange icons.",
                inputSchema: schema(
                    point.merging(["seconds": ["type": "number", "description": "Hold time, default 1"]]) { $1 },
                    required: ["x", "y"]), readOnly: false),
            ToolDefinition(
                name: "swipe", title: "Swipe",
                description:
                    "Drag from one point to another. To scroll a list down, swipe up: from a larger y to a smaller y.",
                inputSchema: schema(
                    [
                        "from_x": ["type": "number"], "from_y": ["type": "number"],
                        "to_x": ["type": "number"], "to_y": ["type": "number"],
                        "duration": ["type": "number", "description": "Seconds, default 0.3"],
                    ], required: ["from_x", "from_y", "to_x", "to_y"]), readOnly: false),
            ToolDefinition(
                name: "scroll", title: "Scroll",
                description:
                    "Scroll with the mouse wheel at a point (default: screen center). \"down\" reveals content further down.",
                inputSchema: schema(
                    point.merging([
                        "direction": ["type": "string", "enum": ["up", "down"]],
                        "amount": ["type": "integer", "description": "Wheel steps, default 5"],
                    ]) { $1 }, required: ["direction"]), readOnly: false),
            ToolDefinition(
                name: "type_text", title: "Type text",
                description:
                    "Type text into the focused field with the hardware keyboard. Tap the field first. Set submit to press Return afterwards. At most 1000 characters per call; send longer text in several calls.",
                inputSchema: schema(
                    ["text": ["type": "string"], "submit": ["type": "boolean", "description": "Press Return after typing"]],
                    required: ["text"]), readOnly: false),
            ToolDefinition(
                name: "press_key", title: "Press key",
                description:
                    "Press a key with optional modifiers, e.g. {\"key\":\"space\",\"modifiers\":[\"cmd\"]} for Spotlight. Keys: enter, escape, backspace, tab, space, up, down, left, right, home, end, pageup, pagedown, f1-f12, or one character.",
                inputSchema: schema(
                    [
                        "key": ["type": "string"],
                        "modifiers": [
                            "type": "array",
                            "items": ["type": "string", "enum": ["cmd", "shift", "option", "ctrl"]],
                        ],
                    ], required: ["key"]), readOnly: false),
            ToolDefinition(
                name: "home", title: "Go home",
                description: "Go to the home screen.",
                inputSchema: schema([:]), readOnly: false),
            ToolDefinition(
                name: "open_app", title: "Open app",
                description: "Open an installed app by name through Spotlight search.",
                inputSchema: schema(["name": ["type": "string"]], required: ["name"]), readOnly: false),
            ToolDefinition(
                name: "read_screen", title: "Read screen",
                description:
                    "Recognize all visible text on the screen with its position (on-device OCR). Cheaper than a screenshot.",
                inputSchema: schema([:], screenshot: false), readOnly: true),
            ToolDefinition(
                name: "find_text", title: "Find text",
                description: "Find visible text (case and accent insensitive) and return where it is.",
                inputSchema: schema(["text": ["type": "string"]], required: ["text"], screenshot: false),
                readOnly: true),
            ToolDefinition(
                name: "tap_text", title: "Tap text",
                description:
                    "Tap visible text such as a button label. Exact matches win over partial ones. If the text appears more than once, pass index (0 = topmost).",
                inputSchema: schema(
                    ["text": ["type": "string"], "index": ["type": "integer", "minimum": 0]], required: ["text"]),
                readOnly: false),
            ToolDefinition(
                name: "wait_for_text", title: "Wait for text",
                description: "Wait until text appears (or disappears with gone=true).",
                inputSchema: schema(
                    [
                        "text": ["type": "string"],
                        "timeout": ["type": "number", "description": "Seconds, default 10, at most 60"],
                        "gone": ["type": "boolean"],
                    ], required: ["text"]), readOnly: true),
        ] + appDefinitions
    }()

    public static func definition(named name: String) -> ToolDefinition? {
        definitions.first { $0.name == name }
    }

    /// Runs a tool. Unknown tools throw; everything else becomes a result, errors included.
    public func call(
        _ name: String, arguments: JSONValue?, source: String, screenshotByDefault: Bool
    ) async throws -> ToolOutput {
        guard let definition = Self.definition(named: name) else { throw UnknownToolError(name: name) }
        let args = Arguments(arguments ?? [:])
        do {
            var output = try await run(name, args)
            let wantsScreenshot = args.bool("screenshot") ?? screenshotByDefault
            let offersScreenshot = definition.inputSchema["properties"]?["screenshot"] != nil && !definition.readOnly
            if wantsScreenshot, output.image == nil, offersScreenshot {
                try await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
                output.image = phone.frame().flatMap(ImageTools.screenshot)
            }
            activity.record(source: source, tool: name, summary: summary(name, args, output), failed: false)
            return output
        } catch {
            let message = String(describing: error)
            activity.record(source: source, tool: name, summary: message, failed: true)
            return ToolOutput(text: message, isError: true)
        }
    }

    // MARK: Tools

    private func run(_ name: String, _ args: Arguments) async throws -> ToolOutput {
        switch name {
        case "status":
            return statusOutput()
        case "screenshot":
            let (frame, _) = try currentFrame()
            guard let image = ImageTools.screenshot(frame) else { throw ToolFailure("Could not encode the screenshot.") }
            return ToolOutput(
                text: "Screenshot \(image.width)×\(image.height) px. Tap coordinates are pixels of this image.",
                data: ["width": .number(Double(image.width)), "height": .number(Double(image.height))], image: image)
        case "tap":
            let point = try self.point(args, "x", "y")
            try requireTouch()
            try await phone.tap(at: point, hold: 0.08)
            return ToolOutput(text: "Tapped \(try describe(point)).")
        case "long_press":
            let point = try self.point(args, "x", "y")
            let seconds = try args.number("seconds", default: 1, range: 0.2...10)
            try requireTouch()
            try await phone.tap(at: point, hold: seconds)
            return ToolOutput(text: "Pressed \(try describe(point)) for \(seconds) s.")
        case "swipe":
            let start = try self.point(args, "from_x", "from_y")
            let end = try self.point(args, "to_x", "to_y")
            let duration = try args.number("duration", default: 0.3, range: 0.05...5)
            try requireTouch()
            try await phone.swipe(from: start, to: end, duration: duration)
            return ToolOutput(text: "Swiped from \(try describe(start)) to \(try describe(end)).")
        case "scroll":
            let point =
                args.has("x") || args.has("y") ? try self.point(args, "x", "y") : NormalizedPoint(x: 0.5, y: 0.5)
            let direction = try args.string("direction")
            guard direction == "up" || direction == "down" else {
                throw ToolFailure("direction must be \"up\" or \"down\". Use swipe to move sideways.")
            }
            let amount = Int(try args.number("amount", default: 5, range: 1...50))
            try requireTouch()
            try await phone.scroll(at: point, ticks: direction == "up" ? amount : -amount)
            return ToolOutput(text: "Scrolled \(direction) by \(amount).")
        case "type_text":
            let text = try args.string("text", maxLength: Self.maxTypedCharacters)
            let layout = phone.status().keyboardLayout
            var strokes = try layout.strokes(typing: text)
            if args.bool("submit") == true { strokes.append(KeyStroke(0x28)) }
            try requireTouch()
            try await phone.type(strokes)
            return ToolOutput(text: "Typed \(text.count) characters\(args.bool("submit") == true ? " and pressed Return" : "").")
        case "press_key":
            let key = try args.string("key")
            let modifiers = args.strings("modifiers")
            let stroke = try phone.status().keyboardLayout.stroke(forKey: key, modifiers: modifiers)
            try requireTouch()
            try await phone.press(stroke)
            return ToolOutput(text: "Pressed \((modifiers + [key]).joined(separator: "+")).")
        case "home":
            try requireTouch()
            try await phone.press(.home)
            return ToolOutput(text: "Went to the home screen.")
        case "open_app":
            let name = try args.string("name", maxLength: 100)
            let layout = phone.status().keyboardLayout
            let strokes = try layout.strokes(typing: name)
            try requireTouch()
            try await phone.press(.home)
            try await pause(0.6)
            try await phone.press(.search)
            try await pause(0.8)
            try await phone.type(strokes)
            try await pause(1.0)
            try await phone.press(KeyStroke(0x28))
            try await pause(1.0)
            return ToolOutput(text: "Searched Spotlight for \"\(name)\" and opened the top hit.")
        case "read_screen":
            let (frame, size) = try currentFrame()
            let lines = try TextRecognizer.lines(in: frame)
            let text = lines.isEmpty
                ? "No text recognized."
                : lines.map { "\($0.text) @ \(coordinates($0.center, size))" }.joined(separator: "\n")
            return ToolOutput(text: text, data: .array(lines.map { matchJSON($0, size) }))
        case "find_text":
            let query = try args.string("text")
            let (frame, size) = try currentFrame()
            let matches = try TextRecognizer.find(query, in: frame)
            let text = matches.isEmpty
                ? "\"\(query)\" is not visible."
                : matches.enumerated().map { index, match in
                    "\(index): \(match.text) @ \(coordinates(match.center, size))\(match.exact ? " (exact)" : "")"
                }.joined(separator: "\n")
            return ToolOutput(text: text, data: .array(matches.map { matchJSON($0, size) }))
        case "tap_text":
            let query = try args.string("text")
            let (frame, size) = try currentFrame()
            try requireTouch()
            let matches = try TextRecognizer.find(query, in: frame)
            let exact = matches.filter(\.exact)
            let candidates = exact.isEmpty ? matches : exact
            guard !candidates.isEmpty else {
                throw ToolFailure("\"\(query)\" is not visible. Use read_screen or screenshot to see what is.")
            }
            let index = args.has("index") ? Int(try args.number("index", default: 0, range: 0...999)) : nil
            if index == nil, candidates.count > 1 {
                let list = candidates.enumerated().map { "\($0): \($1.text) @ \(coordinates($1.center, size))" }
                throw ToolFailure(
                    "\"\(query)\" appears \(candidates.count) times. Pass index:\n" + list.joined(separator: "\n"))
            }
            let chosen = index ?? 0
            guard chosen < candidates.count else {
                throw ToolFailure("index \(chosen) is out of range; \(candidates.count) matches.")
            }
            let match = candidates[chosen]
            try await phone.tap(at: match.center, hold: 0.08)
            return ToolOutput(text: "Tapped \"\(match.text)\" at \(coordinates(match.center, size)).")
        case "wait_for_text":
            let query = try args.string("text")
            let timeout = try args.number("timeout", default: 10, range: 0...60)
            let gone = args.bool("gone") ?? false
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let (frame, _) = try currentFrame()
                let visible = !(try TextRecognizer.find(query, in: frame)).isEmpty
                if visible != gone {
                    return ToolOutput(text: gone ? "\"\(query)\" is gone." : "\"\(query)\" is visible.")
                }
                if Date() >= deadline {
                    throw ToolFailure(
                        "Timed out after \(timeout) s: \"\(query)\" \(gone ? "is still visible" : "did not appear").")
                }
                try await pause(0.5)
            }
        default:
            return try await runAppTool(name, args)
        }
    }

    // MARK: Helpers

    private func statusOutput() -> ToolOutput {
        let status = phone.status()
        var screenshot: JSONValue = .null
        var lines = ["Screen (USB): \(status.screen.summary)", "Input (Bluetooth): \(status.bluetooth.summary)"]
        if let size = status.frameSize {
            let shot = ScreenGeometry.screenshotSize(forFrameWidth: size.width, height: size.height)
            screenshot = ["width": .number(Double(shot.width)), "height": .number(Double(shot.height))]
            lines.append("Screenshot coordinates: \(shot.width)×\(shot.height) px")
        }
        lines.append("Keyboard layout: \(status.keyboardLayout.displayName)")
        let ready = status.frameSize != nil && status.bluetooth.isConnected
        lines.insert(ready ? "Ready." : "Not ready.", at: 0)
        return ToolOutput(
            text: lines.joined(separator: "\n"),
            data: [
                "ready": .bool(ready),
                "screen": ["connected": .bool(status.screen.isConnected), "summary": .string(status.screen.summary)],
                "bluetooth": [
                    "connected": .bool(status.bluetooth.isConnected), "summary": .string(status.bluetooth.summary),
                ],
                "screenshot": screenshot,
                "keyboard_layout": .string(status.keyboardLayout.rawValue),
            ])
    }

    private func currentFrame() throws -> (CGImage, (width: Int, height: Int)) {
        let status = phone.status()
        guard status.screen.isConnected, let frame = phone.frame() else {
            throw ToolFailure("The iPhone screen is not available. \(status.screen.summary).")
        }
        let size = ScreenGeometry.screenshotSize(forFrameWidth: frame.width, height: frame.height)
        return (frame, size)
    }

    private func screenshotSize() throws -> (width: Int, height: Int) {
        let status = phone.status()
        guard let frame = status.frameSize else {
            throw ToolFailure("The iPhone screen is not available. \(status.screen.summary).")
        }
        return ScreenGeometry.screenshotSize(forFrameWidth: frame.width, height: frame.height)
    }

    private func point(_ args: Arguments, _ xKey: String, _ yKey: String) throws -> NormalizedPoint {
        let size = try screenshotSize()
        let x = try args.number(xKey)
        let y = try args.number(yKey)
        guard (0...Double(size.width)).contains(x), (0...Double(size.height)).contains(y) else {
            throw ToolFailure(
                "(\(format(x)), \(format(y))) is outside the screenshot, which is \(size.width)×\(size.height) px.")
        }
        return NormalizedPoint(x: x / Double(size.width), y: y / Double(size.height))
    }

    private func requireTouch() throws {
        guard phone.status().bluetooth.isConnected else { throw HIDError.notConnected }
    }

    private func describe(_ point: NormalizedPoint) throws -> String {
        coordinates(point, try screenshotSize())
    }

    private func coordinates(_ point: NormalizedPoint, _ size: (width: Int, height: Int)) -> String {
        "(\(Int((point.x * Double(size.width)).rounded())), \(Int((point.y * Double(size.height)).rounded())))"
    }

    private func matchJSON(_ match: TextMatch, _ size: (width: Int, height: Int)) -> JSONValue {
        let w = Double(size.width)
        let h = Double(size.height)
        return [
            "text": .string(match.text),
            "x": .number((match.center.x * w).rounded()),
            "y": .number((match.center.y * h).rounded()),
            "box": [
                .number((match.box.minX * w).rounded()), .number((match.box.minY * h).rounded()),
                .number((match.box.width * w).rounded()), .number((match.box.height * h).rounded()),
            ],
            "exact": .bool(match.exact),
        ]
    }

    private func summary(_ name: String, _ args: Arguments, _ output: ToolOutput) -> String {
        switch name {
        case "type_text": "typed \((args.value["text"]?.stringValue ?? "").count) characters"
        default: output.text.split(separator: "\n").first.map(String.init) ?? name
        }
    }

    private func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Also used for coordinates that failed validation, so it must not trap on huge values.
    private func format(_ value: Double) -> String {
        if value.rounded() == value, let integer = Int(exactly: value) { return String(integer) }
        return String(format: "%.1f", value)
    }
}

struct Arguments {
    let value: JSONValue

    init(_ value: JSONValue) { self.value = value }

    func has(_ key: String) -> Bool { value[key].map { !$0.isNull } ?? false }

    func number(_ key: String) throws -> Double {
        guard let number = value[key]?.doubleValue, number.isFinite else {
            throw ToolFailure("\(key) must be a number.")
        }
        return number
    }

    func number(_ key: String, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
        guard has(key) else { return fallback }
        let number = try number(key)
        guard range.contains(number) else {
            throw ToolFailure("\(key) must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return number
    }

    func string(_ key: String) throws -> String {
        guard let string = value[key]?.stringValue, !string.isEmpty else {
            throw ToolFailure("\(key) must be a non-empty string.")
        }
        return string
    }

    func string(_ key: String, maxLength: Int) throws -> String {
        let string = try string(key)
        guard string.count <= maxLength else {
            throw ToolFailure("\(key) has \(string.count) characters; at most \(maxLength) per call.")
        }
        return string
    }

    func strings(_ key: String) -> [String] {
        value[key]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    func bool(_ key: String) -> Bool? { value[key]?.boolValue }
}
