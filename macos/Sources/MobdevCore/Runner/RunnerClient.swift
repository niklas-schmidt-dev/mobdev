import CoreGraphics
import Foundation

/// Mobdev Runner's HTTP API (see Runner/MobdevRunner/RunnerTests.swift): through usbmuxd on an
/// iPhone, on 127.0.0.1 on a simulator, whose network is the Mac's. One request per connection.
struct RunnerClient: Sendable {
    enum Route: Sendable, Equatable {
        case usb(udid: String)
        case loopback
    }

    /// The runner's API version this Mac speaks. Mobdev builds the runner from its own copy of
    /// `Runner/` on every start, so a runner of another version means an old build is still running.
    static let protocolVersion = 2

    var route: Route
    var port: UInt16
    var token: String
    var usbmux = USBMux()

    /// Throws unless the runner answers with this Mac's token and speaks this Mac's version.
    func health() async throws {
        try Self.checkVersion(try await call("GET", "/health", timeout: 3))
    }

    /// Throws when a /health answer names another version than this Mac's.
    static func checkVersion(_ reply: JSONValue) throws {
        let version = reply["version"]?.doubleValue.map { Int($0) }
        guard version == protocolVersion else { throw VersionMismatch(version: version) }
    }

    struct VersionMismatch: Error, CustomStringConvertible {
        let version: Int?
        var description: String {
            "Mobdev Runner on the device is version \(version.map(String.init) ?? "unknown"); this Mac needs version \(RunnerClient.protocolVersion), so an old build is still running there."
        }
    }

    func tree() async throws -> [UIElement] {
        try Self.elements(fromTree: try await call("GET", "/tree", timeout: 30))
    }

    /// A tap, or a press of `hold` seconds from 0.2 on (a long press).
    func tap(_ point: NormalizedPoint, hold: TimeInterval = 0) async throws {
        _ = try await call("POST", "/tap", body: Self.tapBody(point, hold: hold), timeout: 30 + hold)
    }

    func doubleTap(_ point: NormalizedPoint) async throws {
        _ = try await call("POST", "/tap", body: Self.tapBody(point, count: 2), timeout: 30)
    }

    /// Presses at `start` for `press` seconds, moves to `end` in `duration` seconds and lifts after
    /// `hold` more: a swipe with the defaults, a drag (rearranging icons) with a longer press.
    func drag(
        from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval, press: TimeInterval = 0.05,
        hold: TimeInterval = 0
    ) async throws {
        let body = Self.dragBody(from: start, to: end, duration: duration, press: press, hold: hold)
        _ = try await call("POST", "/drag", body: body, timeout: 30 + duration + press + hold)
    }

    /// Types into the focused element. XCTest types about ten characters a second.
    func type(_ text: String) async throws {
        _ = try await call("POST", "/type", body: ["text": .string(text)], timeout: 30 + Double(text.count) / 5)
    }

    /// One key by its name (return, escape, …) or character, with cmd, shift, option or ctrl.
    func key(_ key: String, modifiers: [String] = []) async throws {
        _ = try await call("POST", "/key", body: Self.keyBody(key, modifiers: modifiers), timeout: 30)
    }

    /// home, volume_up or volume_down.
    func button(_ name: String) async throws {
        _ = try await call("POST", "/button", body: ["name": .string(name)], timeout: 30)
    }

    /// Brings an app to the front, launching it when it is not running.
    func activate(_ bundleID: String) async throws {
        _ = try await call("POST", "/activate", body: ["bundle": .string(bundleID)], timeout: 60)
    }

    static func tapBody(_ point: NormalizedPoint, hold: TimeInterval = 0, count: Int = 1) -> JSONValue {
        var body: [String: JSONValue] = ["x": .number(point.x), "y": .number(point.y)]
        if hold >= 0.2 { body["hold"] = .number(hold) }
        if count != 1 { body["count"] = .number(Double(count)) }
        return .object(body)
    }

    static func dragBody(
        from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval, press: TimeInterval, hold: TimeInterval
    ) -> JSONValue {
        [
            "from": [.number(start.x), .number(start.y)], "to": [.number(end.x), .number(end.y)],
            "duration": .number(duration), "press": .number(press), "hold": .number(hold),
        ]
    }

    static func keyBody(_ key: String, modifiers: [String]) -> JSONValue {
        var body: [String: JSONValue] = ["key": .string(key)]
        if !modifiers.isEmpty { body["modifiers"] = .array(modifiers.map(JSONValue.string)) }
        return .object(body)
    }

    func call(_ method: String, _ path: String, body: JSONValue? = nil, timeout: TimeInterval) async throws -> JSONValue {
        let payload = body?.encoded() ?? Data()
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        head += "Authorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n"
        let request = Data(head.utf8) + payload
        let route = self.route, port = self.port, usbmux = self.usbmux
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        let deadline = Date().addingTimeInterval(timeout)
                        let socket: StreamSocket
                        switch route {
                        case .usb(let udid): socket = try usbmux.connect(udid: udid, port: port)
                        case .loopback: socket = try StreamSocket.loopback(port: port, purpose: "Mobdev Runner")
                        }
                        try socket.write(request, until: deadline)
                        return try socket.readToEnd(until: deadline, limit: 32 * 1024 * 1024)
                    })
            }
        }
        let (status, data) = try Self.parse(response)
        let json = try? JSONValue.parse(data)
        guard status == 200, let json else {
            let reason = json?["error"]?.stringValue ?? "status \(status)"
            throw DeveloperError("Mobdev Runner: \(Self.shortened(reason))")
        }
        return json
    }

    /// Status and body of a response that ends where the runner closed the connection.
    static func parse(_ response: Data) throws -> (status: Int, body: Data) {
        guard let end = response.firstRange(of: Data("\r\n\r\n".utf8)),
            let head = String(data: response[response.startIndex..<end.lowerBound], encoding: .utf8),
            let status = head.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap({ Int($0) })
        else { throw DeveloperError("Mobdev Runner sent an incomplete answer.") }
        var body = Data(response[end.upperBound...])
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length",
                let length = Int(parts[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            guard length <= body.count else { throw DeveloperError("Mobdev Runner sent an incomplete answer.") }
            body = body.prefix(length)
        }
        return (status, body)
    }

    /// XCTest's failures end with the whole element tree; the first sentence says what happened.
    static func shortened(_ reason: String) -> String {
        var text = reason.components(separatedBy: "\n").first ?? reason
        if let range = text.range(of: " Event dispatch snapshot") { text = String(text[..<range.lowerBound]) }
        return text.count > 400 ? String(text.prefix(400)) + "…" : text
    }

    // MARK: Elements

    /// Roles someone taps, as the runner names XCUIElement types. Icons are apps on the home screen.
    static let tappableTypes: Set<String> = [
        "Button", "Link", "TextField", "SecureTextField", "SearchField", "TextView", "Cell", "Switch", "Toggle",
        "Slider", "CheckBox", "RadioButton", "Tab", "Key", "MenuItem", "MenuButton", "PopUpButton", "ComboBox",
        "ToolbarButton", "Icon", "Stepper", "PickerWheel", "DisclosureTriangle", "SegmentedControl",
    ]

    /// The runner's /tree answer as elements with frames as fractions of the screen. The screenshot
    /// shows the whole screen, and the runner's frames are points of that screen. Elements outside it
    /// are left out, those partly outside are cut to what shows, and exact duplicates (XCTest lists
    /// some twice) are listed once.
    static func elements(fromTree json: JSONValue) throws -> [UIElement] {
        guard let width = json["screen"]?["width"]?.doubleValue, let height = json["screen"]?["height"]?.doubleValue,
            width > 0, height > 0
        else { throw DeveloperError("Mobdev Runner did not say how large the screen is.") }
        let screen = CGRect(x: 0, y: 0, width: width, height: height)
        var elements: [UIElement] = []
        for item in json["elements"]?.arrayValue ?? [] {
            guard let numbers = item["frame"]?.arrayValue?.compactMap(\.doubleValue), numbers.count == 4 else { continue }
            let visible = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]).intersection(screen)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
            let role = item["type"]?.stringValue ?? "Other"
            var label = item["label"]?.stringValue ?? ""
            if label.isEmpty { label = item["placeholder"]?.stringValue ?? "" }
            var value = item["value"]?.stringValue ?? ""
            if role == "Switch" || role == "Toggle" || role == "CheckBox" {
                value = value == "1" ? "on" : value == "0" ? "off" : value
            }
            let element = UIElement(
                role: role, label: label, identifier: item["identifier"]?.stringValue ?? "", value: value,
                frame: CGRect(
                    x: visible.minX / width, y: visible.minY / height, width: visible.width / width,
                    height: visible.height / height),
                enabled: item["enabled"]?.boolValue ?? true, tappable: tappableTypes.contains(role))
            if !elements.contains(element) { elements.append(element) }
            if elements.count >= 1500 { break }
        }
        return elements
    }
}
