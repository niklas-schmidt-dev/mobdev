import Foundation

/// React Native's dev server on this Mac: Metro, also when Expo CLI runs it. Its message socket at
/// ws://localhost:<port>/message passes "reload" and "devMenu" on to every app connected to it,
/// which is what pressing r or d in Metro's terminal does. Protocol version 2, as in Expo CLI 57's
/// `createMessageSocket` and the React Native CLI's server: a broadcast has a method and no id; a
/// request to the server has an id and target "server". Metro accepts broadcasts from this Mac only.
public struct Metro: Sendable {
    public let port: Int

    public init(port: Int) { self.port = port }

    /// An app connected to Metro, with the query it connected with, e.g. "role=ios".
    public struct Peer: Sendable, Equatable {
        public var id: String
        public var query: String
    }

    /// Lists the connected apps and, when there is at least one, sends them `method`. Throws when
    /// nothing answers on the port.
    public func send(_ method: String, timeout: TimeInterval = 5) async throws -> [Peer] {
        guard let url = URL(string: "ws://localhost:\(port)/message") else {
            throw DeveloperError("\(port) is not a port.")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let id = UUID().uuidString
        // receive() ignores task cancellation, so the timeout closes the socket, which ends it.
        let timedOut = Locked(false)
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            timedOut.set(true)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timer.cancel() }
        let peers: [Peer]
        do {
            try await socket.send(.string(Self.message(["id": .string(id), "target": "server", "method": "getpeers"])))
            peers = try await Self.peers(from: socket, id: id)
        } catch {
            let reason = timedOut.get()
                ? "no answer within \(Int(timeout)) seconds"
                : error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            throw DeveloperError(
                "Metro is not running on port \(port), or it did not answer (\(reason)). Start it with npx expo start or npx react-native start, or pass its port.")
        }
        guard !peers.isEmpty else { return [] }
        try await socket.send(.string(Self.message(["method": .string(method)])))
        // A moment for the message to leave before the socket closes.
        try? await Task.sleep(nanoseconds: 200_000_000)
        return peers
    }

    static func message(_ fields: [String: JSONValue]) -> String {
        JSONValue.object(fields.merging(["version": 2]) { $1 }).compactString
    }

    /// Reads until the answer to the getpeers request with `id`; other messages are skipped.
    private static func peers(from socket: URLSessionWebSocketTask, id: String) async throws -> [Peer] {
        while true {
            let message = try await socket.receive()
            let text: String
            switch message {
            case .string(let string): text = string
            case .data(let data): text = String(decoding: data, as: UTF8.self)
            @unknown default: continue
            }
            if let peers = parsePeers(text, id: id) { return peers }
        }
    }

    /// `{"version":2,"id":"…","result":{"<client id>":{"role":"ios"}}}`; nil for other messages.
    static func parsePeers(_ text: String, id: String) -> [Peer]? {
        guard let json = try? JSONValue.parse(Data(text.utf8)), json["id"]?.stringValue == id else { return nil }
        let result = json["result"]?.objectValue ?? [:]
        return result.map { key, value in
            let query: String
            if let object = value.objectValue {
                query = object.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.stringValue ?? $0.value.compactString)" }
                    .joined(separator: "&")
            } else {
                query = value.stringValue ?? ""
            }
            return Peer(id: key, query: query)
        }
        .sorted { $0.id < $1.id }
    }
}
