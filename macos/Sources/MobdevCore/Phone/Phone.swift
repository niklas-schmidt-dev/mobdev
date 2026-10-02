import CoreGraphics
import Foundation

/// How taps and keys reach a device.
public enum InputRoute: Sendable, Equatable {
    /// The Mac's Bluetooth keyboard and pointer, for iPhones and iPads.
    case bluetooth
    /// Straight into the device, e.g. "Simulator" or "adb"; ready whenever the device is.
    case direct(String)
}

public struct PhoneStatus: Sendable, Equatable {
    public var screen: ScreenState
    public var bluetooth: BluetoothState
    public var keyboardLayout: KeyboardLayout
    /// How the pointer reacted the last time it was checked; nil until then.
    public var pointer: PointerBehavior?
    public var input: InputRoute

    public init(
        screen: ScreenState, bluetooth: BluetoothState, keyboardLayout: KeyboardLayout, pointer: PointerBehavior? = nil,
        input: InputRoute = .bluetooth
    ) {
        self.screen = screen
        self.bluetooth = bluetooth
        self.keyboardLayout = keyboardLayout
        self.pointer = pointer
        self.input = input
    }

    public var frameSize: (width: Int, height: Int)? {
        if case .connected(_, let width, let height) = screen, width > 0, height > 0 { return (width, height) }
        return nil
    }

    /// Whether taps and keys can reach the device.
    public var inputReady: Bool {
        if case .direct = input { return screen.isConnected }
        return bluetooth.isConnected
    }

    public var isReady: Bool { frameSize != nil && inputReady }

    /// "Paired" style state of the input for people and agents.
    public var inputSummary: String {
        switch input {
        case .bluetooth: bluetooth.summary
        case .direct(let route): inputReady ? "Direct (\(route))" : "Not available"
        }
    }
}

/// What the tools need from a phone. The app uses `HardwareDevice`, `SimulatorDevice` and
/// `AndroidDevice`; tests use a fake.
public protocol PhoneBackend: Sendable {
    func status() -> PhoneStatus
    func frame() -> CGImage?
    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws
    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws
    func scroll(at point: NormalizedPoint, ticks: Int) async throws
    /// Scrolls sideways; positive `ticks` reveal content further right.
    func pan(at point: NormalizedPoint, ticks: Int) async throws
    func type(_ strokes: [KeyStroke]) async throws
    func press(_ stroke: KeyStroke) async throws
    func press(_ button: ConsumerUsage) async throws
    /// Moves the pointer to `point` without clicking and reads how it reacts. Nil when unknown.
    func checkPointer(at point: NormalizedPoint) async throws -> PointerBehavior?
    /// Installing, launching and debugging apps, for devices in Developer Mode. Nil when unavailable.
    var apps: AppBackend? { get }
    /// Opens an app by name without Spotlight and says what it opened. Nil: search with Spotlight.
    func openApp(named name: String) async throws -> String?
    /// Types text as a whole. False: the tools type it key by key with the keyboard layout.
    func typeText(_ text: String) async throws -> Bool
    /// The elements on screen from the accessibility tree. Nil where there is none (an iPhone).
    func uiTree() async throws -> [UIElement]?
}

/// A wheel as a swipe, for devices without one: each step moves the content by a little over 5% of
/// the screen, at most 60%. Positive ticks reveal content further down, or further right when
/// `sideways`, so the finger moves up or left.
func wheelSwipe(at point: NormalizedPoint, ticks: Int, sideways: Bool = false) -> (from: NormalizedPoint, to: NormalizedPoint) {
    let distance = min(Double(abs(ticks)) * 0.055, 0.6)
    let direction = ticks > 0 ? -1.0 : 1.0
    let start = min(max((sideways ? point.x : point.y) - direction * distance / 2, 0.05), 0.95)
    let end = min(max(start + direction * distance, 0.05), 0.95)
    return sideways
        ? (NormalizedPoint(x: start, y: point.y), NormalizedPoint(x: end, y: point.y))
        : (NormalizedPoint(x: point.x, y: start), NormalizedPoint(x: point.x, y: end))
}

extension PhoneBackend {
    public var apps: AppBackend? { nil }
    public func checkPointer(at point: NormalizedPoint) async throws -> PointerBehavior? { nil }
    public func openApp(named name: String) async throws -> String? { nil }
    public func typeText(_ text: String) async throws -> Bool { false }
    public func uiTree() async throws -> [UIElement]? { nil }
}
