import Foundation

/// The App Store Connect tools: what agents read about the user's apps (builds, TestFlight,
/// versions, reviews) and the few changes they may make once the user allows it. They work with
/// the key stored on this Mac, not a device, like the project tools.
enum AppStoreTools {
    static let writeTools: Set<String> = ["appstore_add_build_to_group", "appstore_set_what_to_test", "appstore_reply_to_review"]
    /// Apple's limit for a reply to a review.
    static let maxReplyLength = 5970
    /// Apple's limit for a build's What to Test.
    static let maxWhatToTestLength = 4000

    static let definitions: [ToolDefinition] = {
        let app: JSONValue = [
            "type": "string",
            "description":
                "The app: its bundle ID, such as com.example.MyApp, or its App Store Connect app ID (digits). Default the active project's bundle ID (list_projects), else the only app",
        ]
        let limit: JSONValue = ["type": "integer", "description": "At most this many, newest first; default 20, at most 200"]
        let build: JSONValue = [
            "type": "string",
            "description": "The build: its build number (CFBundleVersion, such as 45) or its id from appstore_builds",
        ]
        let version: JSONValue = [
            "type": "string", "description": "The version (CFBundleShortVersionString, such as 1.2), when a build number repeats across versions",
        ]
        func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
            PhoneTools.schema(properties, required: required, screenshot: false)
        }
        let allowed =
            " It changes real App Store Connect data, so it works only when the user turned on \"Agents may change App Store Connect\" in Mobdev's Settings › App Store Connect; confirm with the user first."
        return [
            ToolDefinition(
                name: "appstore_apps", title: "App Store Connect apps",
                description:
                    "The apps in the user's App Store Connect team: name, bundle ID, App Store Connect app ID, SKU and primary language. Uses the API key the user stored in Mobdev's Settings › App Store Connect; the key itself is never shown.",
                inputSchema: schema([:]), readOnly: true),
            ToolDefinition(
                name: "appstore_builds", title: "App Store Connect builds",
                description:
                    "An app's uploaded builds, newest first: version and build number, platform, processing state (PROCESSING, VALID, INVALID, FAILED), upload date, expiry, TestFlight state for internal and external testers, beta app review state, What to Test, and the build's id.",
                inputSchema: schema([
                    "app": app, "version": ["type": "string", "description": "Only builds of this version, such as 1.2"],
                    "limit": limit,
                ]), readOnly: true),
            ToolDefinition(
                name: "appstore_testflight", title: "TestFlight groups",
                description:
                    "An app's TestFlight groups: name, internal or external, how many testers, the public link if it is on, and the builds each group gets. Testers' names and addresses are not read.",
                inputSchema: schema(["app": app]), readOnly: true),
            ToolDefinition(
                name: "appstore_versions", title: "App Store versions",
                description:
                    "An app's App Store versions, newest first: version, platform, state (such as PREPARE_FOR_SUBMISSION, WAITING_FOR_REVIEW, IN_REVIEW, REJECTED, PENDING_DEVELOPER_RELEASE, READY_FOR_SALE), the chosen build, release type and phased release.",
                inputSchema: schema(["app": app, "limit": limit]), readOnly: true),
            ToolDefinition(
                name: "appstore_reviews", title: "Customer reviews",
                description:
                    "An app's customer reviews on the App Store, newest first: rating, title, text, reviewer's nickname, country, date, the review's id and the developer's reply with its state.",
                inputSchema: schema([
                    "app": app,
                    "rating": ["type": "integer", "description": "Only reviews with this many stars, 1 to 5"],
                    "territory": ["type": "string", "description": "Only reviews from this App Store country, such as USA or DEU"],
                    "unanswered": ["type": "boolean", "description": "Only reviews without a published reply"],
                    "limit": limit,
                ]), readOnly: true),
            ToolDefinition(
                name: "appstore_add_build_to_group", title: "Add build to TestFlight group",
                description:
                    "Give a TestFlight group a build, so its testers can install it. External groups get it once the build passed beta app review." + allowed,
                inputSchema: schema(
                    [
                        "app": app, "build": build, "version": version,
                        "group": ["type": "string", "description": "The group's name or id from appstore_testflight"],
                    ], required: ["build", "group"]), readOnly: false),
            ToolDefinition(
                name: "appstore_set_what_to_test", title: "Set What to Test",
                description:
                    "Set the \"What to Test\" text TestFlight shows testers for a build, replacing the text in that language." + allowed,
                inputSchema: schema(
                    [
                        "app": app, "build": build, "version": version,
                        "text": ["type": "string", "description": "What testers should try, at most 4000 characters"],
                        "locale": [
                            "type": "string",
                            "description": "The language, such as en-US; default the build's only one, else the app's primary language",
                        ],
                    ], required: ["build", "text"]), readOnly: false),
            ToolDefinition(
                name: "appstore_reply_to_review", title: "Reply to review",
                description:
                    "Reply to a customer review, or replace your earlier reply. Apple checks a reply before it appears on the App Store." + allowed,
                inputSchema: schema(
                    [
                        "review": ["type": "string", "description": "The review's id from appstore_reviews"],
                        "text": ["type": "string", "description": "The reply, at most 5970 characters"],
                    ], required: ["review", "text"]), readOnly: false),
        ]
    }()

    static func isAppStoreTool(_ name: String) -> Bool { definitions.contains { $0.name == name } }

    /// Runs a tool; App Store Connect's errors become tool errors the agent can read.
    static func call(_ name: String, _ args: Arguments, connect: AppStoreConnect, projects: ProjectList, source: String) async
        -> ToolOutput
    {
        do {
            if writeTools.contains(name), !connect.agentChangesAllowed() {
                throw ToolFailure(
                    "Agents may not change App Store Connect on this Mac. The user can allow it with \"Agents may change App Store Connect\" in Mobdev's Settings › App Store Connect, or make the change in Mobdev's App Store Connect pages.")
            }
            let output = try await run(name, args, connect: connect, projects: projects)
            if writeTools.contains(name) { Log.info("App Store Connect, \(name) from \(source): \(output.text)") }
            return output
        } catch let failure as ToolFailure {
            return ToolOutput(text: failure.description, isError: true)
        } catch let error as AppStoreError {
            return ToolOutput(text: error.description, isError: true)
        } catch is CancellationError {
            return ToolOutput(text: "Cancelled.", isError: true)
        } catch {
            return ToolOutput(text: "App Store Connect: \(error.localizedDescription)", isError: true)
        }
    }

    private static func run(_ name: String, _ args: Arguments, connect: AppStoreConnect, projects: ProjectList) async throws
        -> ToolOutput
    {
        switch name {
        case "appstore_apps":
            let apps = try await connect.apps()
            guard !apps.isEmpty else { return ToolOutput(text: "The key sees no apps.", data: .array([])) }
            return ToolOutput(
                text: apps.map { "\($0.name): \($0.bundleID), app ID \($0.id)\($0.sku.isEmpty ? "" : ", SKU \($0.sku)")" }
                    .joined(separator: "\n"),
                data: .array(apps.map(\.json)))
        case "appstore_builds":
            let app = try await resolveApp(args, connect: connect, projects: projects)
            let version = args.has("version") ? try args.string("version") : nil
            let builds = try await connect.builds(app: app.id, version: version, limit: try limit(args))
            let heading = "\(app.name) (\(app.bundleID)), builds\(version.map { " of \($0)" } ?? "") newest first:"
            guard !builds.isEmpty else {
                return ToolOutput(text: "\(app.name) has no builds\(version.map { " of \($0)" } ?? "").", data: ["app": app.json, "builds": []])
            }
            return ToolOutput(
                text: ([heading] + builds.map(describe)).joined(separator: "\n"),
                data: ["app": app.json, "builds": .array(builds.map(\.json))])
        case "appstore_testflight":
            let app = try await resolveApp(args, connect: connect, projects: projects)
            let groups = try await connect.betaGroups(app: app.id)
            guard !groups.isEmpty else {
                return ToolOutput(text: "\(app.name) has no TestFlight groups.", data: ["app": app.json, "groups": []])
            }
            return ToolOutput(
                text: (["\(app.name) (\(app.bundleID)), TestFlight groups:"] + groups.map(describe)).joined(separator: "\n"),
                data: ["app": app.json, "groups": .array(groups.map(\.json))])
        case "appstore_versions":
            let app = try await resolveApp(args, connect: connect, projects: projects)
            let versions = try await connect.versions(app: app.id, limit: try limit(args))
            guard !versions.isEmpty else {
                return ToolOutput(text: "\(app.name) has no App Store versions yet.", data: ["app": app.json, "versions": []])
            }
            return ToolOutput(
                text: (["\(app.name) (\(app.bundleID)), App Store versions newest first:"] + versions.map(describe)).joined(separator: "\n"),
                data: ["app": app.json, "versions": .array(versions.map(\.json))])
        case "appstore_reviews":
            let app = try await resolveApp(args, connect: connect, projects: projects)
            let rating = args.has("rating") ? Int(try args.number("rating", default: 5, range: 1...5)) : nil
            let territory = args.has("territory") ? try args.string("territory", maxLength: 3) : nil
            let unanswered = args.bool("unanswered") ?? false
            let reviews = try await connect.reviews(
                app: app.id, rating: rating, territory: territory, unanswered: unanswered, limit: try limit(args))
            guard !reviews.isEmpty else {
                return ToolOutput(text: "No reviews of \(app.name) match.", data: ["app": app.json, "reviews": []])
            }
            return ToolOutput(
                text: (["\(app.name) (\(app.bundleID)), reviews newest first:"] + reviews.map(describe)).joined(separator: "\n\n"),
                data: ["app": app.json, "reviews": .array(reviews.map(\.json))])
        case "appstore_add_build_to_group":
            let app = try await resolveApp(args, connect: connect, projects: projects)
            let groupQuery = try args.string("group")
            let build = try await resolveBuild(args, app: app, connect: connect)
            let groups = try await connect.betaGroups(app: app.id)
            guard
                let group = groups.first(where: { $0.id == groupQuery })
                    ?? groups.first(where: { $0.name.caseInsensitiveCompare(groupQuery) == .orderedSame })
            else {
                throw ToolFailure(
                    "\(app.name) has no TestFlight group \"\(groupQuery)\". Groups: \(groups.isEmpty ? "none" : groups.map(\.name).joined(separator: ", ")).")
            }
            if group.builds.contains(where: { $0.id == build.id }) {
                return ToolOutput(text: "The group \(group.name) has build \(build.title) already.", data: ["build": build.json, "group": group.json])
            }
            try await connect.addBuild(build.id, toGroup: group.id)
            return ToolOutput(
                text: "Added build \(build.title) to the TestFlight group \(group.name)."
                    + (group.isInternal ? "" : " External testers get it once the build passed beta app review."),
                data: ["build": build.json, "group": ["id": .string(group.id), "name": .string(group.name)]])
        case "appstore_set_what_to_test":
            let app = try await resolveApp(args, connect: connect, projects: projects)
            let text = try args.string("text", maxLength: maxWhatToTestLength)
            let build = try await resolveBuild(args, app: app, connect: connect)
            let locale: String
            if args.has("locale") {
                locale = try args.string("locale", maxLength: 20)
            } else {
                let existing = try await connect.whatToTestLocales(build: build.id)
                if existing.count == 1 {
                    locale = existing[0]
                } else if existing.isEmpty {
                    locale = app.primaryLocale.isEmpty ? "en-US" : app.primaryLocale
                } else {
                    throw ToolFailure("Build \(build.title) has What to Test in \(existing.joined(separator: ", ")). Pass locale.")
                }
            }
            try await connect.setWhatToTest(build: build.id, locale: locale, text: text)
            return ToolOutput(
                text: "Set What to Test (\(locale)) of \(app.name) build \(build.title).",
                data: ["build": build.json, "locale": .string(locale)])
        case "appstore_reply_to_review":
            let id = try args.string("review", maxLength: 100)
            let text = try args.string("text", maxLength: maxReplyLength)
            let review = try await connect.review(id: id)
            let response = try await connect.reply(toReview: review.id, text: text)
            let replaced = review.response != nil
            return ToolOutput(
                text: "\(replaced ? "Replaced the reply to" : "Replied to") the \(review.rating)-star review \"\(review.title)\". "
                    + (response.state == "PUBLISHED" ? "It is on the App Store." : "Apple checks it before it appears on the App Store."),
                data: ["review": review.json, "response": response.json])
        default:
            throw UnknownToolError(name: name)
        }
    }

    private static func limit(_ args: Arguments) throws -> Int {
        Int(try args.number("limit", default: 20, range: 1...200))
    }

    /// The app a call means: the `app` argument, else the current project's bundle ID, else the only app.
    static func resolveApp(_ args: Arguments, connect: AppStoreConnect, projects: ProjectList) async throws -> AppStoreApp {
        if args.has("app") { return try await connect.app(matching: try args.string("app", maxLength: 200)) }
        if let folder = projects.current(), let project = try? TestProject.load(folder), let bundleID = project.app.bundleID {
            do {
                return try await connect.app(matching: bundleID)
            } catch AppStoreError.notFound {
                throw ToolFailure(
                    "The project \(project.name) is for \(bundleID), which is not in this App Store Connect team. Pass app: a bundle ID or app ID from appstore_apps.")
            }
        }
        let apps = try await connect.apps()
        if apps.count == 1 { return apps[0] }
        guard !apps.isEmpty else { throw ToolFailure("The key sees no apps in App Store Connect.") }
        let names = apps.prefix(20).map { "\($0.name) (\($0.bundleID))" }.joined(separator: ", ")
        throw ToolFailure("Pass app: a bundle ID or app ID. Apps: \(names)\(apps.count > 20 ? ", …" : "").")
    }

    /// The build a call means: an id, or a build number with an optional version.
    static func resolveBuild(_ args: Arguments, app: AppStoreApp, connect: AppStoreConnect) async throws -> AppStoreBuild {
        let query = try args.string("build", maxLength: 100)
        if UUID(uuidString: query) != nil {
            let (build, owner) = try await connect.build(id: query)
            if let owner, owner != app.id { throw ToolFailure("Build \(query) belongs to another app than \(app.name).") }
            return build
        }
        let version = args.has("version") ? try args.string("version", maxLength: 50) : nil
        let builds = try await connect.builds(app: app.id, version: version, number: query, limit: 20)
        if builds.count == 1 { return builds[0] }
        guard !builds.isEmpty else {
            throw ToolFailure("\(app.name) has no build \(query)\(version.map { " of version \($0)" } ?? ""). appstore_builds lists them.")
        }
        throw ToolFailure(
            "\(app.name) has several builds \(query): \(builds.map { "\($0.title), id \($0.id)" }.joined(separator: "; ")). Pass version or the id.")
    }

    // MARK: Text

    static func describe(_ build: AppStoreBuild) -> String {
        var parts = ["\(build.title)\(build.platform.map { ", \(AppStoreFormat.platform($0))" } ?? ""): \(build.processingState)"]
        if let uploaded = build.uploaded { parts.append("uploaded \(AppStoreFormat.minute(uploaded))") }
        if build.expired {
            parts.append("expired")
        } else if let expires = build.expires {
            parts.append("expires \(AppStoreFormat.day(expires))")
        }
        var testFlight: [String] = []
        if let state = build.internalState { testFlight.append("internal \(state)") }
        if let state = build.externalState { testFlight.append("external \(state)") }
        if let state = build.betaReviewState { testFlight.append("beta review \(state)") }
        if !testFlight.isEmpty { parts.append("TestFlight: " + testFlight.joined(separator: ", ")) }
        var line = parts.joined(separator: ", ") + ". id: \(build.id)"
        for (locale, text) in build.whatToTest.sorted(by: { $0.key < $1.key }) where !text.isEmpty {
            line += "\n  What to Test (\(locale)): \(text.replacingOccurrences(of: "\n", with: " "))"
        }
        return line
    }

    static func describe(_ group: AppStoreBetaGroup) -> String {
        var parts = ["\(group.name) (\(group.isInternal ? "internal" : "external"))"]
        if let count = group.testerCount { parts.append("\(count) tester\(count == 1 ? "" : "s")") }
        if let link = group.publicLink { parts.append("public link \(link)") }
        let builds = group.builds.filter { !$0.expired }.prefix(5).map(\.number)
        parts.append(builds.isEmpty ? "no current builds" : "builds \(builds.joined(separator: ", "))")
        return parts.joined(separator: ", ") + ". id: \(group.id)"
    }

    static func describe(_ version: AppStoreVersion) -> String {
        var parts = ["\(version.version), \(AppStoreFormat.platform(version.platform)): \(version.state)"]
        if let build = version.build { parts.append("build \(build)") }
        switch version.releaseType {
        case "MANUAL": parts.append("released by hand")
        case "AFTER_APPROVAL": parts.append("released after approval")
        case "SCHEDULED": parts.append("scheduled\(version.earliestRelease.map { " for \(AppStoreFormat.minute($0))" } ?? "")")
        default: break
        }
        if let phased = version.phasedRelease, phased.state != "INACTIVE" {
            parts.append("phased release \(phased.state)\(phased.day.map { ", day \($0) of 7" } ?? "")")
        }
        if let created = version.created { parts.append("created \(AppStoreFormat.day(created))") }
        return parts.joined(separator: ", ") + ". id: \(version.id)"
    }

    static func describe(_ review: AppStoreReview) -> String {
        var meta = [review.territory]
        if let created = review.created { meta.append(AppStoreFormat.day(created)) }
        if !review.reviewer.isEmpty { meta.append("by \(review.reviewer)") }
        var lines = [
            "\(review.rating)/5 \"\(review.title)\" (\(meta.filter { !$0.isEmpty }.joined(separator: ", "))). id: \(review.id)",
            review.body,
        ]
        if let response = review.response {
            let state = response.state == "PUBLISHED" ? "published" : "waiting for Apple"
            lines.append("Reply (\(state)\(response.modified.map { ", \(AppStoreFormat.day($0))" } ?? "")): \(response.body)")
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
