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
}

/// A real iPhone: screen over USB, input over Bluetooth LE.
public final class HardwarePhone: PhoneBackend, @unchecked Sendable {
    public let capture: ScreenCapture
    public let peripheral: HIDPeripheral
    public let input: HIDInput
    private let layout: Locked<KeyboardLayout>

    public init(keyboardLayout: KeyboardLayout, onChange: @escaping @Sendable () -> Void) {
        capture = ScreenCapture(onStateChange: { _ in onChange() })
        peripheral = HIDPeripheral(onStateChange: { _ in onChange() })
        input = HIDInput(sink: peripheral)
        layout = Locked(keyboardLayout)
    }

    public func start(preferredCaptureDeviceID: String?) {
        peripheral.start()
        capture.start(preferredDeviceID: preferredCaptureDeviceID)
    }

    public var keyboardLayout: KeyboardLayout {
        get { layout.get() }
        set { layout.set(newValue) }
    }

    public func status() -> PhoneStatus {
        PhoneStatus(screen: capture.state, bluetooth: peripheral.state, keyboardLayout: layout.get())
    }

    public func frame() -> CGImage? { capture.frame() }

    public func tap(at point: NormalizedPoint, hold: TimeInterval) async throws {
        try await input.tap(at: point, hold: hold)
    }

    public func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {
        try await input.swipe(from: start, to: end, duration: duration)
    }

    public func scroll(at point: NormalizedPoint, ticks: Int) async throws {
        try await input.scroll(at: point, ticks: ticks)
    }

    public func type(_ strokes: [KeyStroke]) async throws {
        try await input.type(strokes)
    }

    public func press(_ stroke: KeyStroke) async throws {
        try await input.press(stroke)
    }

    public func press(_ button: ConsumerUsage) async throws {
        try await input.consumer(button)
    }
}
