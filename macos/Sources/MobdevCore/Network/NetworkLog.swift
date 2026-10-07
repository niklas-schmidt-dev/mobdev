import Foundation

/// One request or HTTPS tunnel an app made, as far as Mobdev could see it.
public struct NetworkEntry: Sendable, Equatable {
    /// Where the information comes from.
    public enum Source: String, Sendable {
        /// Mobdev's proxy, which Android sends its traffic through: plain HTTP in full, HTTPS as a
        /// tunnel to a host and port.
        case proxy
        /// The app's own CFNetwork log on iOS: method, host, status and size, without the path.
        case cfnetwork
    }

    /// Set when the entry is added to a log; the cursor for `after`.
    public var number = 0
    /// When the request started.
    public var time: Date
    /// The app that made it, where the source knows: iOS, not Android's proxy.
    public var app: String?
    /// GET, POST…, or CONNECT for an HTTPS tunnel through the proxy.
    public var method: String
    /// "http" or "https"; nil for a tunnel.
    public var scheme: String?
    public var host: String
    /// Only when it is not the scheme's default, or for a tunnel.
    public var port: Int?
    /// Nil where it is not known: iOS hides it, and a tunnel is encrypted.
    public var path: String?
    /// Without the "?". Shown only when asked for.
    public var query: String?
    public var status: Int?
    /// What the app sent and received, as the source counts it: on the wire with headers for the
    /// proxy and CFNetwork's summary, the response body for CFNetwork alone.
    public var bytesSent: Int?
    public var bytesReceived: Int?
    public var duration: TimeInterval?
    /// Why it failed, e.g. "host not found".
    public var error: String?
    /// "http/1.1", "h2" or "h3", where CFNetwork says.
    public var httpProtocol: String?
    public var source: Source
    /// Answered by `mock_response` instead of the server.
    public var mocked = false
    /// With credentials replaced; plain HTTP through the proxy only.
    public var requestHeaders: [Header] = []
    public var responseHeaders: [Header] = []

    public struct Header: Sendable, Equatable {
        public var name: String
        public var value: String
    }

    public init(
        time: Date, app: String? = nil, method: String, scheme: String?, host: String, port: Int? = nil,
        path: String? = nil, query: String? = nil, source: Source
    ) {
        self.time = time
        self.app = app
        self.method = method
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
        self.query = query
        self.source = source
    }

    /// "https://example.com/feed?…", or "example.com:443" for a tunnel. The query shows as "?…"
    /// unless `query` is true; an unknown path as "/…".
    public func target(query showQuery: Bool) -> String {
        guard let scheme else { return "\(host):\(port ?? 443)" }
        var text = "\(scheme)://\(host)"
        if let port { text += ":\(port)" }
        text += path ?? "/…"
        if let query, !query.isEmpty { text += showQuery ? "?\(query)" : "?…" }
        return text
    }

    /// One line for people and agents: "15:28:56.327 GET https://example.com/… 404, 701 B in, 49 ms".
    public func summary(query: Bool, open: Bool = false) -> String {
        var parts: [String] = []
        if let status { parts.append(method == "CONNECT" && status == 200 ? "tunnel" : String(status)) }
        if let error { parts.append(error) }
        if mocked { parts.append("mocked") }
        if let bytesSent { parts.append("\(Self.size(bytesSent)) out") }
        if let bytesReceived { parts.append("\(Self.size(bytesReceived)) in") }
        if open {
            parts.append("open for \(Self.milliseconds(Date().timeIntervalSince(time)))")
        } else if let duration {
            parts.append(Self.milliseconds(duration))
        }
        if let httpProtocol { parts.append(httpProtocol) }
        let clock = Self.clock.string(from: time)
        let details = parts.isEmpty ? "" : " " + parts.joined(separator: ", ")
        return "\(clock) \(method) \(target(query: query))\(details)"
    }

    public func json(query: Bool, headers: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "n": .number(Double(number)), "time": .string(Self.timestamp.format(time)),
            "method": .string(method), "host": .string(host), "url": .string(target(query: query)),
            "source": .string(source.rawValue),
        ]
        func set(_ key: String, _ value: JSONValue?) { if let value { object[key] = value } }
        set("app", app.map(JSONValue.string))
        set("scheme", scheme.map(JSONValue.string))
        set("port", port.map { .number(Double($0)) })
        set("path", path.map(JSONValue.string))
        if query { set("query", self.query.map(JSONValue.string)) }
        set("status", status.map { .number(Double($0)) })
        set("bytes_sent", bytesSent.map { .number(Double($0)) })
        set("bytes_received", bytesReceived.map { .number(Double($0)) })
        set("duration_ms", duration.map { .number(($0 * 1000).rounded()) })
        set("error", error.map(JSONValue.string))
        set("protocol", httpProtocol.map(JSONValue.string))
        if mocked { object["mocked"] = true }
        if headers {
            func list(_ headers: [Header]) -> JSONValue {
                .array(headers.map { ["name": .string($0.name), "value": .string($0.value)] })
            }
            if !requestHeaders.isEmpty { object["request_headers"] = list(requestHeaders) }
            if !responseHeaders.isEmpty { object["response_headers"] = list(responseHeaders) }
        }
        return .object(object)
    }

    static func size(_ bytes: Int) -> String {
        bytes < 10_000 ? "\(bytes) B" : String(format: "%.1f kB", Double(bytes) / 1000)
    }

    static func milliseconds(_ seconds: TimeInterval) -> String {
        seconds < 10 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.1f s", seconds)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Headers whose values are credentials, replaced before they are kept.
    static let secretHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie"]

    /// At most 50 headers of at most 1000 characters each, credentials replaced.
    static func redacted(_ headers: [Header]) -> [Header] {
        headers.prefix(50).map { header in
            Header(
                name: header.name,
                value: secretHeaders.contains(header.name.lowercased()) ? "<redacted>" : String(header.value.prefix(1000)))
        }
    }
}

/// The requests a device made while Mobdev captured them, numbered like `AppLogs` so agents ask
/// for newer ones only. An entry is listed once it finished; until then it is open.
public final class NetworkLog: Sendable {
    public struct Page: Sendable, Equatable {
        public let entries: [NetworkEntry]
        public let cursor: Int
        public let more: Bool
        /// Finished entries after `after` that were dropped before they were read.
        public let dropped: Int
    }

    private struct State {
        var entries: [NetworkEntry] = []
        var next = 1
        /// Requests and tunnels still running, by an id of the source's choosing.
        var open: [Int: NetworkEntry] = [:]
        var nextOpen = 1
    }

    private let state = Locked(State())
    private let limit: Int

    public init(limit: Int = 2000) { self.limit = limit }

    /// Starts an open entry and returns its id for `update` and `finish`.
    @discardableResult
    func open(_ entry: NetworkEntry) -> Int {
        state.withLock { state in
            let id = state.nextOpen
            state.nextOpen += 1
            state.open[id] = entry
            return id
        }
    }

    /// Changes an open entry, e.g. its byte counts. Nothing when it is no longer open.
    func update(_ id: Int, _ change: (inout NetworkEntry) -> Void) {
        state.withLock { state in
            guard var entry = state.open[id] else { return }
            change(&entry)
            state.open[id] = entry
        }
    }

    /// Lists an open entry, changed one last time, and returns its number.
    @discardableResult
    func finish(_ id: Int, _ change: (inout NetworkEntry) -> Void = { _ in }) -> Int? {
        state.withLock { state in
            guard var entry = state.open.removeValue(forKey: id) else { return nil }
            change(&entry)
            return Self.append(entry, to: &state, limit: limit)
        }
    }

    /// Lists a finished entry and returns its number.
    @discardableResult
    func add(_ entry: NetworkEntry) -> Int {
        state.withLock { Self.append(entry, to: &$0, limit: limit) }
    }

    /// Changes a listed entry, e.g. with CFNetwork's summary that arrives right after it finished.
    func amend(_ number: Int, _ change: (inout NetworkEntry) -> Void) {
        state.withLock { state in
            guard let index = state.entries.lastIndex(where: { $0.number == number }) else { return }
            change(&state.entries[index])
        }
    }

    private static func append(_ entry: NetworkEntry, to state: inout State, limit: Int) -> Int {
        var entry = entry
        entry.number = state.next
        state.next += 1
        state.entries.append(entry)
        if state.entries.count > limit { state.entries.removeFirst(state.entries.count - limit) }
        return entry.number
    }

    /// The finished entries that match `matches`, newest last.
    func entries(where matches: (NetworkEntry) -> Bool) -> [NetworkEntry] {
        state.get().entries.filter(matches)
    }

    /// Requests and tunnels still running, oldest first.
    public var openEntries: [NetworkEntry] {
        state.get().open.sorted { $0.key < $1.key }.map(\.value)
    }

    /// The ids and entries still open, for a source that matches what it sees to them.
    func openWithIDs() -> [(id: Int, entry: NetworkEntry)] {
        state.get().open.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Without `after`, the newest `limit` entries. With it, the oldest `limit` entries after it, so
    /// paging with the returned cursor never skips one. Optionally for one app, containing some text
    /// in the method, URL (query included) or error.
    public func read(app: String?, after: Int?, limit: Int, contains: String?) -> Page {
        let current = state.get()
        let last = current.next - 1
        // A cursor from before Mobdev restarted is newer than anything here: start over.
        let after = after.flatMap { $0 > last ? nil : $0 }
        let matching = current.entries.filter { entry in
            entry.number > (after ?? 0) && (app == nil || entry.app == nil || entry.app == app)
                && (contains.map { Self.text(of: entry).localizedCaseInsensitiveContains($0) } ?? true)
        }
        guard let after else { return Page(entries: Array(matching.suffix(limit)), cursor: last, more: false, dropped: 0) }
        let page = Array(matching.prefix(limit))
        let more = matching.count > limit
        let oldest = current.entries.first?.number ?? current.next
        return Page(
            entries: page, cursor: more ? page.last!.number : last, more: more, dropped: max(0, oldest - 1 - after))
    }

    static func text(of entry: NetworkEntry) -> String {
        "\(entry.method) \(entry.target(query: true)) \(entry.error ?? "")"
    }
}
