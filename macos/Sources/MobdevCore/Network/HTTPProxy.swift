import Foundation
import Network

/// A canned answer `mock_response` gives instead of the server, for plain HTTP through the proxy.
public struct ResponseMock: Sendable, Equatable {
    /// Matches every URL that contains it, e.g. "/api/feed" or "http://10.0.2.2:3000/login".
    public var url: String
    public var status: Int
    public var contentType: String
    public var body: Data

    public init(url: String, status: Int, contentType: String, body: Data) {
        self.url = url
        self.status = status
        self.contentType = contentType
        self.body = body
    }
}

/// Mobdev's HTTP proxy for Android, on 127.0.0.1 only. Plain HTTP requests (absolute URLs, as
/// clients send them to a proxy) are forwarded one per connection and logged in full: method, URL,
/// status, sizes, time and headers with credentials replaced. HTTPS arrives as CONNECT and is
/// tunneled without being decrypted, so only the host, port, bytes each way and time are known.
///
/// Every callback runs on one serial queue, so a session's state needs no lock.
public final class HTTPProxy: @unchecked Sendable {
    public let log: NetworkLog
    /// Shared with the capture that owns the proxy, so mocks outlive a restart of it.
    let mocks: Locked<[ResponseMock]>
    private let queue = DispatchQueue(label: "dev.mobdev.proxy")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: ProxySession] = [:]
    private let boundPort = Locked<UInt16>(0)

    /// The longest request head Mobdev reads, and how many clients it serves at once.
    static let maxHeadBytes = 64 * 1024
    static let maxSessions = 256

    init(log: NetworkLog = NetworkLog(), mocks: Locked<[ResponseMock]> = Locked([])) {
        self.log = log
        self.mocks = mocks
    }

    /// The port on 127.0.0.1, once started.
    public var port: UInt16 { boundPort.get() }

    /// Listens on 127.0.0.1 at a free port. The emulator reaches it as 10.0.2.2, a phone through
    /// `adb reverse`; nothing outside this Mac can.
    public func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let started = Locked(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.boundPort.set(listener.port?.rawValue ?? 0)
                    if !started.withLock({ let was = $0; $0 = true; return was }) { continuation.resume() }
                case .failed(let error):
                    if !started.withLock({ let was = $0; $0 = true; return was }) { continuation.resume(throwing: error) }
                    listener.cancel()
                default:
                    break
                }
            }
            queue.sync { self.listener = listener }
            listener.start(queue: queue)
        }
    }

    /// Stops listening and ends every connection; open tunnels are listed as they stand.
    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            let open = Array(sessions.values)
            sessions = [:]
            for session in open { session.close(reason: nil) }
        }
        boundPort.set(0)
    }

    private func accept(_ connection: NWConnection) {
        guard sessions.count < Self.maxSessions else {
            connection.cancel()
            return
        }
        let session = ProxySession(client: connection, proxy: self, queue: queue)
        sessions[ObjectIdentifier(session)] = session
        session.start()
    }

    /// Called on the queue when a session is done.
    fileprivate func ended(_ session: ProxySession) {
        sessions[ObjectIdentifier(session)] = nil
    }

    fileprivate func mock(for url: String) -> ResponseMock? {
        mocks.get().last { url.contains($0.url) }
    }
}

// MARK: - Request heads

/// The first line and headers of a request a client sent to the proxy.
struct ProxyRequestHead: Equatable {
    var method: String
    /// "http://example.com/path?q" for a request, "example.com:443" for CONNECT.
    var target: String
    var version: String
    var headers: [NetworkEntry.Header]
    /// Bytes of the head, the empty line included.
    var length: Int

    enum ParseResult: Equatable {
        case incomplete
        case head(ProxyRequestHead)
        case invalid(String)
    }

    /// Reads a head from the start of `data`.
    static func parse(_ data: Data) -> ParseResult {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > HTTPProxy.maxHeadBytes ? .invalid("The request head is too large.") : .incomplete
        }
        let text = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .invalid("Not an HTTP/1 request.") }
        var headers: [NetworkEntry.Header] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("A header line has no colon.") }
            headers.append(
                NetworkEntry.Header(
                    name: line[..<colon].trimmingCharacters(in: .whitespaces),
                    value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return .head(
            ProxyRequestHead(
                method: first[0].uppercased(), target: first[1], version: first[2], headers: headers,
                length: end.upperBound - data.startIndex))
    }

    /// "example.com:443" as host and port.
    static func hostAndPort(_ authority: String, defaultPort: Int) -> (host: String, port: Int)? {
        var host = authority
        var port = defaultPort
        if authority.hasPrefix("[") {
            // [2001:db8::1]:443
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            if rest.hasPrefix(":") {
                guard let number = Int(rest.dropFirst()) else { return nil }
                port = number
            }
        } else if let colon = authority.lastIndex(of: ":") {
            guard let number = Int(authority[authority.index(after: colon)...]) else { return nil }
            host = String(authority[..<colon])
            port = number
        }
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    /// The head as the origin server gets it: the path instead of the full URL, the proxy's own
    /// headers dropped, and "Connection: close", so each connection carries one request and its
    /// answer ends when the server closes.
    func forwarded(path: String) -> Data {
        var text = "\(method) \(path) \(version)\r\n"
        let dropped: Set<String> = ["proxy-connection", "proxy-authorization", "connection", "keep-alive"]
        for header in headers where !dropped.contains(header.name.lowercased()) {
            text += "\(header.name): \(header.value)\r\n"
        }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }
}

/// The status line and headers of the server's answer, read before they are passed on.
struct ProxyResponseHead: Equatable {
    var statusLine: String
    var status: Int
    var headers: [NetworkEntry.Header]
    var length: Int

    /// Nil until the whole head is there, or when it is not HTTP.
    static func parse(_ data: Data) -> ProxyResponseHead? {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let text = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let first = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard first.count >= 2, first[0].hasPrefix("HTTP/"), let status = Int(first[1]) else { return nil }
        let headers = lines.compactMap { line -> NetworkEntry.Header? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return NetworkEntry.Header(
                name: line[..<colon].trimmingCharacters(in: .whitespaces),
                value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return ProxyResponseHead(
            statusLine: statusLine, status: status, headers: headers, length: end.upperBound - data.startIndex)
    }

    /// The head with "Connection: close", so the client sends no second request on a connection
    /// the proxy ends after this answer.
    var forwarded: Data {
        var text = statusLine + "\r\n"
        let dropped: Set<String> = ["connection", "keep-alive", "proxy-connection"]
        for header in headers where !dropped.contains(header.name.lowercased()) {
            text += "\(header.name): \(header.value)\r\n"
        }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }
}

// MARK: - Sessions

/// One client connection: one plain HTTP request, or one CONNECT tunnel. Lives on the proxy's
/// queue: every method and callback runs there.
private final class ProxySession: @unchecked Sendable {
    let client: NWConnection
    weak var proxy: HTTPProxy?
    let queue: DispatchQueue
    var upstream: NWConnection?
    var upstreamReady = false
    /// What arrived from the client while its head is read.
    var buffer = Data()
    /// The log's id of this session's open entry.
    var entryID: Int?
    var started = Date()
    var sent = 0
    var received = 0
    var tunnel = false
    /// Plain HTTP: the server's answer until its head is complete, which is then passed on with
    /// "Connection: close". Nil once the head went through.
    var pendingResponse: Data? = Data()
    /// Tunnels: directions that reached their end, client to server and server to client.
    var upDone = false
    var downDone = false
    var closed = false

    init(client: NWConnection, proxy: HTTPProxy, queue: DispatchQueue) {
        self.client = client
        self.proxy = proxy
        self.queue = queue
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(reason: nil)
            default: break
            }
        }
        client.start(queue: queue)
        // A client that never finishes its request head is dropped.
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.entryID == nil, !self.closed else { return }
            self.close(reason: nil)
        }
        readHead()
    }

    private func readHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            switch ProxyRequestHead.parse(self.buffer) {
            case .incomplete:
                if isComplete || error != nil { self.close(reason: nil) } else { self.readHead() }
            case .invalid(let message):
                self.answer(400, message)
            case .head(let head):
                self.handle(head)
            }
        }
    }

    private func handle(_ head: ProxyRequestHead) {
        guard let proxy else { return close(reason: nil) }
        let rest = Data(buffer.dropFirst(head.length))
        buffer = Data()
        started = Date()
        if head.method == "CONNECT" {
            guard let (host, port) = ProxyRequestHead.hostAndPort(head.target, defaultPort: 443) else {
                return answer(400, "CONNECT needs host:port.")
            }
            tunnel = true
            var entry = NetworkEntry(time: started, method: "CONNECT", scheme: nil, host: host, port: port, source: .proxy)
            entry.bytesSent = 0
            entry.bytesReceived = 0
            entryID = proxy.log.open(entry)
            connect(host: host, port: port) { [weak self] in
                guard let self else { return }
                let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                self.client.send(content: established, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.closed else { return }
                    if error != nil { return self.close(reason: nil) }
                    self.proxy?.log.update(self.entryID ?? 0) { $0.status = 200 }
                    self.forward(rest)
                    self.pipeDown()
                })
            }
            return
        }
        // A request to the proxy itself rather than through it has no absolute URL.
        guard let url = URLComponents(string: head.target), url.scheme?.lowercased() == "http", let host = url.host,
            !host.isEmpty
        else {
            return answer(400, "Mobdev's proxy takes requests for absolute http:// URLs, and CONNECT for HTTPS.")
        }
        let port = url.port ?? 80
        let path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        var entry = NetworkEntry(
            time: started, method: head.method, scheme: "http", host: host, port: port == 80 ? nil : port, path: path,
            query: url.percentEncodedQuery, source: .proxy)
        entry.requestHeaders = NetworkEntry.redacted(head.headers)
        if let mock = proxy.mock(for: head.target) {
            entry.mocked = true
            entry.status = mock.status
            entryID = proxy.log.open(entry)
            sent = head.length + rest.count
            return answerMock(mock)
        }
        entryID = proxy.log.open(entry)
        let target = path + (url.percentEncodedQuery.map { "?\($0)" } ?? "")
        connect(host: host, port: port) { [weak self] in
            guard let self else { return }
            self.forward(head.forwarded(path: target) + rest)
            self.pipeDown()
        }
    }

    /// Opens the connection to the server and calls `ready` once it stands; answers 502 when the
    /// server cannot be reached.
    private func connect(host: String, port: Int, ready: @escaping @Sendable () -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return answer(400, "Bad port \(port).") }
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.upstream = upstream
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                guard !self.upstreamReady else { return }
                self.upstreamReady = true
                ready()
            case .waiting(let error), .failed(let error):
                // Waiting means the server cannot be reached now, e.g. its name does not resolve.
                if self.upstreamReady { return self.close(reason: Self.describe(error)) }
                self.fail(Self.describe(error))
            default:
                break
            }
        }
        upstream.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.upstreamReady, !self.closed else { return }
            self.fail("timed out connecting")
        }
    }

    /// Sends what the client already sent after its head, then passes on the rest.
    private func forward(_ data: Data) {
        guard let upstream else { return }
        guard !data.isEmpty else { return pipeUp() }
        count(sent: data.count)
        upstream.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil { return self.close(reason: nil) }
            self.pipeUp()
        })
    }

    /// Client to server, one chunk at a time, each sent before the next is read.
    private func pipeUp() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed, let upstream = self.upstream else { return }
            if let data, !data.isEmpty {
                self.count(sent: data.count)
                upstream.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.closed else { return }
                    if error != nil { return self.close(reason: nil) }
                    if isComplete { self.endUp() } else { self.pipeUp() }
                })
            } else if isComplete || error != nil {
                self.endUp()
            } else {
                self.pipeUp()
            }
        }
    }

    /// The client is done sending: the server gets a half-close so it sees the end too.
    private func endUp() {
        upstream?.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        upDone = true
        if tunnel, downDone { close(reason: nil) }
    }

    /// Server to client, one chunk at a time.
    private func pipeDown() {
        upstream?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            let ended = isComplete || error != nil
            if let data, !data.isEmpty { self.count(received: data.count) }
            let passed = self.responseData(data ?? Data(), ended: ended)
            guard !passed.isEmpty else { return ended ? self.endDown() : self.pipeDown() }
            self.client.send(content: passed, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil { return self.close(reason: nil) }
                if ended { self.endDown() } else { self.pipeDown() }
            })
        }
    }

    /// What of the server's bytes goes to the client now. A tunnel passes everything; plain HTTP
    /// holds the answer back until its head is complete, notes the status and headers, and passes
    /// the head with "Connection: close". Interim 1xx heads go through as they are.
    private func responseData(_ data: Data, ended: Bool) -> Data {
        guard !tunnel, var pending = pendingResponse else { return data }
        pending.append(data)
        var out = Data()
        while let head = ProxyResponseHead.parse(pending) {
            let body = Data(pending.dropFirst(head.length))
            if (100..<200).contains(head.status) {
                out.append(pending.prefix(head.length))
                pending = body
                continue
            }
            proxy?.log.update(entryID ?? 0) { entry in
                entry.status = head.status
                entry.responseHeaders = NetworkEntry.redacted(head.headers)
            }
            pendingResponse = nil
            return out + head.forwarded + body
        }
        // A head that never ends is not HTTP: it is passed on as it is.
        if ended || pending.count > HTTPProxy.maxHeadBytes {
            pendingResponse = nil
            return out + pending
        }
        pendingResponse = pending
        return out
    }

    /// The server is done. For plain HTTP that is the end of the answer, so the client is closed
    /// once it has everything; a tunnel's client gets a half-close.
    private func endDown() {
        guard tunnel else {
            client.send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { [weak self] _ in self?.close(reason: nil) })
            return
        }
        client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        downDone = true
        if upDone { close(reason: nil) }
    }

    private func count(sent: Int = 0, received: Int = 0) {
        self.sent += sent
        self.received += received
        let total = (sent: self.sent, received: self.received)
        proxy?.log.update(entryID ?? 0) { entry in
            entry.bytesSent = total.sent
            entry.bytesReceived = total.received
        }
    }

    /// The server could not be reached: the client gets a 502 and the entry says why.
    private func fail(_ reason: String) {
        proxy?.log.update(entryID ?? 0) { $0.status = 502 }
        answer(502, "Mobdev's proxy could not reach the server: \(reason).", reason: reason)
    }

    private func answer(_ status: Int, _ message: String, reason: String? = nil) {
        let body = Data((message + "\n").utf8)
        let head =
            "HTTP/1.1 \(status) \(HTTPServer.reason(status))\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        client.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.close(reason: reason)
        })
    }

    private func answerMock(_ mock: ResponseMock) {
        let head =
            "HTTP/1.1 \(mock.status) \(HTTPServer.reason(mock.status))\r\nContent-Type: \(mock.contentType)\r\nContent-Length: \(mock.body.count)\r\nConnection: close\r\n\r\n"
        let payload = Data(head.utf8) + mock.body
        received = payload.count
        client.send(content: payload, completion: .contentProcessed { [weak self] _ in self?.close(reason: nil) })
    }

    /// Ends both connections and lists the entry. Safe to call more than once.
    func close(reason: String?) {
        guard !closed else { return }
        closed = true
        let sent = self.sent, received = self.received, started = self.started
        if let entryID {
            proxy?.log.finish(entryID) { entry in
                entry.bytesSent = sent
                entry.bytesReceived = received
                entry.duration = Date().timeIntervalSince(started)
                if let reason { entry.error = reason }
            }
        }
        upstream?.cancel()
        client.cancel()
        proxy?.ended(self)
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .dns: "host not found"
        case .posix(let code) where code == .ECONNREFUSED: "connection refused"
        case .posix(let code) where code == .ETIMEDOUT: "timed out"
        default: error.localizedDescription
        }
    }
}

