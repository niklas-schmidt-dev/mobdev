import Foundation

/// An app in App Store Connect.
public struct AppStoreApp: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let sku: String
    public let primaryLocale: String

    init(_ resource: JSONAPIResource) {
        id = resource.id
        name = resource.string("name") ?? resource.id
        bundleID = resource.string("bundleId") ?? ""
        sku = resource.string("sku") ?? ""
        primaryLocale = resource.string("primaryLocale") ?? ""
    }

    public init(id: String, name: String, bundleID: String, sku: String = "", primaryLocale: String = "") {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.sku = sku
        self.primaryLocale = primaryLocale
    }

    var json: JSONValue {
        [
            "id": .string(id), "name": .string(name), "bundle_id": .string(bundleID), "sku": .string(sku),
            "primary_locale": .string(primaryLocale),
        ]
    }
}

/// An uploaded build with what TestFlight says about it.
public struct AppStoreBuild: Sendable, Equatable, Identifiable {
    public let id: String
    /// The build number, CFBundleVersion, such as 45.
    public let number: String
    /// The version it belongs to, CFBundleShortVersionString, such as 1.2.
    public let version: String?
    /// IOS, MAC_OS, TV_OS or VISION_OS.
    public let platform: String?
    /// PROCESSING, FAILED, INVALID or VALID.
    public let processingState: String
    public let uploaded: Date?
    public let expires: Date?
    public let expired: Bool
    public let minimumOSVersion: String?
    /// TestFlight for the team's own testers, such as IN_BETA_TESTING or MISSING_EXPORT_COMPLIANCE.
    public let internalState: String?
    /// TestFlight for external testers, such as READY_FOR_BETA_SUBMISSION or IN_BETA_REVIEW.
    public let externalState: String?
    /// Beta app review: WAITING_FOR_REVIEW, IN_REVIEW, REJECTED or APPROVED.
    public let betaReviewState: String?
    /// "What to Test" by locale.
    public let whatToTest: [String: String]

    init(_ resource: JSONAPIResource, in document: JSONAPIDocument) {
        id = resource.id
        number = resource.string("version") ?? ""
        let release = document.related(resource, "preReleaseVersion").first
        version = release?.string("version")
        platform = release?.string("platform")
        processingState = resource.string("processingState") ?? ""
        uploaded = resource.date("uploadedDate")
        expires = resource.date("expirationDate")
        expired = resource.bool("expired") ?? false
        minimumOSVersion = resource.string("minOsVersion")
        let detail = document.related(resource, "buildBetaDetail").first
        internalState = detail?.string("internalBuildState")
        externalState = detail?.string("externalBuildState")
        betaReviewState = document.related(resource, "betaAppReviewSubmission").first?.string("betaReviewState")
        var notes: [String: String] = [:]
        for localization in document.related(resource, "betaBuildLocalizations") {
            if let locale = localization.string("locale") { notes[locale] = localization.string("whatToTest") ?? "" }
        }
        whatToTest = notes
    }

    /// "1.2 (45)", or "45" while the version is unknown.
    public var title: String { version.map { "\($0) (\(number))" } ?? number }

    var json: JSONValue {
        [
            "id": .string(id), "build_number": .string(number), "version": version.map(JSONValue.string) ?? .null,
            "platform": platform.map(JSONValue.string) ?? .null, "processing_state": .string(processingState),
            "uploaded": uploaded.map { .string($0.ISO8601Format()) } ?? .null,
            "expires": expires.map { .string($0.ISO8601Format()) } ?? .null, "expired": .bool(expired),
            "min_os_version": minimumOSVersion.map(JSONValue.string) ?? .null,
            "internal_state": internalState.map(JSONValue.string) ?? .null,
            "external_state": externalState.map(JSONValue.string) ?? .null,
            "beta_review_state": betaReviewState.map(JSONValue.string) ?? .null,
            "what_to_test": .object(whatToTest.mapValues(JSONValue.string)),
        ]
    }
}

/// A TestFlight group of testers and the builds it gets.
public struct AppStoreBetaGroup: Sendable, Equatable, Identifiable {
    public struct Build: Sendable, Equatable, Identifiable {
        public let id: String
        public let number: String
        public let uploaded: Date?
        public let expired: Bool
    }

    public let id: String
    public let name: String
    /// The team's own testers (App Store Connect users) rather than external ones.
    public let isInternal: Bool
    /// Nil when App Store Connect did not say.
    public let testerCount: Int?
    public let publicLink: String?
    /// The group's builds, newest first.
    public let builds: [Build]

    init(_ resource: JSONAPIResource, in document: JSONAPIDocument) {
        id = resource.id
        name = resource.string("name") ?? resource.id
        isInternal = resource.bool("isInternalGroup") ?? false
        let testers = resource.relationships["betaTesters"]
        testerCount = testers.map { $0.total ?? $0.identifiers.count }
        publicLink = resource.bool("publicLinkEnabled") == true ? resource.string("publicLink") : nil
        builds = document.related(resource, "builds")
            .map { Build(id: $0.id, number: $0.string("version") ?? "", uploaded: $0.date("uploadedDate"), expired: $0.bool("expired") ?? false) }
            .sorted { ($0.uploaded ?? .distantPast) > ($1.uploaded ?? .distantPast) }
    }

    var json: JSONValue {
        [
            "id": .string(id), "name": .string(name), "internal": .bool(isInternal),
            "testers": testerCount.map { JSONValue($0) } ?? .null, "public_link": publicLink.map(JSONValue.string) ?? .null,
            "builds": .array(builds.map {
                [
                    "id": .string($0.id), "build_number": .string($0.number),
                    "uploaded": $0.uploaded.map { .string($0.ISO8601Format()) } ?? .null, "expired": .bool($0.expired),
                ]
            }),
        ]
    }
}

/// A version on the App Store, from being prepared to being for sale.
public struct AppStoreVersion: Sendable, Equatable, Identifiable {
    public struct PhasedRelease: Sendable, Equatable {
        /// INACTIVE, ACTIVE, PAUSED or COMPLETE.
        public let state: String
        public let started: Date?
        /// Which of the seven days it is in.
        public let day: Int?
    }

    public let id: String
    public let version: String
    public let platform: String
    /// Such as PREPARE_FOR_SUBMISSION, WAITING_FOR_REVIEW, IN_REVIEW, REJECTED or READY_FOR_SALE.
    public let state: String
    /// MANUAL, AFTER_APPROVAL or SCHEDULED.
    public let releaseType: String?
    public let earliestRelease: Date?
    public let created: Date?
    public let phasedRelease: PhasedRelease?
    /// The build number chosen for it.
    public let build: String?

    init(_ resource: JSONAPIResource, in document: JSONAPIDocument) {
        id = resource.id
        version = resource.string("versionString") ?? ""
        platform = resource.string("platform") ?? ""
        // appStoreState is the long-standing field with READY_FOR_SALE; newer answers may carry
        // only appVersionState.
        state = resource.string("appStoreState") ?? resource.string("appVersionState") ?? ""
        releaseType = resource.string("releaseType")
        earliestRelease = resource.date("earliestReleaseDate")
        created = resource.date("createdDate")
        phasedRelease = document.related(resource, "appStoreVersionPhasedRelease").first.map {
            PhasedRelease(state: $0.string("phasedReleaseState") ?? "", started: $0.date("startDate"), day: $0.int("currentDayNumber"))
        }
        build = document.related(resource, "build").first?.string("version")
    }

    var json: JSONValue {
        [
            "id": .string(id), "version": .string(version), "platform": .string(platform), "state": .string(state),
            "release_type": releaseType.map(JSONValue.string) ?? .null,
            "earliest_release": earliestRelease.map { .string($0.ISO8601Format()) } ?? .null,
            "created": created.map { .string($0.ISO8601Format()) } ?? .null,
            "phased_release": phasedRelease.map {
                ["state": .string($0.state), "started": $0.started.map { .string($0.ISO8601Format()) } ?? .null, "day": $0.day.map { JSONValue($0) } ?? .null]
            } ?? .null,
            "build_number": build.map(JSONValue.string) ?? .null,
        ]
    }
}

/// A customer review and the developer's reply to it.
public struct AppStoreReview: Sendable, Equatable, Identifiable {
    public struct Response: Sendable, Equatable {
        public let id: String
        public let body: String
        /// PUBLISHED or PENDING_PUBLISH.
        public let state: String
        public let modified: Date?

        init(_ resource: JSONAPIResource) {
            id = resource.id
            body = resource.string("responseBody") ?? ""
            state = resource.string("state") ?? ""
            modified = resource.date("lastModifiedDate")
        }

        var json: JSONValue {
            [
                "id": .string(id), "body": .string(body), "state": .string(state),
                "modified": modified.map { .string($0.ISO8601Format()) } ?? .null,
            ]
        }
    }

    public let id: String
    public let rating: Int
    public let title: String
    public let body: String
    /// The nickname shown with the review on the App Store.
    public let reviewer: String
    /// The App Store country, such as USA or DEU.
    public let territory: String
    public let created: Date?
    public let response: Response?

    init(_ resource: JSONAPIResource, in document: JSONAPIDocument) {
        id = resource.id
        rating = resource.int("rating") ?? 0
        title = resource.string("title") ?? ""
        body = resource.string("body") ?? ""
        reviewer = resource.string("reviewerNickname") ?? ""
        territory = resource.string("territory") ?? ""
        created = resource.date("createdDate")
        response = document.related(resource, "response").first.map(Response.init)
    }

    var json: JSONValue {
        [
            "id": .string(id), "rating": JSONValue(rating), "title": .string(title), "body": .string(body),
            "reviewer": .string(reviewer), "territory": .string(territory),
            "created": created.map { .string($0.ISO8601Format()) } ?? .null, "response": response?.json ?? .null,
        ]
    }
}

// MARK: Reading and changing

extension AppStoreConnect {
    static let buildIncludes = "preReleaseVersion,buildBetaDetail,betaAppReviewSubmission,betaBuildLocalizations"

    /// The apps the key can see, by name.
    public func apps(limit: Int = 200) async throws -> [AppStoreApp] {
        let document = try await list(
            "/v1/apps", ["sort": "name", "fields[apps]": "name,bundleId,sku,primaryLocale"], limit: limit)
        return document.data.map(AppStoreApp.init)
    }

    /// How many apps the key can see, for Test Connection.
    public func appCount() async throws -> Int {
        let document = try await list("/v1/apps", ["fields[apps]": "name"], limit: 200)
        return document.total ?? document.data.count
    }

    /// An app by its App Store Connect ID (digits) or its bundle ID.
    public func app(matching query: String) async throws -> AppStoreApp {
        let query = query.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty, query.allSatisfy(\.isASCII), query.allSatisfy(\.isNumber) {
            do {
                guard let document = try await send("GET", url("/v1/apps/\(query)")), let resource = document.data.first else {
                    throw AppStoreError.notFound("")
                }
                return AppStoreApp(resource)
            } catch AppStoreError.notFound {
                throw AppStoreError.notFound("No app with the App Store Connect ID \(query) for this key.")
            }
        }
        let document = try await list("/v1/apps", ["filter[bundleId]": query], limit: 50)
        // The filter also matches longer bundle IDs; only the exact one counts.
        guard let resource = document.data.first(where: { $0.string("bundleId")?.caseInsensitiveCompare(query) == .orderedSame })
        else { throw AppStoreError.notFound("No app with the bundle ID \(query) for this key.") }
        return AppStoreApp(resource)
    }

    /// An app's builds, newest first; `version` keeps those of one version such as 1.2, `number`
    /// those with one build number.
    public func builds(app: String, version: String? = nil, number: String? = nil, limit: Int = 20) async throws -> [AppStoreBuild] {
        var query = ["filter[app]": app, "sort": "-uploadedDate", "include": Self.buildIncludes]
        if let version { query["filter[preReleaseVersion.version]"] = version }
        if let number { query["filter[version]"] = number }
        let document = try await list("/v1/builds", query, limit: limit)
        return document.data.map { AppStoreBuild($0, in: document) }
    }

    /// One build by its App Store Connect ID, with the app it belongs to.
    public func build(id: String) async throws -> (build: AppStoreBuild, app: String?) {
        let include = Self.buildIncludes + ",app"
        guard let document = try await send("GET", url("/v1/builds/\(id)", ["include": include])),
            let resource = document.data.first
        else { throw AppStoreError.notFound("No build \(id).") }
        return (AppStoreBuild(resource, in: document), resource.relationships["app"]?.identifiers.first?.id)
    }

    /// An app's TestFlight groups with their tester counts and builds.
    public func betaGroups(app: String) async throws -> [AppStoreBetaGroup] {
        let document = try await list(
            "/v1/betaGroups",
            [
                "filter[app]": app, "include": "builds,betaTesters", "limit[builds]": "50", "limit[betaTesters]": "50",
                // Testers are only counted: their names and addresses stay in App Store Connect.
                "fields[betaTesters]": "inviteType", "fields[builds]": "version,uploadedDate,expired",
            ], limit: 200)
        return document.data.map { AppStoreBetaGroup($0, in: document) }
            .sorted { ($0.isInternal ? 0 : 1, $0.name.lowercased()) < ($1.isInternal ? 0 : 1, $1.name.lowercased()) }
    }

    /// An app's App Store versions, newest first.
    public func versions(app: String, limit: Int = 20) async throws -> [AppStoreVersion] {
        let document = try await list(
            "/v1/apps/\(app)/appStoreVersions", ["include": "appStoreVersionPhasedRelease,build"], limit: limit)
        return document.data.map { AppStoreVersion($0, in: document) }
            .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    /// An app's customer reviews, newest first. `unanswered` keeps those without a published reply.
    public func reviews(
        app: String, rating: Int? = nil, territory: String? = nil, unanswered: Bool = false, limit: Int = 20
    ) async throws -> [AppStoreReview] {
        var query = ["sort": "-createdDate", "include": "response"]
        if let rating { query["filter[rating]"] = String(rating) }
        if let territory { query["filter[territory]"] = territory.uppercased() }
        if unanswered { query["exists[publishedResponse]"] = "false" }
        let document = try await list("/v1/apps/\(app)/customerReviews", query, limit: limit)
        return document.data.map { AppStoreReview($0, in: document) }
    }

    public func review(id: String) async throws -> AppStoreReview {
        guard let document = try await send("GET", url("/v1/customerReviews/\(id)", ["include": "response"])),
            let resource = document.data.first
        else { throw AppStoreError.notFound("No review \(id).") }
        return AppStoreReview(resource, in: document)
    }

    /// Gives a TestFlight group a build. External groups' testers get it after beta app review.
    public func addBuild(_ build: String, toGroup group: String) async throws {
        try await send(
            "POST", url("/v1/betaGroups/\(group)/relationships/builds"),
            body: ["data": [["type": "builds", "id": .string(build)]]])
    }

    /// Sets a build's "What to Test" for one locale, creating the text when the build has none for it.
    public func setWhatToTest(build: String, locale: String, text: String) async throws {
        let existing = try await list("/v1/builds/\(build)/betaBuildLocalizations", [:], limit: 50)
        if let localization = existing.data.first(where: { $0.string("locale")?.caseInsensitiveCompare(locale) == .orderedSame }) {
            try await send(
                "PATCH", url("/v1/betaBuildLocalizations/\(localization.id)"),
                body: [
                    "data": [
                        "type": "betaBuildLocalizations", "id": .string(localization.id), "attributes": ["whatToTest": .string(text)],
                    ]
                ])
        } else {
            try await send(
                "POST", url("/v1/betaBuildLocalizations"),
                body: [
                    "data": [
                        "type": "betaBuildLocalizations",
                        "attributes": ["locale": .string(locale), "whatToTest": .string(text)],
                        "relationships": ["build": ["data": ["type": "builds", "id": .string(build)]]],
                    ]
                ])
        }
    }

    /// The locales a build has "What to Test" in.
    public func whatToTestLocales(build: String) async throws -> [String] {
        try await list("/v1/builds/\(build)/betaBuildLocalizations", [:], limit: 50).data.compactMap { $0.string("locale") }
    }

    /// Replies to a review, replacing an earlier reply. Apple publishes it after a check.
    @discardableResult
    public func reply(toReview review: String, text: String) async throws -> AppStoreReview.Response {
        let answer = try await send(
            "POST", url("/v1/customerReviewResponses"),
            body: [
                "data": [
                    "type": "customerReviewResponses", "attributes": ["responseBody": .string(text)],
                    "relationships": ["review": ["data": ["type": "customerReviews", "id": .string(review)]]],
                ]
            ])
        guard let resource = answer?.data.first else { throw AppStoreError.invalidResponse("no reply in the answer") }
        return AppStoreReview.Response(resource)
    }
}
