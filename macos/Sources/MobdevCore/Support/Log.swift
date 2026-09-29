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
    /// back, so a device's log keeps growing across launches; `older(than:limit:)` pages further
    /// back. The file keeps the newest `Self.fileLimit` entries.
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

    /// Entries kept on disk per log; the file is trimmed back to this once it holds twice as many.
    public static let fileLimit = 50_000

    /// Up to `limit` entries recorded before `date`, newest first, read from the file. Blocking;
    /// call off the main thread.
    public func older(than date: Date, limit: Int) -> [Entry] {
        guard let file, let data = try? Data(contentsOf: file) else { return [] }
        let decoder = Self.decoder
        var result: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)), entry.date < date else { continue }
            result.append(entry)
            if result.count == limit { break }
        }
        return result
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    /// The newest `limit` entries, newest first. Trims the file when it grew far beyond `fileLimit`.
    private static func load(_ file: URL, limit: Int) -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        if lines.count > fileLimit * 2 {
            let kept = lines.suffix(fileLimit)
            try? Data(kept.joined(separator: [UInt8(ascii: "\n")]) + [UInt8(ascii: "\n")]).write(to: file)
        }
        return lines.suffix(limit).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }.reversed()
    }

    public func observe(_ observer: @escaping @Sendable ([Entry]) -> Void) {
        observers.withLock { $0.append(observer) }
    }
}
