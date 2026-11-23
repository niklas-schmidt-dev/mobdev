import Foundation

/// Where a device's request log stood at a moment: requests numbered after `cursor` finished
/// later, and a tunnel opened at or after `time` is newer.
struct NetworkMark: Sendable, Equatable {
    var cursor: Int
    /// Nil when the moment is not known: every open tunnel counts.
    var time: Date?
}

/// The iOS apps of one device whose requests Mobdev reads from their CFNetwork log.
final class AppNetworkCapture: Sendable {
    let log = NetworkLog()
    let readers = Locked<[String: CFNetworkLog]>([:])
    /// Where the device's request log (this one, or Android's proxy's) stood when the last action
    /// on the device began, for `wait_for_request` without a cursor.
    let lastAction = Locked<NetworkMark?>(nil)
    /// The HTTPS tunnels `wait_for_request` returned, each with the cursor it returned: a tunnel has
    /// no number while it is open and gets a newer one when it closes, so that cursor alone would
    /// find the same connection again.
    let returnedTunnels = Locked<[String: Int]>([:])

    /// A tunnel as `returnedTunnels` knows it, open or closed: where it goes and when it opened.
    static func tunnelKey(_ entry: NetworkEntry) -> String {
        "\(entry.host):\(entry.port ?? 443)@\(entry.time.timeIntervalSinceReferenceDate)"
    }

    var capturing: [String] { readers.get().filter { $0.value.isRecording }.keys.sorted() }

    /// Stops listing an app's requests; nil stops every app's. Returns the apps that were captured.
    @discardableResult
    func stop(_ app: String?) -> [String] {
        let stopped = readers.get().filter { (app == nil || $0.key == app) && $0.value.isRecording }
        for reader in stopped.values { reader.stopRecording() }
        return stopped.keys.sorted()
    }
}

/// What an app sends over the network, for debugging, checking analytics and API calls, and
/// privacy audits. Android's traffic goes through Mobdev's proxy; iOS apps report their requests in
/// their own CFNetwork log. Neither decrypts HTTPS.
extension PhoneTools {
    /// Makes CFNetwork log each request and copies the app's system log to its console, where
    /// launch_app captures it (see `CFNetworkLog`).
    static let networkDiagnosticsEnvironment = ["CFNETWORK_DIAGNOSTICS": "1", "ACTIVITY_LOG_STDERR": "1"]

    static let networkDefinitions: [ToolDefinition] = {
        let bundleID: JSONValue = [
            "type": "string", "description": "Bundle ID, e.g. com.example.MyApp, or the package name on Android",
        ]
        return [
            ToolDefinition(
                name: "start_network_capture", title: "Start network capture",
                description:
                    "Start recording which requests an app makes; read them with network_log. iOS (simulators, and iPhones with Developer Mode): relaunches the app (bundle_id) so it reports its URLSession requests in its own log: method, host, status, bytes and time, but iOS hides paths and queries, and web views and other processes are not included. Android: sends the device's traffic through Mobdev's proxy (every app's, without telling them apart): plain HTTP in full, HTTPS as host, port, bytes and time without decrypting it; with bundle_id the app is restarted so its connections use the proxy. Apps that ignore Android's proxy setting, such as Flutter apps, bypass it. Stop with stop_network_capture, which removes the proxy again.",
                inputSchema: schema(["bundle_id": bundleID], screenshot: false), readOnly: false),
            ToolDefinition(
                name: "network_log", title: "Network log",
                description:
                    "Requests recorded since start_network_capture, in the order they finished: start time, method, URL, status, bytes each way, duration and where the information comes from (proxy or cfnetwork). Ones still running, such as open HTTPS tunnels, are listed apart. Queries show as ?… unless query is true; headers (plain HTTP on Android only, with Authorization and cookies replaced) with headers true. Pass the cursor of the previous result as after for newer requests only.",
                inputSchema: schema(
                    [
                        "bundle_id": ["type": "string", "description": "Only this app's requests (iOS)"],
                        "contains": ["type": "string", "description": "Only requests whose method, URL or error contain this"],
                        "after": ["type": "integer", "minimum": 0, "description": "Only requests after this cursor"],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 1000, "description": "At most, default 100"],
                        "query": ["type": "boolean", "description": "Show query strings, default false"],
                        "headers": ["type": "boolean", "description": "Include request and response headers, default false"],
                    ], screenshot: false),
                readOnly: true),
            ToolDefinition(
                name: "wait_for_request", title: "Wait for request",
                description:
                    "Wait until the running network capture records a request whose URL contains url, optionally with this method and status, and return it, e.g. to prove in a flow or test that the app called its API. Counts requests that finished after the cursor after (from network_log or an earlier wait_for_request), else those since the last action on the device began (a tap, typing, launch_app…), so a request a tap caused counts even when it finished before this call. Fails after timeout, at once when no capture runs, and when the filter can never match what the device reports: iOS shows hosts without paths (wait for api.example.com, not /login); Android's proxy shows plain HTTP in full but HTTPS only as a connection to the host, once per connection rather than per request.",
                inputSchema: schema(
                    [
                        "url": [
                            "type": "string",
                            "description": "Part of the URL, e.g. api.example.com, or /api/login for plain HTTP on Android",
                        ],
                        "method": ["type": "string", "description": "GET, POST…"],
                        "status": ["type": "integer", "minimum": 100, "maximum": 599],
                        "after": [
                            "type": "integer", "minimum": 0,
                            "description": "Only requests after this cursor; default since the last action",
                        ],
                        "timeout": ["type": "number", "description": "Seconds, default 10, at most 60"],
                    ], required: ["url"], screenshot: false),
                readOnly: true),
            ToolDefinition(
                name: "stop_network_capture", title: "Stop network capture",
                description:
                    "Stop recording requests. On Android this removes Mobdev's proxy from the device's settings. An iOS app keeps logging its requests until it is launched again. network_log still lists what was recorded.",
                inputSchema: schema(
                    ["bundle_id": ["type": "string", "description": "Only this app (iOS); default every app"]],
                    screenshot: false),
                readOnly: false),
            ToolDefinition(
                name: "mock_response", title: "Mock a response",
                description:
                    "Android only: answer plain HTTP requests whose URL contains url with a fixed status and body instead of asking the server, while network capture runs, e.g. to test an error state against a local dev server (http://10.0.2.2:3000/…). HTTPS cannot be mocked, since Mobdev does not decrypt it. clear true removes every mock.",
                inputSchema: schema(
                    [
                        "url": ["type": "string", "description": "Part of the URL, e.g. /api/feed"],
                        "status": ["type": "integer", "minimum": 100, "maximum": 599, "description": "Default 200"],
                        "body": ["type": "string", "description": "Default empty"],
                        "content_type": [
                            "type": "string", "description": "Default application/json for a JSON body, text/plain otherwise",
                        ],
                        "clear": ["type": "boolean", "description": "Remove every mock instead"],
                    ], screenshot: false),
                readOnly: false),
        ]
    }()

    func runNetworkTool(_ name: String, _ args: Arguments) async throws -> ToolOutput? {
        switch name {
        case "start_network_capture": return try await startNetworkCapture(args)
        case "network_log": return try networkLog(args)
        case "wait_for_request": return try await waitForRequest(args)
        case "stop_network_capture": return try await stopNetworkCapture(args)
        case "mock_response": return try mockResponse(args)
        default: return nil
        }
    }

    private func startNetworkCapture(_ args: Arguments) async throws -> ToolOutput {
        let bundleID = args.has("bundle_id") ? try args.string("bundle_id") : nil
        if let proxy = phone.networkProxy {
            let address = try await proxy.start()
            var text =
                "Capturing the device's traffic through Mobdev's proxy at \(address): plain HTTP in full, HTTPS as host, port, bytes and time. Read it with network_log; stop_network_capture removes the proxy again."
            if let bundleID, let apps = phone.apps {
                // The capture runs either way, so a failed restart is reported rather than thrown.
                do {
                    _ = try await apps.launch(bundleID, arguments: [], environment: [:], restart: true)
                    text += " Restarted \(bundleID) so its connections go through the proxy."
                } catch {
                    text += " Could not restart \(bundleID): \(error). Start it with launch_app."
                }
            } else {
                text += " Apps keep connections they opened before until they reconnect; pass bundle_id to restart one."
            }
            return ToolOutput(text: text, data: ["proxy": .string(address), "source": "proxy"])
        }
        guard let apps = phone.apps else {
            throw ToolFailure(
                "Network capture needs a simulator, an iPhone with Developer Mode, or Android. Mobdev has not read this iPhone's identity over USB yet: reconnect the cable and unlock it.")
        }
        guard let bundleID else {
            throw ToolFailure("Pass bundle_id: on iOS the app reports its own requests, so Mobdev relaunches that app.")
        }
        let reader = CFNetworkLog(app: bundleID, log: appNetwork.log)
        appNetwork.stop(bundleID)
        appNetwork.readers.withLock { $0[bundleID] = reader }
        apps.logs.setReader({ reader.consume($0) }, for: bundleID)
        let outcome: LaunchOutcome
        do {
            outcome = try await apps.launch(
                bundleID, arguments: [], environment: Self.networkDiagnosticsEnvironment, restart: true)
        } catch {
            endAppCapture(bundleID)
            throw error
        }
        guard outcome != .launchedWithoutOutput else {
            endAppCapture(bundleID)
            throw ToolFailure(
                "Relaunched \(bundleID), but devicectl could not attach to its output, which carries its requests. Call start_network_capture again.")
        }
        return ToolOutput(
            text:
                "Relaunched \(bundleID) with CFNetwork's diagnostics on; its requests are recorded with method, host, status, bytes and time (iOS hides paths and queries). Read them with network_log.",
            data: ["bundle_id": .string(bundleID), "source": "cfnetwork"])
    }

    /// Stops reading an app's network lines, when it is launched again without the diagnostics.
    func endAppCapture(_ bundleID: String) {
        appNetwork.stop(bundleID)
        appNetwork.readers.withLock { _ = $0.removeValue(forKey: bundleID) }
        phone.apps?.logs.setReader(nil, for: bundleID)
    }

    private func stopNetworkCapture(_ args: Arguments) async throws -> ToolOutput {
        if let proxy = phone.networkProxy {
            guard try await proxy.stop() else {
                return ToolOutput(text: "Network capture was not running. Start it with start_network_capture.")
            }
            let count = proxy.log.read(app: nil, after: nil, limit: Int.max, contains: nil).entries.count
            return ToolOutput(
                text: "Stopped capturing and removed Mobdev's proxy from the device. network_log lists the \(count) recorded requests.")
        }
        let app = args.has("bundle_id") ? try args.string("bundle_id") : nil
        let stopped = appNetwork.stop(app)
        guard !stopped.isEmpty else {
            return ToolOutput(text: "Network capture was not running\(app.map { " for \($0)" } ?? ""). Start it with start_network_capture.")
        }
        return ToolOutput(
            text:
                "Stopped recording requests of \(stopped.joined(separator: ", ")). The app keeps CFNetwork's diagnostics until it is launched again; network_log lists what was recorded.")
    }

    private func networkLog(_ args: Arguments) throws -> ToolOutput {
        let app = args.has("bundle_id") ? try args.string("bundle_id") : nil
        let after = args.has("after") ? Int(try args.number("after", default: 0, range: 0...1e15)) : nil
        let limit = Int(try args.number("limit", default: 100, range: 1...1000))
        let contains = args.has("contains") ? try args.string("contains") : nil
        let showQuery = args.bool("query") ?? false
        let showHeaders = args.bool("headers") ?? false

        let log = requestLog
        let capturing = captureState().text
        var notes: [String] = []
        if phone.networkProxy != nil, app != nil {
            notes.append("Android's proxy sees every app's traffic and cannot tell which app made a request.")
        }
        let page = log.read(app: app, after: after, limit: limit, contains: contains)
        let open = log.openEntries.filter { entry in
            (app == nil || entry.app == nil || entry.app == app)
                && (contains.map { NetworkLog.text(of: entry).localizedCaseInsensitiveContains($0) } ?? true)
        }
        // The first line counts, since the activity log and flow results show only it.
        var head = page.entries.isEmpty
            ? (after == nil ? "No requests" : "No new requests")
            : "\(page.entries.count) \(page.entries.count == 1 ? "request" : "requests")\(after == nil ? "" : " since \(after!)")"
        if !open.isEmpty { head += ", \(open.count) still running" }
        var lines = ["\(head). \(capturing)"] + notes
        if page.dropped > 0 { lines.append("\(page.dropped) older requests were dropped before you read them.") }
        if page.entries.isEmpty, open.isEmpty, log.read(app: nil, after: nil, limit: 1, contains: nil).entries.isEmpty {
            lines.append("Start with start_network_capture, then use the app.")
        }
        // Agents read the text, so asked-for headers go there too, indented under their request.
        func headerLines(_ entry: NetworkEntry) -> [String] {
            guard showHeaders else { return [] }
            return entry.requestHeaders.map { "  > \($0.name): \($0.value)" }
                + entry.responseHeaders.map { "  < \($0.name): \($0.value)" }
        }
        for entry in page.entries { lines += [entry.summary(query: showQuery)] + headerLines(entry) }
        if !open.isEmpty {
            lines.append("Still running:")
            for entry in open { lines += [entry.summary(query: showQuery, open: true)] + headerLines(entry) }
        }
        lines.append(
            page.more
                ? "Cursor: \(page.cursor). More requests are waiting: call again with after \(page.cursor)."
                : "Cursor: \(page.cursor). Pass it as after to get only newer requests.")
        return ToolOutput(
            text: lines.joined(separator: "\n"),
            data: [
                "entries": .array(page.entries.map { $0.json(query: showQuery, headers: showHeaders) }),
                "open": .array(open.map { $0.json(query: showQuery, headers: showHeaders) }),
                "cursor": .number(Double(page.cursor)),
                "more": .bool(page.more),
                "dropped": .number(Double(page.dropped)),
            ])
    }

    /// The log this device's requests go to: Android's proxy's, or that of the iOS apps.
    var requestLog: NetworkLog { phone.networkProxy?.log ?? appNetwork.log }

    /// Notes where the request log stands as an action begins, so `wait_for_request` counts the
    /// requests the action caused even when they finished before it was called.
    func markNetworkAction() {
        appNetwork.lastAction.set(NetworkMark(cursor: requestLog.cursor, time: Date()))
    }

    /// Whether this device records requests now, and how, as network_log says it.
    private func captureState() -> (running: Bool, text: String) {
        if let proxy = phone.networkProxy {
            guard let address = proxy.address else { return (false, "Not capturing now.") }
            return (true, "Capturing through Mobdev's proxy at \(address).")
        }
        let apps = appNetwork.capturing
        guard !apps.isEmpty else { return (false, "Not capturing now.") }
        return (true, "Capturing \(apps.joined(separator: ", ")) through CFNetwork's log.")
    }

    private func waitForRequest(_ args: Arguments) async throws -> ToolOutput {
        let filter = RequestFilter(
            url: try args.string("url", maxLength: 2000),
            method: args.has("method") ? try args.string("method", maxLength: 20).uppercased() : nil,
            status: args.has("status") ? Int(try args.number("status", default: 200, range: 100...599)) : nil)
        let timeout = try args.number("timeout", default: 10, range: 0...60)
        let log = requestLog
        let source: NetworkEntry.Source = phone.networkProxy == nil ? .cfnetwork : .proxy
        let start: NetworkMark
        // With a cursor, a tunnel an earlier wait returned with that cursor or an older one is not news.
        var returned: [String: Int] = [:]
        if args.has("after") {
            // A cursor from before Mobdev restarted is newer than anything here: start over, as
            // network_log does.
            let after = Int(try args.number("after", default: 0, range: 0...1e15))
            let cursor = after > log.cursor ? 0 : after
            // A tunnel is newer when it opened after the cursor's request finished.
            let previous = cursor == 0 ? nil : log.entries { $0.number <= cursor }.last
            start = NetworkMark(cursor: cursor, time: previous.map { $0.time.addingTimeInterval($0.duration ?? 0) })
            returned = appNetwork.returnedTunnels.get().filter { $0.value <= cursor }
        } else {
            start = appNetwork.lastAction.get() ?? NetworkMark(cursor: log.cursor, time: Date())
        }
        let seen: (NetworkEntry) -> Bool = { $0.scheme == nil && returned[AppNetworkCapture.tunnelKey($0)] != nil }
        let pathsSeen = !log.entries { $0.source == source && $0.path != nil }.isEmpty
        if let reason = filter.impossible(on: source, pathsSeen: pathsSeen) { throw ToolFailure(reason) }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let (entry, open) = Self.firstRequest(matching: filter, in: log, since: start, skipping: seen) {
                // An open tunnel has no number yet: what follows it comes after the log's end.
                let cursor = open ? log.cursor : entry.number
                if open {
                    appNetwork.returnedTunnels.withLock { tunnels in
                        // Old ones go once there are many; a wait rarely reaches back that far.
                        if tunnels.count >= 500 { tunnels = tunnels.filter { $0.value > cursor - 1000 } }
                        tunnels[AppNetworkCapture.tunnelKey(entry)] = cursor
                    }
                }
                var text = "Found \(entry.summary(query: false, open: open))."
                if entry.scheme == nil { text += " Android's proxy sees HTTPS only as this connection to the host." }
                text += "\nCursor: \(cursor). Pass it as after to wait for a later request."
                return ToolOutput(
                    text: text,
                    data: [
                        "request": entry.json(query: false, headers: false), "open": .bool(open),
                        "cursor": .number(Double(cursor)),
                    ])
            }
            let capture = captureState()
            guard capture.running else {
                throw ToolFailure(
                    "Network capture is not running, so no request can arrive: no request matched \(filter). Start it with start_network_capture, then do what should send the request.")
            }
            if Date() >= deadline {
                throw ToolFailure(requestTimeout(filter, timeout, log: log, start: start, source: source, capture: capture.text))
            }
            try await pause(0.25)
        }
    }

    /// The oldest finished request after `start` that matches, else an HTTPS tunnel through the
    /// proxy that opened since: one is listed only once it closes, which a connection kept alive
    /// does minutes later.
    static func firstRequest(
        matching filter: RequestFilter, in log: NetworkLog, since start: NetworkMark,
        skipping seen: (NetworkEntry) -> Bool = { _ in false }
    ) -> (entry: NetworkEntry, open: Bool)? {
        if let entry = log.entries(where: { $0.number > start.cursor && filter.matches($0) && !seen($0) }).first {
            return (entry, false)
        }
        let tunnel = log.openEntries.first { entry in
            entry.scheme == nil && entry.time >= (start.time ?? .distantPast) && filter.matches(entry) && !seen(entry)
        }
        return tunnel.map { ($0, true) }
    }

    /// Says what came instead: requests to the same URL with another method or status, ones still
    /// running, and how many others finished, so the agent can tell a typo from a missing call.
    private func requestTimeout(
        _ filter: RequestFilter, _ timeout: Double, log: NetworkLog, start: NetworkMark, source: NetworkEntry.Source,
        capture: String
    ) -> String {
        var lines = ["Timed out after \(format(timeout)) s: no request matched \(filter). \(capture)"]
        let sameURL = RequestFilter(url: filter.url)
        let since = log.entries { $0.number > start.cursor }
        let near = since.filter(sameURL.matches)
        if !near.isEmpty {
            lines.append("With \"\(filter.url)\" in the URL but another method or status:")
            lines += near.suffix(5).map { $0.summary(query: false) }
        }
        let running = log.openEntries.filter(sameURL.matches)
        if !running.isEmpty {
            lines.append("Still running:")
            lines += running.suffix(5).map { $0.summary(query: false, open: true) }
        }
        if source == .proxy {
            if filter.needsDetails, filter.parts.scheme != "http" {
                lines.append(
                    "Android's proxy sees HTTPS only as a connection to the host, so a path, method or status matches plain HTTP requests only.")
            }
            if running.contains(where: { $0.scheme == nil }) {
                lines.append("A request sent over an HTTPS connection that was already open does not show again.")
            }
        }
        let others = since.count - near.count
        lines.append(
            others == 0
                ? "No other request finished since cursor \(start.cursor)."
                : "\(others) other \(others == 1 ? "request" : "requests") finished since cursor \(start.cursor); network_log with after \(start.cursor) lists them.")
        return lines.joined(separator: "\n")
    }

    private func mockResponse(_ args: Arguments) throws -> ToolOutput {
        guard let proxy = phone.networkProxy else {
            throw ToolFailure(
                "mock_response works on Android only, where requests pass through Mobdev's proxy. On iOS, point the app at a test server with launch_app's environment or arguments instead.")
        }
        if args.bool("clear") == true {
            let count = proxy.clearMocks()
            return ToolOutput(text: count == 0 ? "There were no mocks." : "Removed \(count) mocks.")
        }
        let url = try args.string("url", maxLength: 2000)
        let status = Int(try args.number("status", default: 200, range: 100...599))
        let body = args.value["body"]?.stringValue ?? ""
        guard body.utf8.count <= 1_000_000 else { throw ToolFailure("body has more than 1 MB; keep mocks small.") }
        let isJSON = (try? JSONValue.parse(Data(body.utf8))) != nil
        let contentType = args.has("content_type")
            ? try args.string("content_type", maxLength: 200) : (isJSON ? "application/json" : "text/plain; charset=utf-8")
        guard !contentType.contains("\r"), !contentType.contains("\n") else {
            throw ToolFailure("content_type must be one line, e.g. application/json.")
        }
        proxy.addMock(ResponseMock(url: url, status: status, contentType: contentType, body: Data(body.utf8)))
        var text = "Plain HTTP requests whose URL contains \"\(url)\" now get \(status) with \(body.utf8.count) bytes of \(contentType)."
        if proxy.address == nil { text += " Start network capture with start_network_capture for it to apply." }
        if url.lowercased().hasPrefix("https") { text += " HTTPS cannot be mocked: Mobdev does not decrypt it." }
        return ToolOutput(text: text, data: ["mocks": .number(Double(proxy.mocks.count))])
    }
}

/// What `wait_for_request` waits for: part of the URL, and optionally the method and status.
struct RequestFilter: Sendable, Equatable, CustomStringConvertible {
    var url: String
    /// Upper case.
    var method: String?
    var status: Int?

    init(url: String, method: String? = nil, status: Int? = nil) {
        self.url = url
        self.method = method
        self.status = status
    }

    var description: String {
        (["url \"\(url)\""] + [method.map { "method \($0)" }, status.map { "status \($0)" }].compactMap { $0 })
            .joined(separator: ", ")
    }

    /// The url split where its host ends: "https://api.example.com/v1?page=2" is "https",
    /// "api.example.com" and "/v1?page=2".
    var parts: (scheme: String?, host: String, rest: String) {
        var scheme: String?
        var remainder = Substring(url)
        if let separator = url.range(of: "://"), case let given = url[..<separator.lowerBound], !given.isEmpty,
            given.allSatisfy(\.isLetter)
        {
            scheme = given.lowercased()
            remainder = url[separator.upperBound...]
        }
        let end = remainder.firstIndex { $0 == "/" || $0 == "?" } ?? remainder.endIndex
        return (scheme, String(remainder[..<end]), String(remainder[end...]))
    }

    /// The url names a path or query, not only a host.
    var hasPath: Bool { !["", "/"].contains(parts.rest) }

    /// Asks for what a connection to a host does not show: a path, a method or a status.
    var needsDetails: Bool { hasPath || (method != nil && method != "CONNECT") || status != nil }

    func matches(_ entry: NetworkEntry) -> Bool {
        // A tunnel through Android's proxy is an HTTPS connection: its host and port, nothing more.
        // "https://api.example.com" means it as well as "api.example.com:443" does.
        if entry.scheme == nil {
            guard status == nil, method == nil || method == entry.method else { return false }
            let port = entry.port ?? 443
            let texts = ["\(entry.host):\(port)", "https://\(entry.host)\(port == 443 ? "" : ":\(port)")/"]
            return texts.contains { $0.localizedCaseInsensitiveContains(url) }
        }
        if let method, entry.method.uppercased() != method { return false }
        if let status, entry.status != status { return false }
        return entry.target(query: true).localizedCaseInsensitiveContains(url)
    }

    /// Why no request this source records can ever match, or nil. iOS hides paths and queries
    /// unless one it already reported shows otherwise; Android's proxy sees HTTPS as a tunnel.
    func impossible(on source: NetworkEntry.Source, pathsSeen: Bool) -> String? {
        let (scheme, host, _) = parts
        let example = host.isEmpty ? "api.example.com" : host
        switch source {
        case .cfnetwork:
            guard hasPath, !pathsSeen else { return nil }
            return
                "iOS reports requests without their paths and queries (https://\(example)/…), so url \"\(url)\" can never match. Wait for the host instead, e.g. url \"\(example)\", with method and status if needed."
        case .proxy:
            guard scheme == "https", needsDetails else { return nil }
            let tunnel = example.contains(":") ? example : example + ":443"
            return
                "Android's proxy sees an HTTPS request only as a connection to its host (CONNECT \(tunnel)), without path, method or status, so \(self) can never match. Wait for url \"\(example)\" alone; plain HTTP, such as a local dev server, shows in full."
        }
    }
}
