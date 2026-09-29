import Foundation

/// MCP over Streamable HTTP. Serves both eras on one endpoint: modern clients (2026-07-28,
/// stateless, per-request `_meta` mirrored into headers) and legacy clients that start with
/// `initialize` (2024-11-05 to 2025-11-25). No sessions, no server-initiated messages.
public final class MCPHandler: Sendable {
    public static let modernVersions = ["2026-07-28"]
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverName = "mobdev"
    public static let serverVersion = "0.1.0"

    private let tools: PhoneTools

    public init(tools: PhoneTools) {
        self.tools = tools
    }

    private static let serverInfo: JSONValue = [
        "name": .string(serverName), "title": "Mobdev", "version": .string(serverVersion),
    ]

    public func handle(_ request: HTTPRequest, source: String) async -> HTTPResponse {
        guard request.method == "POST" else {
            return HTTPResponse(status: 405, headers: ["Allow": "POST"])
        }
        guard let message = try? JSONValue.parse(request.body) else {
            return rpcError(id: .null, code: -32700, message: "Parse error", status: 400)
        }
        guard case .object(let object) = message else {
            return rpcError(id: .null, code: -32600, message: "Batches are not supported", status: 400)
        }
        guard let method = object["method"]?.stringValue else {
            // A JSON-RPC response from a legacy client. We never send requests, so ignore it.
            return HTTPResponse(status: 202)
        }
        guard let id = object["id"], !id.isNull else {
            return HTTPResponse(status: 202)  // Notifications such as notifications/initialized.
        }
        let params = object["params"] ?? [:]
        let meta = params["_meta"]
        let requestedModern = meta?["io.modelcontextprotocol/protocolVersion"]?.stringValue

        if method == "initialize" {
            return initialize(id: id, params: params)
        }
        if let version = requestedModern {
            if let failure = validateModern(request, version: version, method: method, params: params, id: id) {
                return failure
            }
            return await dispatch(method, id: id, params: params, modern: true, source: source)
        }
        if let header = request.header("mcp-protocol-version"), !Self.legacyVersions.contains(header) {
            if Self.modernVersions.contains(header) {
                return rpcError(
                    id: id, code: -32602, message: "Missing _meta.io.modelcontextprotocol/protocolVersion", status: 400)
            }
            return unsupported(id: id, requested: header)
        }
        return await dispatch(method, id: id, params: params, modern: false, source: source)
    }

    // MARK: Protocol

    private func initialize(id: JSONValue, params: JSONValue) -> HTTPResponse {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        let version = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]
        return result(
            id: id,
            [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": Self.serverInfo,
                "instructions": .string(PhoneTools.instructions),
            ], modern: false)
    }

    private func validateModern(
        _ request: HTTPRequest, version: String, method: String, params: JSONValue, id: JSONValue
    ) -> HTTPResponse? {
        guard Self.modernVersions.contains(version) else { return unsupported(id: id, requested: version) }
        func mismatch(_ message: String) -> HTTPResponse {
            rpcError(id: id, code: -32020, message: "Header mismatch: \(message)", status: 400)
        }
        guard let header = request.header("mcp-protocol-version") else {
            return mismatch("MCP-Protocol-Version header is missing")
        }
        guard header == version else {
            return mismatch("MCP-Protocol-Version header '\(header)' does not match body value '\(version)'")
        }
        guard let methodHeader = request.header("mcp-method") else { return mismatch("Mcp-Method header is missing") }
        guard methodHeader == method else {
            return mismatch("Mcp-Method header '\(methodHeader)' does not match body value '\(method)'")
        }
        if method == "tools/call" {
            let name = params["name"]?.stringValue ?? ""
            guard let raw = request.header("mcp-name") else { return mismatch("Mcp-Name header is missing") }
            guard let decoded = Self.decodeHeaderValue(raw), decoded == name else {
                return mismatch("Mcp-Name header '\(raw)' does not match body value '\(name)'")
            }
        }
        guard params["_meta"]?["io.modelcontextprotocol/clientCapabilities"] != nil else {
            return rpcError(
                id: id, code: -32602, message: "Missing _meta.io.modelcontextprotocol/clientCapabilities", status: 400)
        }
        return nil
    }

    private func dispatch(_ method: String, id: JSONValue, params: JSONValue, modern: Bool, source: String) async
        -> HTTPResponse
    {
        switch method {
        case "server/discover":
            return result(
                id: id,
                [
                    "supportedVersions": .array((Self.modernVersions + Self.legacyVersions).map(JSONValue.string)),
                    "capabilities": ["tools": ["listChanged": false]],
                    "instructions": .string(PhoneTools.instructions),
                ], modern: true)
        case "ping":
            return result(id: id, [:], modern: modern)
        case "tools/list":
            return result(id: id, ["tools": .array(PhoneTools.definitions.map(\.mcpJSON))], modern: modern)
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return rpcError(id: id, code: -32602, message: "params.name is required", status: modern ? 400 : 200)
            }
            do {
                let output = try await tools.call(
                    name, arguments: params["arguments"], source: source, screenshotByDefault: true)
                var content: [JSONValue] = [["type": "text", "text": .string(output.text)]]
                if let image = output.image {
                    content.append([
                        "type": "image", "data": .string(image.data.base64EncodedString()),
                        "mimeType": .string(image.mimeType),
                    ])
                }
                return result(id: id, ["content": .array(content), "isError": .bool(output.isError)], modern: modern)
            } catch {
                return rpcError(id: id, code: -32602, message: String(describing: error), status: 200)
            }
        default:
            return rpcError(id: id, code: -32601, message: "Method not found: \(method)", status: modern ? 404 : 200)
        }
    }

    private func unsupported(id: JSONValue, requested: String) -> HTTPResponse {
        rpcError(
            id: id, code: -32022, message: "Unsupported protocol version", status: 400,
            data: [
                "supported": .array((Self.modernVersions + Self.legacyVersions).map(JSONValue.string)),
                "requested": .string(requested),
            ])
    }

    private func result(id: JSONValue, _ value: [String: JSONValue], modern: Bool) -> HTTPResponse {
        var value = value
        value["resultType"] = "complete"
        if modern { value["_meta"] = ["io.modelcontextprotocol/serverInfo": Self.serverInfo] }
        return .json(["jsonrpc": "2.0", "id": id, "result": .object(value)])
    }

    private func rpcError(id: JSONValue, code: Int, message: String, status: Int, data: JSONValue? = nil)
        -> HTTPResponse
    {
        var error: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { error["data"] = data }
        var body: [String: JSONValue] = ["jsonrpc": "2.0", "error": .object(error)]
        if !id.isNull { body["id"] = id }
        return .json(.object(body), status: status)
    }

    /// Decodes the `=?base64?…?=` sentinel used for non-ASCII header values.
    static func decodeHeaderValue(_ value: String) -> String? {
        guard value.hasPrefix("=?base64?"), value.hasSuffix("?=") else { return value }
        let encoded = value.dropFirst("=?base64?".count).dropLast(2)
        guard let data = Data(base64Encoded: String(encoded)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
