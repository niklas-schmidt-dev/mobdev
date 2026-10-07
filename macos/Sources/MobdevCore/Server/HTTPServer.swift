import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: value.encoded())
    }

    public static func error(_ message: String, status: Int) -> HTTPResponse {
        json(["ok": false, "error": .string(message)], status: status)
    }
}

enum HTTPParseResult {
    case incomplete
    case complete(HTTPRequest)
    case invalid(Int, String)
}

enum HTTPParser {
    /// Parses one complete request at once. The server reads with `HTTPRequestReader` as bytes arrive.
    static func parse(_ buffer: Data) -> HTTPParseResult {
        var reader = HTTPRequestReader()
        return reader.append(buffer)
    }
}

/// Reads one request as its bytes arrive. Every byte is examined once, the header, body and chunk
/// framing each have a limit, and consumed bytes leave the buffer, so a slow or malformed request
/// can neither grow memory nor make each new segment rescan what came before.
struct HTTPRequestReader {
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 16 * 1024 * 1024
    /// A chunk-size line with its extensions, or a trailer line.
    static let maxLineBytes = 4 * 1024
    /// Everything a request may send: headers, body and chunk framing.
    static let maxRequestBytes = maxHeaderBytes + maxBodyBytes + 4 * 1024 * 1024

    private enum Framing {
        case length(Int)
        case chunkSize
        case chunkData(Int)
        case trailer
    }

    private struct Head {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var framing: Framing
    }

    private var buffer = Data()
    /// Bytes at the start of `buffer` that are already consumed.
    private var position = 0
    private var received = 0
    private var head: Head?
    private var body = Data()

    mutating func append(_ data: Data) -> HTTPParseResult {
        received += data.count
        guard received <= Self.maxRequestBytes else { return .invalid(413, "request too large") }
        let searchFrom = max(position, buffer.count - 3)
        buffer.append(data)
        if head == nil, let result = readHead(searchFrom: searchFrom) { return result }
        let result = readBody()
        if case .incomplete = result, position > 0 {
            buffer = Data(buffer.dropFirst(position))
            position = 0
        }
        return result
    }

    /// Nil once the head is read; otherwise what to answer.
    private mutating func readHead(searchFrom: Int) -> HTTPParseResult? {
        let bytes = buffer
        guard let headerEnd = bytes[(bytes.startIndex + searchFrom)...].firstRange(of: Data("\r\n\r\n".utf8)) else {
            return bytes.count > Self.maxHeaderBytes ? .invalid(431, "headers too large") : .incomplete
        }
        guard headerEnd.lowerBound - bytes.startIndex <= Self.maxHeaderBytes else {
            return .invalid(431, "headers too large")
        }
        guard let text = String(data: bytes[bytes.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(400, "headers are not UTF-8")
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid(400, "bad request line")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400, "bad header") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        guard let components = URLComponents(string: "http://localhost" + requestLine[1]) else {
            return .invalid(400, "bad request target")
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }

        let framing: Framing
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            framing = .chunkSize
        } else if let lengthHeader = headers["content-length"] {
            guard let length = Int(lengthHeader), length >= 0 else { return .invalid(400, "bad content-length") }
            guard length <= Self.maxBodyBytes else { return .invalid(413, "body too large") }
            framing = .length(length)
        } else {
            framing = .length(0)
        }
        head = Head(
            method: String(requestLine[0]).uppercased(), path: components.path, query: query, headers: headers,
            framing: framing)
        position = headerEnd.upperBound - bytes.startIndex
        return nil
    }

    private mutating func readBody() -> HTTPParseResult {
        guard var head else { return .incomplete }
        defer { self.head = head }
        while true {
            let available = buffer.count - position
            switch head.framing {
            case .length(let length):
                guard available >= length else { return .incomplete }
                return finish(head, body: bytes(position, length))
            case .chunkSize:
                guard let line = takeLine() else { return lineIncomplete() }
                // The size in hex, optionally followed by ";extensions". Signs, inner spaces and
                // sizes beyond the body limit are malformed, checked before any arithmetic.
                let digits = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard (1...8).contains(digits.count), digits.allSatisfy(\.isHexDigit), let size = Int(digits, radix: 16)
                else { return .invalid(400, "bad chunked body") }
                guard size <= Self.maxBodyBytes - body.count else { return .invalid(413, "body too large") }
                head.framing = size == 0 ? .trailer : .chunkData(size)
            case .chunkData(let size):
                guard available >= size + 2 else { return .incomplete }
                guard bytes(position + size, 2) == Data("\r\n".utf8) else { return .invalid(400, "bad chunked body") }
                body.append(bytes(position, size))
                position += size + 2
                head.framing = .chunkSize
            case .trailer:
                // Trailer fields are allowed and ignored; an empty line ends the body.
                guard let line = takeLine() else { return lineIncomplete() }
                if line.isEmpty { return finish(head, body: body) }
            }
        }
    }

    private func bytes(_ offset: Int, _ count: Int) -> Data {
        let start = buffer.startIndex + offset
        return buffer[start..<(start + count)]
    }

    /// The next CRLF-terminated line, consumed.
    private mutating func takeLine() -> String? {
        let window = bytes(position, min(buffer.count - position, Self.maxLineBytes + 2))
        guard let end = window.firstRange(of: Data("\r\n".utf8)) else { return nil }
        position += end.upperBound - window.startIndex
        return String(decoding: window[window.startIndex..<end.lowerBound], as: UTF8.self)
    }

    private func lineIncomplete() -> HTTPParseResult {
        buffer.count - position > Self.maxLineBytes + 1 ? .invalid(400, "bad chunked body") : .incomplete
    }

    private func finish(_ head: Head, body: Data) -> HTTPParseResult {
        .complete(
            HTTPRequest(method: head.method, path: head.path, query: head.query, headers: head.headers, body: Data(body)))
    }
}

/// A small HTTP/1.1 server on Network.framework. One request per connection.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// Connections served at once; more are closed right away.
    static let maxConnections = 64

    private enum Endpoint {
        case loopback(UInt16)
        case socket(URL)
    }

    private let queue = DispatchQueue(label: "dev.mobdev.http")
    private let endpoint: Endpoint
    private let handler: Handler
    private var listener: NWListener?
    private let boundPort = Locked<UInt16>(0)
    private let connections = Locked(0)

    /// Serves on 127.0.0.1. Port 0 picks a free one.
    public init(port: UInt16, handler: @escaping Handler) {
        self.endpoint = .loopback(port)
        self.handler = handler
    }

    /// Serves on a Unix-domain socket that only this user can connect to: the file is 0600 in a
    /// directory only this user may write to. Unlike a loopback port, no other user can take it over.
    public init(socket: URL, handler: @escaping Handler) {
        self.endpoint = .socket(socket)
        self.handler = handler
    }

    public var port: UInt16 { boundPort.get() }

    public func start() async throws {
        let parameters = NWParameters.tcp
        switch endpoint {
        case .loopback(let port):
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        case .socket(let url):
            try LocalSocket.prepareToListen(at: url)
            parameters.requiredLocalEndpoint = .unix(path: url.path)
        }
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let started = Locked(false)
        let endpoint = self.endpoint
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.boundPort.set(listener.port?.rawValue ?? 0)
                    if case .socket(let url) = endpoint { chmod(url.path, 0o600) }
                    if !started.withLock({ let was = $0; $0 = true; return was }) { continuation.resume() }
                case .failed(let error):
                    if !started.withLock({ let was = $0; $0 = true; return was }) {
                        continuation.resume(throwing: error)
                    }
                    listener.cancel()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        if case .socket(let url) = endpoint { unlink(url.path) }
    }

    private func accept(_ connection: NWConnection) {
        let admitted = connections.withLock { count -> Bool in
            guard count < Self.maxConnections else { return false }
            count += 1
            return true
        }
        guard admitted else {
            connection.cancel()
            return
        }
        let connections = self.connections
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .waiting: connection.cancel()
            case .cancelled: connections.withLock { $0 -= 1 }
            default: break
            }
        }
        connection.start(queue: queue)
        let received = Locked(false)
        queue.asyncAfter(deadline: .now() + 30) {
            if !received.get() { connection.cancel() }
        }
        receive(connection, reader: HTTPRequestReader(), received: received)
    }

    private func receive(_ connection: NWConnection, reader: HTTPRequestReader, received: Locked<Bool>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var reader = reader
            switch data.map({ reader.append($0) }) ?? .incomplete {
            case .complete(let request):
                received.set(true)
                let handler = self.handler
                let task = Task {
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
                // A client that hangs up no longer waits for the answer: stop the work it asked for,
                // such as typing that is still going.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
                    if isComplete || error != nil { task.cancel() }
                }
            case .invalid(let status, let message):
                received.set(true)
                self.send(.error(message, status: status), on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    received.set(true)
                    connection.cancel()
                } else {
                    self.receive(connection, reader: reader, received: received)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = headers["Cache-Control"] ?? "no-store"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 422: "Unprocessable Content"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        case 507: "Insufficient Storage"
        default: "Status"
        }
    }
}
