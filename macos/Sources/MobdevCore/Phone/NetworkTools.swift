import Foundation

/// The iOS apps of one device whose requests Mobdev reads from their CFNetwork log.
final class AppNetworkCapture: Sendable {
    let log = NetworkLog()
    let readers = Locked<[String: CFNetworkLog]>([:])

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

        let log: NetworkLog
        let capturing: String
        var notes: [String] = []
        if let proxy = phone.networkProxy {
            log = proxy.log
            capturing = proxy.address.map { "Capturing through Mobdev's proxy at \($0)." } ?? "Not capturing now."
            if app != nil { notes.append("Android's proxy sees every app's traffic and cannot tell which app made a request.") }
        } else {
            log = appNetwork.log
            let apps = appNetwork.capturing
            capturing = apps.isEmpty ? "Not capturing now." : "Capturing \(apps.joined(separator: ", ")) through CFNetwork's log."
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
