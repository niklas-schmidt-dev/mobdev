import CoreGraphics
import Foundation

public struct PhoneStatus: Sendable, Equatable {
    public var screen: ScreenState
    public var bluetooth: BluetoothState
    public var keyboardLayout: KeyboardLayout

    public init(screen: ScreenState, bluetooth: BluetoothState, keyboardLayout: KeyboardLayout) {
        self.screen = screen
        self.bluetooth = bluetooth
        self.keyboardLayout = keyboardLayout
    }

    public var frameSize: (width: Int, height: Int)? {
        if case .connected(_, let width, let height) = screen, width > 0, height > 0 { return (width, height) }
        return nil
    }
}

/// What the tools need from a phone. The app uses `HardwarePhone`; tests use a fake.
public protocol PhoneBackend: Sendable {
    func status() -> PhoneStatus
    func frame() -> CGImage?
    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws
    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws
    func scroll(at point: NormalizedPoint, ticks: Int) async throws
    func type(_ strokes: [KeyStroke]) async throws
    func press(_ stroke: KeyStroke) async throws
    func press(_ button: ConsumerUsage) async throws
    /// Installing, launching and debugging apps, for devices in Developer Mode. Nil when unavailable.
    var apps: AppBackend? { get }
}

extension PhoneBackend {
    public var apps: AppBackend? { nil }
}
