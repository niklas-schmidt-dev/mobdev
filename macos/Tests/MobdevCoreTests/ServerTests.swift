import Foundation
import Testing
@testable import MobdevCore

/// A running API server on an ephemeral loopback port, backed by a fake phone.
final class TestServer: Sendable {
    let phone: FakePhone
    let server: HTTPServer
    let router: APIRouter
    let token = "mdl_test-token"

    init(phone: FakePhone = FakePhone(lines: [("Settings", 420, 300)])) async throws {
        self.phone = phone
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let portBox = Locked<UInt16>(0)
        let token = self.token
        let router = APIRouter(tools: tools, token: { token }, port: { portBox.get() })
        self.router = router
        server = HTTPServer(port: 0) { request in await router.handle(request, from: .local) }
        try await server.start()
        portBox.set(server.port)
    }

    var base: String { "http://127.0.0.1:\(server.port)" }

    func request(
        _ method: String, _ path: String, body: JSONValue? = nil, headers: [String: String] = [:],
        authorized: Bool = true
    ) async throws -> (Int, Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        if let body {
            request.httpBody = body.encoded()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, data, http)
    }
}

@Suite struct HTTPParserTests {
    @Test func parsesContentLengthBodies() {
        let raw = "POST /v1/tools/tap?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}"
        guard case .complete(let request) = HTTPParser.parse(Data(raw.utf8)) else {
            Issue.record("not parsed")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/v1/tools/tap")
        #expect(request.query == ["x": "1"])
        #expect(request.header("HOST") == "127.0.0.1")
        #expect(request.body == Data("{}".utf8))
    }

    @Test func waitsForTheWholeBody() {
        let raw = "POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"
        guard case .incomplete = HTTPParser.parse(Data(raw.utf8)) else {
            Issue.record("should wait")
            return
        }
    }

    @Test func decodesChunkedBodies() {
        let raw = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{\"\r\n3\r\na\":\r\n2\r\n1}\r\n0\r\n\r\n"
        guard case .complete(let request) = HTTPParser.parse(Data(raw.utf8)) else {
            Issue.record("not parsed")
            return
        }
        #expect(String(decoding: request.body, as: UTF8.self) == "{\"a\":1}")
    }

    @Test func rejectsOversizedBodies() {
        let raw = "POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n"
        guard case .invalid(413, _) = HTTPParser.parse(Data(raw.utf8)) else {
            Issue.record("should reject")
            return
        }
    }

    /// Malformed chunk sizes used to trap (a reversed range, an overflowing sum) before authentication.
    @Test func rejectsNegativeSignedAndHugeChunkSizes() {
        let head = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        for chunks in [
            "-1\r\nab\r\n0\r\n\r\n", "+2\r\nab\r\n0\r\n\r\n", "1\r\na\r\n7fffffffffffffff\r\nab\r\n",
            "1\r\na\r\nffffffff\r\n", "1 2\r\nab\r\n", "\r\n", "2\r\nabXY0\r\n\r\n",
        ] {
            switch HTTPParser.parse(Data((head + chunks).utf8)) {
            case .invalid: break
            case let result: Issue.record("\(chunks.debugDescription) gave \(result)")
            }
        }
    }

    @Test func boundsChunkFramingLines() {
        let head = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        var reader = HTTPRequestReader()
        #expect({ if case .incomplete = reader.append(Data((head + "1;").utf8)) { true } else { false } }())
        let extensions = Data(repeating: UInt8(ascii: "x"), count: HTTPRequestReader.maxLineBytes + 8)
        guard case .invalid(400, _) = reader.append(extensions) else {
            Issue.record("an endless chunk extension should be refused")
            return
        }
    }

    @Test func boundsTheWholeRequest() {
        var reader = HTTPRequestReader()
        _ = reader.append(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        let chunk = Data("1000\r\n".utf8) + Data(repeating: 0x61, count: 0x1000) + Data("\r\n".utf8)
        var result = HTTPParseResult.incomplete
        for _ in 0..<(HTTPRequestReader.maxRequestBytes / chunk.count + 2) {
            result = reader.append(chunk)
            if case .incomplete = result { continue }
            break
        }
        guard case .invalid(413, _) = result else {
            Issue.record("expected 413, got \(result)")
            return
        }
    }

    /// Byte by byte, as a slow client sends it, the result is the same as all at once.
    @Test func readsRequestsThatArriveInPieces() {
        let raw = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2;x=1\r\n{\"\r\n5\r\na\":1}\r\n0\r\nX-Trailer: 1\r\n\r\n"
        var reader = HTTPRequestReader()
        var result = HTTPParseResult.incomplete
        for byte in Data(raw.utf8) {
            if case .complete = result { Issue.record("completed early") }
            result = reader.append(Data([byte]))
        }
        guard case .complete(let request) = result else {
            Issue.record("not parsed: \(result)")
            return
        }
        #expect(request.path == "/mcp")
        #expect(String(decoding: request.body, as: UTF8.self) == "{\"a\":1}")

        var lengthReader = HTTPRequestReader()
        let body = "POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcd"
        var lengthResult = HTTPParseResult.incomplete
        for byte in Data(body.utf8) { lengthResult = lengthReader.append(Data([byte])) }
        guard case .complete(let lengthRequest) = lengthResult else {
            Issue.record("not parsed: \(lengthResult)")
            return
        }
        #expect(lengthRequest.body == Data("abcd".utf8))
    }
}

@Suite struct ServerTests {
    @Test func healthNeedsNoTokenButEverythingElseDoes() async throws {
        let server = try await TestServer()
        defer { server.server.stop() }
        let (health, _, _) = try await server.request("GET", "/healthz", authorized: false)
        #expect(health == 200)
        let (status, _, response) = try await server.request("GET", "/v1/status", authorized: false)
        #expect(status == 401)
        #expect(response.value(forHTTPHeaderField: "WWW-Authenticate") == "Bearer")
        let (wrong, _, _) = try await server.request(
            "GET", "/v1/status", headers: ["Authorization": "Bearer mdl_wrong"], authorized: false)
        #expect(wrong == 401)
    }

    @Test func rejectsBrowserOriginsAndForeignHosts() async throws {
        let server = try await TestServer()
        defer { server.server.stop() }
        let (origin, _, _) = try await server.request("GET", "/v1/status", headers: ["Origin": "https://evil.example"])
        #expect(origin == 403)
        let router = server.router
        let rebinding = HTTPRequest(
            method: "GET", path: "/v1/status",
            headers: ["Host": "evil.example:\(server.server.port)", "Authorization": "Bearer \(server.token)"])
        #expect(await router.handle(rebinding, from: .local).status == 403)
        // The relay path is authenticated by the relay and skips the loopback checks.
        #expect(await router.handle(HTTPRequest(method: "GET", path: "/v1/status"), from: .relay).status == 200)
    }

    @Test func restStatusScreenshotAndTools() async throws {
        let server = try await TestServer()
        defer { server.server.stop() }
        let (status, statusBody, _) = try await server.request("GET", "/v1/status")
        #expect(status == 200)
        #expect(try JSONValue.parse(statusBody)["data"]?["ready"] == true)

        let (shot, image, response) = try await server.request("GET", "/v1/screenshot")
        #expect(shot == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(response.value(forHTTPHeaderField: "X-Image-Height") == "1280")
        #expect(image.starts(with: [0xFF, 0xD8]))

        let (tap, tapBody, _) = try await server.request("POST", "/v1/tools/tap", body: ["x": 59, "y": 128])
        #expect(tap == 200, "\(String(decoding: tapBody, as: UTF8.self))")
        #expect(server.phone.events.get() == [.tap(NormalizedPoint(x: 0.1, y: 0.1), 0.08)])

        let (bad, badBody, _) = try await server.request("POST", "/v1/tools/tap", body: ["x": "left"])
        #expect(bad == 422)
        #expect(try JSONValue.parse(badBody)["ok"] == false)

        let (missing, _, _) = try await server.request("POST", "/v1/tools/nope", body: [:])
        #expect(missing == 404)
    }
}

@Suite struct MCPTests {
    func call(_ server: TestServer, _ message: JSONValue, headers: [String: String] = [:]) async throws -> (Int, JSONValue?) {
        var headers = headers
        headers["Accept"] = "application/json, text/event-stream"
        let (status, data, _) = try await server.request("POST", "/mcp", body: message, headers: headers)
        return (status, data.isEmpty ? nil : try JSONValue.parse(data))
    }

    static let modernMeta: JSONValue = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": ["name": "test", "version": "1"],
        "io.modelcontextprotocol/clientCapabilities": [:],
    ]

    @Test func legacyHandshakeListAndCall() async throws {
        let server = try await TestServer()
        defer { server.server.stop() }
        let (status, initialize) = try await call(
            server,
            [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]],
            ])
        #expect(status == 200)
        #expect(initialize?["result"]?["protocolVersion"] == "2025-06-18")
        #expect(initialize?["result"]?["capabilities"]?["tools"] != nil)

        let (notified, body) = try await call(server, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(notified == 202)
        #expect(body == nil)

        let (_, list) = try await call(
            server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], headers: ["MCP-Protocol-Version": "2025-06-18"])
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("tap_text"))
        #expect(names.count == PhoneTools.definitions.count)

        let (_, result) = try await call(
            server,
            ["jsonrpc": "2.0", "id": "a", "method": "tools/call", "params": ["name": "screenshot", "arguments": [:]]])
        #expect(result?["id"] == "a")
        let content = result?["result"]?["content"]?.arrayValue ?? []
        #expect(content.map { $0["type"] } == ["text", "image"])
        #expect(content.last?["mimeType"] == "image/jpeg")
    }

    @Test func unknownLegacyVersionFallsBackToLatestLegacy() async throws {
        let server = try await TestServer()
        defer { server.server.stop() }
        let (_, initialize) = try await call(
            server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2099-01-01"]])
        #expect(initialize?["result"]?["protocolVersion"] == "2025-11-25")
    }

    @Test func modernStatelessCall() async throws {
        let server = try await TestServer()
        defer { server.server.stop() }
        let headers = ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "tap"]
        let (status, result) = try await call(
            server,
            [
                "jsonrpc": "2.0", "id": 7, "method": "tools/call",
                "params": ["name": "tap", "arguments": ["x": 10, "y": 10, "screenshot": false], "_meta": Self.modernMeta],
            ], headers: headers)
        #expect(status == 200)
        #expect(result?["result"]?["resultType"] == "complete")
        #expect(result?["result"]?["isError"] == false)
        #expect(result?["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "mobdev")
        #expect(server.phone.events.get().count == 1)
    }

    @Test func modernDiscover() async throws {
        let server = try await TestServer()
        defer { server.server.stop() }
        let (status, result) = try await call(
            server, ["jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": ["_meta": Self.modernMeta]],
            headers: ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "server/discover"])
        #expect(status == 200)
        #expect(result?["result"]?["supportedVersions"]?.arrayValue?.first == "2026-07-28")
    }

    @Test func modernHeaderMismatchIsRejected() async throws {
        let server = try await TestServer()
        defer { server.server.stop() }
        let (status, result) = try await call(
            server,
            [
                "jsonrpc": "2.0", "id": 7, "method": "tools/call",
                "params": ["name": "tap", "arguments": ["x": 10, "y": 10], "_meta": Self.modernMeta],
            ], headers: ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "home"])
        #expect(status == 400)
        #expect(result?["error"]?["code"] == -32020)
        #expect(server.phone.events.get().isEmpty)
    }

    @Test func unsupportedVersionListsSupportedOnes() async throws {
        let server = try await TestServer()
        defer { server.server.stop() }
        var meta = Self.modernMeta.objectValue!
        meta["io.modelcontextprotocol/protocolVersion"] = "2031-01-01"
        let (status, result) = try await call(
            server, ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": ["_meta": .object(meta)]],
            headers: ["MCP-Protocol-Version": "2031-01-01", "Mcp-Method": "tools/list"])
        #expect(status == 400)
        #expect(result?["error"]?["code"] == -32022)
        #expect(result?["error"]?["data"]?["supported"]?.arrayValue?.contains("2026-07-28") == true)
    }

    @Test func getIsNotAllowedAndUnknownMethodsFail() async throws {
        let server = try await TestServer()
        defer { server.server.stop() }
        let (get, _, response) = try await server.request("GET", "/mcp")
        #expect(get == 405)
        #expect(response.value(forHTTPHeaderField: "Allow") == "POST")
        let (_, result) = try await call(server, ["jsonrpc": "2.0", "id": 1, "method": "resources/list"])
        #expect(result?["error"]?["code"] == -32601)
    }

    @Test func toolErrorsAreResultsNotProtocolErrors() async throws {
        let server = try await TestServer()
        defer { server.server.stop() }
        let (_, result) = try await call(
            server,
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "tap", "arguments": ["x": -5, "y": 1]]])
        #expect(result?["result"]?["isError"] == true)
        let (_, unknown) = try await call(
            server, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "rm_rf"]])
        #expect(unknown?["error"]?["code"] == -32602)
    }

    @Test func headerValueEncoding() {
        #expect(MCPHandler.decodeHeaderValue("tap") == "tap")
        #expect(MCPHandler.decodeHeaderValue("=?base64?SGVsbG8sIOS4lueVjA==?=") == "Hello, 世界")
        #expect(MCPStdioBridge.Bridge.headerValue("Hello, 世界") == "=?base64?SGVsbG8sIOS4lueVjA==?=")
        #expect(MCPStdioBridge.Bridge.headerValue("tap_text") == "tap_text")
    }
}

/// An API server on a Unix socket in a fresh private directory, as the app runs one for `Mobdev mcp`.
final class SocketServer: Sendable {
    let phone: FakePhone
    let directory: URL
    let socket: URL
    let tokenFile: URL
    let server: HTTPServer
    let requests = Locked(0)
    /// Whether a delayed request saw its task cancelled, because the client hung up.
    let cancelled = Locked(false)
    let token = "mdl_socket-token"

    /// A short path: a socket path must fit in 104 bytes, which the default temporary folder can exceed.
    init(phone: FakePhone = FakePhone(lines: [("Settings", 420, 300)]), start: Bool = true, delay: TimeInterval = 0)
        async throws
    {
        self.phone = phone
        directory = URL(fileURLWithPath: "/tmp/mobdev-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        socket = directory.appendingPathComponent("mobdev.sock")
        tokenFile = directory.appendingPathComponent("token")
        try Data((token + "\n").utf8).write(to: tokenFile)
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let token = self.token
        let router = APIRouter(tools: tools, token: { token }, port: { 4686 })
        let requests = self.requests
        let cancelled = self.cancelled
        server = HTTPServer(socket: socket) { request in
            if request.path == "/mcp" { requests.withLock { $0 += 1 } }
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { cancelled.set(true) }
            }
            return await router.handle(request, from: .socket)
        }
        if start { try await server.start() }
    }

    func bridge(launchWait: TimeInterval = 5, timeout: TimeInterval = 30, launchApp: @escaping @Sendable () -> Void = {})
        -> MCPStdioBridge.Bridge
    {
        MCPStdioBridge.Bridge(
            socket: socket, tokenFile: tokenFile, launchWait: launchWait, timeout: timeout, launchApp: launchApp)
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite struct StdioBridgeTests {
    @Test func forwardsRequestsAndSwallowsNotifications() async throws {
        let server = try await SocketServer()
        defer { server.stop() }
        let bridge = server.bridge()
        let reply = await bridge.forward(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(reply?.contains("tap_text") == true)
        #expect(await bridge.forward(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let modern = JSONValue([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "home", "arguments": ["screenshot": false], "_meta": MCPTests.modernMeta],
        ]).compactString
        let modernReply = await bridge.forward(modern)
        #expect(modernReply?.contains(#""resultType":"complete""#) == true, "\(modernReply ?? "nil")")
        #expect(server.phone.events.get() == [.button(.home)])
    }

    @Test func socketIsOnlyForThisUser() async throws {
        let server = try await SocketServer()
        defer { server.stop() }
        var info = stat()
        #expect(lstat(server.socket.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_uid == getuid())
    }

    @Test func socketNeedsTheToken() async throws {
        let server = try await SocketServer()
        defer { server.stop() }
        try Data("mdl_wrong\n".utf8).write(to: server.tokenFile)
        let reply = await server.bridge().forward(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(reply?.contains("bearer token") == true, "\(reply ?? "nil")")
    }

    /// A directory others can write to could hold someone else's socket: nothing is sent there.
    @Test func refusesASocketInADirectoryOthersCanWrite() async throws {
        let server = try await SocketServer()
        defer { server.stop() }
        chmod(server.directory.path, 0o777)
        let reply = await server.bridge().forward(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(reply?.contains("writable only by you") == true, "\(reply ?? "nil")")
        #expect(server.requests.get() == 0)
    }

    @Test func explainsWhenTheAppIsNotRunning() async throws {
        let server = try await SocketServer(start: false)
        defer { server.stop() }
        let launched = Locked(false)
        let bridge = server.bridge(launchWait: 0.5) { launched.set(true) }
        let reply = await bridge.forward(#"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#)
        #expect(reply?.contains("Mobdev is not running") == true)
        #expect(reply?.contains(#""id":9"#) == true)
        #expect(launched.get())
    }

    /// The app started by the bridge gets the request exactly once, after it answers a health check.
    @Test func startsTheAppAndSendsOnce() async throws {
        let server = try await SocketServer(start: false)
        defer { server.stop() }
        let bridge = server.bridge(launchWait: 5) {
            Task { try? await server.server.start() }
        }
        let call = JSONValue([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "home", "arguments": ["screenshot": false], "_meta": MCPTests.modernMeta],
        ]).compactString
        let reply = await bridge.forward(call)
        #expect(reply?.contains(#""resultType":"complete""#) == true, "\(reply ?? "nil")")
        #expect(server.requests.get() == 1)
        #expect(server.phone.events.get() == [.button(.home)])
    }

    /// A request whose answer never came may have run: it is reported, not sent again, and the app
    /// stops working on it once the bridge hangs up.
    @Test func neverResendsARequestThatMayHaveRun() async throws {
        let server = try await SocketServer(delay: 3)
        defer { server.stop() }
        let bridge = server.bridge(timeout: 1)
        let reply = await bridge.forward(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        #expect(reply?.contains("may or may not have been carried out") == true, "\(reply ?? "nil")")
        #expect(server.requests.get() == 1)
        for _ in 0..<40 where !server.cancelled.get() { try await Task.sleep(for: .milliseconds(100)) }
        #expect(server.cancelled.get())

        let parsed = try MCPStdioBridge.Bridge.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8))
        #expect(parsed.1 == 200 && parsed.0 == Data("{}".utf8))
        #expect(throws: LocalSocket.Failure.self) {
            try MCPStdioBridge.Bridge.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{}".utf8))
        }
    }
}
