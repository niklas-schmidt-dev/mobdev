import Foundation
import os

public enum Log {
    private static let logger = Logger(subsystem: MobdevPaths.bundleIdentifier, category: "mobdev")

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

/// A small thread-safe box for state shared between queues.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    public func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    @discardableResult
    public func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Every call an agent makes, kept in memory so the app can show what is happening on the phone.
public final class ActivityLog: @unchecked Sendable {
    public struct Entry: Identifiable, Sendable, Equatable, Codable {
        public let id: UUID
        public let date: Date
        public let source: String
        public let tool: String
        public let summary: String
        public let failed: Bool
    }

    private let entries = Locked<[Entry]>([])
    private let limit: Int
    private let file: URL?
    private let observers = Locked<[@Sendable ([Entry]) -> Void]>([])

    /// With a `file`, entries are appended to it as JSON lines and the newest `limit` are loaded
    /// back, so a device's log keeps growing across launches.
    public init(limit: Int = 200, file: URL? = nil) {
        self.limit = limit
        self.file = file
        if let file { entries.set(Self.load(file, limit: limit)) }
    }

    public var all: [Entry] { entries.get() }

    public func record(source: String, tool: String, summary: String, failed: Bool) {
        // Whole milliseconds, as stored, so a reloaded entry equals the one recorded.
        let date = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
        let entry = Entry(id: UUID(), date: date, source: source, tool: tool, summary: summary, failed: failed)
        let snapshot = entries.withLock { list -> [Entry] in
            list.insert(entry, at: 0)
            if list.count > limit { list.removeLast(list.count - limit) }
            if let file, let line = try? Self.encoder.encode(entry) { Self.append(line + Data("\n".utf8), to: file) }
            return list
        }
        for observer in observers.get() { observer(snapshot) }
    }

    public func clear() {
        entries.withLock { list in
            list = []
            if let file { try? Data().write(to: file) }
        }
        for observer in observers.get() { observer([]) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static func append(_ data: Data, to file: URL) {
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    /// The newest `limit` entries, newest first. Compacts the file when it grew far beyond that.
    private static func load(_ file: URL, limit: Int) -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let lines = data.split(separator: UInt8(ascii: "\n"))
        let kept = lines.suffix(limit)
        if lines.count > limit * 4 {
            try? Data(kept.joined(separator: [UInt8(ascii: "\n")]) + [UInt8(ascii: "\n")]).write(to: file)
        }
        return kept.compactMap { try? decoder.decode(Entry.self, from: Data($0)) }.reversed()
    }

    public func observe(_ observer: @escaping @Sendable ([Entry]) -> Void) {
        observers.withLock { $0.append(observer) }
    }
}
