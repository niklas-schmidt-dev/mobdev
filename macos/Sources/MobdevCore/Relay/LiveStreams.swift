import CoreGraphics
import Foundation

/// Live view through the relay: streams a device's screen to viewers in a browser, or to an agent,
/// and runs their taps and typing as tool calls.
///
/// The relay asks for a stream with `{"type":"live_start","id","device","fps","viewers"}`, repeats
/// it every 30 s while someone watches and whenever the viewers change, and ends it with
/// `{"type":"live_stop","id"}`. The Mac answers with `{"type":"live_frame","id","seq","width",
/// "height","jpeg"}` (JPEG in base64, long edge 800 px, at most `fps` a second, an unchanged picture
/// only every 2 s) and ends a stream itself with `{"type":"live_end","id","code","reason"}`: live
/// view is off ("disabled"), the device is unknown ("no_device"), someone stopped it on this Mac
/// ("stopped") or nobody renewed it for 75 s ("timeout"). Input arrives as
/// `{"type":"live_input","id","input":{"action",…}}` with points as fractions of the screen.
///
/// Live view is off until the person at the Mac allows it (`setAllowed`): it shows the screen,
/// with whatever private data is on it, to whoever the relay lets watch.
public final class LiveStreams: @unchecked Sendable {
    /// Who watches, as the relay reports it.
    public struct Viewer: Codable, Equatable, Sendable {
        /// "key": an agent or tool with the client key; "owner": the account in the dashboard;
        /// "share": someone with a share link.
        public var kind: String
        /// A share link's name.
        public var label: String?
        /// Whether this viewer may tap and type.
        public var control: Bool

        public init(kind: String, label: String? = nil, control: Bool) {
            self.kind = kind
            self.label = label
            self.control = control
        }

        /// "you in the dashboard", "the share link “Anna” (view only)" and the like.
        public var summary: String {
            let who =
                switch kind {
                case "owner": "you in the dashboard"
                case "share": label.map { "the share link “\($0)”" } ?? "a share link"
                default: "an agent with the client key"
                }
            return control ? who : "\(who) (view only)"
        }
    }

    /// A stream someone watches.
    public struct Session: Identifiable, Equatable, Sendable {
        public let id: String
        /// The device's id, nil when it is not one of this Mac's devices (in tests).
        public var deviceID: String?
        public var deviceName: String
        public var viewers: [Viewer]
        public var fps: Int
        public let started: Date
    }

    /// Sends a text frame on the relay connection; false once it is gone.
    public typealias Send = @Sendable (String) async -> Bool

    public static let longEdge = 800
    public static let quality = 0.5
    public static let defaultFPS = 5
    public static let maxFPS = 10
    /// Inputs waiting to run per stream; more are dropped, so a flood cannot queue up on the phone.
    static let maxQueuedInputs = 8
    static let disabledReason = "Live view is off on this Mac. Turn on “Allow live view” under Remote Access in Mobdev."

    private let tools: any ToolCalling
    private let renewTimeout: TimeInterval
    private let repeatInterval: TimeInterval
    private let onChange: @Sendable ([Session]) -> Void
    private let state: Locked<State>

    private struct State {
        var allowed: Bool
        var streams: [String: Stream] = [:]
    }

    /// One running stream. Its mutable fields are only touched under `state`'s lock.
    private final class Stream: @unchecked Sendable {
        let id: String
        let device: String
        let phone: PhoneBackend
        let activity: ActivityLog?
        let send: Send
        var session: Session
        var renewed = Date()
        var capture: Task<Void, Never>?
        var inputs: Task<Void, Never>?
        var queuedInputs = 0

        init(id: String, device: String, phone: PhoneBackend, activity: ActivityLog?, send: @escaping Send, session: Session) {
            self.id = id
            self.device = device
            self.phone = phone
            self.activity = activity
            self.send = send
            self.session = session
        }

        func cancel() {
            capture?.cancel()
            inputs?.cancel()
        }
    }

    /// `renewTimeout` ends streams the relay stopped renewing; `repeatInterval` is how often an
    /// unchanged picture is sent again, so viewers know the stream still runs.
    public init(
        tools: any ToolCalling, allowed: Bool = false, renewTimeout: TimeInterval = 75, repeatInterval: TimeInterval = 2,
        onChange: @escaping @Sendable ([Session]) -> Void = { _ in }
    ) {
        self.tools = tools
        self.renewTimeout = renewTimeout
        self.repeatInterval = repeatInterval
        self.onChange = onChange
        state = Locked(State(allowed: allowed))
    }

    public var isAllowed: Bool { state.get().allowed }

    /// Who watches what right now, oldest first.
    public var sessions: [Session] {
        state.get().streams.values.map(\.session).sorted { $0.started < $1.started }
    }

    /// Turning live view off ends every stream at once.
    public func setAllowed(_ allowed: Bool) {
        let ended = state.withLock { state -> [Stream] in
            state.allowed = allowed
            guard !allowed else { return [] }
            defer { state.streams = [:] }
            return Array(state.streams.values)
        }
        finish(ended, code: "disabled", reason: Self.disabledReason, log: "Live view ended: it was turned off on this Mac")
    }

    /// Ends the streams of a device (all with nil), for "Stop" in the app.
    public func end(device: String?) {
        let ended = state.withLock { state -> [Stream] in
            let matching = state.streams.values.filter { device == nil || $0.session.deviceID == device }
            for stream in matching { state.streams[stream.id] = nil }
            return matching
        }
        finish(ended, code: "stopped", reason: "Stopped on the Mac.", log: "Live view ended: stopped on this Mac")
    }

    /// Ends every stream without telling the relay: its connection is gone.
    func connectionEnded() {
        let ended = state.withLock { state -> [Stream] in
            defer { state.streams = [:] }
            return Array(state.streams.values)
        }
        finish(ended, code: nil, reason: "", log: "Live view ended: the relay connection closed")
    }

    // MARK: Frames from the relay

    struct Frame: Decodable {
        var type: String
        var id: String?
        var device: String?
        var fps: Int?
        var viewers: [Viewer]?
        var input: Input?
    }

    /// A viewer's input, which the relay already checked.
    struct Input: Decodable, Equatable {
        var action: String
        var x: Double?
        var y: Double?
        var fromX: Double?
        var fromY: Double?
        var toX: Double?
        var toY: Double?
        var duration: Double?
        var seconds: Double?
        var direction: String?
        var amount: Double?
        var text: String?
        var key: String?
        var modifiers: [String]?

        enum CodingKeys: String, CodingKey {
            case action, x, y, duration, seconds, direction, amount, text, key, modifiers
            case fromX = "from_x"
            case fromY = "from_y"
            case toX = "to_x"
            case toY = "to_y"
        }
    }

    /// Handles a live_start, live_stop or live_input frame; `send` answers on the same connection.
    func handle(_ text: String, send: @escaping Send) {
        guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(text.utf8)), let id = frame.id, !id.isEmpty
        else { return }
        switch frame.type {
        case "live_start":
            start(id: id, device: frame.device ?? "", fps: frame.fps, viewers: frame.viewers ?? [], send: send)
        case "live_stop":
            let ended = state.withLock { $0.streams.removeValue(forKey: id) }
            finish(ended.map { [$0] } ?? [], code: nil, reason: "", log: "Live view ended: nobody watches any more")
        case "live_input":
            if let input = frame.input { queue(input, for: id) }
        default:
            break
        }
    }

    private func start(id: String, device: String, fps requested: Int?, viewers: [Viewer], send: @escaping Send) {
        let fps = min(max(requested ?? Self.defaultFPS, 1), Self.maxFPS)
        // A renewal, or other viewers.
        let renewed = state.withLock { state -> (changed: Bool, stream: Stream)? in
            guard let stream = state.streams[id] else { return nil }
            stream.renewed = Date()
            let changed = stream.session.viewers != viewers
            stream.session.viewers = viewers
            stream.session.fps = fps
            return (changed, stream)
        }
        if let renewed {
            if renewed.changed {
                renewed.stream.activity?.record(
                    source: "browser", tool: "live_view", summary: "Now watched by \(Self.describe(viewers))", failed: false)
                notify()
            }
            return
        }

        let phone: PhoneBackend
        do {
            phone = try tools.phone(for: device.isEmpty ? nil : device)
        } catch {
            let reason = (error as? ToolFailure)?.description ?? String(describing: error)
            Task { _ = await send(Self.endFrame(id: id, code: "no_device", reason: reason)) }
            return
        }
        let resolved = phone as? any Device
        let session = Session(
            id: id, deviceID: resolved?.id, deviceName: resolved?.name ?? (device.isEmpty ? "Device" : device),
            viewers: viewers, fps: fps, started: Date())
        let stream = Stream(
            id: id, device: device, phone: phone, activity: tools.activity(for: device.isEmpty ? nil : device), send: send,
            session: session)
        let started = state.withLock { state -> Bool in
            guard state.allowed else { return false }
            state.streams[id] = stream
            stream.capture = Task.detached(priority: .userInitiated) { [weak self] in await self?.capture(stream) }
            return true
        }
        guard started else {
            Task { _ = await send(Self.endFrame(id: id, code: "disabled", reason: Self.disabledReason)) }
            return
        }
        stream.activity?.record(
            source: "browser", tool: "live_view", summary: "Live view started: watched by \(Self.describe(viewers))",
            failed: false)
        notify()
    }

    /// Takes pictures at the stream's fps and sends those that changed, until the stream ends.
    /// Waiting for each send to finish keeps a slow connection from piling frames up.
    private func capture(_ stream: Stream) async {
        var seq = 0
        var last: Data?
        var lastSent = Date.distantPast
        while !Task.isCancelled {
            let begin = Date()
            guard let (fps, renewed) = state.withLock({ $0.streams[stream.id].map { ($0.session.fps, $0.renewed) } })
            else { return }
            if begin.timeIntervalSince(renewed) > renewTimeout {
                let ended = state.withLock { $0.streams.removeValue(forKey: stream.id) }
                finish(
                    ended.map { [$0] } ?? [], code: "timeout", reason: "The relay stopped renewing the stream.",
                    log: "Live view ended: the relay stopped asking for it")
                return
            }
            if let frame = stream.phone.frame(),
                let image = ImageTools.encode(ImageTools.scaled(frame, longEdge: Self.longEdge), quality: Self.quality),
                image.data != last || begin.timeIntervalSince(lastSent) >= repeatInterval
            {
                seq += 1
                guard await stream.send(Self.frameJSON(id: stream.id, seq: seq, image: image)) else { return }
                last = image.data
                lastSent = Date()
            }
            let wait = 1 / Double(fps) - Date().timeIntervalSince(begin)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
    }

    private func queue(_ input: Input, for id: String) {
        state.withLock { state in
            // The relay sends input only from viewers who may control; one of them must be watching.
            guard state.allowed, let stream = state.streams[id], stream.queuedInputs < Self.maxQueuedInputs,
                stream.session.viewers.contains(where: \.control)
            else { return }
            stream.queuedInputs += 1
            let previous = stream.inputs
            stream.inputs = Task { [weak self] in
                await previous?.value
                if !Task.isCancelled { await self?.perform(input, on: stream) }
                self?.state.withLock { _ in stream.queuedInputs -= 1 }
            }
        }
    }

    /// Runs an input as the tool call an agent would make, so it shows in the device's activity
    /// as coming from the browser.
    private func perform(_ input: Input, on stream: Stream) async {
        guard var (tool, arguments) = Self.toolCall(for: input, frameSize: stream.phone.status().frameSize) else { return }
        if let device = stream.session.deviceID ?? (stream.device.isEmpty ? nil : stream.device) {
            arguments["device"] = .string(device)
        }
        _ = try? await tools.call(tool, arguments: .object(arguments), source: "browser", screenshotByDefault: false)
    }

    /// The tool and its arguments for an input. Points arrive as fractions of the screen and become
    /// screenshot pixels, as tools take them. Nil when the input makes no sense.
    static func toolCall(for input: Input, frameSize: (width: Int, height: Int)?) -> (String, [String: JSONValue])? {
        let size = frameSize.map { ScreenGeometry.screenshotSize(forFrameWidth: $0.width, height: $0.height) }
        func pixel(_ fraction: Double?, _ total: Int?) -> JSONValue? {
            guard let fraction, let total, total > 0, fraction.isFinite, (0...1).contains(fraction) else { return nil }
            return .number(min((fraction * Double(total)).rounded(), Double(total - 1)))
        }
        func clamped(_ value: Double?, _ fallback: Double, _ range: ClosedRange<Double>) -> JSONValue {
            guard let value, value.isFinite else { return .number(fallback) }
            return .number(min(max(value, range.lowerBound), range.upperBound))
        }
        switch input.action {
        case "tap", "long_press":
            guard let x = pixel(input.x, size?.width), let y = pixel(input.y, size?.height) else { return nil }
            if input.action == "tap" { return ("tap", ["x": x, "y": y]) }
            return ("long_press", ["x": x, "y": y, "seconds": clamped(input.seconds, 1, 0.3...5)])
        case "swipe":
            guard let fromX = pixel(input.fromX, size?.width), let fromY = pixel(input.fromY, size?.height),
                let toX = pixel(input.toX, size?.width), let toY = pixel(input.toY, size?.height)
            else { return nil }
            return (
                "swipe",
                [
                    "from_x": fromX, "from_y": fromY, "to_x": toX, "to_y": toY,
                    "duration": clamped(input.duration, 0.3, 0.1...2),
                ]
            )
        case "scroll":
            guard let direction = input.direction, ["up", "down", "left", "right"].contains(direction),
                let x = pixel(input.x ?? 0.5, size?.width), let y = pixel(input.y ?? 0.5, size?.height)
            else { return nil }
            let amount = min(max((input.amount ?? 3).rounded(), 1), 20)
            return ("scroll", ["x": x, "y": y, "direction": .string(direction), "amount": .number(amount)])
        case "text":
            guard let text = input.text, !text.isEmpty, text.count <= 1000 else { return nil }
            return ("type_text", ["text": .string(text)])
        case "key":
            guard let key = input.key, !key.isEmpty, key.count <= 16 else { return nil }
            let modifiers = (input.modifiers ?? []).filter { ["cmd", "shift", "option", "ctrl"].contains($0) }
            var arguments: [String: JSONValue] = ["key": .string(key)]
            if !modifiers.isEmpty { arguments["modifiers"] = .array(modifiers.map(JSONValue.string)) }
            return ("press_key", arguments)
        case "home":
            return ("home", [:])
        default:
            return nil
        }
    }

    // MARK: Helpers

    /// Stops streams that were already taken out of `state`, tells the relay why when `code` is set,
    /// and logs it in each device's activity.
    private func finish(_ streams: [Stream], code: String?, reason: String, log: String) {
        guard !streams.isEmpty else { return }
        for stream in streams {
            stream.cancel()
            if let code {
                let frame = Self.endFrame(id: stream.id, code: code, reason: reason)
                Task { _ = await stream.send(frame) }
            }
            stream.activity?.record(source: "browser", tool: "live_view", summary: log, failed: false)
        }
        notify()
    }

    private func notify() { onChange(sessions) }

    /// "you in the dashboard and the share link “QA” (view only)" and the like.
    public static func describe(_ viewers: [Viewer]) -> String {
        guard !viewers.isEmpty else { return "nobody" }
        var counted: [(summary: String, count: Int)] = []
        for viewer in viewers {
            if let index = counted.firstIndex(where: { $0.summary == viewer.summary }) {
                counted[index].count += 1
            } else {
                counted.append((viewer.summary, 1))
            }
        }
        let parts = counted.map { $0.count > 1 ? "\($0.summary) ×\($0.count)" : $0.summary }
        return parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    static func frameJSON(id: String, seq: Int, image: EncodedImage) -> String {
        struct Frame: Encodable {
            let type = "live_frame"
            let id: String
            let seq: Int
            let width: Int
            let height: Int
            let jpeg: String
        }
        let frame = Frame(id: id, seq: seq, width: image.width, height: image.height, jpeg: image.data.base64EncodedString())
        return (try? encoder.encode(frame)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func endFrame(id: String, code: String, reason: String) -> String {
        let frame = ["type": "live_end", "id": id, "code": code, "reason": reason]
        return (try? encoder.encode(frame)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
