import Foundation

/// A point on the phone screen as fractions of its width and height, from the top-left corner.
public struct NormalizedPoint: Sendable, Equatable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var description: String { String(format: "(%.3f, %.3f)", x, y) }
}

public protocol ReportSink: Sendable {
    func send(_ id: ReportID, _ bytes: [UInt8]) throws
}

extension HIDPeripheral: ReportSink {}

/// Turns taps, swipes and text into HID reports. Everything runs on one serial queue, so
/// gestures from concurrent requests and live mouse input never interleave.
public final class HIDInput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.mobdev.input")
    private let sink: ReportSink
    /// Seconds between reports. BLE connection intervals are roughly 15-30 ms.
    private let step: TimeInterval
    private let wakeAfterIdle: TimeInterval?
    private var buttons: UInt8 = 0
    private var lastReport = Date.distantPast

    /// `wakeAfterIdle`: seconds without input after which a wake-up report goes first (nil: never).
    public init(sink: ReportSink, step: TimeInterval = 0.03, wakeAfterIdle: TimeInterval? = 1.5) {
        self.sink = sink
        self.step = step
        self.wakeAfterIdle = wakeAfterIdle
    }

    public func tap(at point: NormalizedPoint, hold: TimeInterval = 0.08) async throws {
        try await run {
            try self.pointer(point)
            self.pause(self.step * 2)
            try self.button(down: true)
            self.pause(hold)
            try self.button(down: false)
            self.pause(self.step)
        }
    }

    public func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {
        try await run {
            let steps = max(2, Int(duration / self.step))
            try self.pointer(start)
            self.pause(self.step * 2)
            try self.button(down: true)
            self.pause(self.step)
            for index in 1...steps {
                let t = Double(index) / Double(steps)
                try self.pointer(NormalizedPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                self.pause(duration / Double(steps))
            }
            self.pause(self.step)
            try self.button(down: false)
            self.pause(self.step)
        }
    }

    /// Scroll wheel at a point. Positive `ticks` reveal content further down, because iOS scrolls
    /// wheels naturally by default. One report per tick: iOS scrolls by the number of reports, not
    /// by their size, and hardly moves for the first one.
    public func scroll(at point: NormalizedPoint, ticks: Int) async throws {
        try await run {
            try self.pointer(point)
            self.pause(self.step * 2)
            for _ in 0..<abs(ticks) {
                try self.sink.send(.relativeMouse, HIDReportMap.relativeMouseReport(buttons: 0, wheel: ticks.signum()))
                self.pause(self.step)
            }
        }
    }

    public func move(to point: NormalizedPoint) async throws {
        try await run {
            try self.pointer(point)
            self.pause(self.step)
        }
    }

    /// Stops between keystrokes when the calling task is cancelled, e.g. when the agent's request
    /// timed out at the relay or its connection closed, so the text does not keep coming later.
    public func type(_ strokes: [KeyStroke]) async throws {
        let cancelled = Locked(false)
        try await withTaskCancellationHandler {
            try await run {
                for stroke in strokes {
                    if cancelled.get() { throw CancellationError() }
                    try self.sendStroke(stroke)
                }
            }
        } onCancel: {
            cancelled.set(true)
        }
    }

    public func press(_ stroke: KeyStroke) async throws {
        try await run { try self.sendStroke(stroke) }
    }

    public func consumer(_ usage: ConsumerUsage) async throws {
        try await run {
            try self.sink.send(.consumer, HIDReportMap.consumerReport(usage: usage.rawValue))
            self.pause(0.08)
            try self.sink.send(.consumer, HIDReportMap.consumerReport(usage: 0))
            self.pause(self.step)
        }
    }

    // MARK: Live control from the mirror view. Fire and forget, in order.

    public func pointerDown(at point: NormalizedPoint) {
        queue.async {
            try? self.wakeIfIdle()
            self.lastReport = Date()
            try? self.pointer(point)
            self.pause(self.step)
            try? self.button(down: true)
        }
    }

    public func pointerMove(to point: NormalizedPoint) {
        queue.async {
            try? self.pointer(point)
            self.lastReport = Date()
        }
    }

    public func pointerUp(at point: NormalizedPoint) {
        queue.async {
            try? self.pointer(point)
            self.pause(self.step)
            try? self.button(down: false)
            self.lastReport = Date()
        }
    }

    public func pressLive(_ stroke: KeyStroke) {
        queue.async {
            try? self.wakeIfIdle()
            try? self.sendStroke(stroke)
            self.lastReport = Date()
        }
    }

    // MARK: Queue-only helpers

    private func run(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.wakeIfIdle()
                    try body()
                    self.lastReport = Date()
                    continuation.resume()
                } catch {
                    // Never leave a button or key held after a failure.
                    self.buttons = 0
                    try? self.sink.send(.relativeMouse, HIDReportMap.relativeMouseReport(buttons: 0))
                    try? self.sink.send(.keyboard, HIDReportMap.keyboardReport(modifiers: 0, usage: nil))
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// iOS lets an idle Bluetooth keyboard doze and drops the first report that wakes it, which
    /// swallowed the first tap or key after a pause. An empty mouse report wakes it first.
    private func wakeIfIdle() throws {
        guard let wakeAfterIdle, Date().timeIntervalSince(lastReport) >= wakeAfterIdle else { return }
        try sink.send(.relativeMouse, HIDReportMap.relativeMouseReport(buttons: buttons))
        pause(step > 0 ? 0.2 : 0)
    }

    private func sendStroke(_ stroke: KeyStroke) throws {
        if stroke.modifiers != 0 {
            try sink.send(.keyboard, HIDReportMap.keyboardReport(modifiers: stroke.modifiers, usage: nil))
            pause(step)
        }
        try sink.send(.keyboard, HIDReportMap.keyboardReport(modifiers: stroke.modifiers, usage: stroke.usage))
        pause(step)
        try sink.send(.keyboard, HIDReportMap.keyboardReport(modifiers: stroke.modifiers, usage: nil))
        pause(step)
        if stroke.modifiers != 0 {
            try sink.send(.keyboard, HIDReportMap.keyboardReport(modifiers: 0, usage: nil))
            pause(step)
        }
    }

    /// iOS positions the pointer from the absolute report but ignores its buttons,
    /// so clicks go through the relative mouse.
    private func pointer(_ point: NormalizedPoint) throws {
        try sink.send(.absolutePointer, HIDReportMap.absolutePointerReport(x: point.x, y: point.y, buttons: buttons))
    }

    private func button(down: Bool) throws {
        buttons = down ? 1 : 0
        try sink.send(.relativeMouse, HIDReportMap.relativeMouseReport(buttons: buttons))
    }

    private func pause(_ seconds: TimeInterval) {
        if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
    }
}

/// Sends reports to one Bluetooth host, so each iPhone gets its own input.
public struct HostSink: ReportSink {
    public let peripheral: HIDPeripheral
    public let host: UUID

    public init(peripheral: HIDPeripheral, host: UUID) {
        self.peripheral = peripheral
        self.host = host
    }

    public func send(_ id: ReportID, _ bytes: [UInt8]) throws {
        try peripheral.send(id, bytes, to: host)
    }
}
