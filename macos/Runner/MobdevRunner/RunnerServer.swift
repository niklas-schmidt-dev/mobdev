import Foundation
import Network

/// A small HTTP/1.1 server, one request per connection, on the loopback interface only: Mobdev
/// reaches it through usbmuxd on an iPhone and on 127.0.0.1 on a simulator, and nothing on the
/// network can. Every request must carry the token Mobdev started the runner with, so other apps on
/// the phone cannot drive it either. Handlers run on the main thread, one at a time.
final class RunnerServer {
    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data

        /// The body as a JSON object.
        func json() throws -> [String: Any] {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw RunnerError("The body must be a JSON object.")
            }
            return object
        }
    }

    struct Response {
        var status: Int
        var body: Data

        static func json(_ object: Any, status: Int = 200) -> Response {
            let body = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
            return Response(status: status, body: body ?? Data("{}".utf8))
        }

        static func error(_ message: String, status: Int) -> Response { .json(["error": message], status: status) }
    }

    private let listener: NWListener
    private let token: String
    private let handler: (Request) -> Response
    private let queue = DispatchQueue(label: "dev.mobdev.runner.server")
    /// Only touched on the main thread.
    private var busy = false
    private var waiting: [() -> Void] = []

    init(port: UInt16, token: String, handler: @escaping (Request) -> Response) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: port) else { throw RunnerError("Invalid port \(port).") }
        listener = try NWListener(using: parameters, on: port)
        self.token = token
        self.handler = handler
    }

    func start() {
        listener.stateUpdateHandler = { state in NSLog("Mobdev Runner: listener %@", "\(state)") }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .complete(let request):
                self.respond(to: request, on: connection)
            case .incomplete where !complete && error == nil && buffer.count < 4 * 1024 * 1024:
                self.receive(on: connection, buffer: buffer)
            default:
                self.send(.error("Bad request.", status: 400), on: connection)
            }
        }
    }

    private func respond(to request: Request, on connection: NWConnection) {
        guard token.isEmpty || request.headers["authorization"] == "Bearer \(token)" else {
            send(.error("Wrong or missing token.", status: 401), on: connection)
            return
        }
        DispatchQueue.main.async {
            self.serially {
                let response = self.handler(request)
                self.send(response, on: connection)
            }
        }
    }

    /// XCTest spins the run loop while it waits for the device, which would start the next request
    /// in the middle of this one; those wait for their turn instead.
    private func serially(_ work: @escaping () -> Void) {
        if busy {
            waiting.append(work)
            return
        }
        busy = true
        work()
        busy = false
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            DispatchQueue.main.async { self.serially(next) }
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][response.status] ?? "Error"
        let head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private enum Parsed {
        case complete(Request)
        case incomplete
        case invalid
    }

    private static func parse(_ buffer: Data) -> Parsed {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, let url = URLComponents(string: String(parts[1])) else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return .incomplete }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(
            Request(method: String(parts[0]), path: url.path, query: query, headers: headers, body: Data(body.prefix(length))))
    }
}

struct RunnerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
