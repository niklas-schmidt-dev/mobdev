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
        #expect(try RelayClient.validatedURL("https://example.com/mobdev/relay/").path == "/mobdev/relay")
    }

    /// Relay URLs arrive in connect links and end up in shell commands.
    @Test func relayURLHasNoShellSyntaxCredentialsOrQuery() {
        for text in [
            "https://relay.mobdev.sh/$(id)", "https://relay.mobdev.sh/`id`", "https://relay.mobdev.sh/a;id",
            "https://relay.mobdev.sh/?x=$(id)", "https://relay.mobdev.sh/#$(id)", "https://user:pw@relay.mobdev.sh",
            "https://relay.mobdev.sh/%24(id)", "https://relay.mobdev.sh/a'b",
        ] {
            #expect(throws: RelayError.self, "\(text)") { try RelayClient.validatedURL(text) }
        }
    }
}

@Suite struct ShellQuotingTests {
    @Test func plainWordsStayAsTheyAre() {
        #expect(Shell.quoted("https://relay.mobdev.sh/h/studio/mcp") == "https://relay.mobdev.sh/h/studio/mcp")
        #expect(Shell.quoted("/Applications/Mobdev.app/Contents/MacOS/Mobdev") == "/Applications/Mobdev.app/Contents/MacOS/Mobdev")
    }

    /// The shell must hand back exactly the value, running nothing in it.
    @Test func everythingElseReachesTheCommandLiterally() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-shell-\(UUID().uuidString)")
        let values = [
            "https://relay.mobdev.sh/$(touch \(marker.path))/mcp", "`touch \(marker.path)`", "a'b\"c", "it's; touch \(marker.path)",
            "Authorization: Bearer mdc_abc", "", "/Applications/My Apps/Mobdev.app", "$HOME \\ * ? ~",
        ]
        for value in values {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s \(Shell.quoted(value))"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == value)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
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
        let router = APIRouter(tools: tools, token: { "unused" }, port: { 0 })
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
            "params": ["name": "tap", "arguments": ["x": 295, "y": 640]],
        ]).encoded()
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let result = try JSONValue.parse(data)
        #expect(result["result"]?["isError"] == false, "\(result.compactString.prefix(400))")
        #expect(result["result"]?["content"]?.arrayValue?.last?["type"] == "image")
        #expect(phone.events.get() == [.tap(NormalizedPoint(x: 0.5, y: 0.5), 0.08)])

        // A wrong key reaches nothing.
        var wrong = request
        wrong.setValue("Bearer \(RelayClient.clientKey(forSecret: "mdh_someone-else-entirely"))", forHTTPHeaderField: "Authorization")
        let (_, wrongResponse) = try await URLSession.shared.data(for: wrong)
        #expect((wrongResponse as? HTTPURLResponse)?.statusCode == 503)
        #expect(phone.events.get().count == 1)
    }

    /// When the agent gives up, the relay sends "cancel" and the Mac stops the work: typing that
    /// nobody waits for must not keep going on the phone.
    @Test(.enabled(if: RelayEndToEndTests.goPath != nil, "Go is not installed"))
    func abandonedRequestsAreCancelledOnTheMac() async throws {
        let relay = try await RelayProcess.start()
        defer { relay.stop() }
        let started = Locked(false)
        let cancelled = Locked(false)
        let client = RelayClient(handler: { _ in
            started.set(true)
            try? await Task.sleep(for: .seconds(20))
            cancelled.set(Task.isCancelled)
            return HTTPResponse(status: 200)
        })
        let secret = "mdh_" + SecretStore.randomHex(bytes: 32)
        client.start(url: relay.base, secret: secret, hostName: "studio", accessToken: nil)
        defer { client.stop() }
        for _ in 0..<100 where client.state != .connected { try await Task.sleep(for: .milliseconds(50)) }
        #expect(client.state == .connected)

        var request = URLRequest(url: relay.base.appendingPathComponent("mcp"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(RelayClient.clientKey(forSecret: secret))", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        let agent = Task { try await URLSession.shared.data(for: request) }
        for _ in 0..<100 where !started.get() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(started.get())
        agent.cancel()
        for _ in 0..<100 where !cancelled.get() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(cancelled.get())
        #expect(client.state == .connected)
    }

    /// The Mac reports its devices over the relay, and the relay lists them for the key.
    @Test(.enabled(if: RelayEndToEndTests.goPath != nil, "Go is not installed"))
    func devicesReachTheRelay() async throws {
        let relay = try await RelayProcess.start()
        defer { relay.stop() }
        let client = RelayClient(handler: { _ in HTTPResponse(status: 200) })
        let secret = "mdh_" + SecretStore.randomHex(bytes: 32)
        let phone = DeviceSummary(
            id: "00008120-000639440C13C01E", name: "iPhone von Niklas", model: "iPhone15,2",
            modelName: "iPhone 14 Pro", osVersion: "27.0", deviceClass: "iPhone", screen: true, bluetooth: true,
            ready: true)
        // Reported before the connection exists: sent once it is established.
        client.updateDevices([phone])
        client.start(url: relay.base, secret: secret, hostName: "studio", accessToken: nil)
        defer { client.stop() }

        func listed() async throws -> [RemoteMac] {
            var request = URLRequest(url: relay.base.appendingPathComponent("v1/relay/devices"))
            request.setValue("Bearer \(RelayClient.clientKey(forSecret: secret))", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(RemoteMac.Response.self, from: data).macs
        }
        var macs: [RemoteMac] = []
        for _ in 0..<60 where macs.first?.devices.isEmpty ?? true {
            macs = try await listed()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(macs.map(\.name) == ["studio"])
        #expect(macs.first?.devices == [phone])

        // A change is sent right away.
        var locked = phone
        locked.screen = false
        locked.ready = false
        client.updateDevices([locked])
        for _ in 0..<60 where try await listed().first?.devices.first?.ready != false {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await listed().first?.devices == [locked])
    }

    /// A build reaches the Mac through the relay in chunks, a full 8 MiB one among them, byte for
    /// byte, and install_app installs it: sent by Mobdev upload's client and by the shell script.
    @Test(.enabled(if: RelayEndToEndTests.goPath != nil, "Go is not installed"))
    func uploadsThroughTheRelay() async throws {
        let relay = try await RelayProcess.start()
        defer { relay.stop() }
        let temporary = TemporaryFolder()
        let store = UploadStore(folder: temporary.url.appendingPathComponent("uploads"))
        let apps = FakeApps(platform: .simulator)
        let tools = PhoneTools(phone: FakePhone(lines: [], apps: apps), activity: ActivityLog(), settleDelay: 0, uploads: store)
        let router = APIRouter(tools: tools, uploads: store, token: { "unused" }, port: { 0 })
        let client = RelayClient(handler: { request in await router.handle(request, from: .relay) })
        let secret = "mdh_" + SecretStore.randomHex(bytes: 32)
        client.start(url: relay.base, secret: secret, hostName: "studio", accessToken: nil)
        defer { client.stop() }
        for _ in 0..<100 where client.state != .connected { try await Task.sleep(for: .milliseconds(50)) }
        #expect(client.state == .connected)
        let key = RelayClient.clientKey(forSecret: secret)
        let mac = relay.base.appendingPathComponent("h/studio")

        let data = randomData((8 << 20) + 1000)
        let apk = try temporary.file("app-debug.apk", data)
        let uploaded = try await UploadClient(transport: HTTPUploadTransport(base: mac, key: key), pause: { _ in })
            .upload(apk, name: "app-debug.apk")
        let path = try #require(uploaded["path"]?.stringValue)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)

        let script = try await MobdevUploadScript.run([try temporary.app().path], url: mac.absoluteString, key: key)
        #expect(script.status == 0, "\(script.errors)")
        let id = script.output.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: mac.appendingPathComponent("v1/tools/install_app"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = JSONValue(["upload": .string(id)]).encoded()
        let (body, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(String(decoding: body, as: UTF8.self))")
        let result = try JSONValue.parse(body)
        #expect(result["text"]?.stringValue?.contains("from the upload Fixture.app.zip") == true, "\(result)")
        #expect(apps.installed.get().map(\.lastPathComponent) == ["Fixture.app"])
    }
}

/// Builds the Go relay once and runs it on a free loopback port.
struct RelayProcess {
    let process: Process
    let base: URL

    private static let binary = Locked<URL?>(nil)

    /// Several suites start relays in parallel, so the "free" port can be taken by the time the relay
    /// binds it; a relay that exits right away is retried on another port.
    static func start(environment: [String: String] = [:]) async throws -> RelayProcess {
        let binary = try buildOnce()
        for _ in 0..<3 {
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
            for _ in 0..<200 where process.isRunning {
                if let (_, response) = try? await URLSession.shared.data(from: base.appendingPathComponent("healthz")),
                    (response as? HTTPURLResponse)?.statusCode == 200
                {
                    return RelayProcess(process: process, base: base)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            process.terminate()
        }
        throw URLError(.cannotConnectToHost)
    }

    func stop() { process.terminate() }

    /// One build for every suite: callers wait for the first build instead of starting their own.
    private static let building = NSLock()

    private static func buildOnce() throws -> URL {
        building.lock()
        defer { building.unlock() }
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

    /// The hosted relay answers 429 when the plan allows no more Macs; the client says so.
    @Test func planLimitIsReported() async throws {
        let relay = HTTPServer(port: 0) { _ in .error("this account's plan allows 1 connected Mac", status: 429) }
        try await relay.start()
        defer { relay.stop() }
        let client = RelayClient(handler: { _ in HTTPResponse(status: 200) })
        client.start(
            url: URL(string: "http://127.0.0.1:\(relay.port)")!, secret: "mdh_" + SecretStore.randomHex(bytes: 32),
            hostName: "mac", accessToken: "mda_" + SecretStore.randomHex(bytes: 32))
        defer { client.stop() }
        for _ in 0..<60 where client.state == .connecting { try await Task.sleep(for: .milliseconds(50)) }
        #expect(client.state == .failed(RelayError.limited.description))
    }
}

@Suite struct RelayInviteTests {
    let token = "mda_" + String(repeating: "ab", count: 32)

    @Test func acceptsDashboardLinks() {
        let url = URL(string: "mobdev://connect?relay=https%3A%2F%2Frelay.mobdev.sh&token=\(token)")!
        #expect(RelayInvite(url: url) == RelayInvite(url: url))
        #expect(RelayInvite(url: url)?.relay.absoluteString == "https://relay.mobdev.sh")
        #expect(RelayInvite(url: url)?.token == token)
        // The development build's scheme.
        let dev = URL(string: "mobdev-dev://connect?relay=https%3A%2F%2Frelay.mobdev.sh&token=\(token)")!
        #expect(RelayInvite(url: dev)?.token == token)
    }

    @Test func rejectsInsecureRelaysAndBadTokens() {
        #expect(RelayInvite(url: URL(string: "mobdev://connect?relay=http%3A%2F%2Fevil.example&token=\(token)")!) == nil)
        #expect(RelayInvite(url: URL(string: "mobdev://connect?relay=https%3A%2F%2Frelay.mobdev.sh&token=mda_short")!) == nil)
        #expect(RelayInvite(url: URL(string: "mobdev://other?relay=https%3A%2F%2Frelay.mobdev.sh&token=\(token)")!) == nil)
        #expect(RelayInvite(url: URL(string: "https://connect?relay=https%3A%2F%2Frelay.mobdev.sh&token=\(token)")!) == nil)
    }
}
