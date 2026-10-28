import Foundation

/// What went wrong talking to App Store Connect, in words an agent or the user can act on.
public enum AppStoreError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case noKey
    case invalidKey(String)
    /// 401: the key was revoked, or the key ID and issuer ID do not belong together.
    case unauthorized(String)
    /// 403: the key's role does not allow the request.
    case forbidden(String)
    case notFound(String)
    /// 429: the key's hourly request limit is used up.
    case rateLimited(retryAfter: Int?)
    case failed(status: Int, message: String)
    case unreachable(String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .noKey:
            "No App Store Connect key yet. The user adds one in Mobdev's Settings › App Store Connect: an API key from App Store Connect › Users and Access › Integrations."
        case .invalidKey(let message): message
        case .unauthorized(let detail):
            "App Store Connect did not accept the key (401). Check the key ID and issuer ID in Mobdev's Settings › App Store Connect, and that the key was not revoked."
                + (detail.isEmpty ? "" : " \(detail)")
        case .forbidden(let detail):
            "The key's role does not allow this (403)\(detail.isEmpty ? "" : ": \(detail)"). A key with the App Manager or Admin role may do everything Mobdev asks for; the user creates one in App Store Connect › Users and Access › Integrations."
        case .notFound(let detail): detail.isEmpty ? "App Store Connect does not know it (404)." : "Not found (404): \(detail)"
        case .rateLimited(let seconds):
            "App Store Connect's hourly request limit for this key is used up (429). Try again "
                + (seconds.map { "in \($0) seconds." } ?? "later.")
        case .failed(let status, let message): "App Store Connect answered \(status)\(message.isEmpty ? "" : ": \(message)")."
        case .unreachable(let message): "Could not reach App Store Connect: \(message)"
        case .invalidResponse(let message): "App Store Connect sent an answer Mobdev cannot read: \(message)"
        }
    }

    public var errorDescription: String? { description }
}

/// Sends App Store Connect's requests: URLSession in the app, canned answers in tests.
public protocol AppStoreTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionAppStoreTransport: AppStoreTransport {
    private let session: URLSession

    public init() {
        // No cookies or cache: each request carries its token and nothing else.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// One resource of a JSON:API document, as App Store Connect sends them.
struct JSONAPIResource: Sendable {
    struct Identifier: Sendable, Hashable {
        let type: String
        let id: String
    }

    struct Relationship: Sendable {
        let identifiers: [Identifier]
        /// How many there are in all, when App Store Connect says so (`meta.paging.total`).
        let total: Int?
    }

    let type: String
    let id: String
    let attributes: [String: JSONValue]
    let relationships: [String: Relationship]

    init?(_ json: JSONValue) {
        guard let type = json["type"]?.stringValue, let id = json["id"]?.stringValue else { return nil }
        self.type = type
        self.id = id
        attributes = json["attributes"]?.objectValue ?? [:]
        var relationships: [String: Relationship] = [:]
        for (name, value) in json["relationships"]?.objectValue ?? [:] {
            // A to-many relationship holds an array, a to-one an object or null.
            var items: [JSONValue] = []
            if let array = value["data"]?.arrayValue {
                items = array
            } else if let single = value["data"], single.objectValue != nil {
                items = [single]
            }
            relationships[name] = Relationship(
                identifiers: items.compactMap { item in
                    guard let type = item["type"]?.stringValue, let id = item["id"]?.stringValue else { return nil }
                    return Identifier(type: type, id: id)
                },
                total: value["meta"]?["paging"]?["total"]?.doubleValue.flatMap { Int(exactly: $0) })
        }
        self.relationships = relationships
    }

    func string(_ key: String) -> String? {
        guard let value = attributes[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    func bool(_ key: String) -> Bool? { attributes[key]?.boolValue }
    func int(_ key: String) -> Int? { attributes[key]?.doubleValue.flatMap { Int(exactly: $0) } }
    func date(_ key: String) -> Date? { string(key).flatMap(AppStoreFormat.parseDate) }
}

/// A JSON:API document: the resources asked for, the related ones `include` added, and the link to
/// the next page.
struct JSONAPIDocument: Sendable {
    var data: [JSONAPIResource] = []
    var included: [JSONAPIResource.Identifier: JSONAPIResource] = [:]
    var next: URL?
    /// All resources across the pages, when App Store Connect says.
    var total: Int?

    init() {}

    init(_ json: JSONValue) throws {
        guard json.objectValue != nil else { throw AppStoreError.invalidResponse("not a JSON object") }
        let data = json["data"]
        if let items = data?.arrayValue {
            self.data = items.compactMap(JSONAPIResource.init)
        } else if let item = data, let resource = JSONAPIResource(item) {
            self.data = [resource]
        }
        for item in json["included"]?.arrayValue ?? [] {
            if let resource = JSONAPIResource(item) { included[.init(type: resource.type, id: resource.id)] = resource }
        }
        next = json["links"]?["next"]?.stringValue.flatMap(URL.init(string:))
        total = json["meta"]?["paging"]?["total"]?.doubleValue.flatMap { Int(exactly: $0) }
    }

    /// The included resources a relationship of `resource` points at, in its order.
    func related(_ resource: JSONAPIResource, _ name: String) -> [JSONAPIResource] {
        (resource.relationships[name]?.identifiers ?? []).compactMap { included[$0] }
    }

    mutating func append(_ page: JSONAPIDocument) {
        data += page.data
        included.merge(page.included) { first, _ in first }
        next = page.next
        if total == nil { total = page.total }
    }
}

/// Talks to the App Store Connect API with the key the user stored: lists apps, builds, TestFlight
/// groups, versions and reviews, and makes the few changes Mobdev offers. Shared by the tools and
/// the app's App Store Connect pages.
public final class AppStoreConnect: Sendable {
    public static let host = "api.appstoreconnect.apple.com"

    public let keys: AppStoreKeyStore
    private let transport: any AppStoreTransport
    private let now: @Sendable () -> Date
    /// Whether agents may change App Store Connect: the switch in the app's settings.
    let agentChangesAllowed: @Sendable () -> Bool
    private let token = Locked<(credentials: AppStoreCredentials, token: String, expires: Date)?>(nil)

    public init(
        keys: AppStoreKeyStore = AppStoreKeyStore(), transport: any AppStoreTransport = URLSessionAppStoreTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        agentChangesAllowed: @escaping @Sendable () -> Bool = { AppSettings.load().appStoreAgentChanges }
    ) {
        self.keys = keys
        self.transport = transport
        self.now = now
        self.agentChangesAllowed = agentChangesAllowed
    }

    public var hasKey: Bool { keys.hasKey }

    /// A token for the stored key, reused until two minutes before it expires.
    func bearerToken() throws -> String {
        guard let credentials = keys.load() else { throw AppStoreError.noKey }
        let now = now()
        if let cached = token.get(), cached.credentials == credentials, cached.expires.timeIntervalSince(now) > 120 {
            return cached.token
        }
        let made = try AppStoreToken.make(credentials, key: credentials.signingKey(), now: now)
        token.set((credentials, made.token, made.expires))
        return made.token
    }

    // MARK: Requests

    func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    /// One request; nil for an answer without a body, such as 204.
    @discardableResult
    func send(_ method: String, _ url: URL, body: JSONValue? = nil) async throws -> JSONAPIDocument? {
        // The token must only ever go to App Store Connect, also when a `next` link says otherwise.
        guard url.scheme == "https", url.host == Self.host else {
            throw AppStoreError.invalidResponse("a link to \(url.host ?? "another host") instead of \(Self.host)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try bearerToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body.encoded()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw AppStoreError.unreachable(error.localizedDescription)
        }
        switch response.statusCode {
        case 200..<300:
            guard !data.isEmpty, response.statusCode != 204 else { return nil }
            do {
                return try JSONAPIDocument(JSONValue.parse(data))
            } catch let error as AppStoreError {
                throw error
            } catch {
                throw AppStoreError.invalidResponse("not JSON")
            }
        case 401:
            // A new token next time: this one may have been made by a clock that was off.
            token.set(nil)
            throw AppStoreError.unauthorized(Self.message(data))
        case 403: throw AppStoreError.forbidden(Self.message(data))
        case 404: throw AppStoreError.notFound(Self.message(data))
        case 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            throw AppStoreError.rateLimited(retryAfter: retry)
        default: throw AppStoreError.failed(status: response.statusCode, message: Self.message(data))
        }
    }

    /// Every page of a list, following `links.next`, up to `limit` resources.
    func list(_ path: String, _ query: [String: String] = [:], limit: Int) async throws -> JSONAPIDocument {
        var query = query
        query["limit"] = String(min(max(limit, 1), 200))
        var next: URL? = url(path, query)
        var document = JSONAPIDocument()
        var pages = 0
        while let page = next, pages < 50 {
            guard let answer = try await send("GET", page) else { break }
            document.append(answer)
            pages += 1
            next = document.data.count < limit ? answer.next : nil
        }
        document.data = Array(document.data.prefix(limit))
        return document
    }

    /// App Store Connect's errors as one line: "title: detail" of each.
    static func message(_ data: Data) -> String {
        guard let json = try? JSONValue.parse(data), let errors = json["errors"]?.arrayValue else { return "" }
        return errors.map { error in
            let title = error["title"]?.stringValue ?? ""
            let detail = error["detail"]?.stringValue ?? ""
            if title.isEmpty || detail.hasPrefix(title) { return detail }
            return detail.isEmpty ? title : "\(title): \(detail)"
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Dates and states as the tools write them.
public enum AppStoreFormat {
    /// App Store Connect writes dates like 2026-10-27T10:15:30.000+00:00 or 2026-10-27T03:15:30-07:00.
    public static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    /// "2026-10-27 10:15 UTC", the same on every Mac.
    static func minute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }

    /// "2026-10-27" in UTC.
    static func day(_ date: Date) -> String { String(minute(date).prefix(10)) }

    /// A state such as READY_FOR_SALE as the app shows it: "Ready for sale".
    public static func label(_ state: String) -> String {
        let words = state.lowercased().split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// IOS, MAC_OS, TV_OS and VISION_OS as Apple writes them for people.
    public static func platform(_ platform: String) -> String {
        switch platform {
        case "IOS": "iOS"
        case "MAC_OS": "macOS"
        case "TV_OS": "tvOS"
        case "VISION_OS": "visionOS"
        default: label(platform)
        }
    }
}
