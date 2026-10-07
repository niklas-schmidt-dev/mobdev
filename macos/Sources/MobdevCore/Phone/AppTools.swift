import Foundation

/// Developer tools: install, launch and stop apps, open links, read app output and crash reports.
/// They run through `PhoneBackend.apps`: `devicectl` for iPhones (Developer Mode and Xcode needed)
/// and simulators, adb for Android.
extension PhoneTools {
    static let appDefinitions: [ToolDefinition] = {
        let bundleID: JSONValue = [
            "type": "string", "description": "Bundle ID, e.g. com.example.MyApp, or the package name on Android",
        ]
        return [
            ToolDefinition(
                name: "list_apps", title: "List apps",
                description:
                    "Apps installed for development (from Xcode, install_app or adb) with bundle ID and version. all=true lists every app, including App Store and system apps. On an iPhone this needs Developer Mode.",
                inputSchema: schema(["all": ["type": "boolean"]], screenshot: false), readOnly: true),
            ToolDefinition(
                name: "install_app", title: "Install app",
                description:
                    "Install a build from a path on the Mac that runs Mobdev: for an iPhone an .app or .ipa built for devices (Debug-iphoneos), for a simulator an .app built for the simulator (Debug-iphonesimulator), for Android an .apk. Replaces an older build and keeps its data. On an iPhone this needs Developer Mode.",
                inputSchema: schema(
                    ["path": ["type": "string", "description": "Absolute path on the Mac"]], required: ["path"],
                    screenshot: false),
                readOnly: false),
            ToolDefinition(
                name: "uninstall_app", title: "Uninstall app",
                description:
                    "Remove an app installed for development, with its data. App Store and system apps are refused.",
                inputSchema: schema(["bundle_id": bundleID], required: ["bundle_id"], screenshot: false),
                readOnly: false),
            ToolDefinition(
                name: "launch_app", title: "Launch app",
                description:
                    "Launch an app by bundle ID and capture what it prints: print, NSLog and os_log lines, or its logcat lines on Android. Read them with logs. A running copy is restarted first unless restart is false. Android ignores arguments and environment.",
                inputSchema: schema(
                    [
                        "bundle_id": bundleID,
                        "arguments": ["type": "array", "items": ["type": "string"], "description": "Launch arguments"],
                        "environment": [
                            "type": "object", "additionalProperties": ["type": "string"],
                            "description": "Environment variables",
                        ],
                        "restart": ["type": "boolean", "description": "Stop a running copy first, default true"],
                    ], required: ["bundle_id"]),
                readOnly: false),
            ToolDefinition(
                name: "stop_app", title: "Stop app",
                description: "Stop a running app by bundle ID.",
                inputSchema: schema(["bundle_id": bundleID], required: ["bundle_id"]), readOnly: false),
            ToolDefinition(
                name: "open_url", title: "Open URL",
                description:
                    "Open a URL on the phone: a deep link such as myapp://settings, a universal link or a web page. When iOS asks \"Open in <app>?\" for a deep link and the device has a UI tree, Mobdev taps Open.",
                inputSchema: schema(["url": ["type": "string"]], required: ["url"]), readOnly: false),
            ToolDefinition(
                name: "logs", title: "App logs",
                description:
                    "Output of apps started with launch_app and whether each still runs, exited or crashed. Without after, the newest lines. Pass the cursor of the previous result as after to page through newer lines in order.",
                inputSchema: schema(
                    [
                        "bundle_id": bundleID,
                        "after": ["type": "integer", "minimum": 0, "description": "Only lines after this cursor"],
                        "lines": ["type": "integer", "minimum": 1, "maximum": 2000, "description": "At most, default 100"],
                        "contains": ["type": "string", "description": "Only lines containing this text"],
                    ], screenshot: false),
                readOnly: true),
            ToolDefinition(
                name: "crash_reports", title: "Crash reports",
                description:
                    "Crash and hang reports of the device, newest first, optionally for one app (name or bundle ID). Pass name to read one: exception, reason and the crashed thread. The full report is saved on the Mac. On an iPhone this needs Developer Mode.",
                inputSchema: schema(
                    [
                        "app": ["type": "string", "description": "App name or bundle ID"],
                        "name": ["type": "string", "description": "A report name from the list"],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Default 10"],
                    ], screenshot: false),
                readOnly: true),
        ]
    }()

    func runAppTool(_ name: String, _ args: Arguments) async throws -> ToolOutput {
        switch name {
        case "list_apps":
            let all = args.bool("all") ?? false
            let apps = try await requireApps().apps(all: all)
            guard !apps.isEmpty else {
                return ToolOutput(
                    text: all
                        ? "No apps."
                        : "No apps installed for development. Install one with install_app, or pass all: true to list every app.",
                    data: .array([]))
            }
            return ToolOutput(
                text: apps.map { "\($0.title): \($0.bundleID)" }.joined(separator: "\n"),
                data: .array(apps.map(\.json)))
        case "install_app":
            let apps = try requireApps()
            let path = try appPath(args.string("path"), for: apps.platform)
            let app = try await apps.install(at: path)
            return ToolOutput(
                text: "Installed \(app.title) as \(app.bundleID). Start it with launch_app.", data: app.json)
        case "uninstall_app":
            let app = try await requireApps().uninstall(try args.string("bundle_id"))
            return ToolOutput(text: "Removed \(app.title) (\(app.bundleID)) and its data.", data: app.json)
        case "launch_app":
            let bundleID = try args.string("bundle_id")
            let arguments = try args.stringArray("arguments")
            let environment = try args.stringDictionary("environment")
            let restart = args.bool("restart") ?? true
            let outcome = try await requireApps().launch(
                bundleID, arguments: arguments, environment: environment, restart: restart)
            switch outcome {
            case .broughtToFront:
                return ToolOutput(text: "\(bundleID) was already running with its output captured; brought it to the front.")
            case .launched where restart:
                return ToolOutput(text: "Launched \(bundleID). Its output is captured; read it with logs.")
            case .launched:
                return ToolOutput(
                    text:
                        "Launched \(bundleID). Its output is captured unless it was already running; pass restart: true to be sure.")
            }
        case "stop_app":
            let bundleID = try args.string("bundle_id")
            let stopped = try await requireApps().stop(bundleID)
            return ToolOutput(text: stopped ? "Stopped \(bundleID)." : "\(bundleID) was not running.")
        case "open_url":
            let text = try args.string("url")
            guard let url = URL(string: text), url.scheme != nil else {
                throw ToolFailure("url must be a full URL with a scheme, e.g. myapp://settings or https://example.com.")
            }
            try await requireApps().open(url)
            if await confirmOpenPrompt(for: url) {
                return ToolOutput(text: "Opened \(text). iOS asked whether to open it in the app; Mobdev tapped Open.")
            }
            return ToolOutput(text: "Opened \(text).")
        case "logs":
            return try readLogs(args)
        case "crash_reports":
            return try await crashReports(args)
        default:
            throw UnknownToolError(name: name)
        }
    }

    /// How long iOS gets to show "Open in “App”?" after a custom-scheme URL was opened from outside
    /// the app. GitHub's simulators show it, a developer's often does not, so the wait is short.
    static let openPromptWait: TimeInterval = 2.5

    /// Taps Open in iOS's "Open in “App”?" prompt when it appears for a custom URL scheme on a
    /// device with a UI tree. Left alone, the prompt stays over SpringBoard, hides the app from
    /// the tree and fails every later step. Web links open without one. True when it was tapped.
    private func confirmOpenPrompt(for url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https" else { return false }
        let deadline = Date().addingTimeInterval(Self.openPromptWait)
        while true {
            guard let tree = try? await phone.uiTree() else { return false }
            if let open = Self.openPromptButton(in: tree) {
                guard (try? requireTouch()) != nil, (try? await phone.tap(at: open.center, hold: 0.08)) != nil else { return false }
                // Until the prompt is gone, so the next step sees the app.
                let gone = Date().addingTimeInterval(Self.openPromptWait)
                while Date() < gone, let after = try? await phone.uiTree(), Self.openPromptButton(in: after) != nil {
                    try? await pause(0.25)
                }
                return true
            }
            if Date() >= deadline { return false }
            try? await pause(0.25)
        }
    }

    /// The prompt's Open button: a tappable "Open" next to a title that starts with "Open in".
    static func openPromptButton(in tree: [UIElement]) -> UIElement? {
        guard tree.contains(where: { ElementQuery.folded($0.label).hasPrefix("open in") }) else { return nil }
        return tree.first { $0.tappable && ElementQuery.folded($0.label) == "open" }
    }

    private func requireApps() throws -> AppBackend {
        guard let apps = phone.apps else {
            throw ToolFailure(
                "Tools for apps are not available for this device yet: Mobdev has not read its identity over USB. Reconnect the cable and unlock the iPhone.")
        }
        return apps
    }

    /// A build on this Mac that fits the device, checked before devicectl or adb sees it.
    private func appPath(_ text: String, for platform: AppPlatform) throws -> URL {
        let expanded = (text as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ToolFailure("path must be absolute: a location on the Mac that runs Mobdev.")
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let kind = url.pathExtension.lowercased()
        switch platform {
        case .iPhone:
            guard kind == "app" || kind == "ipa" else { throw ToolFailure("path must be an .app bundle or an .ipa file.") }
        case .simulator:
            guard kind == "app" else { throw ToolFailure("path must be an .app bundle built for the simulator.") }
        case .android:
            guard kind == "apk" else { throw ToolFailure("path must be an .apk file.") }
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolFailure("\(url.path) does not exist on this Mac.")
        }
        guard kind == "app", let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")),
            let platforms = info["CFBundleSupportedPlatforms"] as? [String]
        else { return url }
        if platform == .iPhone, platforms.contains("iPhoneSimulator") {
            throw ToolFailure(
                "\(url.lastPathComponent) is built for the Simulator. Build for a device, e.g. xcodebuild -scheme <scheme> -destination 'generic/platform=iOS' build, and install the app from Debug-iphoneos.")
        }
        if platform == .simulator, !platforms.contains("iPhoneSimulator") {
            throw ToolFailure(
                "\(url.lastPathComponent) is built for devices. Build for the simulator, e.g. xcodebuild -scheme <scheme> -destination 'generic/platform=iOS Simulator' build, and install the app from Debug-iphonesimulator.")
        }
        return url
    }

    private func readLogs(_ args: Arguments) throws -> ToolOutput {
        let logs = try requireApps().logs
        let app = args.has("bundle_id") ? try args.string("bundle_id") : nil
        // Converting Double(Int.max) back to Int would trap, so the range stays well inside Int.
        let after = args.has("after") ? Int(try args.number("after", default: 0, range: 0...1e15)) : nil
        let limit = Int(try args.number("lines", default: 100, range: 1...2000))
        let contains = args.has("contains") ? try args.string("contains") : nil
        let statuses = logs.statuses.filter { app == nil || $0.app == app }
        guard !statuses.isEmpty else {
            return ToolOutput(
                text: app.map { "No output captured for \($0). Launch it with launch_app to capture what it prints." }
                    ?? "No app output captured yet. Launch an app with launch_app to capture what it prints.",
                data: ["lines": .array([]), "cursor": 0, "apps": .array([])])
        }
        let page = logs.read(app: app, after: after, limit: limit, contains: contains)
        let labelled = app == nil && statuses.count > 1
        var text = statuses.map { "\($0.app): \($0.status)" }
        if page.dropped > 0 { text.append("\(page.dropped) older lines were dropped before you read them.") }
        text += page.lines.isEmpty
            ? ["No new lines."] : page.lines.map { labelled ? "[\($0.app)] \($0.text)" : $0.text }
        text.append(
            page.more
                ? "Cursor: \(page.cursor). More lines are waiting: call again with after \(page.cursor)."
                : "Cursor: \(page.cursor). Pass it as after to get only newer lines.")
        return ToolOutput(
            text: text.joined(separator: "\n"),
            data: [
                "lines": .array(
                    page.lines.map { ["n": .number(Double($0.number)), "app": .string($0.app), "text": .string($0.text)] }),
                "cursor": .number(Double(page.cursor)),
                "more": .bool(page.more),
                "dropped": .number(Double(page.dropped)),
                "apps": .array(statuses.map { ["bundle_id": .string($0.app), "status": .string($0.status)] }),
            ])
    }

    private func crashReports(_ args: Arguments) async throws -> ToolOutput {
        let apps = try requireApps()
        if args.has("name") {
            let (report, file) = try await apps.crashReport(named: try args.string("name"))
            let summary = report?.summary ?? "The report could not be parsed."
            return ToolOutput(
                text: summary + "\nFull report on the Mac: \(file.path)",
                data: ["report": report?.json ?? .null, "file": .string(file.path)])
        }
        let limit = Int(try args.number("limit", default: 10, range: 1...100))
        var reports = try await apps.crashReports()
        var filter: String?
        if args.has("app") {
            let query = try args.string("app")
            var needles = [query]
            // Reports are named after the executable, which is usually the bundle's folder name.
            if query.contains("."), let app = try? await apps.app(query) {
                needles.append(app.name)
                if let folder = app.location.flatMap(URL.init(string:))?.deletingPathExtension().lastPathComponent {
                    needles.append(folder)
                }
            }
            reports = reports.filter { report in
                needles.contains { report.process.localizedCaseInsensitiveContains($0) }
            }
            filter = query
        }
        let shown = Array(reports.prefix(limit))
        guard !shown.isEmpty else {
            return ToolOutput(text: "No crash reports\(filter.map { " for \($0)" } ?? "").", data: .array([]))
        }
        let dates = ISO8601DateFormatter()
        let lines = shown.map { report in
            "\(report.name)  \(report.date.map(dates.string(from:)) ?? "")  \(report.size) bytes"
        }
        return ToolOutput(
            text: (lines + ["Pass name to read one."]).joined(separator: "\n"),
            data: .array(
                shown.map { report in
                    [
                        "name": .string(report.name), "process": .string(report.process),
                        "date": report.date.map { .string(dates.string(from: $0)) } ?? .null,
                        "size": .number(Double(report.size)),
                    ]
                }))
    }
}

extension Arguments {
    /// An optional array of strings.
    func stringArray(_ key: String) throws -> [String] {
        guard has(key) else { return [] }
        guard let array = value[key]?.arrayValue else { throw ToolFailure("\(key) must be an array of strings.") }
        return try array.map { item in
            guard let string = item.stringValue else { throw ToolFailure("\(key) must be an array of strings.") }
            return string
        }
    }

    /// An optional object whose values are strings.
    func stringDictionary(_ key: String) throws -> [String: String] {
        guard has(key) else { return [:] }
        guard let object = value[key]?.objectValue else { throw ToolFailure("\(key) must be an object of strings.") }
        return try object.mapValues { item in
            guard let string = item.stringValue else { throw ToolFailure("\(key) values must be strings.") }
            return string
        }
    }
}
