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
    let activity: ActivityLog
    private let settleDelay: TimeInterval
    /// Every line of an image (query nil) or where a query is; Vision unless a test replaces it.
    let readText: @Sendable (CGImage, String?) throws -> [TextMatch]
    /// How long past its timeout an element wait keeps trying a tree that cannot be read yet.
    let unreadableGrace: TimeInterval
    /// Collects this device's calls while a flow is being recorded.
    public let recorder = FlowRecorder()
    /// The newest successful actions, always, so `recent_steps` can turn what just worked into a test.
    let history = FlowRecorder(limit: 200)
    /// The flow, test run or crawl that holds this device while it runs.
    let hold = Locked<DeviceHold?>(nil)
    /// The marks of the last `observe`, for `tap_mark`.
    let observed = Locked<ObservedMarks?>(nil)
    /// The screen recording `start_recording` started.
    let recording = Locked<ActiveRecording?>(nil)
    /// iOS apps whose requests `start_network_capture` reads; Android's are in its proxy.
    let appNetwork = AppNetworkCapture()
    /// Answers `assert_with_ai`: Apple Intelligence unless a test replaces it.
    let judge: any ScreenJudge
    /// Builds sent from elsewhere, which `install_app` takes as `upload`.
    let uploads: UploadStore
    /// The projects of this process, shared by every device: where recordings, screenshots,
    /// baselines and runs go when a call gives no path.
    let projects: ProjectList

    public convenience init(
        phone: PhoneBackend, activity: ActivityLog, settleDelay: TimeInterval = 0.6, uploads: UploadStore = .shared,
        projects: ProjectList = ProjectList()
    ) {
        self.init(phone: phone, activity: activity, settleDelay: settleDelay, uploads: uploads, projects: projects) {
            try TextRecognizer.read($0, query: $1)
        }
    }

    init(
        phone: PhoneBackend, activity: ActivityLog, settleDelay: TimeInterval,
        unreadableGrace: TimeInterval = PhoneTools.unreadableGrace, judge: any ScreenJudge = AppleIntelligenceJudge(),
        uploads: UploadStore = .shared, projects: ProjectList = ProjectList(),
        readText: @escaping @Sendable (CGImage, String?) throws -> [TextMatch]
    ) {
        self.phone = phone
        self.activity = activity
        self.settleDelay = settleDelay
        self.unreadableGrace = unreadableGrace
        self.judge = judge
        self.uploads = uploads
        self.projects = projects
        self.readText = readText
        history.start()
    }

    /// Typing takes about 60 ms per character and holds the phone's input until done, so one call
    /// stays well within the relays' 90-second limit.
    static let maxTypedCharacters = 1000

    public static let instructions = """
        Mobdev controls a real iPhone connected to this Mac: it reads the screen over USB. With Developer \
        Mode on the iPhone and Xcode on the Mac, Mobdev Runner, a UI test Mobdev keeps running on the \
        iPhone, taps, swipes, types any text and presses keys and buttons; `status` says "Input: Mobdev \
        Runner (Developer Mode)". Without Developer Mode, Mobdev taps and types as a Bluetooth keyboard \
        and pointer: swipes then need AssistiveTouch with Snap to Item off and Perform Touch Gestures on, \
        `status` shows what the pointer does once it has been checked, and `swipe` refuses when it snaps. \
        `pinch` zooms with two fingers, on every device but an iPhone over Bluetooth. \
        Coordinates are pixels of the image returned by `screenshot` (origin top-left); the size never \
        changes while the phone keeps its orientation. Prefer `tap_text` and `find_text` for visible \
        labels, and `open_app` to launch an app by name. Actions return a fresh screenshot unless \
        `screenshot` is false. The phone must stay unlocked. \
        With Developer Mode, `install_app`, `launch_app`, `logs` and `crash_reports` close the loop for \
        apps you build: install a build, run it, read its output. \
        Booted iOS simulators and Android emulators and phones (through adb) take the same tools with \
        nothing to set up; `list_devices` shows every device and `device` picks one. On Android, \
        `press_key` escape is Back and `open_app` matches package names such as com.android.settings. \
        On simulators, Android and iPhones with Mobdev Runner, `ui_tree` lists the elements on \
        screen, and `tap_element` and `wait_for_element` find them by accessibility identifier or label: \
        prefer them to OCR there. \
        `observe` lists what is on screen as numbered marks, cheaper than a screenshot; `tap_mark` taps one. \
        `scroll_until_visible` scrolls to an element or text, `wait_for_idle` waits until the screen stops moving. \
        Set device state directly instead of tapping through Settings: `set_location`, `set_permission`, \
        `send_push`, `set_appearance`, `set_language`, `set_status_bar`, `biometrics`, `reset_app`, \
        `clipboard` and `set_orientation` (simulators and Android; some on iPhones with Developer Mode). \
        `start_recording` and `stop_recording` keep a video of the screen; `save_screenshot` saves the \
        screen at full resolution, e.g. for App Store screenshots. \
        `performance` samples an app's CPU, memory and frames and `measure_launch` times its cold launch, \
        both with optional budgets that fail the call; `record_trace` records an Instruments template \
        (iPhones, simulators) or a Perfetto trace (Android) and `device_load` shows the whole device's \
        busiest processes, memory and thermal state; `reload_app` and `dev_menu` reload a React Native \
        or Expo app and open its developer menu. \
        `start_network_capture`, `network_log` and `stop_network_capture` show which requests an app makes \
        (Android through Mobdev's proxy, iOS from the app's own CFNetwork log; HTTPS is not decrypted). \
        Checks fail a flow or test step when the screen does not pass: `assert_screenshot` compares it with \
        a baseline picture, `accessibility_audit` finds missing labels, small targets and low contrast, and \
        `assert_with_ai` asks Apple Intelligence on the Mac a yes/no question about it. \
        `run_flow` replays a saved list of tool calls and stops at the first failing step; control steps \
        (if, repeat, retry, run, set, extract) check the screen instead of guessing waits, and Maestro \
        .yaml flows run too. \
        A project is a folder in the app's repository, usually mobdev/, with mobdev.json, tests/, flows/, \
        baselines/, screenshots/ and maps/ (versioned) and output/ (runs, recordings, crawls; ignored). \
        Without a path, recordings, screenshots, baselines, crawls and runs go into the project: the one \
        of your working folder, else the active one (`list_projects`, `open_project`, `create_project`; ask \
        before creating one). `list_tests` shows its tests, `save_test` and `save_flow` write one, \
        `run_tests` runs them on a device with a video and a screenshot of each failure, and \
        `test_result` returns the newest results. `run_native_tests` runs the app's own XCTest or \
        Gradle suite on the device in the background and `native_test_result` reads its failures with \
        file and line. \
        With an App Store Connect key in Mobdev's settings, `appstore_apps`, `appstore_builds`, \
        `appstore_testflight`, `appstore_versions` and `appstore_reviews` read the user's apps, builds, \
        TestFlight groups, review states and customer reviews; the tools that change App Store Connect \
        work only when the user allowed it there.
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
            "x": ["type": ["number", "string"], "description": "X in screenshot pixels, or a share of the width like \"50%\""],
            "y": ["type": ["number", "string"], "description": "Y in screenshot pixels, or a share of the height like \"50%\""],
        ]
        let coordinate: JSONValue = ["type": ["number", "string"]]
        let double: JSONValue = ["type": "boolean", "description": "Tap twice quickly, a double tap"]
        let hold: JSONValue = ["type": "number", "description": "Hold this many seconds, a long press (0.2 to 10)"]
        func schema(_ properties: [String: JSONValue], required: [String] = [], screenshot: Bool = true) -> JSONValue {
            PhoneTools.schema(properties, required: required, screenshot: screenshot)
        }
        return [
            ToolDefinition(
                name: "status", title: "Phone status",
                description:
                    "Whether the screen and input are ready, how input reaches the device (on an iPhone: Mobdev Runner with Developer Mode, or Bluetooth), and the screenshot size.",
                inputSchema: schema([:], screenshot: false), readOnly: true),
            ToolDefinition(
                name: "screenshot", title: "Screenshot",
                description: "Capture the iPhone screen. Tap and swipe coordinates are pixels of this image.",
                inputSchema: schema([:], screenshot: false), readOnly: true),
            ToolDefinition(
                name: "tap", title: "Tap",
                description: "Tap at a point of the screenshot. double taps twice quickly.",
                inputSchema: schema(point.merging(["double": double]) { $1 }, required: ["x", "y"]), readOnly: false),
            ToolDefinition(
                name: "long_press", title: "Long press",
                description: "Touch and hold at a point, e.g. for context menus or to rearrange icons.",
                inputSchema: schema(
                    point.merging(["seconds": ["type": "number", "description": "Hold time, default 1"]]) { $1 },
                    required: ["x", "y"]), readOnly: false),
            ToolDefinition(
                name: "swipe", title: "Swipe",
                description:
                    "Drag from one point to another. To scroll a list down, swipe up: from a larger y to a smaller y. On an iPhone over Bluetooth the first swipe checks the pointer without clicking; if it snaps to items (AssistiveTouch Snap to Item on), the swipe fails instead of tapping.",
                inputSchema: schema(
                    [
                        "from_x": coordinate, "from_y": coordinate, "to_x": coordinate, "to_y": coordinate,
                        "duration": ["type": "number", "description": "Seconds, default 0.3"],
                    ], required: ["from_x", "from_y", "to_x", "to_y"]), readOnly: false),
            ToolDefinition(
                name: "scroll", title: "Scroll",
                description:
                    "Scroll with the mouse wheel at a point (default: screen center). \"down\" reveals content further down, \"right\" content further right.",
                inputSchema: schema(
                    point.merging([
                        "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                        "amount": ["type": "integer", "description": "Wheel steps, default 5"],
                    ]) { $1 }, required: ["direction"]), readOnly: false),
            ToolDefinition(
                name: "pinch", title: "Pinch",
                description:
                    "Pinch with two fingers around a point (default: screen center), e.g. to zoom a map, photo or plan. scale above 1 spreads the fingers and zooms in (2: to twice their distance), below 1 brings them together and zooms out. On simulators, Android and iPhones and iPads with Mobdev Runner; over Bluetooth there is one finger.",
                inputSchema: schema(
                    point.merging([
                        "scale": ["type": "number", "description": "Finger distance at the end over the start: above 1 zooms in, below 1 out (0.1 to 10)"],
                        "duration": ["type": "number", "description": "Seconds, default 0.5"],
                    ]) { $1 }, required: ["scale"]), readOnly: false),
            ToolDefinition(
                name: "type_text", title: "Type text",
                description:
                    "Type text into the focused field. Tap the field first. Set submit to press Return afterwards. At most 1000 characters per call; send longer text in several calls.",
                inputSchema: schema(
                    ["text": ["type": "string"], "submit": ["type": "boolean", "description": "Press Return after typing"]],
                    required: ["text"]), readOnly: false),
            ToolDefinition(
                name: "press_key", title: "Press key",
                description:
                    "Press a key with optional modifiers, e.g. {\"key\":\"space\",\"modifiers\":[\"cmd\"]} for Spotlight. Keys: enter, escape, backspace, tab, space, up, down, left, right, home, end, pageup, pagedown, f1-f12, or one character; volume_up and volume_down press the buttons on iPhones and Android. count presses it several times, e.g. backspace 20 times to clear a field.",
                inputSchema: schema(
                    [
                        "key": ["type": "string"],
                        "modifiers": [
                            "type": "array",
                            "items": ["type": "string", "enum": ["cmd", "shift", "option", "ctrl"]],
                        ],
                        "count": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Times to press it, default 1"],
                    ], required: ["key"]), readOnly: false),
            ToolDefinition(
                name: "home", title: "Go home",
                description: "Go to the home screen.",
                inputSchema: schema([:]), readOnly: false),
            ToolDefinition(
                name: "open_app", title: "Open app",
                description:
                    "Open an installed app by name or bundle ID: directly on simulators, Android and iPhones with Mobdev Runner, through Spotlight on an iPhone over Bluetooth.",
                inputSchema: schema(["name": ["type": "string"]], required: ["name"]), readOnly: false),
            ToolDefinition(
                name: "read_screen", title: "Read screen",
                description:
                    "Recognize all visible text on the screen with its position (on-device OCR). Cheaper than a screenshot. If macOS text recognition fails, this and the other text tools answer from the UI tree on simulators, Android and iPhones with Mobdev Runner.",
                inputSchema: schema([:], screenshot: false), readOnly: true),
            ToolDefinition(
                name: "find_text", title: "Find text",
                description: "Find visible text (case and accent insensitive) and return where it is.",
                inputSchema: schema(["text": ["type": "string"]], required: ["text"], screenshot: false),
                readOnly: true),
            ToolDefinition(
                name: "tap_text", title: "Tap text",
                description:
                    "Tap visible text such as a button label. Exact matches win over partial ones. If the text appears more than once, pass index (0 = topmost). double taps twice, hold presses long.",
                inputSchema: schema(
                    [
                        "text": ["type": "string"], "index": ["type": "integer", "minimum": 0], "double": double,
                        "hold": hold,
                    ], required: ["text"]),
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
        ] + secretDefinitions + observeDefinitions + treeDefinitions + appDefinitions + settingsDefinitions + recordingDefinitions
            + sessionDefinitions + crawlDefinitions + checkDefinitions + flowDefinitions + testDefinitions
            + nativeTestDefinitions + devLoopDefinitions + profilingDefinitions + networkDefinitions
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
        // An agent waiting for "Ready." polls status; repeats show as one entry with a count.
        let collapsing = name == "status"
        do {
            try AppBlocklist.check(name, args)
            var output: ToolOutput
            if let what = Self.holdingTools[name] {
                output = try await holding(what, source: source) {
                    switch name {
                    case "run_flow": try await runFlowTool(args, source: source)
                    case "run_tests": try await runTestsTool(args, source: source)
                    default: try await runCrawlTool(name, args, source: source)!
                    }
                }
            } else {
                if !definition.readOnly { try checkNotHeld() }
                switch name {
                case "type_secret": output = try await typeSecret(args, source: source)
                case "run_native_tests": output = try await runNativeTestsTool(args, source: source)
                default: output = try await run(name, args)
                }
            }
            let wantsScreenshot = args.bool("screenshot") ?? screenshotByDefault
            let offersScreenshot = definition.inputSchema["properties"]?["screenshot"] != nil && !definition.readOnly
            if wantsScreenshot, output.image == nil, offersScreenshot {
                try await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
                output.image = phone.frame().flatMap(ImageTools.screenshot)
            }
            activity.record(
                source: source, tool: name, summary: summary(name, args, output), failed: output.isError,
                collapsing: collapsing)
            if !output.isError {
                for steps in [recorder, history] {
                    if name == "tap_mark" {
                        recordMarkTap(args, into: steps)
                    } else {
                        // A test's step keeps a secret's name, not the value it was filled in with.
                        let recorded = Variables.current.map { $0.redact(arguments ?? [:]) } ?? arguments
                        steps.record(name, recorded?.objectValue ?? [:])
                    }
                }
            }
            return output
        } catch {
            let message = String(describing: error)
            activity.record(source: source, tool: name, summary: message, failed: true, collapsing: collapsing)
            return ToolOutput(text: message, isError: true)
        }
    }

    // MARK: Tools

    func run(_ name: String, _ args: Arguments) async throws -> ToolOutput {
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
            let how = try await tap(point, args)
            return ToolOutput(text: "\(how) \(try describe(point)).")
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
            // With Snap to Item on, iOS would tap the nearest item instead of swiping. Mobdev Runner
            // and simulators touch the screen without a pointer.
            let status = phone.status()
            if status.input == .bluetooth, status.pointer != .follows, try await phone.checkPointer(at: start) == .snaps {
                throw ToolFailure(
                    "Did not swipe: the pointer snaps to items, so iOS would tap the nearest item instead. \(PointerBehavior.snapAdvice) Then try again."
                )
            }
            try await phone.swipe(from: start, to: end, duration: duration)
            return ToolOutput(text: "Swiped from \(try describe(start)) to \(try describe(end)).")
        case "scroll":
            let point =
                args.has("x") || args.has("y") ? try self.point(args, "x", "y") : NormalizedPoint(x: 0.5, y: 0.5)
            let direction = try args.string("direction")
            guard ["up", "down", "left", "right"].contains(direction) else {
                throw ToolFailure("direction must be \"up\", \"down\", \"left\" or \"right\".")
            }
            let amount = Int(try args.number("amount", default: 5, range: 1...50))
            try requireTouch()
            switch direction {
            case "left", "right": try await phone.pan(at: point, ticks: direction == "right" ? amount : -amount)
            default: try await phone.scroll(at: point, ticks: direction == "down" ? amount : -amount)
            }
            return ToolOutput(text: "Scrolled \(direction) by \(amount).")
        case "pinch":
            let center =
                args.has("x") || args.has("y") ? try self.point(args, "x", "y") : NormalizedPoint(x: 0.5, y: 0.5)
            let scale = try args.number("scale")
            guard (0.1...10).contains(scale), scale != 1 else {
                throw ToolFailure("scale must be between 0.1 and 10 and not 1: above 1 zooms in, below 1 zooms out.")
            }
            let duration = try args.number("duration", default: 0.5, range: 0.1...5)
            try requireTouch()
            try await phone.pinch(at: center, scale: scale, duration: duration)
            return ToolOutput(
                text: "Pinched around \(try describe(center)) to zoom \(scale > 1 ? "in" : "out"), scale \(format(scale)).")
        case "type_text":
            let text = try args.string("text", maxLength: Self.maxTypedCharacters)
            let submit = args.bool("submit") == true
            try requireTouch()
            if try await phone.typeText(text) {
                if submit { try await phone.press(KeyStroke(0x28)) }
            } else {
                var strokes = try phone.status().keyboardLayout.strokes(typing: text)
                if submit { strokes.append(KeyStroke(0x28)) }
                try await phone.type(strokes)
            }
            return ToolOutput(text: "Typed \(text.count) characters\(submit ? " and pressed Return" : "").")
        case "press_key":
            let key = try args.string("key")
            let modifiers = args.strings("modifiers")
            let count = Int(try args.number("count", default: 1, range: 1...100))
            let times = count == 1 ? "" : " \(count) times"
            if let button = Self.buttons[key.lowercased()] {
                try requireTouch()
                for _ in 0..<count { try await phone.press(button) }
                return ToolOutput(text: "Pressed \(key.lowercased())\(times).")
            }
            // Mobdev Runner types a character as it is, also one the keyboard layout has no key for.
            if phone.status().input == .runner, key.count == 1, modifiers.isEmpty {
                try requireTouch()
                // False when the runner ended meanwhile: then the key goes the keyboard's way below.
                var typed = 0
                while typed < count, try await phone.typeText(key) { typed += 1 }
                if typed == count { return ToolOutput(text: "Pressed \(key)\(times).") }
                if typed > 0 { throw ToolFailure("Pressed \(key) \(typed) of \(count) times; then Mobdev Runner stopped.") }
            }
            let stroke = try phone.status().keyboardLayout.stroke(forKey: key, modifiers: modifiers)
            try requireTouch()
            for _ in 0..<count { try await phone.press(stroke) }
            return ToolOutput(text: "Pressed \((modifiers + [key]).joined(separator: "+"))\(times).")
        case "home":
            try requireTouch()
            try await phone.press(.home)
            return ToolOutput(text: "Went to the home screen.")
        case "open_app":
            let name = try args.string("name", maxLength: 100)
            try requireTouch()
            if let opened = try await phone.openApp(named: name) {
                try await pause(1.0)
                return ToolOutput(text: opened)
            }
            let layout = phone.status().keyboardLayout
            let strokes = try layout.strokes(typing: name)
            try await phone.press(.home)
            try await pause(0.6)
            // ⌘Space, not the HID Search key: iOS 27.0.1 ignores the Search key, and the name
            // was then typed into nothing (2026-10-01).
            try await phone.press(try layout.stroke(forKey: "space", modifiers: ["cmd"]))
            try await pause(0.8)
            try await phone.type(strokes)
            try await pause(1.0)
            try await phone.press(KeyStroke(0x28))
            try await pause(1.0)
            return ToolOutput(text: "Searched Spotlight for \"\(name)\" and opened the top hit.")
        case "read_screen":
            let (frame, size) = try currentFrame()
            let found = try await screenText(nil, in: frame)
            let lines = found.matches
            let text = lines.isEmpty
                ? "No text recognized."
                : lines.map { "\($0.text) @ \(coordinates($0.center, size))" }.joined(separator: "\n")
            return ToolOutput(
                text: found.fromTree ? Self.fromTreeNote + "\n" + text : text,
                data: .array(lines.map { matchJSON($0, size) }))
        case "find_text":
            let query = try args.string("text")
            let (frame, size) = try currentFrame()
            let found = try await screenText(query, in: frame)
            let matches = found.matches
            let text = matches.isEmpty
                ? "\"\(query)\" is not visible."
                : matches.enumerated().map { index, match in
                    "\(index): \(match.text) @ \(coordinates(match.center, size))\(match.exact ? " (exact)" : "")"
                }.joined(separator: "\n")
            return ToolOutput(
                text: found.fromTree ? Self.fromTreeNote + "\n" + text : text,
                data: .array(matches.map { matchJSON($0, size) }))
        case "tap_text":
            let query = try args.string("text")
            let (frame, size) = try currentFrame()
            try requireTouch()
            let found = try await screenText(query, in: frame)
            let matches = found.matches
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
            let how = try await tap(match.center, args)
            return ToolOutput(
                text: "\(how) \"\(match.text)\" at \(coordinates(match.center, size))."
                    + (found.fromTree ? " " + Self.fromTreeNote : ""))
        case "wait_for_text":
            let query = try args.string("text")
            let timeout = try args.number("timeout", default: 10, range: 0...60)
            let gone = args.bool("gone") ?? false
            let deadline = Date().addingTimeInterval(timeout)
            // Once recognition failed, the rest of the wait reads the UI tree.
            var fromTree = false
            while true {
                let (frame, _) = try currentFrame()
                let found: ScreenText
                do {
                    found = try await screenText(query, in: frame, treeOnly: fromTree)
                } catch where fromTree && Date() < deadline {
                    // A tree that cannot be read yet, as while an app launches, counts as not visible.
                    try await pause(0.5)
                    continue
                }
                fromTree = found.fromTree
                let visible = !found.matches.isEmpty
                if visible != gone {
                    return ToolOutput(
                        text: (gone ? "\"\(query)\" is gone." : "\"\(query)\" is visible.")
                            + (fromTree ? " " + Self.fromTreeNote : ""))
                }
                if Date() >= deadline {
                    throw ToolFailure(
                        "Timed out after \(timeout) s: \"\(query)\" \(gone ? "is still visible" : "did not appear")."
                            + (fromTree ? " " + Self.fromTreeNote : ""))
                }
                try await pause(0.5)
            }
        default:
            if let output = try await runObserveTool(name, args) { return output }
            if let output = try await runTreeTool(name, args) { return output }
            if let output = try await runSettingsTool(name, args) { return output }
            if let output = try await runRecordingTool(name, args) { return output }
            if let output = try await runSessionTool(name, args) { return output }
            if let output = try await runCheckTool(name, args) { return output }
            if let output = try await runDevLoopTool(name, args) { return output }
            if let output = try await runProfilingTool(name, args) { return output }
            if let output = try await runNetworkTool(name, args) { return output }
            return try await runAppTool(name, args)
        }
    }

    // MARK: Helpers

    private func statusOutput() -> ToolOutput {
        let status = phone.status()
        var screenshot: JSONValue = .null
        var lines: [String]
        switch status.input {
        case .bluetooth:
            lines = ["Screen (USB): \(status.screen.summary)", "Input (Bluetooth): \(status.bluetooth.summary)"]
            if let runner = status.runner, runner != .off {
                lines.append("Mobdev Runner (Developer Mode): \(runner.summary)")
            }
        case .runner:
            lines = ["Screen (USB): \(status.screen.summary)", "Input: \(status.inputSummary)"]
        case .direct:
            lines = ["Screen: \(status.screen.summary)", "Input: \(status.inputSummary)"]
        }
        if let size = status.frameSize {
            let shot = ScreenGeometry.screenshotSize(forFrameWidth: size.width, height: size.height)
            screenshot = ["width": .number(Double(shot.width)), "height": .number(Double(shot.height))]
            lines.append("Screenshot coordinates: \(shot.width)×\(shot.height) px")
        }
        // Mobdev Runner types characters and needs no pointer.
        if status.input == .bluetooth {
            lines.append("Keyboard layout: \(status.keyboardLayout.displayName)")
            if let pointer = status.pointer { lines.append("Pointer: \(pointer.summary)") }
        }
        let ready = status.isReady
        lines.insert(ready ? "Ready." : "Not ready.", at: 0)
        var input: JSONValue = .null
        switch status.input {
        case .direct(let route): input = ["route": .string(route), "ready": .bool(status.inputReady)]
        case .runner: input = ["route": "Mobdev Runner", "ready": .bool(status.inputReady)]
        case .bluetooth: break
        }
        return ToolOutput(
            text: lines.joined(separator: "\n"),
            data: [
                "ready": .bool(ready),
                "screen": ["connected": .bool(status.screen.isConnected), "summary": .string(status.screen.summary)],
                "bluetooth": [
                    "connected": .bool(status.bluetooth.isConnected), "summary": .string(status.bluetooth.summary),
                ],
                "input": input,
                "runner": status.runner.map { .string($0.summary) } ?? .null,
                "screenshot": screenshot,
                "keyboard_layout": .string(status.keyboardLayout.rawValue),
                "pointer": status.pointer.map { .string($0.rawValue) } ?? .null,
            ])
    }

    func currentFrame() throws -> (CGImage, (width: Int, height: Int)) {
        let status = phone.status()
        guard status.screen.isConnected, let frame = phone.frame() else {
            throw ToolFailure("The iPhone screen is not available. \(status.screen.summary).")
        }
        let size = ScreenGeometry.screenshotSize(forFrameWidth: frame.width, height: frame.height)
        return (frame, size)
    }

    func screenshotSize() throws -> (width: Int, height: Int) {
        let status = phone.status()
        guard let frame = status.frameSize else {
            throw ToolFailure("The iPhone screen is not available. \(status.screen.summary).")
        }
        return ScreenGeometry.screenshotSize(forFrameWidth: frame.width, height: frame.height)
    }

    /// Buttons press_key presses by name, which are not keys of the keyboard.
    static let buttons: [String: ConsumerUsage] = ["volume_up": .volumeUp, "volume_down": .volumeDown]

    /// Taps once, twice quickly with double, or holds for hold seconds, and says which: "Tapped",
    /// "Double-tapped" or "Pressed".
    func tap(_ point: NormalizedPoint, _ args: Arguments) async throws -> String {
        if args.has("hold") {
            try await phone.tap(at: point, hold: try args.number("hold", default: 1, range: 0.2...10))
            return "Pressed"
        }
        guard args.bool("double") == true else {
            try await phone.tap(at: point, hold: 0.08)
            return "Tapped"
        }
        try await phone.doubleTap(at: point)
        return "Double-tapped"
    }

    private func point(_ args: Arguments, _ xKey: String, _ yKey: String) throws -> NormalizedPoint {
        let size = try screenshotSize()
        let x = try coordinate(args, xKey, size.width)
        let y = try coordinate(args, yKey, size.height)
        guard (0...Double(size.width)).contains(x), (0...Double(size.height)).contains(y) else {
            throw ToolFailure(
                "(\(format(x)), \(format(y))) is outside the screenshot, which is \(size.width)×\(size.height) px.")
        }
        return NormalizedPoint(x: x / Double(size.width), y: y / Double(size.height))
    }

    /// Screenshot pixels, or "50%" of the width or height.
    private func coordinate(_ args: Arguments, _ key: String, _ length: Int) throws -> Double {
        if let text = args.value[key]?.stringValue, text.hasSuffix("%") {
            guard let share = Double(text.dropLast().trimmingCharacters(in: .whitespaces)), (0...100).contains(share) else {
                throw ToolFailure("\(key) must be pixels or a percentage from 0% to 100%, like \"50%\".")
            }
            return share / 100 * Double(length)
        }
        return try args.number(key)
    }

    func requireTouch() throws {
        let status = phone.status()
        guard status.inputReady else {
            guard status.input == .bluetooth else {
                throw ToolFailure("The device does not accept input right now: \(status.screen.summary).")
            }
            // On the way to Mobdev Runner, Bluetooth stands in only when it is paired.
            switch status.runner {
            case .building?, .starting?:
                throw ToolFailure(
                    "Mobdev Runner, which taps and types on this iPhone, is still starting: \(status.runner?.summary ?? ""). The first build takes a minute or two; try again then.")
            case .failed(let reason)?:
                throw ToolFailure(
                    "Mobdev Runner could not start on this iPhone: \(reason) Then click Try Again under Developer Mode Control in the iPhone's info in Mobdev. Without Developer Mode, pair the iPhone over Bluetooth instead.")
            default:
                throw HIDError.notConnected
            }
        }
    }

    private func describe(_ point: NormalizedPoint) throws -> String {
        coordinates(point, try screenshotSize())
    }

    func coordinates(_ point: NormalizedPoint, _ size: (width: Int, height: Int)) -> String {
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
        case "type_secret": "typed the secret \(args.value["name"]?.stringValue ?? "")"
        default: output.text.split(separator: "\n").first.map(String.init) ?? name
        }
    }

    func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Also used for coordinates that failed validation, so it must not trap on huge values.
    func format(_ value: Double) -> String {
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
