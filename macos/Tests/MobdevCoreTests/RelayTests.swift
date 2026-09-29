import Foundation
import Testing
@testable import MobdevCore

@Suite struct RelayKeyTests {
    @Test func clientKeyMatchesTheGoRelay() {
        // Same vector as relay/relay_test.go.
        #expect(
            RelayClient.clientKey(forSecret: "mdh_0123456789abcdef")
                == "mdc_0e465dea368fb6d8eb7a0c146da16c6a88b354216735682efcdf51a0ec3a9ab4")
    }

    @Test func relayURLMustBeHTTPSExceptLocally() throws {
        #expect(try RelayClient.validatedURL("https://relay.example.com").host == "relay.example.com")
        #expect(try RelayClient.validatedURL("http://127.0.0.1:8080").port == 8080)
        #expect(throws: RelayError.self) { try RelayClient.validatedURL("http://relay.example.com") }
        #expect(throws: RelayError.self) { try RelayClient.validatedURL("relay.example.com") }
    }
}

/// Builds and runs the real Go relay, connects a RelayClient backed by a fake phone, and
/// drives the phone through the relay's MCP endpoint. Skipped when Go is not installed.
@Suite(.serialized) struct RelayEndToEndTests {
    static let goPath: String? = {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map { "\($0)/go" } ?? []
        return (path + ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    @Test(.enabled(if: goPath != nil, "Go is not installed"))
    func mcpThroughTheRelay() async throws {
        let relayDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("relay")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let binary = work.appendingPathComponent("relay")

        let build = Process()
        build.executableURL = URL(fileURLWithPath: Self.goPath!)
        build.arguments = ["build", "-o", binary.path, "."]
        build.currentDirectoryURL = relayDirectory
        try build.run()
        build.waitUntilExit()
        #expect(build.terminationStatus == 0)

        let port = try await Self.freePort()
        let relay = Process()
        relay.executableURL = binary
        relay.environment = ["RELAY_ADDR": "127.0.0.1:\(port)"]
        relay.standardError = FileHandle.nullDevice
        try relay.run()
        defer { relay.terminate() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await Self.waitUntilHealthy(base)

        let phone = FakePhone(lines: [("Settings", 420, 300)])
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let router = APIRouter(tools: tools, phone: phone, token: { "unused" }, port: { 0 })
        let client = RelayClient(pollers: 2, handler: { request in await router.handle(request, from: .relay) })
        let secret = "mdh_" + SecretStore.randomHex(bytes: 32)
        client.start(url: base, secret: secret, hostName: "test-mac", accessToken: nil)
        defer { client.stop() }
        let key = RelayClient.clientKey(forSecret: secret)

        // Wait until the Mac shows up at the relay.
        var hosts: [String] = []
        for _ in 0..<50 where hosts.isEmpty {
            var request = URLRequest(url: base.appendingPathComponent("v1/relay/hosts"))
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: request)
            hosts = try JSONValue.parse(data)["hosts"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if hosts.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        #expect(hosts == ["test-mac"])
        #expect(client.state == .connected)

        var request = URLRequest(url: base.appendingPathComponent("h/test-mac/mcp"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = JSONValue([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "tap_text", "arguments": ["text": "Settings"]],
        ]).encoded()
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let result = try JSONValue.parse(data)
        #expect(result["result"]?["isError"] == false, "\(result.compactString.prefix(400))")
        #expect(result["result"]?["content"]?.arrayValue?.last?["type"] == "image")
        #expect(phone.events.get().count == 1)

        // A wrong key reaches nothing.
        var wrong = request
        wrong.setValue("Bearer \(RelayClient.clientKey(forSecret: "mdh_someone-else-entirely"))", forHTTPHeaderField: "Authorization")
        let (_, wrongResponse) = try await URLSession.shared.data(for: wrong)
        #expect((wrongResponse as? HTTPURLResponse)?.statusCode == 503)
        #expect(phone.events.get().count == 1)
    }

    static func freePort() async throws -> UInt16 {
        let server = HTTPServer(port: 0) { _ in HTTPResponse(status: 200) }
        try await server.start()
        defer { server.stop() }
        return server.port
    }

    static func waitUntilHealthy(_ base: URL) async throws {
        for _ in 0..<100 {
            if let (_, response) = try? await URLSession.shared.data(from: base.appendingPathComponent("healthz")),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw URLError(.cannotConnectToHost)
    }
}
