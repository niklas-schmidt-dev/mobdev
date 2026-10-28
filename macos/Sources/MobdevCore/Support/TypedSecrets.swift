import Foundation

/// Passwords and codes of test accounts that agents type with `type_secret` without seeing them.
/// They live in `secrets.json`, readable only by this user (mode 0600) like the API token. Only
/// the user adds them, in the app's settings or with `Mobdev secret set`.
public enum TypedSecrets {
    public struct Entry: Codable, Equatable, Sendable {
        public var value: String
        /// Whether agents connected through a relay may type it too.
        public var relay: Bool
    }

    public struct Listing: Equatable, Sendable, Identifiable {
        public let name: String
        public let relay: Bool
        public var id: String { name }
    }

    static var file: URL { (folderOverride.get() ?? MobdevPaths.home).appendingPathComponent("secrets.json") }
    /// Tests keep their secrets elsewhere than the app's data; `Mobdev flow` and `Mobdev test` keep
    /// reading them from the data directory while their own files go to the artifacts directory.
    static let folderOverride = Locked<URL?>(nil)
    private static let lock = NSLock()

    /// Names like test-password or otp.backup: letters, digits, dots, dashes and underscores.
    public static func validate(name: String) throws {
        let allowed = name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0)
        }
        guard (1...64).contains(name.count), allowed else {
            throw ToolFailure("A secret's name has 1 to 64 letters, digits, dots, dashes or underscores.")
        }
    }

    public static func list() -> [Listing] {
        lock.withLock { load() }.map { Listing(name: $0.key, relay: $0.value.relay) }.sorted { $0.name < $1.name }
    }

    static func entry(_ name: String) -> Entry? { lock.withLock { load()[name] } }

    /// The value, when the caller may use it: agents through a relay only those allowed there.
    static func value(_ name: String, source: String) -> String? {
        guard let entry = entry(name), source != "relay" || entry.relay else { return nil }
        return entry.value
    }

    public static func set(_ name: String, value: String, relay: Bool) throws {
        try validate(name: name)
        guard !value.isEmpty else { throw ToolFailure("A secret needs a value.") }
        guard value.count <= PhoneTools.maxTypedCharacters else {
            throw ToolFailure("A secret has at most \(PhoneTools.maxTypedCharacters) characters.")
        }
        try lock.withLock {
            var entries = load()
            entries[name] = Entry(value: value, relay: relay)
            try save(entries)
        }
    }

    /// Changes only whether relayed agents may type it.
    public static func setRelay(_ name: String, _ relay: Bool) throws {
        try lock.withLock {
            var entries = load()
            guard entries[name] != nil else { return }
            entries[name]?.relay = relay
            try save(entries)
        }
    }

    @discardableResult
    public static func remove(_ name: String) throws -> Bool {
        try lock.withLock {
            var entries = load()
            guard entries.removeValue(forKey: name) != nil else { return false }
            try save(entries)
            return true
        }
    }

    private static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private static func save(_ entries: [String: Entry]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        // Written next to the file and moved over it, so it never exists with wider permissions.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".secrets-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: file)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
