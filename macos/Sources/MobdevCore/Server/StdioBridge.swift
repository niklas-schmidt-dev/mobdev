import Foundation

/// `Mobdev mcp`: an MCP stdio server for clients that launch servers as subprocesses. Each
/// line is forwarded to the running app's HTTP endpoint with the local token, so the MCP
/// config needs no secret.
public enum MCPStdioBridge {
    public static func run(launchApp: @escaping @Sendable () -> Void) -> Never {
        let port = MobdevPaths.port(settings: AppSettings.load())
        Task {
            let bridge = Bridge(port: port, tokenFile: MobdevPaths.tokenFile, launchApp: launchApp)
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
        private let port: UInt16
        private let tokenFile: URL
        private let launchApp: @Sendable () -> Void
        private let launchWait: TimeInterval
        private var launched = false
        private let session: URLSession

        public init(
            port: UInt16, tokenFile: URL, launchWait: TimeInterval = 10, launchApp: @escaping @Sendable () -> Void
        ) {
            self.port = port
            self.tokenFile = tokenFile
            self.launchWait = launchWait
            self.launchApp = launchApp
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            session = URLSession(configuration: configuration)
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
                return self.error(id, "Mobdev is not running or not reachable on port \(port). Open Mobdev.app.")
            }
        }

        private func post(_ body: String, message: JSONValue?) async throws -> (Data, Int) {
            do {
                return try await send(body, message: message)
            } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                guard !launched else { throw error }
                launched = true
                launchApp()
                for _ in 0..<max(1, Int(launchWait / 0.25)) {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    if let result = try? await send(body, message: message) { return result }
                }
                throw error
            }
        }

        private func send(_ body: String, message: JSONValue?) async throws -> (Data, Int) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let token = SecretStore.read(tokenFile) {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            // Mirror the metadata a modern Streamable HTTP client would send.
            if let method = message?["method"]?.stringValue,
                let version = message?["params"]?["_meta"]?["io.modelcontextprotocol/protocolVersion"]?.stringValue
            {
                request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
                request.setValue(method, forHTTPHeaderField: "Mcp-Method")
                if let name = message?["params"]?["name"]?.stringValue {
                    request.setValue(Self.headerValue(name), forHTTPHeaderField: "Mcp-Name")
                }
            }
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
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
