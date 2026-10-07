import Foundation

/// The bundle IDs and package names an app's repository declares, for a new project's
/// app.bundle_id: from an Expo app.json or app.config, an Xcode project or XcodeGen project.yml,
/// an Info.plist that names its bundle ID itself, Gradle's applicationId (else namespace, else
/// the manifest's package) and a Capacitor config.
public enum AppIdentifiers {
    public struct Found: Equatable, Sendable {
        public var id: String
        /// Where it is declared, such as "iOS: ios/App.xcodeproj", the likeliest first.
        public var sources: [String]
        /// iOS, Android or Capacitor, in the order of `sources`.
        public var platforms: [String]
    }

    /// The identifiers found in a repository, the likeliest app first: one that iOS and Android
    /// share, then one an app config names, then Xcode's, then Gradle's; a shorter one before its
    /// extensions such as a widget.
    public static func find(in repository: URL) -> [Found] {
        let root = ProjectList.normalized(repository)
        var hits: [(id: String, platform: String, rank: Int, source: String)] = []
        func add(_ ids: [String], _ platform: String, _ rank: Int, _ url: URL) {
            let relative = ProjectIcons.relativePath(url, in: root) ?? url.lastPathComponent
            for id in ids where isAppIdentifier(id) { hits.append((id, platform, rank, relative)) }
        }
        ProjectIcons.walk(root) { url, isFolder in
            let name = url.lastPathComponent
            if isFolder {
                if url.pathExtension == "xcodeproj" {
                    add(matches(of: #"PRODUCT_BUNDLE_IDENTIFIER = "?([^";\s]+)"?;"#, in: url.appendingPathComponent("project.pbxproj")), "iOS", 2, url)
                }
                return
            }
            switch name {
            case "app.json":
                let expo = json(url)?["expo"] as? [String: Any]
                add([(expo?["ios"] as? [String: Any])?["bundleIdentifier"]].compactMap { $0 as? String }, "iOS", 1, url)
                add([(expo?["android"] as? [String: Any])?["package"]].compactMap { $0 as? String }, "Android", 1, url)
            case "app.config.js", "app.config.ts", "app.config.mjs", "app.config.cjs":
                add(matches(of: #"bundleIdentifier\s*:\s*["'`]([^"'`$]+)["'`]"#, in: url), "iOS", 1, url)
                add(matches(of: #"\bpackage\s*:\s*["'`]([^"'`$]+)["'`]"#, in: url), "Android", 1, url)
            case "project.yml", "project.yaml":
                add(matches(of: #"PRODUCT_BUNDLE_IDENTIFIER:\s*["']?([A-Za-z0-9_.-]+)"#, in: url), "iOS", 2, url)
            case "build.gradle", "build.gradle.kts":
                let ids = matches(of: #"applicationId\s*=?\s*["']([^"'$]+)["']"#, in: url)
                add(ids.isEmpty ? matches(of: #"\bnamespace\s*=?\s*["']([^"'$]+)["']"#, in: url) : ids, "Android", 3, url)
            case "Info.plist":
                let plist = (try? Data(contentsOf: url)).flatMap {
                    try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
                }
                // A Mac app's, which Mobdev does not drive, names a minimum macOS and no iPhone.
                let mac = plist?["LSMinimumSystemVersion"] != nil && plist?["LSRequiresIPhoneOS"] == nil
                    && plist?["UIDeviceFamily"] == nil
                if !mac { add([plist?["CFBundleIdentifier"]].compactMap { $0 as? String }, "iOS", 3, url) }
            case "AndroidManifest.xml":
                add(matches(of: #"<manifest[^>]*\bpackage="([^"]+)""#, in: url), "Android", 4, url)
            case "capacitor.config.json":
                add([json(url)?["appId"]].compactMap { $0 as? String }, "Capacitor", 1, url)
            case "capacitor.config.ts", "capacitor.config.js":
                add(matches(of: #"appId\s*:\s*["'`]([^"'`$]+)["'`]"#, in: url), "Capacitor", 1, url)
            default:
                break
            }
        }
        var order: [String] = []
        var grouped: [String: [(platform: String, rank: Int, source: String)]] = [:]
        for hit in hits {
            if grouped[hit.id] == nil { order.append(hit.id) }
            if grouped[hit.id]?.contains(where: { $0.source == hit.source && $0.platform == hit.platform }) != true {
                grouped[hit.id, default: []].append((hit.platform, hit.rank, hit.source))
            }
        }
        let found = order.map { id -> (Found, Int, Int) in
            let entries = (grouped[id] ?? []).sorted { $0.rank < $1.rank }
            var platforms: [String] = []
            for entry in entries where !platforms.contains(entry.platform) { platforms.append(entry.platform) }
            let both = platforms.contains("iOS") && platforms.contains("Android")
            return (
                Found(id: id, sources: entries.map { "\($0.platform): \($0.source)" }, platforms: platforms),
                both ? 0 : 1, entries.first?.rank ?? 9
            )
        }
        return found.sorted { ($0.1, $0.2, $0.0.id.count, $0.0.id) < ($1.1, $1.2, $1.0.id.count, $1.0.id) }.map(\.0)
    }

    /// A reverse-DNS identifier that names an app, not a test bundle or a dependency.
    static func isAppIdentifier(_ id: String) -> Bool {
        guard id.range(of: #"^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression) != nil else { return false }
        let last = id.split(separator: ".").last.map { $0.lowercased() } ?? ""
        if last.hasSuffix("tests") || last == "test" { return false }
        return !id.hasPrefix("org.cocoapods.") && !id.hasPrefix("org.reactjs.")
    }

    private static func matches(of pattern: String, in file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
            let expression = try? NSRegularExpression(pattern: pattern)
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var ids: [String] = []
        for match in expression.matches(in: text, range: range) {
            guard let found = Range(match.range(at: 1), in: text) else { continue }
            let id = String(text[found])
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    private static func json(_ file: URL) -> [String: Any]? {
        (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
