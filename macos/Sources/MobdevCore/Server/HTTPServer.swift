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
    case complete(HTTPRequest, consumed: Int)
    case invalid(Int, String)
}

enum HTTPParser {
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 16 * 1024 * 1024

    static func parse(_ buffer: Data) -> HTTPParseResult {
        guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderBytes ? .invalid(431, "headers too large") : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(400, "headers are not UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
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

        let bodyStart = headerEnd.upperBound
        var body = Data()
        var consumed = bodyStart - buffer.startIndex
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch decodeChunked(buffer[bodyStart...]) {
            case .incomplete: return .incomplete
            case .invalid: return .invalid(400, "bad chunked body")
            case .complete(let decoded, let length):
                body = decoded
                consumed += length
            }
        } else if let lengthHeader = headers["content-length"] {
            guard let length = Int(lengthHeader), length >= 0 else { return .invalid(400, "bad content-length") }
            guard length <= maxBodyBytes else { return .invalid(413, "body too large") }
            guard buffer.count - consumed >= length else { return .incomplete }
            body = Data(buffer[bodyStart..<(bodyStart + length)])
            consumed += length
        }
        let request = HTTPRequest(
            method: String(requestLine[0]).uppercased(), path: components.path, query: query, headers: headers,
            body: body)
        return .complete(request, consumed: consumed)
    }

    private enum ChunkResult {
        case incomplete, invalid
        case complete(Data, Int)
    }

    private static func decodeChunked(_ data: Data) -> ChunkResult {
        var body = Data()
        var index = data.startIndex
        while true {
            guard let lineEnd = data[index...].firstRange(of: Data("\r\n".utf8)) else { return .incomplete }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return .invalid }
            index = lineEnd.upperBound
            if size == 0 {
                guard let end = data[index...].firstRange(of: Data("\r\n".utf8)) else { return .incomplete }
                return .complete(body, end.upperBound - data.startIndex)
            }
            guard body.count + size <= maxBodyBytes else { return .invalid }
            guard data.endIndex - index >= size + 2 else { return .incomplete }
            body.append(data[index..<(index + size)])
            index += size + 2
        }
    }
}

/// A small HTTP/1.1 server on Network.framework. One request per connection.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let queue = DispatchQueue(label: "dev.mobdev.http")
    private let requestedPort: UInt16
    private let handler: Handler
    private var listener: NWListener?
    private let boundPort = Locked<UInt16>(0)

    public init(port: UInt16, handler: @escaping Handler) {
        self.requestedPort = port
        self.handler = handler
    }

    public var port: UInt16 { boundPort.get() }

    /// Starts listening on 127.0.0.1 only.
    public func start() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let started = Locked(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.boundPort.set(listener.port?.rawValue ?? 0)
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
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let received = Locked(false)
        queue.asyncAfter(deadline: .now() + 30) {
            if !received.get() { connection.cancel() }
        }
        receive(connection, buffer: Data(), received: received)
    }

    private func receive(_ connection: NWConnection, buffer: Data, received: Locked<Bool>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPParser.parse(buffer) {
            case .complete(let request, _):
                received.set(true)
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
            case .invalid(let status, let message):
                received.set(true)
                self.send(.error(message, status: status), on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    received.set(true)
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer, received: received)
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
        default: "Status"
        }
    }
}
