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

/// One request tunnelled through the relay, and its answer. Bodies are base64.
struct RelayEnvelope: Codable {
    var id: String
    var method: String?
    var path: String?
    var query: String?
    var status: Int?
    var headers: [String: String]
    var body: String
}

/// Keeps outbound long-poll connections to a Mobdev relay so agents elsewhere can reach this
/// Mac without opening a port. The relay only forwards; nothing is stored there.
public final class RelayClient: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let handler: Handler
    private let onStateChange: @Sendable (RelayState) -> Void
    private let stateBox = Locked<RelayState>(.off)
    private let task = Locked<Task<Void, Never>?>(nil)
    private let session: URLSession
    private let pollers: Int

    public init(pollers: Int = 3, handler: @escaping Handler, onStateChange: @escaping @Sendable (RelayState) -> Void = { _ in }) {
        self.handler = handler
        self.onStateChange = onStateChange
        self.pollers = pollers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 70
        configuration.httpMaximumConnectionsPerHost = pollers + 2
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
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else { throw RelayError.insecureURL }
        return url
    }

    public func start(url: URL, secret: String, hostName: String, accessToken: String?) {
        stop()
        setState(.connecting)
        let pollers = self.pollers
        let task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<pollers {
                    group.addTask {
                        await self?.pollLoop(url: url, secret: secret, hostName: hostName, accessToken: accessToken)
                    }
                }
            }
        }
        self.task.set(task)
    }

    public func stop() {
        task.get()?.cancel()
        task.set(nil)
        setState(.off)
    }

    private func pollLoop(url: URL, secret: String, hostName: String, accessToken: String?) async {
        var backoff: TimeInterval = 1
        // The first poll returns at once, so a wrong key or URL shows up immediately.
        var wait = false
        while !Task.isCancelled {
            do {
                var components = URLComponents(url: url.appendingPathComponent("v1/host/poll"), resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "name", value: hostName)]
                if !wait { components?.queryItems?.append(URLQueryItem(name: "wait", value: "0")) }
                wait = true
                guard let pollURL = components?.url else { throw RelayError.invalidURL }
                var request = URLRequest(url: pollURL)
                request.timeoutInterval = 70
                authorize(&request, secret: secret, accessToken: accessToken)
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200:
                    setState(.connected)
                    backoff = 1
                    let envelope = try JSONDecoder().decode(RelayEnvelope.self, from: data)
                    let answer = await serve(envelope)
                    var respond = URLRequest(url: url.appendingPathComponent("v1/host/respond"))
                    respond.httpMethod = "POST"
                    respond.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    authorize(&respond, secret: secret, accessToken: accessToken)
                    respond.httpBody = try JSONEncoder().encode(answer)
                    _ = try await session.data(for: respond)
                case 204:
                    setState(.connected)
                    backoff = 1
                case 401, 403:
                    throw RelayError.rejected(String(decoding: data.prefix(200), as: UTF8.self))
                default:
                    throw RelayError.status(status)
                }
            } catch {
                if Task.isCancelled { return }
                setState(.failed(Self.describe(error)))
                wait = false
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    private func serve(_ envelope: RelayEnvelope) async -> RelayEnvelope {
        var query: [String: String] = [:]
        if let text = envelope.query, !text.isEmpty {
            for item in URLComponents(string: "?" + text)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
        let request = HTTPRequest(
            method: envelope.method ?? "GET", path: envelope.path ?? "/", query: query, headers: envelope.headers,
            body: Data(base64Encoded: envelope.body) ?? Data())
        let response = await handler(request)
        return RelayEnvelope(
            id: envelope.id, method: nil, path: nil, query: nil, status: response.status,
            headers: response.headers, body: response.body.base64EncodedString())
    }

    private func authorize(_ request: inout URLRequest, secret: String, accessToken: String?) {
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let accessToken, !accessToken.isEmpty {
            request.setValue(accessToken, forHTTPHeaderField: "X-Relay-Access")
        }
    }

    private func setState(_ state: RelayState) {
        let changed = stateBox.withLock { current -> Bool in
            guard current != state else { return false }
            current = state
            return true
        }
        if changed { onStateChange(state) }
    }

    private static func describe(_ error: Error) -> String {
        if let relay = error as? RelayError { return relay.description }
        if let url = error as? URLError { return "Cannot reach the relay: \(url.localizedDescription)" }
        return "Relay error: \(error.localizedDescription)"
    }
}

public enum RelayError: Error, CustomStringConvertible {
    case invalidURL
    case insecureURL
    case rejected(String)
    case status(Int)

    public var description: String {
        switch self {
        case .invalidURL: "The relay URL is not valid."
        case .insecureURL: "The relay URL must use https (http only for localhost)."
        case .rejected(let body): "The relay rejected this Mac\(body.isEmpty ? "" : ": \(body)")"
        case .status(let status): "The relay answered with HTTP \(status)."
        }
    }
}
