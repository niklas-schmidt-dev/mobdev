import CoreGraphics
import Foundation
import ImageIO

/// A map of an app's screens, made by `crawl_app` and used by `navigate_to`: every screen found,
/// how to reach it from a fresh launch, and the taps between screens.
public struct AppMap: Sendable, Codable, Equatable {
    public struct Screen: Sendable, Codable, Equatable {
        /// "s1", "s2", … in the order they were found.
        public var id: String
        /// What tells this screen apart: a hash of what can be tapped and the headings.
        public var signature: String
        /// The heading or first text, to name the screen.
        public var title: String
        /// What can be tapped on it, as `Button "Save" id=save`.
        public var elements: [String]
        /// The steps from a fresh launch to this screen.
        public var path: [JSONValue]
        public var depth: Int
        /// The screenshot's file name in the crawl's folder.
        public var screenshot: String?
    }

    public struct Edge: Sendable, Codable, Equatable {
        public var from: String
        /// A screen id, or "outside: <app>" when the tap left the app.
        public var to: String
        public var step: JSONValue
    }

    public struct Crash: Sendable, Codable, Equatable {
        /// The screen the tap was on.
        public var screen: String
        /// From a fresh launch to the crash.
        public var steps: [JSONValue]
        /// How the app ended, from its log status.
        public var status: String
        public var screenshot: String?
        /// The flow file that reproduces it.
        public var flow: String?
    }

    public var app: String
    public var device: String
    public var started: Date
    public var seconds: Double
    public var actions: Int
    public var screens: [Screen]
    public var edges: [Edge]
    public var crashes: [Crash]
    /// Why the crawl ended.
    public var ended: String

    public func screen(_ id: String) -> Screen? { screens.first { $0.id == id } }
}

/// What `crawl_app` may do.
struct CrawlOptions {
    var bundleID: String
    var maxActions = 60
    var maxScreens = 40
    var maxDepth = 6
    var seconds: TimeInterval = 120
    /// Labels never to tap, besides the built-in destructive words.
    var avoid: [String] = []
    var output: URL
}

/// Explores an app without a model: from a fresh launch, it taps every element on a screen it
/// has not tapped yet, depth first, notes where each tap leads, goes back by relaunching and
/// replaying the path to a screen that still has untried elements, and keeps every crash with the
/// steps that cause it. Skips text fields and anything that reads like deleting, paying, sending
/// or signing out. Needs the UI tree and the app tools: simulators, Android, iPhones with Mobdev
/// Runner in Developer Mode.
extension PhoneTools {
    static let crawlDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "crawl_app", title: "Crawl app",
            description:
                "Explore an app by itself, without a model: launch it fresh, tap every element it has not tried, note where each tap leads, and keep every crash with the steps that cause it as a flow. Writes a map of the screens with screenshots (crawl.json, report.md) and remembers it for navigate_to. Skips text fields and anything that reads like delete, pay, buy, send or sign out, plus avoid. Runs at most seconds (default 120; over a relay keep it under 80, or use `Mobdev crawl_app … --local`). Simulators, Android, and iPhones with the UI tree on.",
            inputSchema: schema(
                [
                    "bundle_id": ["type": "string"],
                    "max_actions": ["type": "integer", "minimum": 1, "maximum": 1000, "description": "Taps, default 60"],
                    "max_screens": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Default 40"],
                    "max_depth": ["type": "integer", "minimum": 1, "maximum": 20, "description": "Taps from launch, default 6"],
                    "seconds": ["type": "number", "description": "Time limit, default 120, at most 1800"],
                    "avoid": ["type": "array", "items": ["type": "string"], "description": "Labels never to tap"],
                    "output": ["type": "string", "description": "Folder on the Mac for the results; default in Mobdev's crawls folder"],
                ], required: ["bundle_id"], screenshot: false),
            readOnly: false),
        ToolDefinition(
            name: "navigate_to", title: "Navigate to screen",
            description:
                "Go to a screen of an app that crawl_app mapped, by its title or a text on it: relaunches the app and replays the steps the crawl found to reach it. Faster and steadier than finding the way again.",
            inputSchema: schema(
                [
                    "bundle_id": ["type": "string"],
                    "screen": ["type": "string", "description": "A screen's title, a text on it, or its id such as s4"],
                    "map": ["type": "string", "description": "A crawl.json on the Mac; default the newest crawl of the app"],
                ], required: ["bundle_id", "screen"]),
            readOnly: false),
    ]

    func runCrawlTool(_ name: String, _ args: Arguments, source: String) async throws -> ToolOutput? {
        switch name {
        case "crawl_app":
            let bundleID = try args.string("bundle_id")
            var options = CrawlOptions(bundleID: bundleID, output: URL(fileURLWithPath: "/"))
            options.maxActions = Int(try args.number("max_actions", default: 60, range: 1...1000))
            options.maxScreens = Int(try args.number("max_screens", default: 40, range: 1...500))
            options.maxDepth = Int(try args.number("max_depth", default: 6, range: 1...20))
            options.seconds = try args.number("seconds", default: 120, range: 5...1800)
            options.avoid = try args.stringArray("avoid")
            options.output = try args.has("output") ? Self.folder(try args.string("output")) : Self.newCrawlFolder(bundleID)
            let map = try await crawl(options, source: source)
            var output = ToolOutput(text: Self.summary(map, folder: options.output), data: (try? JSONValue.parse(Self.encode(map))) ?? .null)
            if let crash = map.crashes.first, let shot = crash.screenshot,
                let image = CGImage.load(options.output.appendingPathComponent(shot))
            {
                output.image = ImageTools.screenshot(image)
            }
            return output
        case "navigate_to":
            let bundleID = try args.string("bundle_id")
            let query = try args.string("screen")
            let file = try args.has("map") ? URL(fileURLWithPath: (try args.string("map") as NSString).expandingTildeInPath) : nil
            guard let map = Self.savedMap(bundleID, file: file) else {
                throw ToolFailure(
                    file.map { "\($0.path) is not a crawl of \(bundleID)." } ?? "There is no map of \(bundleID) yet. Run crawl_app first.")
            }
            guard let screen = Self.find(query, in: map) else {
                let titles = map.screens.prefix(30).map { "\($0.id) \($0.title)" }.joined(separator: ", ")
                throw ToolFailure("No screen of \(bundleID) matches \"\(query)\". Screens: \(titles).")
            }
            guard let apps = phone.apps else { throw ToolFailure("navigate_to needs the app tools: Developer Mode and Xcode for an iPhone.") }
            try await freshLaunch(bundleID, apps: apps)
            let flow = Flow(
                name: "To \(screen.title)",
                steps: screen.path.compactMap(Self.flowStep).flatMap { [$0, Flow.Step("wait_for_idle")] })
            let result = await run(flow, source: source)
            guard result.passed else {
                throw ToolFailure(
                    "Could not reach \(screen.title): \(result.steps.last?.text ?? "a step failed"). The app may have changed since the crawl; run crawl_app again.")
            }
            return ToolOutput(text: "On \(screen.title) (\(screen.id)) after launching \(bundleID) and \(screen.path.count) taps.")
        default:
            return nil
        }
    }

    // MARK: Crawling

    /// One look at the screen: its signature, title, and what can be tapped.
    private struct Snapshot {
        var signature: String
        var title: String
        var tree: [UIElement]
        var actions: [UIElement]
        /// What can be tapped, by role, identifier and label, to recognize the screen scrolled.
        var keys: Set<String>
    }

    /// Words of actions a crawler must never take, English and German.
    static let destructive = [
        "delete", "remove", "erase", "reset", "log out", "logout", "sign out", "signout", "pay", "buy", "purchase",
        "subscribe", "order", "send", "call", "löschen", "entfernen", "zurücksetzen", "abmelden", "bezahlen", "kaufen",
        "abonnieren", "bestellen", "senden", "anrufen",
    ]

    /// Roles that bring up a keyboard; the crawler does not type.
    static let fieldRoles: Set<String> = ["TextField", "SecureTextField", "SearchField", "TextArea", "EditText"]

    func crawl(_ options: CrawlOptions, source: String) async throws -> AppMap {
        guard let apps = phone.apps else {
            throw ToolFailure("crawl_app needs the app tools: Developer Mode and Xcode for an iPhone.")
        }
        // A tree that cannot be read right now, as on a home screen, is fine; no tree at all is not.
        if case .some(.none) = try? await phone.uiTree() {
            throw ToolFailure("crawl_app needs the UI tree: simulators, Android, or an iPhone with Mobdev Runner.")
        }
        try FileManager.default.createDirectory(
            at: options.output.appendingPathComponent("screens"), withIntermediateDirectories: true)
        let started = Date()
        let deadline = started.addingTimeInterval(options.seconds)
        var map = AppMap(
            app: options.bundleID, device: (phone as? any Device)?.name ?? "Device", started: started, seconds: 0,
            actions: 0, screens: [], edges: [], crashes: [], ended: "")
        var untried: [String: [UIElement]] = [:]
        var bySignature: [String: String] = [:]
        var keysByScreen: [String: (title: String, keys: Set<String>)] = [:]
        /// The screen this is: the same signature, or the same title with a good part of the same
        /// elements, as a list shows after scrolling (a quarter was enough in Settings; half left
        /// "Accessibility" and "Siri" in twice, 2026-10-07).
        func known(_ snapshot: Snapshot) -> String? {
            if let id = bySignature[snapshot.signature] { return id }
            let similar = keysByScreen.first { _, screen in
                guard screen.title == snapshot.title, !screen.keys.isEmpty || !snapshot.keys.isEmpty else { return false }
                let shared = Double(screen.keys.intersection(snapshot.keys).count)
                return shared / Double(screen.keys.union(snapshot.keys).count) >= 0.25
            }
            if let id = similar?.key { bySignature[snapshot.signature] = id }
            return similar?.key
        }

        func launch() async throws { try await freshLaunch(options.bundleID, apps: apps) }
        // Crash reports are named after the executable, which is usually the bundle's folder name.
        let installed = try? await apps.app(options.bundleID)
        let needles = [options.bundleID, installed?.name, installed?.location.flatMap(URL.init(string:))?
            .deletingPathExtension().lastPathComponent].compactMap { $0 }.filter { !$0.isEmpty }
        var knownReports = Set(((try? await apps.crashReports()) ?? []).map(\.name))
        /// A crash report of the app that was not there before, waited for a few seconds: macOS writes
        /// a simulator's report a moment after the crash.
        func newCrashReport() async -> CrashReportFile? {
            for _ in 0..<6 {
                let reports = (try? await apps.crashReports()) ?? []
                if let report = reports.first(where: { report in
                    !knownReports.contains(report.name) && needles.contains { report.process.localizedCaseInsensitiveContains($0) }
                }) {
                    knownReports.formUnion(reports.map(\.name))
                    return report
                }
                try? await pause(1)
            }
            return nil
        }
        func look() async throws -> Snapshot {
            let tree = try await readTree()
            return Self.snapshot(tree, avoid: options.avoid)
        }
        /// Adds a screen the first time it is seen and returns its id.
        func register(_ snapshot: Snapshot, path: [JSONValue], depth: Int) -> String {
            if let id = known(snapshot) { return id }
            let id = "s\(map.screens.count + 1)"
            var shot: String?
            if let frame = phone.frame(), let png = ImageTools.encode(ImageTools.scaled(frame, longEdge: 900), png: true),
                (try? png.data.write(to: options.output.appendingPathComponent("screens/\(id).png"))) != nil
            {
                shot = "screens/\(id).png"
            }
            map.screens.append(
                AppMap.Screen(
                    id: id, signature: snapshot.signature, title: snapshot.title,
                    elements: snapshot.actions.map(Self.describe), path: path, depth: depth, screenshot: shot))
            bySignature[snapshot.signature] = id
            keysByScreen[id] = (snapshot.title, snapshot.keys)
            untried[id] = depth < options.maxDepth ? snapshot.actions : []
            return id
        }

        try await launch()
        let home = try? await phone.frontmostApp()
        var current = register(try await look(), path: [], depth: 0)
        var ended = "Every element of every screen found was tried."
        // An error ends the crawl, but what it found so far is still written.
        do {
            crawling: while true {
                if Task.isCancelled { ended = "Cancelled."; break }
                if Date() >= deadline { ended = "The time limit of \(format(options.seconds)) s was reached."; break }
                if map.actions >= options.maxActions { ended = "The limit of \(options.maxActions) taps was reached."; break }
                guard let element = untried[current]?.first else {
                    // This screen is done: go to the first one that still has untried elements.
                    guard let next = map.screens.first(where: { !(untried[$0.id] ?? []).isEmpty }) else { break crawling }
                    try await launch()
                    for step in next.path.compactMap(Self.flowStep) {
                        _ = try await call(step.tool, arguments: .object(step.arguments.merging(["screenshot": false]) { $1 }), source: source, screenshotByDefault: false)
                        _ = try? await waitForIdle(timeout: 5, stable: 0.5)
                    }
                    let reached = try await look()
                    if known(reached) == next.id {
                        current = next.id
                    } else {
                        // The path no longer leads there, e.g. after state changed: give the screen up.
                        untried[next.id] = []
                        current = register(reached, path: next.path, depth: next.depth)
                    }
                    continue
                }
                untried[current]?.removeFirst()
                let before = try await look()
                // The element where it is now, in case the screen moved since it was listed.
                guard let target = Self.same(element, in: before.tree) else { continue }
                let step = Self.step(for: target, in: before.tree, size: try screenshotSize())
                try requireTouch()
                try await phone.tap(at: target.center, hold: 0.08)
                map.actions += 1
                _ = try? await waitForIdle(timeout: 6, stable: 0.6)
                let path = (map.screen(current)?.path ?? []) + [step.json]

                var crashed = apps.platform == .android ? await appEnded(apps.logs, options.bundleID) : nil
                var left: String?
                if crashed == nil, let home, let front = try? await phone.frontmostApp(), front != home {
                    // Out of the app: a crash, or a link that opened another app.
                    if let report = await newCrashReport() {
                        crashed = "crashed: \(report.name). Read it with crash_reports name \(report.name)."
                    } else {
                        left = front
                    }
                }
                if let status = crashed {
                    var crash = AppMap.Crash(screen: current, steps: path, status: status, screenshot: nil, flow: nil)
                    let number = map.crashes.count + 1
                    if let frame = phone.frame(), let png = ImageTools.encode(frame, png: true),
                        (try? png.data.write(to: options.output.appendingPathComponent("crash-\(number).png"))) != nil
                    {
                        crash.screenshot = "crash-\(number).png"
                    }
                    let flow = Flow(
                        name: "Crash \(number) of \(options.bundleID)",
                        steps: [Flow.Step("launch_app", ["bundle_id": .string(options.bundleID), "restart": true]), Flow.Step("wait_for_idle")]
                            + path.compactMap(Self.flowStep))
                    if (try? flow.encoded().write(to: options.output.appendingPathComponent("crash-\(number).json"))) != nil {
                        crash.flow = "crash-\(number).json"
                    }
                    map.crashes.append(crash)
                    try await launch()
                    current = register(try await look(), path: [], depth: 0)
                    continue
                }
                if let front = left {
                    map.edges.append(AppMap.Edge(from: current, to: "outside: \(front)", step: step.json))
                    try await apps.activate(options.bundleID)
                    _ = try? await waitForIdle(timeout: 5, stable: 0.5)
                    if known(try await look()) != current { try await launch() }
                    current = known(try await look()) ?? current
                    continue
                }
                let after = try await look()
                if known(after) == nil, map.screens.count >= options.maxScreens {
                    // Too many screens: note the tap, but do not explore further.
                    map.edges.append(AppMap.Edge(from: current, to: "unexplored", step: step.json))
                    try await launch()
                    current = known(try await look()) ?? map.screens[0].id
                    continue
                }
                let next = register(after, path: path, depth: (map.screen(current)?.depth ?? 0) + 1)
                if next != current { map.edges.append(AppMap.Edge(from: current, to: next, step: step.json)) }
                current = next
            }
        } catch {
            ended = "Stopped after an error: \(error)"
        }
        map.ended = ended
        map.seconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
        try Self.encode(map).write(to: options.output.appendingPathComponent("crawl.json"))
        try Data(Self.report(map).utf8).write(to: options.output.appendingPathComponent("report.md"))
        Self.saveMap(map)
        return map
    }

    /// The tree, retried for a few seconds while the app settles.
    private func readTree() async throws -> [UIElement] {
        var lastError: (any Error)?
        for _ in 0..<6 {
            do {
                if let tree = try await phone.uiTree() { return tree }
            } catch {
                lastError = error
            }
            try await pause(0.5)
        }
        throw lastError ?? ToolFailure("The UI tree could not be read.")
    }

    /// How the app ended, once it no longer runs: its log status, waiting a moment for a crash
    /// report to name it a crash. Nil while it runs.
    private func appEnded(_ logs: AppLogs, _ bundleID: String) async -> String? {
        guard let status = logs.status(for: bundleID), status != "running" else { return nil }
        for _ in 0..<6 where !(logs.status(for: bundleID)?.hasPrefix("crashed") ?? false) {
            try? await pause(0.5)
        }
        return logs.status(for: bundleID) ?? status
    }

    /// Where on the screen the element listed earlier is now, by identifier, else label and role.
    private static func same(_ element: UIElement, in tree: [UIElement]) -> UIElement? {
        let candidates = tree.filter { other in
            other.role == element.role
                && (element.identifier.isEmpty ? other.label == element.label : other.identifier == element.identifier)
        }
        return candidates.min {
            hypot($0.center.x - element.center.x, $0.center.y - element.center.y)
                < hypot($1.center.x - element.center.x, $1.center.y - element.center.y)
        }
    }

    private static func snapshot(_ tree: [UIElement], avoid: [String]) -> Snapshot {
        let screen = CGRect(x: 0, y: 0, width: 1, height: 1)
        let avoided = (destructive + avoid).map(ElementQuery.folded)
        let actions = ElementQuery.onePerPlace(
            tree.filter { element in
                guard element.tappable, element.enabled, !fieldRoles.contains(element.role) else { return false }
                let visible = element.frame.intersection(screen)
                guard !visible.isNull, visible.width > 0.01, visible.height > 0.01,
                    (0.02...0.98).contains(element.center.y), (0.01...0.99).contains(element.center.x)
                else { return false }
                let label = ElementQuery.folded(element.label)
                return !avoided.contains { !$0.isEmpty && label.contains($0) }
            }
        )
        .sorted { abs($0.frame.minY - $1.frame.minY) > 0.01 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
        // What can be tapped and the headings name a screen; changing text such as times does not.
        let parts = tree.filter { $0.tappable || $0.role == "Heading" }.map { "\($0.role)|\($0.identifier)|\($0.label)" }.sorted()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        // The status bar's clock is no title.
        let content = tree.filter { !$0.label.isEmpty && $0.frame.minY > 0.05 }
        let title = content.first { $0.role == "Heading" }?.label
            ?? content.filter { $0.frame.minY < 0.25 }.min { $0.frame.minY < $1.frame.minY }?.label
            ?? content.first?.label ?? "Untitled"
        let keys = Set(tree.filter(\.tappable).map { "\($0.role)|\($0.identifier)|\($0.label)" })
        return Snapshot(
            signature: String(hash, radix: 16), title: String(title.prefix(80)), tree: tree, actions: actions, keys: keys)
    }

    /// The step that taps `element` again later: by a unique identifier or label, else by position.
    private static func step(for element: UIElement, in tree: [UIElement], size: (width: Int, height: Int)) -> Flow.Step {
        if let arguments = FlowRecorder.element(at: element.center, in: tree) { return Flow.Step("tap_element", arguments) }
        return Flow.Step(
            "tap",
            [
                "x": .number((element.center.x * Double(size.width)).rounded()),
                "y": .number((element.center.y * Double(size.height)).rounded()),
            ])
    }

    static func flowStep(_ json: JSONValue) -> Flow.Step? {
        try? Flow.parse(.array([json])).steps.first
    }

    static func describe(_ element: UIElement) -> String {
        var parts = [element.role]
        if !element.label.isEmpty { parts.append("\"\(element.label)\"") }
        if !element.identifier.isEmpty { parts.append("id=\(element.identifier)") }
        return parts.joined(separator: " ")
    }

    // MARK: Results

    static func encode(_ map: AppMap) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(map)
    }

    static func summary(_ map: AppMap, folder: URL) -> String {
        var lines = [
            "Crawled \(map.app): \(map.screens.count) screens, \(map.actions) taps, \(map.crashes.count) crash\(map.crashes.count == 1 ? "" : "es") in \(String(format: "%.0f", map.seconds)) s. \(map.ended)"
        ]
        for crash in map.crashes {
            lines.append("Crash on \(map.screen(crash.screen)?.title ?? crash.screen): \(crash.status)")
            if let flow = crash.flow { lines.append("  Reproduce with run_flow path \(folder.appendingPathComponent(flow).path)") }
        }
        lines.append("Screens: " + map.screens.map { "\($0.id) \($0.title)" }.joined(separator: ", "))
        lines.append("Results: \(folder.appendingPathComponent("report.md").path)")
        return lines.joined(separator: "\n")
    }

    static func report(_ map: AppMap) -> String {
        var lines = [
            "# Crawl of \(map.app)", "",
            "\(map.screens.count) screens, \(map.actions) taps, \(map.crashes.count) crashes in \(String(format: "%.0f", map.seconds)) s on \(map.device). \(map.ended)",
        ]
        if !map.crashes.isEmpty {
            lines += ["", "## Crashes", ""]
            for (index, crash) in map.crashes.enumerated() {
                lines.append("### \(index + 1). On \(map.screen(crash.screen)?.title ?? crash.screen)")
                lines.append("")
                lines.append(crash.status)
                if let flow = crash.flow { lines.append("\nReproduce: `Mobdev flow \(flow)`") }
                if let shot = crash.screenshot { lines.append("\n![Crash \(index + 1)](\(shot))") }
                lines.append("")
            }
        }
        lines += ["", "## Screens", ""]
        for screen in map.screens {
            lines.append("### \(screen.id): \(screen.title)")
            lines.append("")
            lines.append("Depth \(screen.depth), \(screen.elements.count) tappable elements.")
            if let shot = screen.screenshot { lines.append("\n<img src=\"\(shot)\" width=\"240\">") }
            let outgoing = map.edges.filter { $0.from == screen.id }
            if !outgoing.isEmpty {
                lines.append("")
                for edge in outgoing {
                    let target = map.screen(edge.to).map { "\($0.id) \($0.title)" } ?? edge.to
                    lines.append("- `\(edge.step.compactString)` → \(target)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Saved maps

    static var mapsFolder: URL { MobdevPaths.home.appendingPathComponent("app-maps", isDirectory: true) }

    static func mapFile(_ bundleID: String) -> URL {
        mapsFolder.appendingPathComponent(String(bundleID.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }) + ".json")
    }

    static func saveMap(_ map: AppMap) {
        try? FileManager.default.createDirectory(at: mapsFolder, withIntermediateDirectories: true)
        try? encode(map).write(to: mapFile(map.app))
    }

    static func savedMap(_ bundleID: String, file: URL? = nil) -> AppMap? {
        guard let data = try? Data(contentsOf: file ?? mapFile(bundleID)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let map = try? decoder.decode(AppMap.self, from: data), map.app == bundleID else { return nil }
        return map
    }

    /// Starts an app afresh and waits until it shows something to tap. Android's launch is cheap
    /// and follows the app's log, which names a crash at once. On iOS the console launch failed now
    /// and then while other tools used devicectl (2026-10-07), so the app is stopped and started
    /// plainly, and a crash shows as a new report.
    func freshLaunch(_ bundleID: String, apps: AppBackend) async throws {
        if apps.platform == .android {
            _ = try await apps.launch(bundleID, arguments: [], environment: [:], restart: true)
        } else {
            _ = try? await apps.stop(bundleID)
            // devicectl failed now and then on a busy Mac; a second or third try went through.
            for attempt in 1...3 {
                do {
                    try await apps.activate(bundleID)
                    break
                } catch where attempt < 3 {
                    try await pause(Double(attempt) * 2)
                }
            }
        }
        // A launch screen stands still too: wait until there is something to tap.
        let ready = Date().addingTimeInterval(15)
        while Date() < ready {
            if let tree = try? await phone.uiTree(), tree.contains(where: { $0.tappable && $0.frame.minY > 0.06 }) { break }
            try await pause(0.5)
        }
        _ = try? await waitForIdle(timeout: 10, stable: 0.8)
    }

    /// By id, else an exact title, else a title or element containing the text, the shortest path first.
    static func find(_ query: String, in map: AppMap) -> AppMap.Screen? {
        if let byID = map.screen(query) { return byID }
        let needle = ElementQuery.folded(query)
        let exact = map.screens.filter { ElementQuery.folded($0.title) == needle }
        let loose = map.screens.filter {
            ElementQuery.folded($0.title).contains(needle) || $0.elements.contains { ElementQuery.folded($0).contains(needle) }
        }
        return (exact.isEmpty ? loose : exact).min { $0.depth < $1.depth }
    }

    static func newCrawlFolder(_ bundleID: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = String(bundleID.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" })
        let url = MobdevPaths.home.appendingPathComponent("crawls/\(name)-\(formatter.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func folder(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded, isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension CGImage {
    /// A PNG or JPEG file as an image.
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
