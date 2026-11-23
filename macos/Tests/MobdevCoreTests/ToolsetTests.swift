import Foundation
import Testing
@testable import MobdevCore

@Suite struct ToolsetTests {
    static func names(_ toolsets: Toolset...) -> Set<String> {
        Set(DeviceTools.definitions.filter { toolsets.contains($0.toolset) }.map(\.name))
    }

    /// An MCP request to the app's tools, as the HTTP server or a relay hands it over.
    static func post(_ message: JSONValue, tools: String?, headers: [String: String] = [:]) async throws -> (Int, JSONValue) {
        let handler = MCPHandler(tools: DeviceTools(hub: DeviceHub(keyboardLayout: .us) {}, settleDelay: 0))
        let request = HTTPRequest(
            method: "POST", path: "/mcp", query: tools.map { ["tools": $0] } ?? [:],
            headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: message.encoded())
        let response = await handler.handle(request, source: "local")
        return (response.status, try JSONValue.parse(response.body))
    }

    static func listed(tools: String?) async throws -> [String] {
        let (_, list) = try await post(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], tools: tools)
        return list["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }

    static func instructions(tools: String?) async throws -> String {
        let (_, initialize) = try await post(
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]], tools: tools)
        return initialize["result"]?["instructions"]?.stringValue ?? ""
    }

    @Test func everyToolIsInExactlyOneToolset() {
        let definitions = DeviceTools.definitions
        #expect(Set(definitions.map(\.name)).count == definitions.count)
        let byToolset = Dictionary(grouping: definitions, by: \.toolset)
        #expect(Set(byToolset.keys) == Set(Toolset.allCases), "every toolset has tools")
        #expect(byToolset.values.map(\.count).reduce(0, +) == definitions.count)
        for name in Toolset.exceptions.keys { #expect(definitions.contains { $0.name == name }, "\(name)") }
        // The device tools keep the phone tools' toolsets.
        for definition in PhoneTools.definitions {
            #expect(definitions.first { $0.name == definition.name }?.toolset == definition.toolset, "\(definition.name)")
        }
        // Each list's tools are in its toolset.
        let expected: [String: Toolset] = [
            "list_devices": .core, "tap": .core, "observe": .core, "ui_tree": .core, "launch_app": .core,
            "crash_reports": .apps, "reload_app": .apps, "set_location": .settings, "press_button": .settings,
            "boot_device": .simulators, "start_recording": .recording, "run_tests": .tests, "list_projects": .tests,
            "native_test_result": .tests, "accessibility_audit": .tests, "crawl_app": .tests, "recent_steps": .tests,
            "performance": .performance, "record_trace": .performance, "network_log": .network,
            "list_secrets": .secrets, "type_secret": .secrets, "appstore_builds": .appstore,
        ]
        for (name, toolset) in expected {
            #expect(definitions.first { $0.name == name }?.toolset == toolset, "\(name)")
        }
    }

    @Test func coreSeesAndControlsADevice() {
        let core = Self.names(.core)
        let needed: Set<String> = [
            "list_devices", "status", "screenshot", "observe", "tap_mark", "read_screen", "find_text", "ui_tree", "tap",
            "tap_text", "tap_element", "long_press", "type_text", "swipe", "press_key", "home", "pinch", "wait_for_text",
            "wait_for_element", "wait_for_idle", "open_app", "launch_app", "install_app", "logs",
        ]
        #expect(needed.isSubset(of: core), "\(needed.subtracting(core))")
        #expect((20...30).contains(core.count), "core has \(core.count) tools")
    }

    @Test func selectionParsing() throws {
        #expect(try Toolset.selection(nil) == nil)
        #expect(try Toolset.selection("") == nil)
        #expect(try Toolset.selection(" , ") == nil)
        #expect(try Toolset.selection("core") == [.core])
        #expect(try Toolset.selection("Core, tests,") == [.core, .tests])
        #expect(Toolset.query([.tests, .core, .appstore]) == "core,tests,appstore")
        #expect(throws: UnknownToolsetError.self) { try Toolset.selection("core,nope") }
    }

    @Test func noSelectionListsEveryTool() async throws {
        let listed = try await Self.listed(tools: nil)
        #expect(listed == DeviceTools.definitions.map(\.name))
        #expect(try await Self.listed(tools: "") == listed)
        #expect(try await Self.instructions(tools: nil) == PhoneTools.instructions)
    }

    @Test func aSelectionListsOnlyItsTools() async throws {
        let listed = try await Self.listed(tools: "core")
        #expect(Set(listed) == Self.names(.core))
        #expect(listed.count == Self.names(.core).count)

        let instructions = try await Self.instructions(tools: "core")
        #expect(instructions.hasPrefix(PhoneTools.instructions))
        #expect(instructions.contains("lists the tools of the toolsets core."))
        #expect(instructions.contains("still run when called by name"))
        #expect(instructions.contains("Contents/MacOS/Mobdev <tool> key=value"))
        #expect(instructions.contains("/mcp?tools=") && instructions.contains("--tools"))
        for toolset in Toolset.allCases where toolset != .core {
            #expect(instructions.contains("\n- \(toolset.rawValue): \(toolset.summary) ("), "\(toolset)")
        }
        #expect(instructions.contains("- network: see and mock the requests an app makes (start_network_capture, "))
        #expect(!instructions.contains("\n- core:"))
    }

    @Test func severalToolsets() async throws {
        let listed = try await Self.listed(tools: "core,tests,appstore")
        #expect(Set(listed) == Self.names(.core, .tests, .appstore))
        #expect(listed.contains("run_tests") && listed.contains("appstore_reviews") && !listed.contains("set_location"))

        // server/discover says the same as initialize.
        let (status, discover) = try await Self.post(
            ["jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": ["_meta": MCPTests.modernMeta]],
            tools: "core,tests,appstore", headers: ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "server/discover"])
        #expect(status == 200)
        let instructions = discover["result"]?["instructions"]?.stringValue ?? ""
        #expect(instructions.contains("lists the tools of the toolsets core, tests, appstore."))
        #expect(instructions.contains("\n- settings: ") && !instructions.contains("\n- tests: "))

        // Naming every toolset is the same as naming none.
        #expect(try await Self.instructions(tools: Toolset.allCases.map(\.rawValue).joined(separator: ",")) == PhoneTools.instructions)
    }

    @Test func anUnknownToolsetIsAnErrorThatListsTheNames() async throws {
        for method in ["initialize", "tools/list", "tools/call"] {
            let (status, reply) = try await Self.post(
                ["jsonrpc": "2.0", "id": 3, "method": .string(method), "params": ["name": "status"]], tools: "core,test")
            #expect(status == 400)
            #expect(reply["id"] == 3)
            #expect(reply["error"]?["code"] == -32602)
            let message = reply["error"]?["message"]?.stringValue ?? ""
            #expect(message == "Unknown toolset \"test\". Toolsets: \(Toolset.names).", "\(message)")
            #expect(reply["error"]?["data"]?["toolsets"]?.arrayValue?.count == Toolset.allCases.count)
        }
    }

    /// Over HTTP, `?tools=` filters the list, and a tool outside the selection still runs.
    @Test func toolsOutsideTheSelectionCanBeCalled() async throws {
        let server = try await TestServer()
        defer { server.server.stop() }
        func post(_ message: JSONValue) async throws -> JSONValue {
            let (_, data, _) = try await server.request(
                "POST", "/mcp?tools=core", body: message, headers: ["Accept": "application/json, text/event-stream"])
            return try JSONValue.parse(data)
        }
        let list = try await post(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let names = list["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("tap_text") && !names.contains("recent_steps") && !names.contains("start_recording"))

        let home = try await post([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "home", "arguments": ["screenshot": false]],
        ])
        #expect(home["result"]?["isError"] == false)
        let steps = try await post([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "recent_steps", "arguments": [:]],
        ])
        #expect(steps["result"]?["isError"] == false, "\(steps.compactString.prefix(300))")
        #expect(steps["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("home") == true)
    }

    @Test func stdioFlag() throws {
        #expect(try MCPStdioBridge.options([]) == nil)
        #expect(try MCPStdioBridge.options(["--tools", "core,tests"]) == [.core, .tests])
        #expect(try MCPStdioBridge.options(["--tools=core"]) == [.core])
        #expect(try MCPStdioBridge.options(["--tools", "core", "--tools", "network"]) == [.core, .network])
        #expect(try MCPStdioBridge.options(["--tools", ""]) == nil)
        #expect(throws: MCPStdioBridge.UsageError.self) { try MCPStdioBridge.options(["--tools"]) }
        #expect(throws: MCPStdioBridge.UsageError.self) { try MCPStdioBridge.options(["--tool", "core"]) }
        #expect(throws: UnknownToolsetError.self) { try MCPStdioBridge.options(["--tools", "core,nope"]) }
    }

    @Test func stdioBridgeAsksForItsToolsets() async throws {
        let server = try await SocketServer()
        defer { server.stop() }
        let bridge = MCPStdioBridge.Bridge(
            socket: server.socket, tokenFile: server.tokenFile, toolsets: [.core, .recording], launchApp: {})
        let reply = try JSONValue.parse(Data((await bridge.forward(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#) ?? "").utf8))
        let names = Set(reply["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
        #expect(names == Set(PhoneTools.definitions.filter { [.core, .recording].contains($0.toolset) }.map(\.name)))
        // Every tool still runs.
        let call = await bridge.forward(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"recent_steps","arguments":{}}}"#)
        #expect(call?.contains(#""isError":false"#) == true, "\(call ?? "nil")")
    }

    /// The Go relay forwards the query string, so a remote agent's URL selects toolsets too.
    @Test(.enabled(if: RelayEndToEndTests.goPath != nil, "Go is not installed"))
    func selectionThroughTheRelay() async throws {
        let relay = try await RelayProcess.start()
        defer { relay.stop() }
        let tools = PhoneTools(phone: FakePhone(lines: []), activity: ActivityLog(), settleDelay: 0)
        let router = APIRouter(tools: tools, token: { "unused" }, port: { 0 })
        let client = RelayClient(handler: { request in await router.handle(request, from: .relay) })
        let secret = "mdh_" + SecretStore.randomHex(bytes: 32)
        client.start(url: relay.base, secret: secret, hostName: "toolsets", accessToken: nil)
        defer { client.stop() }
        for _ in 0..<100 where client.state != .connected { try await Task.sleep(for: .milliseconds(50)) }
        #expect(client.state == .connected)

        func list(_ query: String) async throws -> (Int, JSONValue) {
            var request = URLRequest(url: URL(string: relay.base.absoluteString + "/h/toolsets/mcp" + query)!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(RelayClient.clientKey(forSecret: secret))", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = JSONValue(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]).encoded()
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, try JSONValue.parse(data))
        }
        var (status, reply) = try await list("?tools=network")
        #expect(status == 200)
        let names = reply["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(Set(names) == Set(PhoneTools.definitions.filter { $0.toolset == .network }.map(\.name)))
        (status, reply) = try await list("?tools=nope")
        #expect(status == 400)
        #expect(reply["error"]?["message"]?.stringValue?.hasPrefix("Unknown toolset \"nope\".") == true)
    }
}
