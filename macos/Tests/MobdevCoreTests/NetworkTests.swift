import Foundation
import Network
import Testing
@testable import MobdevCore

// MARK: - Local servers and clients

/// A TCP server on 127.0.0.1 that sends back whatever it receives.
final class EchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "echo")
    let port: UInt16

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let queue = queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            @Sendable func echo() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        connection.send(content: data, completion: .contentProcessed { _ in
                            if isComplete { connection.cancel() } else { echo() }
                        })
                    } else if isComplete || error != nil {
                        connection.cancel()
                    } else {
                        echo()
                    }
                }
            }
            echo()
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = Locked(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed.withLock({ let was = $0; $0 = true; return was }) {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    if !resumed.withLock({ let was = $0; $0 = true; return was }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}

/// A client connection that collects what the server sends.
final class TestClient: @unchecked Sendable {
    let connection: NWConnection
    private let received = Locked(Data())
    private let ended = Locked(false)

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "client"))
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.received.withLock { $0.append(data) } }
            if isComplete || error != nil { self.ended.set(true) } else { self.read() }
        }
    }

    func send(_ text: String) { connection.send(content: Data(text.utf8), completion: .idempotent) }
    func send(_ data: Data) { connection.send(content: data, completion: .idempotent) }

    /// Everything received once `done` holds, or after 10 seconds.
    func wait(until done: @escaping (Data, Bool) -> Bool) async -> String {
        let deadline = Date().addingTimeInterval(10)
        while !done(received.get(), ended.get()), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return String(decoding: received.get(), as: UTF8.self)
    }

    func waitForEnd() async -> String { await wait { _, ended in ended } }
    func close() { connection.cancel() }
}

/// Waits for the log to list `count` entries.
func entries(in log: NetworkLog, count: Int) async -> [NetworkEntry] {
    let deadline = Date().addingTimeInterval(10)
    while log.read(app: nil, after: nil, limit: 100, contains: nil).entries.count < count, Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return log.read(app: nil, after: nil, limit: 100, contains: nil).entries
}

// MARK: - Proxy

@Suite struct HTTPProxyTests {
    @Test func forwardsPlainHTTPAndLogsItWithCredentialsReplaced() async throws {
        let origin = HTTPServer(port: 0) { request in
            HTTPResponse(
                status: 201, headers: ["Set-Cookie": "session=abc", "X-Seen": request.header("authorization") ?? "none"],
                body: Data("hello \(request.path) \(request.query["x"] ?? "")".utf8))
        }
        try await origin.start()
        defer { origin.stop() }
        let proxy = HTTPProxy()
        try await proxy.start()
        defer { proxy.stop() }

        let client = TestClient(port: proxy.port)
        client.send(
            "GET http://127.0.0.1:\(origin.port)/hello?x=1 HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\nAuthorization: Bearer secret\r\nProxy-Connection: keep-alive\r\n\r\n")
        let response = await client.waitForEnd()
        #expect(response.hasPrefix("HTTP/1.1 201"))
        #expect(response.contains("Connection: close"))
        #expect(response.contains("X-Seen: Bearer secret"))  // The server got the header itself.
        #expect(response.hasSuffix("hello /hello 1"))

        let entry = try #require(await entries(in: proxy.log, count: 1).first)
        #expect(entry.method == "GET")
        #expect(entry.host == "127.0.0.1")
        #expect(entry.port == Int(origin.port))
        #expect(entry.path == "/hello")
        #expect(entry.query == "x=1")
        #expect(entry.status == 201)
        #expect(entry.source == .proxy)
        // What went to the server: the head as forwarded, with the path and without the proxy's headers.
        let forwarded = "GET /hello?x=1 HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n"
        #expect(entry.bytesSent == forwarded.utf8.count)
        #expect((entry.bytesReceived ?? 0) > "hello /hello 1".utf8.count)
        #expect(entry.duration != nil)
        #expect(entry.requestHeaders.contains(.init(name: "Authorization", value: "<redacted>")))
        #expect(entry.responseHeaders.contains(.init(name: "Set-Cookie", value: "<redacted>")))
        #expect(entry.target(query: false) == "http://127.0.0.1:\(origin.port)/hello?…")
        #expect(entry.target(query: true) == "http://127.0.0.1:\(origin.port)/hello?x=1")
    }

    @Test func tunnelsConnectWithoutReadingIt() async throws {
        let echo = try await EchoServer()
        defer { echo.stop() }
        let proxy = HTTPProxy()
        try await proxy.start()
        defer { proxy.stop() }

        let client = TestClient(port: proxy.port)
        client.send("CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\n\r\n")
        let established = await client.wait { data, _ in data.count >= 39 }
        #expect(established == "HTTP/1.1 200 Connection Established\r\n\r\n")
        // Open tunnels are listed apart until they close.
        #expect(proxy.log.openEntries.first?.method == "CONNECT")

        client.send(Data([0x16, 0x03, 0x01, 0x00, 0x05]) + Data("hello".utf8))
        let echoed = await client.wait { data, _ in data.count >= 39 + 10 }
        #expect(echoed.hasSuffix("hello"))
        client.close()

        let entry = try #require(await entries(in: proxy.log, count: 1).first)
        #expect(entry.method == "CONNECT")
        #expect(entry.scheme == nil)
        #expect(entry.host == "127.0.0.1")
        #expect(entry.port == Int(echo.port))
        #expect(entry.path == nil)
        #expect(entry.status == 200)
        #expect(entry.bytesSent == 10)
        #expect(entry.bytesReceived == 10)
        #expect(entry.target(query: false) == "127.0.0.1:\(echo.port)")
        #expect(proxy.log.openEntries.isEmpty)
    }

    @Test func answers502WhenTheServerIsNotThere() async throws {
        // A port that was free a moment ago.
        let closed = try await EchoServer()
        let port = closed.port
        closed.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let proxy = HTTPProxy()
        try await proxy.start()
        defer { proxy.stop() }

        let client = TestClient(port: proxy.port)
        client.send("GET http://127.0.0.1:\(port)/ HTTP/1.1\r\nHost: x\r\n\r\n")
        let response = await client.waitForEnd()
        #expect(response.hasPrefix("HTTP/1.1 502"))
        let entry = try #require(await entries(in: proxy.log, count: 1).first)
        #expect(entry.status == 502)
        #expect(entry.error == "connection refused")
    }

    @Test func mocksAnswerWithoutTheServer() async throws {
        let mocks = Locked([
            ResponseMock(url: "/api/feed", status: 503, contentType: "application/json", body: Data("{\"error\":1}".utf8))
        ])
        let proxy = HTTPProxy(mocks: mocks)
        try await proxy.start()
        defer { proxy.stop() }

        let client = TestClient(port: proxy.port)
        client.send("GET http://10.0.2.2:3000/api/feed?page=2 HTTP/1.1\r\nHost: 10.0.2.2:3000\r\n\r\n")
        let response = await client.waitForEnd()
        #expect(response.hasPrefix("HTTP/1.1 503"))
        #expect(response.hasSuffix("{\"error\":1}"))
        let entry = try #require(await entries(in: proxy.log, count: 1).first)
        #expect(entry.mocked)
        #expect(entry.status == 503)
        #expect(entry.summary(query: false).contains("GET http://10.0.2.2:3000/api/feed?… 503, mocked"))
    }

    @Test func refusesRequestsThatAreNotForAProxy() async throws {
        let proxy = HTTPProxy()
        try await proxy.start()
        defer { proxy.stop() }
        let client = TestClient(port: proxy.port)
        client.send("GET /index.html HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let response = await client.waitForEnd()
        #expect(response.hasPrefix("HTTP/1.1 400"))
        #expect(proxy.log.read(app: nil, after: nil, limit: 10, contains: nil).entries.isEmpty)
    }

    /// curl through the proxy to real servers, as Android's HTTP stack sends its requests: an
    /// absolute URL for HTTP, CONNECT for HTTPS. Opt-in, since it needs the internet:
    ///
    ///     MOBDEV_TEST_INTERNET=1 swift test --filter HTTPProxyTests
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOBDEV_TEST_INTERNET"] != nil, "Set MOBDEV_TEST_INTERNET"))
    func curlThroughTheProxy() async throws {
        let proxy = HTTPProxy()
        try await proxy.start()
        defer { proxy.stop() }
        let runner = ProcessRunner()
        let curl = URL(fileURLWithPath: "/usr/bin/curl")
        let options = ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-x", "http://127.0.0.1:\(proxy.port)"]
        let plain = try await runner.run(curl, options + ["http://example.com/plain?secret=1"], timeout: 30)
        let tls = try await runner.run(curl, options + ["https://example.com/tls?token=abc"], timeout: 30)
        let missing = try await runner.run(curl, options + ["http://nonexistent.invalid/"], timeout: 30)
        print("curl: \(plain.output) \(tls.output) \(missing.output)")
        #expect(plain.output == "404")
        #expect(tls.output == "404")
        #expect(missing.output == "502")
        let entries = await entries(in: proxy.log, count: 3)
        for entry in entries { print(entry.summary(query: false)) }
        #expect(entries.first { $0.method == "GET" && $0.host == "example.com" }?.status == 404)
        #expect(entries.first { $0.method == "CONNECT" }?.port == 443)
        #expect(entries.first { $0.host == "nonexistent.invalid" }?.error == "host not found")
    }

    @Test func readsRequestAndResponseHeads() throws {
        let data = Data(
            "POST http://example.com/a?b=1 HTTP/1.1\r\nHost: example.com\r\nProxy-Connection: keep-alive\r\nConnection: keep-alive\r\nContent-Length: 2\r\n\r\nhi"
                .utf8)
        guard case .head(let head) = ProxyRequestHead.parse(data) else {
            Issue.record("not parsed")
            return
        }
        #expect(head.method == "POST")
        #expect(head.target == "http://example.com/a?b=1")
        #expect(head.length == data.count - 2)
        #expect(
            String(decoding: head.forwarded(path: "/a?b=1"), as: UTF8.self)
                == "POST /a?b=1 HTTP/1.1\r\nHost: example.com\r\nContent-Length: 2\r\nConnection: close\r\n\r\n")
        #expect(ProxyRequestHead.parse(Data("GET http://x/ HTTP/1.1\r\nHost".utf8)) == .incomplete)
        #expect(ProxyRequestHead.parse(Data("hello\r\n\r\n".utf8)) == .invalid("Not an HTTP/1 request."))

        #expect(ProxyRequestHead.hostAndPort("example.com:8443", defaultPort: 443)! == ("example.com", 8443))
        #expect(ProxyRequestHead.hostAndPort("[2001:db8::1]:443", defaultPort: 80)! == ("2001:db8::1", 443))
        #expect(ProxyRequestHead.hostAndPort("example.com", defaultPort: 80)! == ("example.com", 80))
        #expect(ProxyRequestHead.hostAndPort("example.com:http", defaultPort: 80) == nil)

        let response = try #require(
            ProxyResponseHead.parse(Data("HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 3\r\n\r\nabc".utf8)))
        #expect(response.status == 200)
        #expect(
            String(decoding: response.forwarded, as: UTF8.self) == "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\n")
    }
}
