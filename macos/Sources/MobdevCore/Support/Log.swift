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
        /// When the call was made; for a collapsed entry, the last one.
        public let date: Date
        public let source: String
        public let tool: String
        public let summary: String
        public let failed: Bool
        /// How many identical calls in a row this entry stands for.
        public var count = 1
    }

    private let entries = Locked<[Entry]>([])
    private let limit: Int
    private let file: URL?
    private let observers = Locked<[@Sendable ([Entry]) -> Void]>([])
    /// Bytes of the file's last line when this log wrote it, so a collapsed entry can replace it.
    /// Only touched under `entries`' lock.
    private var lastLineLength: Int?

    /// With a `file`, entries are appended to it as JSON lines and the newest `limit` are loaded
    /// back, so a device's log keeps growing across launches; `older(than:limit:)` pages further
    /// back. The file keeps the newest `Self.fileLimit` entries.
    public init(limit: Int = 200, file: URL? = nil) {
        self.limit = limit
        self.file = file
        if let file { entries.set(Self.load(file, limit: limit)) }
    }

    public var all: [Entry] { entries.get() }

    /// With `collapsing`, a call identical to the newest entry (source, tool, summary and outcome)
    /// updates that entry's time and count instead of adding one, so polling does not flood the log.
    public func record(source: String, tool: String, summary: String, failed: Bool, collapsing: Bool = false) {
        // Whole milliseconds, as stored, so a reloaded entry equals the one recorded.
        let date = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
        let snapshot = entries.withLock { list -> [Entry] in
            if collapsing, let newest = list.first, newest.source == source, newest.tool == tool,
                newest.summary == summary, newest.failed == failed
            {
                let entry = Entry(
                    id: newest.id, date: date, source: source, tool: tool, summary: summary, failed: failed,
                    count: newest.count + 1)
                list[0] = entry
                write(entry, replacingLastLine: true)
            } else {
                let entry = Entry(id: UUID(), date: date, source: source, tool: tool, summary: summary, failed: failed)
                list.insert(entry, at: 0)
                if list.count > limit { list.removeLast(list.count - limit) }
                write(entry, replacingLastLine: false)
            }
            return list
        }
        for observer in observers.get() { observer(snapshot) }
    }

    public func clear() {
        entries.withLock { list in
            list = []
            lastLineLength = nil
            if let file { try? Data().write(to: file) }
        }
        for observer in observers.get() { observer([]) }
    }

    /// Under `entries`' lock. A replaced line is only overwritten when this log wrote it; otherwise
    /// the new version is appended and reading keeps the last line for each id.
    private func write(_ entry: Entry, replacingLastLine: Bool) {
        guard let file, let json = try? Self.encoder.encode(entry) else { return }
        let line = json + Data("\n".utf8)
        if replacingLastLine, let length = lastLineLength, Self.replaceTail(of: file, length: length, with: line) {
            lastLineLength = line.count
            return
        }
        Self.append(line, to: file)
        lastLineLength = line.count
    }

    private static func replaceTail(of file: URL, length: Int, with data: Data) -> Bool {
        guard let handle = try? FileHandle(forWritingTo: file) else { return false }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            guard end >= UInt64(length) else { return false }
            try handle.truncate(atOffset: end - UInt64(length))
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
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
        // The last line for an id is its newest version; older versions of it are skipped.
        var seen = Set<UUID>()
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)), seen.insert(entry.id).inserted,
                entry.date < date
            else { continue }
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
        var seen = Set<UUID>()
        return lines.suffix(limit).reversed().compactMap { line in
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)), seen.insert(entry.id).inserted else {
                return nil
            }
            return entry
        }
    }

    public func observe(_ observer: @escaping @Sendable ([Entry]) -> Void) {
        observers.withLock { $0.append(observer) }
    }
}

extension ActivityLog.Entry {
    /// Lines written before entries were collapsed have no count.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        source = try container.decode(String.self, forKey: .source)
        tool = try container.decode(String.self, forKey: .tool)
        summary = try container.decode(String.self, forKey: .summary)
        failed = try container.decode(Bool.self, forKey: .failed)
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
    }
}
