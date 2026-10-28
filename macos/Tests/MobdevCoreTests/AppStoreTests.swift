import CryptoKit
import Foundation
import Testing
@testable import MobdevCore

/// App Store Connect answers as the API sends them, without a network: each test says what the
/// fake answers to a method and path, and checks what Mobdev asked.
final class FakeAppStoreTransport: AppStoreTransport {
    struct Request: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let body: JSONValue?
        let authorization: String?
    }

    typealias Answer = (status: Int, body: String, headers: [String: String])

    let requests = Locked<[Request]>([])
    private let answer: @Sendable (Request) -> Answer

    init(_ answer: @escaping @Sendable (Request) -> Answer) { self.answer = answer }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { _, last in last }
        let recorded = Request(
            method: request.httpMethod ?? "GET", path: url.path, query: query,
            body: request.httpBody.flatMap { try? JSONValue.parse($0) }, authorization: request.value(forHTTPHeaderField: "Authorization"))
        requests.withLock { $0.append(recorded) }
        let (status, body, headers) = answer(recorded)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(body.utf8), response)
    }

    var calls: [String] { requests.get().map { "\($0.method) \($0.path)" } }
}

@Suite struct AppStoreTests {
    static let issuer = "57246542-96fe-1a63-e053-0824d011072a"
    static let build45 = "0f8fad5b-d9cb-469f-a165-70867728950e"
    static let build44 = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    static let review1 = "00000033-1f2e-9b01-0000-000000000001"

    /// A key store in a temporary folder with a fresh key, removed by the caller.
    func keyStore(withKey: Bool = true) throws -> AppStoreKeyStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-asc-\(UUID().uuidString)")
        let store = AppStoreKeyStore(folder: folder)
        if withKey {
            try store.save(
                AppStoreCredentials(issuerID: Self.issuer, keyID: "2X9R4HXF34", privateKey: P256.Signing.PrivateKey().pemRepresentation))
        }
        return store
    }

    func connect(
        _ store: AppStoreKeyStore, allowChanges: Bool = false, now: @escaping @Sendable () -> Date = Date.init,
        _ answer: @escaping @Sendable (FakeAppStoreTransport.Request) -> FakeAppStoreTransport.Answer
    ) -> (AppStoreConnect, FakeAppStoreTransport) {
        let transport = FakeAppStoreTransport(answer)
        return (AppStoreConnect(keys: store, transport: transport, now: now, agentChangesAllowed: { allowChanges }), transport)
    }

    func tools(_ connect: AppStoreConnect, projects: ProjectList = ProjectList()) -> DeviceTools {
        DeviceTools(hub: DeviceHub(keyboardLayout: .us) {}, settleDelay: 0, projects: projects, appStore: connect)
    }

    func call(_ tools: DeviceTools, _ name: String, _ arguments: JSONValue = [:], source: String = "local") async throws -> ToolOutput {
        try await tools.call(name, arguments: arguments, source: source, screenshotByDefault: false)
    }

    static func ok(_ body: String) -> FakeAppStoreTransport.Answer { (200, body, ["Content-Type": "application/json"]) }
    static let missing: FakeAppStoreTransport.Answer = (
        404, #"{"errors":[{"status":"404","code":"NOT_FOUND","title":"The specified resource does not exist","detail":"There is no resource of type 'apps' with id '1'"}]}"#, [:]
    )

    // MARK: Fixtures, shaped like App Store Connect's answers

    static let appsPage1 = """
        {"data":[{"type":"apps","id":"1234567890","attributes":{"name":"Pocket Garden","bundleId":"com.example.garden","sku":"GARDEN1","primaryLocale":"en-US"},"links":{"self":"https://api.appstoreconnect.apple.com/v1/apps/1234567890"}}],
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps?limit=200&sort=name","next":"https://api.appstoreconnect.apple.com/v1/apps?cursor=Mg.ANrdhP0&limit=200&sort=name"},
         "meta":{"paging":{"total":2,"limit":200}}}
        """
    static let appsPage2 = """
        {"data":[{"type":"apps","id":"2234567890","attributes":{"name":"Pocket Garden Pro","bundleId":"com.example.garden.pro","sku":"GARDEN2","primaryLocale":"de-DE"}}],
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps?cursor=Mg.ANrdhP0&limit=200&sort=name"},"meta":{"paging":{"total":2,"limit":200}}}
        """
    /// The bundle ID filter also matches longer bundle IDs.
    static let gardenByBundleID = """
        {"data":[{"type":"apps","id":"2234567890","attributes":{"name":"Pocket Garden Pro","bundleId":"com.example.garden.pro","sku":"GARDEN2","primaryLocale":"de-DE"}},
                 {"type":"apps","id":"1234567890","attributes":{"name":"Pocket Garden","bundleId":"com.example.garden","sku":"GARDEN1","primaryLocale":"en-US"}}],
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps?filter%5BbundleId%5D=com.example.garden"},"meta":{"paging":{"total":2,"limit":50}}}
        """
    static let builds = """
        {"data":[
          {"type":"builds","id":"\(build45)","attributes":{"version":"45","uploadedDate":"2026-10-27T10:15:30.000-07:00","expirationDate":"2027-01-25T10:15:30.000-08:00","expired":false,"minOsVersion":"18.0","processingState":"VALID","buildAudienceType":"APP_STORE_ELIGIBLE","usesNonExemptEncryption":false},
           "relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"pre-12"}},"buildBetaDetail":{"data":{"type":"buildBetaDetails","id":"\(build45)"}},"betaAppReviewSubmission":{"data":{"type":"betaAppReviewSubmissions","id":"\(build45)"}},
             "betaBuildLocalizations":{"meta":{"paging":{"total":1,"limit":10}},"data":[{"type":"betaBuildLocalizations","id":"loc-45"}]}}},
          {"type":"builds","id":"\(build44)","attributes":{"version":"44","uploadedDate":"2026-07-20T09:00:00.000-07:00","expirationDate":"2026-10-18T09:00:00.000-07:00","expired":true,"minOsVersion":"18.0","processingState":"VALID"},
           "relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"pre-11"}},"buildBetaDetail":{"data":{"type":"buildBetaDetails","id":"\(build44)"}},"betaAppReviewSubmission":{"data":null},"betaBuildLocalizations":{"data":[]}}}],
         "included":[
          {"type":"preReleaseVersions","id":"pre-12","attributes":{"version":"1.2","platform":"IOS"}},
          {"type":"preReleaseVersions","id":"pre-11","attributes":{"version":"1.1","platform":"IOS"}},
          {"type":"buildBetaDetails","id":"\(build45)","attributes":{"autoNotifyEnabled":true,"internalBuildState":"IN_BETA_TESTING","externalBuildState":"WAITING_FOR_BETA_REVIEW"}},
          {"type":"buildBetaDetails","id":"\(build44)","attributes":{"autoNotifyEnabled":true,"internalBuildState":"EXPIRED","externalBuildState":"EXPIRED"}},
          {"type":"betaAppReviewSubmissions","id":"\(build45)","attributes":{"betaReviewState":"WAITING_FOR_REVIEW","submittedDate":"2026-10-27T18:00:00.000-07:00"}},
          {"type":"betaBuildLocalizations","id":"loc-45","attributes":{"whatToTest":"Try the new watering reminders.","locale":"en-US"}}],
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/builds"},"meta":{"paging":{"total":2,"limit":20}}}
        """
    static let groups = """
        {"data":[
          {"type":"betaGroups","id":"grp-friends","attributes":{"name":"Friends","isInternalGroup":false,"hasAccessToAllBuilds":null,"publicLinkEnabled":true,"publicLink":"https://testflight.apple.com/join/AbCdEf12","publicLinkLimit":100,"feedbackEnabled":true,"createdDate":"2026-01-02T10:00:00.000+00:00"},
           "relationships":{"builds":{"meta":{"paging":{"total":1,"limit":50}},"data":[{"type":"builds","id":"\(build44)"}]},
             "betaTesters":{"meta":{"paging":{"total":73,"limit":50}},"data":[{"type":"betaTesters","id":"t1"},{"type":"betaTesters","id":"t2"}]}}},
          {"type":"betaGroups","id":"grp-team","attributes":{"name":"Team","isInternalGroup":true,"hasAccessToAllBuilds":true,"publicLinkEnabled":false,"publicLink":null},
           "relationships":{"builds":{"data":[{"type":"builds","id":"\(build44)"},{"type":"builds","id":"\(build45)"}]},"betaTesters":{"data":[{"type":"betaTesters","id":"t9"}]}}}],
         "included":[
          {"type":"builds","id":"\(build45)","attributes":{"version":"45","uploadedDate":"2026-10-27T10:15:30.000-07:00","expired":false}},
          {"type":"builds","id":"\(build44)","attributes":{"version":"44","uploadedDate":"2026-07-20T09:00:00.000-07:00","expired":false}},
          {"type":"betaTesters","id":"t1","attributes":{"inviteType":"PUBLIC_LINK"}},
          {"type":"betaTesters","id":"t2","attributes":{"inviteType":"EMAIL"}},
          {"type":"betaTesters","id":"t9","attributes":{"inviteType":"EMAIL"}}],
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/betaGroups"},"meta":{"paging":{"total":2,"limit":200}}}
        """
    static let versions = """
        {"data":[
          {"type":"appStoreVersions","id":"ver-11","attributes":{"platform":"IOS","versionString":"1.1","appStoreState":"READY_FOR_SALE","appVersionState":"READY_FOR_DISTRIBUTION","copyright":"2026 Example","releaseType":"MANUAL","earliestReleaseDate":null,"downloadable":true,"createdDate":"2026-09-01T08:00:00.000-07:00"},
           "relationships":{"appStoreVersionPhasedRelease":{"data":{"type":"appStoreVersionPhasedReleases","id":"phased-11"}},"build":{"data":{"type":"builds","id":"\(build44)"}}}},
          {"type":"appStoreVersions","id":"ver-12","attributes":{"platform":"IOS","versionString":"1.2","appStoreState":"WAITING_FOR_REVIEW","appVersionState":"WAITING_FOR_REVIEW","releaseType":"AFTER_APPROVAL","earliestReleaseDate":null,"downloadable":true,"createdDate":"2026-10-26T08:00:00.000-07:00"},
           "relationships":{"appStoreVersionPhasedRelease":{"data":null},"build":{"data":{"type":"builds","id":"\(build45)"}}}}],
         "included":[
          {"type":"appStoreVersionPhasedReleases","id":"phased-11","attributes":{"phasedReleaseState":"ACTIVE","startDate":"2026-09-03T00:00:00.000-07:00","totalPauseDuration":0,"currentDayNumber":4}},
          {"type":"builds","id":"\(build44)","attributes":{"version":"44"}},
          {"type":"builds","id":"\(build45)","attributes":{"version":"45"}}],
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps/1234567890/appStoreVersions"},"meta":{"paging":{"total":2,"limit":20}}}
        """
    static let reviews = """
        {"data":[
          {"type":"customerReviews","id":"\(review1)","attributes":{"rating":2,"title":"Crashes on launch","body":"Since the update it closes right away.","reviewerNickname":"plantlover","createdDate":"2026-10-27T21:03:00-07:00","territory":"USA"},
           "relationships":{"response":{"data":null}}},
          {"type":"customerReviews","id":"00000033-1f2e-9b01-0000-000000000002","attributes":{"rating":5,"title":"Wunderbar","body":"Endlich gießt jemand für mich.","reviewerNickname":"Gärtnerin","createdDate":"2026-10-20T07:00:00-07:00","territory":"DEU"},
           "relationships":{"response":{"data":{"type":"customerReviewResponses","id":"resp-2"}}}}],
         "included":[{"type":"customerReviewResponses","id":"resp-2","attributes":{"responseBody":"Danke!","lastModifiedDate":"2026-10-21T09:00:00-07:00","state":"PUBLISHED"}}],
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps/1234567890/customerReviews"},"meta":{"paging":{"total":2,"limit":20}}}
        """
    static let review = """
        {"data":{"type":"customerReviews","id":"\(review1)","attributes":{"rating":2,"title":"Crashes on launch","body":"Since the update it closes right away.","reviewerNickname":"plantlover","createdDate":"2026-10-27T21:03:00-07:00","territory":"USA"},
          "relationships":{"response":{"data":null}}},"links":{"self":"https://api.appstoreconnect.apple.com/v1/customerReviews/\(review1)"}}
        """
    static let reply = """
        {"data":{"type":"customerReviewResponses","id":"resp-9","attributes":{"responseBody":"Sorry! 1.2.1 fixes it.","lastModifiedDate":"2026-10-28T09:00:00-07:00","state":"PENDING_PUBLISH"},
          "relationships":{"review":{"data":{"type":"customerReviews","id":"\(review1)"}}}},"links":{"self":"https://api.appstoreconnect.apple.com/v1/customerReviewResponses/resp-9"}}
        """

    /// The usual answers for Pocket Garden.
    static func garden(_ request: FakeAppStoreTransport.Request) -> FakeAppStoreTransport.Answer {
        switch (request.method, request.path) {
        case ("GET", "/v1/apps") where request.query["filter[bundleId]"] != nil: ok(gardenByBundleID)
        case ("GET", "/v1/apps") where request.query["cursor"] != nil: ok(appsPage2)
        case ("GET", "/v1/apps"): ok(appsPage1)
        case ("GET", "/v1/apps/1234567890"): ok(#"{"data":{"type":"apps","id":"1234567890","attributes":{"name":"Pocket Garden","bundleId":"com.example.garden","sku":"GARDEN1","primaryLocale":"en-US"}}}"#)
        case ("GET", "/v1/builds"): ok(builds)
        case ("GET", let path) where path.hasPrefix("/v1/builds/"): single(build: String(path.dropFirst("/v1/builds/".count)))
        case ("GET", "/v1/betaGroups"): ok(groups)
        case ("GET", "/v1/apps/1234567890/appStoreVersions"): ok(versions)
        case ("GET", "/v1/apps/1234567890/customerReviews"): ok(reviews)
        case ("GET", "/v1/customerReviews/\(review1)"): ok(review)
        default: missing
        }
    }

    /// One build from the list, as GET /v1/builds/<id> sends it with its app.
    static func single(build id: String) -> FakeAppStoreTransport.Answer {
        let list = try! JSONValue.parse(Data(builds.utf8))
        guard case .object(var resource)? = list["data"]?.arrayValue?.first(where: { $0["id"]?.stringValue == id }),
            case .object(var relationships)? = resource["relationships"]
        else { return missing }
        relationships["app"] = ["data": ["type": "apps", "id": "1234567890"]]
        resource["relationships"] = .object(relationships)
        return ok(JSONValue.object(["data": .object(resource), "included": list["included"] ?? []]).compactString)
    }

    // MARK: The key

    /// The token is checked by OpenSSL, not only by CryptoKit that made it, with a key made the way
    /// App Store Connect's .p8 files are: a PKCS #8 P-256 key.
    @Test func tokensAreES256JWTsThatOpenSSLVerifies() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-jwt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func openssl(_ arguments: [String]) async throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            process.currentDirectoryURL = folder
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return try await process.runToExit(timeout: 30)
        }
        #expect(try await openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ec.pem"]) == 0)
        #expect(try await openssl(["pkcs8", "-topk8", "-nocrypt", "-in", "ec.pem", "-out", "AuthKey_2X9R4HXF34.p8"]) == 0)
        let p8 = try String(contentsOf: folder.appendingPathComponent("AuthKey_2X9R4HXF34.p8"), encoding: .utf8)
        #expect(p8.hasPrefix("-----BEGIN PRIVATE KEY-----"))

        let credentials = AppStoreCredentials(
            issuerID: Self.issuer, keyID: try #require(AppStoreCredentials.keyID(fromFileName: "AuthKey_2X9R4HXF34.p8")), privateKey: p8)
        let key = try credentials.signingKey()
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let (token, expires) = try AppStoreToken.make(credentials, key: key, now: now)

        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        #expect(!token.contains("=") && !token.contains("+") && !token.contains("/"))
        func decode(_ part: String) throws -> JSONValue {
            var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            return try JSONValue.parse(try #require(Data(base64Encoded: base64)))
        }
        #expect(try decode(parts[0]) == ["alg": "ES256", "kid": "2X9R4HXF34", "typ": "JWT"])
        let claims = try decode(parts[1])
        #expect(claims == ["iss": .string(Self.issuer), "iat": 1_793_000_000, "exp": 1_793_001_140, "aud": "appstoreconnect-v1"])
        #expect(expires.timeIntervalSince(now) <= 20 * 60)

        let signature = try #require(Data(base64Encoded: try base64(parts[2])))
        #expect(signature.count == 64)
        let input = Data((parts[0] + "." + parts[1]).utf8)
        #expect(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: input))

        try input.write(to: folder.appendingPathComponent("input"))
        try P256.Signing.ECDSASignature(rawRepresentation: signature).derRepresentation.write(to: folder.appendingPathComponent("signature.der"))
        #expect(try await openssl(["ec", "-in", "ec.pem", "-pubout", "-out", "public.pem"]) == 0)
        #expect(try await openssl(["dgst", "-sha256", "-verify", "public.pem", "-signature", "signature.der", "input"]) == 0)
        // And OpenSSL says no to a signature over other bytes.
        try Data("tampered".utf8).write(to: folder.appendingPathComponent("input"))
        #expect(try await openssl(["dgst", "-sha256", "-verify", "public.pem", "-signature", "signature.der", "input"]) != 0)
    }

    func base64(_ part: String) throws -> String {
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return base64
    }

    @Test func tokensAreReusedUntilShortlyBeforeTheyExpire() async throws {
        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let clock = Locked(Date(timeIntervalSince1970: 1_793_000_000))
        let (connect, transport) = connect(store, now: { clock.get() }, Self.garden)
        let first = try connect.bearerToken()
        clock.set(clock.get().addingTimeInterval(16 * 60))
        #expect(try connect.bearerToken() == first)
        clock.set(clock.get().addingTimeInterval(60 + 1))  // Less than two minutes left.
        let second = try connect.bearerToken()
        #expect(second != first)
        _ = try await connect.apps()
        #expect(transport.requests.get().allSatisfy { $0.authorization == "Bearer \(second)" })
    }

    @Test func theKeyIsStoredPrivatelyAndChecked() throws {
        let store = try keyStore(withKey: false)
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        #expect(store.load() == nil)
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let credentials = AppStoreCredentials(issuerID: " \(Self.issuer)\n", keyID: "2X9R4HXF34 ", privateKey: pem)
        try store.save(credentials)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(store.load() == credentials)
        #expect(store.load()?.issuerID == Self.issuer)
        // Interpolating the credentials, as a log line might, names the key without its secret.
        #expect("\(credentials)" == "App Store Connect key 2X9R4HXF34")
        #expect(!String(reflecting: credentials).contains("PRIVATE"))

        // The body of a .p8 pasted without its BEGIN and END lines works too.
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined(separator: "\n")
        #expect(throws: Never.self) { try AppStoreCredentials(issuerID: Self.issuer, keyID: "2X9R4HXF34", privateKey: body).signingKey() }

        #expect(throws: AppStoreError.self) { try store.save(AppStoreCredentials(issuerID: "team", keyID: "2X9R4HXF34", privateKey: pem)) }
        #expect(throws: AppStoreError.self) { try store.save(AppStoreCredentials(issuerID: Self.issuer, keyID: "2X9-R4", privateKey: pem)) }
        #expect(throws: AppStoreError.self) {
            try store.save(AppStoreCredentials(issuerID: Self.issuer, keyID: "2X9R4HXF34", privateKey: "-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----"))
        }
        #expect(store.load() == credentials)  // A refused key leaves the stored one.
        try store.remove()
        #expect(store.load() == nil)
        #expect(AppStoreCredentials.keyID(fromFileName: "AuthKey_ABCDE12345.p8") == "ABCDE12345")
        #expect(AppStoreCredentials.keyID(fromFileName: "key.p8") == nil)
    }

    @Test func theSettingIsOffUntilTurnedOn() throws {
        #expect(AppSettings().appStoreAgentChanges == false)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).appStoreAgentChanges == false)
        var settings = AppSettings()
        settings.appStoreAgentChanges = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.appStoreAgentChanges)
    }

    // MARK: Reading

    @Test func appsAreReadAcrossPages() async throws {
        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let (connect, transport) = connect(store, Self.garden)
        let output = try await call(tools(connect), "appstore_apps", source: "relay")
        #expect(!output.isError, "\(output.text)")
        #expect(output.text == "Pocket Garden: com.example.garden, app ID 1234567890, SKU GARDEN1\nPocket Garden Pro: com.example.garden.pro, app ID 2234567890, SKU GARDEN2")
        #expect(output.data?.arrayValue?.count == 2)
        let requests = transport.requests.get()
        #expect(requests.count == 2)
        #expect(requests[0].query["limit"] == "200")
        #expect(requests[1].query["cursor"] == "Mg.ANrdhP0")
        #expect(requests.allSatisfy { $0.authorization?.hasPrefix("Bearer ey") == true })
        // Nothing of the key reaches the agent.
        let key = try #require(store.load()?.privateKey)
        #expect(!output.text.contains(key) && !(output.data?.compactString.contains("PRIVATE") ?? false))
        #expect(try await connect.appCount() == 2)
    }

    @Test func linksToOtherHostsAreNotFollowed() async throws {
        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let (connect, transport) = connect(store) { request in
            request.query["cursor"] == nil
                ? Self.ok(#"{"data":[{"type":"apps","id":"1","attributes":{"name":"A","bundleId":"a.b"}}],"links":{"next":"https://example.com/v1/apps?cursor=x"}}"#)
                : Self.ok(Self.appsPage2)
        }
        await #expect(throws: AppStoreError.self) { try await connect.apps() }
        #expect(transport.requests.get().count == 1)
    }

    @Test func buildsShowTestFlightStatesFromIncludedResources() async throws {
        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let (connect, transport) = connect(store, Self.garden)
        let output = try await call(tools(connect), "appstore_builds", ["app": "com.example.garden", "limit": 5])
        #expect(!output.isError, "\(output.text)")
        #expect(
            output.text == """
                Pocket Garden (com.example.garden), builds newest first:
                1.2 (45), iOS: VALID, uploaded 2026-10-27 17:15 UTC, expires 2027-01-25, TestFlight: internal IN_BETA_TESTING, external WAITING_FOR_BETA_REVIEW, beta review WAITING_FOR_REVIEW. id: \(Self.build45)
                  What to Test (en-US): Try the new watering reminders.
                1.1 (44), iOS: VALID, uploaded 2026-07-20 16:00 UTC, expired, TestFlight: internal EXPIRED, external EXPIRED. id: \(Self.build44)
                """)
        let builds = try #require(output.data?["builds"]?.arrayValue)
        #expect(builds[0]["version"] == "1.2")
        #expect(builds[0]["build_number"] == "45")
        #expect(builds[0]["what_to_test"] == ["en-US": "Try the new watering reminders."])
        #expect(builds[1]["beta_review_state"] == .null)
        let request = try #require(transport.requests.get().last)
        #expect(request.path == "/v1/builds")
        #expect(request.query["filter[app]"] == "1234567890")
        #expect(request.query["sort"] == "-uploadedDate")
        #expect(request.query["limit"] == "5")
        #expect(request.query["include"]?.contains("buildBetaDetail") == true)
        // The bundle ID filter found Pocket Garden Pro first; only the exact match counts.
        #expect(output.data?["app"]?["id"] == "1234567890")
    }

    @Test func testFlightGroupsAreCountedNotListed() async throws {
        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let (connect, transport) = connect(store, Self.garden)
        let output = try await call(tools(connect), "appstore_testflight", ["app": "1234567890"])
        #expect(
            output.text == """
                Pocket Garden (com.example.garden), TestFlight groups:
                Team (internal), 1 tester, builds 45, 44. id: grp-team
                Friends (external), 73 testers, public link https://testflight.apple.com/join/AbCdEf12, builds 44. id: grp-friends
                """)
        let request = try #require(transport.requests.get().last)
        #expect(request.query["filter[app]"] == "1234567890")
        #expect(request.query["fields[betaTesters]"] == "inviteType")
        #expect(transport.calls == ["GET /v1/apps/1234567890", "GET /v1/betaGroups"])
    }

    @Test func versionsShowStateBuildAndPhasedRelease() async throws {
        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let (connect, _) = connect(store, Self.garden)
        let output = try await call(tools(connect), "appstore_versions", ["app": "1234567890"])
        #expect(
            output.text == """
                Pocket Garden (com.example.garden), App Store versions newest first:
                1.2, iOS: WAITING_FOR_REVIEW, build 45, released after approval, created 2026-10-26. id: ver-12
                1.1, iOS: READY_FOR_SALE, build 44, released by hand, phased release ACTIVE, day 4 of 7, created 2026-09-01. id: ver-11
                """)
        #expect(output.data?["versions"]?.arrayValue?.last?["phased_release"]?["day"] == 4)
    }

    @Test func reviewsShowRepliesAndPassFilters() async throws {
        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let (connect, transport) = connect(store, Self.garden)
        let output = try await call(
            tools(connect), "appstore_reviews", ["app": "1234567890", "rating": 2, "territory": "usa", "unanswered": true])
        #expect(
            output.text == """
                Pocket Garden (com.example.garden), reviews newest first:
                2/5 "Crashes on launch" (USA, 2026-10-28, by plantlover). id: \(Self.review1)
                Since the update it closes right away.

                5/5 "Wunderbar" (DEU, 2026-10-20, by Gärtnerin). id: 00000033-1f2e-9b01-0000-000000000002
                Endlich gießt jemand für mich.
                Reply (published, 2026-10-21): Danke!
                """)
        let request = try #require(transport.requests.get().last)
        #expect(request.path == "/v1/apps/1234567890/customerReviews")
        #expect(request.query["filter[rating]"] == "2")
        #expect(request.query["filter[territory]"] == "USA")
        #expect(request.query["exists[publishedResponse]"] == "false")
        #expect(request.query["sort"] == "-createdDate")
        let bad = try await call(tools(connect), "appstore_reviews", ["app": "1234567890", "rating": 7])
        #expect(bad.isError && bad.text.contains("rating must be between 1"))
    }

    @Test func theAppDefaultsToTheProjectsBundleID() async throws {
        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-asc-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try TestProject.create(at: folder, name: "Garden", bundleID: "com.example.garden", builds: [:])
        let (connect, transport) = connect(store, Self.garden)
        let withProject = try await call(tools(connect, projects: ProjectList(known: [folder], active: folder)), "appstore_versions")
        #expect(withProject.text.hasPrefix("Pocket Garden (com.example.garden)"))
        #expect(transport.requests.get().first?.query["filter[bundleId]"] == "com.example.garden")

        // Without a project, two apps are too many to guess from.
        let without = try await call(tools(connect), "appstore_versions")
        #expect(without.isError)
        #expect(without.text == "Pass app: a bundle ID or app ID. Apps: Pocket Garden (com.example.garden), Pocket Garden Pro (com.example.garden.pro).")

        let unknown = try await call(tools(connect), "appstore_builds", ["app": "com.example.unknown"])
        #expect(unknown.isError && unknown.text.contains("No app with the bundle ID com.example.unknown"))
    }

    // MARK: Errors

    @Test func errorsSayWhatToDo() async throws {
        let none = try keyStore(withKey: false)
        let (unset, unsentTransport) = connect(none, Self.garden)
        let missing = try await call(tools(unset), "appstore_apps")
        #expect(missing.isError && missing.text.hasPrefix("No App Store Connect key yet."))
        #expect(unsentTransport.requests.get().isEmpty)

        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        func answer(_ status: Int, _ body: String, _ headers: [String: String] = [:]) async throws -> String {
            let (connect, _) = connect(store) { _ in (status, body, headers) }
            let output = try await call(tools(connect), "appstore_apps")
            #expect(output.isError)
            return output.text
        }
        let unauthorized = try await answer(
            401,
            #"{"errors":[{"status":"401","code":"NOT_AUTHORIZED","title":"Authentication credentials are missing or invalid.","detail":"Provide a properly configured and signed bearer token, and make sure that it has not expired."}]}"#)
        #expect(unauthorized.hasPrefix("App Store Connect did not accept the key (401). Check the key ID and issuer ID"))
        let forbidden = try await answer(
            403,
            #"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"This request is forbidden for security reasons","detail":"The API key in use does not allow this request"}]}"#)
        #expect(
            forbidden.hasPrefix(
                "The key's role does not allow this (403): This request is forbidden for security reasons: The API key in use does not allow this request."))
        #expect(try await answer(429, "", ["Retry-After": "30"]) == "App Store Connect's hourly request limit for this key is used up (429). Try again in 30 seconds.")
        #expect(try await answer(500, "") == "App Store Connect answered 500.")
        #expect(try await answer(200, "<html>") == "App Store Connect sent an answer Mobdev cannot read: not JSON")
    }

    // MARK: Changes

    @Test func changesAreRefusedUntilTheUserAllowsThem() async throws {
        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let (connect, transport) = connect(store, allowChanges: false, Self.garden)
        let tools = tools(connect)
        for (name, arguments): (String, JSONValue) in [
            ("appstore_add_build_to_group", ["app": "1234567890", "build": "45", "group": "Friends"]),
            ("appstore_set_what_to_test", ["app": "1234567890", "build": "45", "text": "Water a plant."]),
            ("appstore_reply_to_review", ["review": .string(Self.review1), "text": "Thanks!"]),
        ] {
            let output = try await call(tools, name, arguments)
            #expect(output.isError, "\(name)")
            #expect(output.text.hasPrefix("Agents may not change App Store Connect on this Mac."), "\(name)")
            #expect(output.text.contains("Agents may change App Store Connect"), "\(name)")
        }
        #expect(transport.requests.get().isEmpty)
        let readOnly = Dictionary(uniqueKeysWithValues: AppStoreTools.definitions.map { ($0.name, $0.readOnly) })
        for (name, isReadOnly) in readOnly { #expect(isReadOnly == !AppStoreTools.writeTools.contains(name), "\(name)") }
    }

    @Test func aBuildIsAddedToAGroupByNumberAndName() async throws {
        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let (connect, transport) = connect(store, allowChanges: true) { request in
            if request.method == "POST" { return (204, "", [:]) }
            if request.path == "/v1/builds" {
                // filter[version]=45 matches one build.
                let one = Self.builds.replacingOccurrences(of: "\"meta\":{\"paging\":{\"total\":2", with: "\"meta\":{\"paging\":{\"total\":1")
                var json = try! JSONValue.parse(Data(one.utf8))
                if case .object(var object) = json, let first = object["data"]?.arrayValue?.first {
                    object["data"] = [first]
                    json = .object(object)
                }
                return Self.ok(json.compactString)
            }
            return Self.garden(request)
        }
        let output = try await call(tools(connect), "appstore_add_build_to_group", ["app": "1234567890", "build": "45", "group": "friends"])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text == "Added build 1.2 (45) to the TestFlight group Friends. External testers get it once the build passed beta app review.")
        let requests = transport.requests.get()
        #expect(requests.first { $0.path == "/v1/builds" }?.query["filter[version]"] == "45")
        let post = try #require(requests.last)
        #expect(post.method == "POST")
        #expect(post.path == "/v1/betaGroups/grp-friends/relationships/builds")
        #expect(post.body == ["data": [["type": "builds", "id": .string(Self.build45)]]])

        // A group that has the build already is left alone.
        let again = try await call(tools(connect), "appstore_add_build_to_group", ["app": "1234567890", "build": .string(Self.build44), "group": "grp-team"])
        #expect(again.text == "The group Team has build 1.1 (44) already.")
        #expect(transport.requests.get().filter { $0.method == "POST" }.count == 1)
    }

    @Test func aBuildNumberInSeveralVersionsNeedsTheVersion() async throws {
        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let twice = Self.builds.replacingOccurrences(of: #""version":"44""#, with: #""version":"45""#)
        let (connect, transport) = connect(store, allowChanges: true) { request in
            request.path == "/v1/builds" ? Self.ok(twice) : Self.garden(request)
        }
        let output = try await call(tools(connect), "appstore_set_what_to_test", ["app": "1234567890", "build": "45", "text": "Water a plant."])
        #expect(output.isError)
        #expect(output.text.hasPrefix("Pocket Garden has several builds 45: 1.2 (45), id \(Self.build45); 1.1 (45), id \(Self.build44). Pass version or the id."))
        #expect(!transport.requests.get().contains { $0.method != "GET" })
    }

    @Test func whatToTestIsChangedOrCreated() async throws {
        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let localizations = Locked(#"{"data":[{"type":"betaBuildLocalizations","id":"loc-45","attributes":{"whatToTest":"Old","locale":"en-US"}}],"links":{"self":"x"},"meta":{"paging":{"total":1,"limit":50}}}"#)
        let (connect, transport) = connect(store, allowChanges: true) { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/builds/\(Self.build45)"):
                Self.ok(#"{"data":{"type":"builds","id":"\#(Self.build45)","attributes":{"version":"45","processingState":"VALID"},"relationships":{"app":{"data":{"type":"apps","id":"1234567890"}}}}}"#)
            case ("GET", "/v1/builds/\(Self.build45)/betaBuildLocalizations"): Self.ok(localizations.get())
            case ("PATCH", _): Self.ok(#"{"data":{"type":"betaBuildLocalizations","id":"loc-45","attributes":{"whatToTest":"New","locale":"en-US"}}}"#)
            case ("POST", _): (201, #"{"data":{"type":"betaBuildLocalizations","id":"loc-new","attributes":{"whatToTest":"New","locale":"en-US"}}}"#, [:])
            default: Self.garden(request)
            }
        }
        let tools = tools(connect)
        let changed = try await call(tools, "appstore_set_what_to_test", ["app": "1234567890", "build": .string(Self.build45), "text": "Water a plant."])
        #expect(changed.text == "Set What to Test (en-US) of Pocket Garden build 45.", "\(changed.text)")
        let patch = try #require(transport.requests.get().last)
        #expect(patch.method == "PATCH")
        #expect(patch.path == "/v1/betaBuildLocalizations/loc-45")
        #expect(patch.body == ["data": ["type": "betaBuildLocalizations", "id": "loc-45", "attributes": ["whatToTest": "Water a plant."]]])

        // Without one, it is made in the app's primary language.
        localizations.set(#"{"data":[],"links":{"self":"x"},"meta":{"paging":{"total":0,"limit":50}}}"#)
        _ = try await call(tools, "appstore_set_what_to_test", ["app": "1234567890", "build": .string(Self.build45), "text": "Water a plant."])
        let post = try #require(transport.requests.get().last)
        #expect(post.method == "POST")
        #expect(post.path == "/v1/betaBuildLocalizations")
        #expect(post.body?["data"]?["attributes"] == ["locale": "en-US", "whatToTest": "Water a plant."])
        #expect(post.body?["data"]?["relationships"]?["build"]?["data"]?["id"] == .string(Self.build45))

        // A build of another app is refused.
        let other = try await call(tools, "appstore_set_what_to_test", ["app": "com.example.garden.pro", "build": .string(Self.build45), "text": "x"])
        #expect(other.isError && other.text.contains("belongs to another app"))
        let long = try await call(
            tools, "appstore_set_what_to_test", ["app": "1234567890", "build": "45", "text": .string(String(repeating: "a", count: 4001))])
        #expect(long.isError && long.text.contains("at most 4000"))
    }

    @Test func aReviewGetsAReply() async throws {
        let store = try keyStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let (connect, transport) = connect(store, allowChanges: true) { request in
            request.method == "POST" ? (201, Self.reply, [:]) : Self.garden(request)
        }
        let output = try await call(tools(connect), "appstore_reply_to_review", ["review": .string(Self.review1), "text": "Sorry! 1.2.1 fixes it."])
        #expect(output.text == "Replied to the 2-star review \"Crashes on launch\". Apple checks it before it appears on the App Store.")
        #expect(output.data?["response"]?["state"] == "PENDING_PUBLISH")
        let post = try #require(transport.requests.get().last)
        #expect(post.path == "/v1/customerReviewResponses")
        #expect(
            post.body == [
                "data": [
                    "type": "customerReviewResponses", "attributes": ["responseBody": "Sorry! 1.2.1 fixes it."],
                    "relationships": ["review": ["data": ["type": "customerReviews", "id": .string(Self.review1)]]],
                ]
            ])
    }
}
