import Foundation

/// Routes the local HTTP API, MCP endpoint and relayed requests.
public final class APIRouter: Sendable {
    public enum Origin: Sendable {
        /// From a process on this Mac: needs the bearer token and a loopback Host header.
        case local
        /// Forwarded by the relay, which already checked the client key.
        case relay
    }

    private let tools: any ToolCalling
    private let mcp: MCPHandler
    private let token: @Sendable () -> String
    private let port: @Sendable () -> UInt16

    public init(
        tools: any ToolCalling, token: @escaping @Sendable () -> String, port: @escaping @Sendable () -> UInt16
    ) {
        self.tools = tools
        self.mcp = MCPHandler(tools: tools)
        self.token = token
        self.port = port
    }

    public func handle(_ request: HTTPRequest, from origin: Origin) async -> HTTPResponse {
        if origin == .local {
            if let rejection = checkLocal(request) { return rejection }
        }
        let source = origin == .local ? "local" : "relay"
        switch (request.method, request.path) {
        case ("GET", "/healthz"):
            return .json(["ok": true, "name": .string(MCPHandler.serverName), "version": .string(MCPHandler.serverVersion)])
        case (_, "/mcp"):
            return await mcp.handle(request, source: source)
        case ("GET", "/v1/status"):
            let device = request.query["device"].map { JSONValue(["device": .string($0)]) }
            return rest(try? await tools.call("status", arguments: device, source: source, screenshotByDefault: false))
        case ("GET", "/v1/tools"):
            return .json(.array(tools.definitions.map(\.mcpJSON)))
        case ("GET", "/v1/screenshot"):
            return screenshot(request)
        case ("POST", let path) where path.hasPrefix("/v1/tools/"):
            let name = String(path.dropFirst("/v1/tools/".count))
            let arguments: JSONValue
            if request.body.isEmpty {
                arguments = [:]
            } else if let parsed = try? JSONValue.parse(request.body), case .object = parsed {
                arguments = parsed
            } else {
                return .error("The body must be a JSON object of tool arguments.", status: 400)
            }
            do {
                return rest(try await tools.call(name, arguments: arguments, source: source, screenshotByDefault: false))
            } catch {
                return .error(String(describing: error), status: 404)
            }
        default:
            return .error("Not found", status: 404)
        }
    }

    private func checkLocal(_ request: HTTPRequest) -> HTTPResponse? {
        // Browsers send Origin; nothing legitimate here does. Blocks DNS rebinding and CSRF.
        if request.header("origin") != nil {
            return .error("Browser requests are not allowed.", status: 403)
        }
        let port = self.port()
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
        guard let host = request.header("host"), allowedHosts.contains(host.lowercased()) else {
            return .error("Invalid Host header.", status: 403)
        }
        if request.method == "GET", request.path == "/healthz" { return nil }
        let expected = "Bearer \(token())"
        guard let provided = request.header("authorization"), Self.constantTimeEquals(provided, expected) else {
            return HTTPResponse(
                status: 401, headers: ["Content-Type": "application/json", "WWW-Authenticate": "Bearer"],
                body: JSONValue(["ok": false, "error": "Missing or wrong bearer token."]).encoded())
        }
        return nil
    }

    private func rest(_ output: ToolOutput?) -> HTTPResponse {
        guard let output else { return .error("Internal error", status: 500) }
        var body: [String: JSONValue] = ["ok": .bool(!output.isError), "text": .string(output.text)]
        if let data = output.data { body["data"] = data }
        if let image = output.image {
            body["screenshot"] = [
                "mime_type": .string(image.mimeType), "width": .number(Double(image.width)),
                "height": .number(Double(image.height)), "data": .string(image.data.base64EncodedString()),
            ]
        }
        if output.isError { body["error"] = .string(output.text) }
        return .json(.object(body), status: output.isError ? 422 : 200)
    }

    private func screenshot(_ request: HTTPRequest) -> HTTPResponse {
        let phone: PhoneBackend
        do {
            phone = try tools.phone(for: request.query["device"])
        } catch {
            return .error(String(describing: error), status: 409)
        }
        guard phone.status().screen.isConnected, let frame = phone.frame() else {
            return .error("The iPhone screen is not available. \(phone.status().screen.summary).", status: 409)
        }
        let full = request.query["full"] == "1" || request.query["full"] == "true"
        let png = request.query["format"] == "png"
        let image = ImageTools.scaled(frame, longEdge: full ? nil : ScreenGeometry.screenshotLongEdge)
        guard let encoded = ImageTools.encode(image, png: png) else { return .error("Encoding failed", status: 500) }
        return HTTPResponse(
            status: 200,
            headers: [
                "Content-Type": encoded.mimeType, "X-Image-Width": String(encoded.width),
                "X-Image-Height": String(encoded.height),
            ], body: encoded.data)
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}

extension JSONValue {
    init(_ object: [String: JSONValue]) { self = .object(object) }
}
