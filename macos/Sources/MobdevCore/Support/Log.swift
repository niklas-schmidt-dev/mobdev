import Foundation
import os

public enum Log {
    private static let logger = Logger(subsystem: "dev.mobdev.mac", category: "mobdev")

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
    public struct Entry: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let date: Date
        public let source: String
        public let tool: String
        public let summary: String
        public let failed: Bool
    }

    private let entries = Locked<[Entry]>([])
    private let limit: Int
    private let observers = Locked<[@Sendable ([Entry]) -> Void]>([])

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public var all: [Entry] { entries.get() }

    public func record(source: String, tool: String, summary: String, failed: Bool) {
        let entry = Entry(id: UUID(), date: Date(), source: source, tool: tool, summary: summary, failed: failed)
        let snapshot = entries.withLock { list -> [Entry] in
            list.insert(entry, at: 0)
            if list.count > limit { list.removeLast(list.count - limit) }
            return list
        }
        for observer in observers.get() { observer(snapshot) }
    }

    public func clear() {
        entries.set([])
        for observer in observers.get() { observer([]) }
    }

    public func observe(_ observer: @escaping @Sendable ([Entry]) -> Void) {
        observers.withLock { $0.append(observer) }
    }
}
