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

    @Test func connectURLUsesWebSockets() {
        let secure = RelayClient.connectURL(base: URL(string: "https://relay.mobdev.sh/")!, hostName: "studio")
        #expect(secure?.absoluteString == "wss://relay.mobdev.sh/v1/host/connect?name=studio")
        let local = RelayClient.connectURL(base: URL(string: "http://127.0.0.1:8080")!, hostName: "a b")
        #expect(local?.absoluteString == "ws://127.0.0.1:8080/v1/host/connect?name=a%20b")
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
        let relay = try await RelayProcess.start()
        defer { relay.stop() }
        let base = relay.base

        let phone = FakePhone(lines: [("Settings", 420, 300)])
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let router = APIRouter(tools: tools, phone: phone, token: { "unused" }, port: { 0 })
        let client = RelayClient(handler: { request in await router.handle(request, from: .relay) })
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
        for _ in 0..<50 where client.state != .connected { try await Task.sleep(for: .milliseconds(50)) }
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
}

/// Builds the Go relay once and runs it on a free loopback port.
struct RelayProcess {
    let process: Process
    let base: URL

    private static let binary = Locked<URL?>(nil)

    static func start(environment: [String: String] = [:]) async throws -> RelayProcess {
        let binary = try buildOnce()
        let server = HTTPServer(port: 0) { _ in HTTPResponse(status: 200) }
        try await server.start()
        let port = server.port
        server.stop()

        let process = Process()
        process.executableURL = binary
        process.environment = environment.merging(["RELAY_ADDR": "127.0.0.1:\(port)"]) { $1 }
        process.standardError = FileHandle.nullDevice
        try process.run()
        let base = URL(string: "http://127.0.0.1:\(port)")!
        for _ in 0..<100 {
            if let (_, response) = try? await URLSession.shared.data(from: base.appendingPathComponent("healthz")),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                return RelayProcess(process: process, base: base)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        process.terminate()
        throw URLError(.cannotConnectToHost)
    }

    func stop() { process.terminate() }

    private static func buildOnce() throws -> URL {
        if let built = binary.get() { return built }
        let relayDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("relay")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-relay-\(UUID().uuidString)")
        let build = Process()
        build.executableURL = URL(fileURLWithPath: RelayEndToEndTests.goPath!)
        build.arguments = ["build", "-o", output.path, "."]
        build.currentDirectoryURL = relayDirectory
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        binary.set(output)
        return output
    }
}

/// The relay rejects a Mac without the required access token, and the client says so.
@Suite(.serialized) struct RelayAccessTests {
    @Test(.enabled(if: RelayEndToEndTests.goPath != nil, "Go is not installed"))
    func missingAccessTokenIsReported() async throws {
        let relay = try await RelayProcess.start(environment: ["RELAY_HOST_ACCESS_TOKEN": "let-me-in"])
        defer { relay.stop() }
        let client = RelayClient(handler: { _ in HTTPResponse(status: 200) })
        client.start(url: relay.base, secret: "mdh_" + SecretStore.randomHex(bytes: 32), hostName: "mac", accessToken: nil)
        defer { client.stop() }
        for _ in 0..<60 where client.state == .connecting { try await Task.sleep(for: .milliseconds(50)) }
        #expect(client.state == .failed(RelayError.rejected(403).description))

        let allowed = RelayClient(handler: { _ in HTTPResponse(status: 200) })
        allowed.start(
            url: relay.base, secret: "mdh_" + SecretStore.randomHex(bytes: 32), hostName: "mac", accessToken: "let-me-in")
        defer { allowed.stop() }
        for _ in 0..<60 where allowed.state != .connected { try await Task.sleep(for: .milliseconds(50)) }
        #expect(allowed.state == .connected)
    }
}

@Suite struct RelayInviteTests {
    let token = "mda_" + String(repeating: "ab", count: 32)

    @Test func acceptsDashboardLinks() {
        let url = URL(string: "mobdev://connect?relay=https%3A%2F%2Frelay.mobdev.sh&token=\(token)")!
        #expect(RelayInvite(url: url) == RelayInvite(url: url))
        #expect(RelayInvite(url: url)?.relay.absoluteString == "https://relay.mobdev.sh")
        #expect(RelayInvite(url: url)?.token == token)
    }

    @Test func rejectsInsecureRelaysAndBadTokens() {
        #expect(RelayInvite(url: URL(string: "mobdev://connect?relay=http%3A%2F%2Fevil.example&token=\(token)")!) == nil)
        #expect(RelayInvite(url: URL(string: "mobdev://connect?relay=https%3A%2F%2Frelay.mobdev.sh&token=mda_short")!) == nil)
        #expect(RelayInvite(url: URL(string: "mobdev://other?relay=https%3A%2F%2Frelay.mobdev.sh&token=\(token)")!) == nil)
        #expect(RelayInvite(url: URL(string: "https://connect?relay=https%3A%2F%2Frelay.mobdev.sh&token=\(token)")!) == nil)
    }
}
