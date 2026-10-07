import Foundation

/// Apps agents may not open: a banking app, mail, anything that pays or sends. Set in Mobdev's
/// settings (Agents › Blocked apps) or with MOBDEV_BLOCKED_APPS, a comma-separated list of names
/// and bundle IDs, for `Mobdev flow` and `Mobdev test`.
///
/// It stops `open_app`, `launch_app` and `activate`-style calls by name or bundle ID. It is a guard
/// rail against mistakes, not a sandbox: an agent can still tap the app's icon on the home screen.
public enum AppBlocklist {
    /// The list from the settings and the environment, read at most every two seconds.
    static func current() -> [String] {
        let now = Date()
        if let cached = cache.get(), now.timeIntervalSince(cached.at) < 2 { return cached.list }
        var list = AppSettings.load().blockedApps
        if let variable = ProcessInfo.processInfo.environment["MOBDEV_BLOCKED_APPS"] {
            list += variable.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        list = list.filter { !$0.isEmpty }
        cache.set((list, now))
        return list
    }

    private static let cache = Locked<(list: [String], at: Date)?>(nil)

    /// Forgets the cached list, after the settings changed.
    public static func reload() { cache.set(nil) }

    /// Whether `app`, a name or bundle ID, is on the list, ignoring case and accents. A name also
    /// matches a bundle ID with that name as one of its parts after the first ("Sparkasse" and
    /// de.sparkasse.app), and the other way round.
    static func isBlocked(_ app: String, in list: [String]) -> Bool {
        let needle = ElementQuery.folded(app)
        guard !needle.isEmpty else { return false }
        func names(in bundleID: String) -> ArraySlice<Substring> { bundleID.split(separator: ".").dropFirst() }
        return list.contains { entry in
            let blocked = ElementQuery.folded(entry)
            if blocked == needle { return true }
            switch (blocked.contains("."), needle.contains(".")) {
            case (false, true): return names(in: needle).contains { $0 == blocked }
            case (true, false): return names(in: blocked).contains { $0 == needle }
            default: return false
            }
        }
    }

    /// Throws when a call would open a blocked app.
    static func check(_ tool: String, _ args: Arguments, list: [String]? = nil) throws {
        let app: String?
        switch tool {
        case "open_app": app = args.value["name"]?.stringValue
        case "launch_app": app = args.value["bundle_id"]?.stringValue
        default: return
        }
        guard let app else { return }
        let list = list ?? current()
        guard !list.isEmpty, isBlocked(app, in: list) else { return }
        throw ToolFailure(
            "\(app) is on Mobdev's list of blocked apps, so agents may not open it. Ask the person at the Mac to open it, or to remove it from Settings › Agents in Mobdev.")
    }
}
