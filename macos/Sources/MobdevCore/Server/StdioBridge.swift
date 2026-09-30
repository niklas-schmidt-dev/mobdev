import Foundation

/// `Mobdev mcp`: an MCP stdio server for clients that launch servers as subprocesses. Each
/// line is forwarded with the local token to the running app over its Unix socket, which only
/// this user can serve, so the MCP config needs no secret and no other user can collect it.
public enum MCPStdioBridge {
    public static func run(launchApp: @escaping @Sendable () -> Void) -> Never {
        Task {
            let bridge = Bridge(socket: MobdevPaths.socketFile, tokenFile: MobdevPaths.tokenFile, launchApp: launchApp)
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    if let reply = await bridge.forward(line) {
                        FileHandle.standardOutput.write(Data((reply + "\n").utf8))
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("mobdev mcp: \(error)\n".utf8))
            }
            exit(0)
        }
        dispatchMain()
    }

    public actor Bridge {
        private let socket: URL
        private let tokenFile: URL
        private let launchApp: @Sendable () -> Void
        private let launchWait: TimeInterval
        private let timeout: TimeInterval
        private var launched = false

        public init(
            socket: URL, tokenFile: URL, launchWait: TimeInterval = 10, timeout: TimeInterval = 300,
            launchApp: @escaping @Sendable () -> Void
        ) {
            self.socket = socket
            self.tokenFile = tokenFile
            self.launchWait = launchWait
            self.timeout = timeout
            self.launchApp = launchApp
        }

        /// Forwards one JSON-RPC line. Returns the reply line, or nil for notifications.
        public func forward(_ line: String) async -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let message = try? JSONValue.parse(Data(trimmed.utf8))
            let id = message?["id"]
            let isRequest = message?["method"] != nil && id.map { !$0.isNull } == true
            do {
                let (data, status) = try await post(trimmed, message: message)
                if status == 202 || data.isEmpty { return isRequest ? error(id, "Empty response from Mobdev") : nil }
                return String(decoding: data, as: UTF8.self)
            } catch {
                guard isRequest else { return nil }
                switch error as? LocalSocket.Failure {
                case .notRunning?:
                    return self.error(id, "Mobdev is not running. Open \(MobdevPaths.appName).app.")
                case .interrupted(let reason)?:
                    // It may have run, so it is not sent again: a second tap or text could do harm.
                    return self.error(
                        id, "\(reason) The request may or may not have been carried out; check before retrying.")
                default:
                    return self.error(id, "Cannot reach Mobdev: \(error)")
                }
            }
        }

        /// Sends the request once. When the app is not running, nothing was sent: it starts the app,
        /// waits until the app answers a health check, then sends it.
        private func post(_ body: String, message: JSONValue?) async throws -> (Data, Int) {
            do {
                return try await send(body, message: message)
            } catch LocalSocket.Failure.notRunning where !launched {
                launched = true
                launchApp()
                let health = Self.request("GET", "/healthz", headers: [:], body: Data())
                for _ in 0..<max(1, Int(launchWait / 0.25)) {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    if (try? await exchange(health)) != nil { return try await send(body, message: message) }
                }
                throw LocalSocket.Failure.notRunning
            }
        }

        private func send(_ body: String, message: JSONValue?) async throws -> (Data, Int) {
            var headers = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"]
            if let token = SecretStore.read(tokenFile) { headers["Authorization"] = "Bearer \(token)" }
            // Mirror the metadata a modern Streamable HTTP client would send.
            if let method = message?["method"]?.stringValue,
                let version = message?["params"]?["_meta"]?["io.modelcontextprotocol/protocolVersion"]?.stringValue
            {
                headers["MCP-Protocol-Version"] = Self.headerValue(version)
                headers["Mcp-Method"] = Self.headerValue(method)
                if let name = message?["params"]?["name"]?.stringValue { headers["Mcp-Name"] = Self.headerValue(name) }
            }
            return try Self.parse(try await exchange(Self.request("POST", "/mcp", headers: headers, body: Data(body.utf8))))
        }

        /// Blocking socket work runs off the actor.
        private func exchange(_ request: Data) async throws -> Data {
            let socket = self.socket
            let timeout = self.timeout
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(with: Result { try LocalSocket.exchange(request, at: socket, timeout: timeout) })
                }
            }
        }

        static func request(_ method: String, _ path: String, headers: [String: String], body: Data) -> Data {
            var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
            for (name, value) in headers.sorted(by: { $0.key < $1.key })
            where !value.contains(where: { $0 == "\r" || $0 == "\n" }) {
                head += "\(name): \(value)\r\n"
            }
            return Data((head + "\r\n").utf8) + body
        }

        /// Status and body of a response that ends where the server closed the connection.
        static func parse(_ response: Data) throws -> (Data, Int) {
            guard let end = response.firstRange(of: Data("\r\n\r\n".utf8)),
                let head = String(data: response[response.startIndex..<end.lowerBound], encoding: .utf8),
                let status = head.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap({ Int($0) })
            else { throw LocalSocket.Failure.interrupted("Mobdev sent an incomplete response.") }
            var body = Data(response[end.upperBound...])
            for line in head.components(separatedBy: "\r\n").dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length",
                    let length = Int(parts[1].trimmingCharacters(in: .whitespaces))
                else { continue }
                guard length <= body.count else {
                    throw LocalSocket.Failure.interrupted("Mobdev sent an incomplete response.")
                }
                body = body.prefix(length)
            }
            return (body, status)
        }

        private func error(_ id: JSONValue?, _ message: String) -> String {
            let reply: JSONValue = [
                "jsonrpc": "2.0", "id": id ?? .null, "error": ["code": -32603, "message": .string(message)],
            ]
            return reply.compactString
        }

        static func headerValue(_ value: String) -> String {
            let plain = value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
            if plain, value.trimmingCharacters(in: .whitespaces) == value, !value.hasPrefix("=?base64?") {
                return value
            }
            return "=?base64?\(Data(value.utf8).base64EncodedString())?="
        }
    }
}
