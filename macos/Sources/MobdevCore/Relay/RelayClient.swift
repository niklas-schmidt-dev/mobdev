import CryptoKit
import Foundation

public enum RelayState: Sendable, Equatable {
    case off
    case connecting
    case connected
    case failed(String)

    public var summary: String {
        switch self {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed(let message): message
        }
    }
}

/// One request tunnelled through the relay ("request") or its answer ("response").
/// Bodies are base64.
struct RelayEnvelope: Codable {
    var type: String
    var id: String
    var method: String?
    var path: String?
    var query: String?
    var status: Int?
    var headers: [String: String]
    var body: String
}

/// Keeps one outgoing WebSocket to a Mobdev relay so agents elsewhere can reach this Mac
/// without opening a port. The relay only forwards; nothing is stored there. The same
/// protocol runs on the self-hosted Go relay and the hosted one.
public final class RelayClient: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// Close codes the relay uses: another connection took over, or the access token was revoked.
    static let closeReplaced = 4000
    static let closeRevoked = 4001
    /// Wait after the relay refuses the connection with 429.
    static let limitedRetry: TimeInterval = 300

    private let handler: Handler
    private let onStateChange: @Sendable (RelayState) -> Void
    private let stateBox = Locked<RelayState>(.off)
    private let loop = Locked<Task<Void, Never>?>(nil)
    private let socket = Locked<URLSessionWebSocketTask?>(nil)
    private let devicesBox = Locked<[DeviceSummary]?>(nil)
    private let session: URLSession
    private let pingInterval: TimeInterval

    public init(
        pingInterval: TimeInterval = 20, handler: @escaping Handler,
        onStateChange: @escaping @Sendable (RelayState) -> Void = { _ in }
    ) {
        self.handler = handler
        self.onStateChange = onStateChange
        self.pingInterval = pingInterval
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public var state: RelayState { stateBox.get() }

    /// The key agents use. Derived from the host secret, so the relay can match clients to
    /// this Mac without storing anything, and a client key cannot be used to act as the host.
    public static func clientKey(forSecret secret: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data("mobdev-relay-client-v1".utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return "mdc_" + code.map { String(format: "%02x", $0) }.joined()
    }

    /// Accepts https URLs, and plain http only for this Mac (for testing a local relay).
    public static func validatedURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
        else { throw RelayError.invalidURL }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".localhost")
        guard scheme == "https" || (scheme == "http" && loopback) else { throw RelayError.insecureURL }
        return url
    }

    /// The WebSocket URL for a relay base URL: https becomes wss, http becomes ws.
    static func connectURL(base: URL, hostName: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/v1/host/connect"
        components.queryItems = [URLQueryItem(name: "name", value: hostName)]
        return components.url
    }

    public func start(url: URL, secret: String, hostName: String, accessToken: String?) {
        stop()
        setState(.connecting)
        let task = Task { [weak self] () -> Void in
            await self?.run(base: url, secret: secret, hostName: hostName, accessToken: accessToken)
        }
        loop.set(task)
    }

    public func stop() {
        loop.get()?.cancel()
        loop.set(nil)
        socket.get()?.cancel(with: .goingAway, reason: nil)
        socket.set(nil)
        setState(.off)
    }

    private func run(base: URL, secret: String, hostName: String, accessToken: String?) async {
        var backoff: TimeInterval = 1
        while !Task.isCancelled {
            guard let url = Self.connectURL(base: base, hostName: hostName) else {
                setState(.failed(RelayError.invalidURL.description))
                return
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            if let accessToken, !accessToken.isEmpty {
                request.setValue(accessToken, forHTTPHeaderField: "X-Relay-Access")
            }
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = 64 << 20
            socket.set(task)
            task.resume()
            let connected = await serve(task)
            task.cancel(with: .goingAway, reason: nil)
            if Task.isCancelled { return }

            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                setState(.failed(RelayError.rejected(status).description))
                backoff = 30
            } else if status == 429 {
                // The plan allows no more Macs, or this Mac reconnected too often. Retrying soon won't help.
                setState(.failed(RelayError.limited.description))
                backoff = Self.limitedRetry
            } else if task.closeCode.rawValue == Self.closeReplaced {
                setState(.failed(RelayError.replaced.description))
                backoff = 30
            } else if task.closeCode.rawValue == Self.closeRevoked {
                setState(.failed(RelayError.revoked.description))
                backoff = 30
            } else {
                setState(.failed(RelayError.unreachable.description))
                if connected { backoff = 1 }
            }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 30)
        }
    }

    /// Serves requests until the connection ends. Returns whether it was ever established.
    private func serve(_ task: URLSessionWebSocketTask) async -> Bool {
        let lastPong = Locked(Date())
        let established = Locked(false)
        let pingInterval = self.pingInterval
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // Keepalive: a ping now confirms the connection, then one per interval.
                while !Task.isCancelled {
                    do {
                        try await task.send(.string("ping"))
                        try await Task.sleep(for: .seconds(pingInterval))
                    } catch { return }
                    if Date().timeIntervalSince(lastPong.get()) > pingInterval * 2.5 { return }
                }
            }
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    guard let message = try? await task.receive() else { return }
                    guard case .string(let text) = message, let self else { continue }
                    if text == "pong" {
                        lastPong.set(Date())
                        if !established.get() {
                            established.set(true)
                            self.setState(.connected)
                            if let devices = self.devicesBox.get() { await Self.send(devices: devices, on: task) }
                        }
                        continue
                    }
                    guard let envelope = try? JSONDecoder().decode(RelayEnvelope.self, from: Data(text.utf8)),
                        envelope.type == "request"
                    else { continue }
                    Task {
                        let answer = await self.answer(envelope)
                        if let data = try? JSONEncoder().encode(answer) {
                            try? await task.send(.string(String(decoding: data, as: UTF8.self)))
                        }
                    }
                }
            }
            // Whichever side ends first ends the connection.
            await group.next()
            group.cancelAll()
            task.cancel(with: .goingAway, reason: nil)
        }
        return established.get()
    }

    /// The devices the relay should list for this Mac: sent once connected and whenever they change.
    public func updateDevices(_ devices: [DeviceSummary]) {
        let changed = devicesBox.withLock { current -> Bool in
            guard current != devices else { return false }
            current = devices
            return true
        }
        guard changed, stateBox.get() == .connected, let task = socket.get() else { return }
        Task { await Self.send(devices: devices, on: task) }
    }

    private static func send(devices: [DeviceSummary], on task: URLSessionWebSocketTask) async {
        struct Frame: Encodable {
            let type = "devices"
            let devices: [DeviceSummary]
        }
        guard let data = try? JSONEncoder().encode(Frame(devices: devices)) else { return }
        try? await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func answer(_ envelope: RelayEnvelope) async -> RelayEnvelope {
        var query: [String: String] = [:]
        if let text = envelope.query, !text.isEmpty {
            for item in URLComponents(string: "?" + text)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
        let request = HTTPRequest(
            method: envelope.method ?? "GET", path: envelope.path ?? "/", query: query, headers: envelope.headers,
            body: Data(base64Encoded: envelope.body) ?? Data())
        let response = await handler(request)
        return RelayEnvelope(
            type: "response", id: envelope.id, status: response.status, headers: response.headers,
            body: response.body.base64EncodedString())
    }

    private func setState(_ state: RelayState) {
        let changed = stateBox.withLock { current -> Bool in
            guard current != state else { return false }
            current = state
            return true
        }
        if changed { onStateChange(state) }
    }
}

public enum RelayError: Error, CustomStringConvertible {
    case invalidURL
    case insecureURL
    case rejected(Int)
    case replaced
    case revoked
    case limited
    case unreachable

    public var description: String {
        switch self {
        case .invalidURL: "The relay URL is not valid."
        case .insecureURL: "The relay URL must use https (http only for localhost)."
        case .rejected(403): "The relay needs a valid access token for this Mac."
        case .rejected: "The relay rejected this Mac's key."
        case .replaced: "Another Mac connected with the same key and name."
        case .revoked: "The access token for this relay was revoked. Create a new one in the dashboard."
        case .limited:
            "The relay has no room for this Mac: your plan's Mac limit is reached, or it reconnected too often. Retrying in 5 minutes."
        case .unreachable: "Cannot reach the relay. Retrying…"
        }
    }
}
